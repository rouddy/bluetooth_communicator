package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class BluetoothBackgroundService : Service() {
    private val bluetoothManager by lazy {
        getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    }
    private val adapter: BluetoothAdapter?
        get() = bluetoothManager.adapter

    private val advertiser: BluetoothLeAdvertiser?
        get() = adapter?.bluetoothLeAdvertiser
    private val scanner: BluetoothLeScanner?
        get() = adapter?.bluetoothLeScanner

    private val activeConnections = ConcurrentHashMap<String, BluetoothGatt>()
    private val writableCharacteristics = ConcurrentHashMap<String, BluetoothGattCharacteristic>()
    // connectGatt() calls that haven't connected yet, kept so they can be cancelled. A
    // pending autoConnect would otherwise complete whenever the device shows up again.
    private val pendingConnections = ConcurrentHashMap<String, BluetoothGatt>()
    private val pendingBondAddresses = ConcurrentHashMap.newKeySet<String>()

    @Volatile
    private var gattServer: BluetoothGattServer? = null

    @Volatile
    private var serverCharacteristic: BluetoothGattCharacteristic? = null
    private val subscribedCentrals = ConcurrentHashMap<String, BluetoothDevice>()
    private val centralMtus = ConcurrentHashMap<String, Int>()
    private val preparedWrites = ConcurrentHashMap<String, ByteArrayOutputStream>()

    // One operation queue per link and role: our client link to a peer, and a central's
    // link to our GATT server.
    private val clientQueues = ConcurrentHashMap<String, GattOperationQueue>()
    private val serverQueues = ConcurrentHashMap<String, GattOperationQueue>()
    private val prefs by lazy { getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) }

    @Volatile
    private var isAdvertising = false

    @Volatile
    private var isCentralEnabled = false

    @Volatile
    private var isScanning = false

    private val handler = Handler(Looper.getMainLooper())
    private val scanStartLimiter = ScanStartLimiter()
    private val retryScan = Runnable {
        startScan()
        emitStatus()
    }

    @Volatile
    private var advertiseDeviceName = true

    override fun onCreate() {
        super.onCreate()
        BleEventBus.init(this)
        createNotificationChannel()
        startForegroundSafely()
        ContextCompat.registerReceiver(
            this,
            bondStateReceiver,
            IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED),
            // Sent by the Bluetooth app rather than the system uid, so NOT_EXPORTED
            // receivers never get it.
            ContextCompat.RECEIVER_EXPORTED
        )
        ContextCompat.registerReceiver(
            this,
            adapterStateReceiver,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
            ContextCompat.RECEIVER_EXPORTED
        )
    }

    private fun startForegroundSafely() {
        try {
            startForeground(
                NOTIFICATION_ID,
                buildNotification("Running"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } catch (e: Exception) {
            e.printStackTrace()
            BleEventBus.emit(
                mapOf(
                    "type" to "error",
                    "message" to "Failed to start foreground service: ${e.message}"
                )
            )
        }
    }

    @SuppressLint("MissingPermission")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A START_STICKY service that the system restarts after killing the process gets
        // a null intent; restore the saved state then, or it would sit idle.
        when (intent?.action ?: ACTION_RESTORE) {
            ACTION_RESTORE -> {
                restoreStateFromPrefs()
                emitCurrentConnections()
            }
            ACTION_START_ADVERTISING -> {
                prefs.edit().putBoolean(PREF_ADVERTISING, true).apply()
                startAdvertising()
            }
            ACTION_STOP_ADVERTISING -> {
                prefs.edit().putBoolean(PREF_ADVERTISING, false).apply()
                stopAdvertising()
            }
            ACTION_START_CENTRAL -> {
                prefs.edit().putBoolean(PREF_CENTRAL, true).apply()
                isCentralEnabled = true
                startScan()
            }
            ACTION_STOP_CENTRAL -> {
                prefs.edit().putBoolean(PREF_CENTRAL, false).apply()
                isCentralEnabled = false
                stopScan()
                disconnectAll()
            }
            ACTION_SCAN_NOW -> startScan()
            ACTION_CONNECT_DEVICE -> connectDevice(
                intent?.getStringExtra(EXTRA_DEVICE_ID),
                intent?.getBooleanExtra(EXTRA_PAIR, false) == true
            )
            ACTION_DISCONNECT_DEVICE -> disconnectDevice(intent?.getStringExtra(EXTRA_DEVICE_ID))
            ACTION_SEND_MESSAGE -> {
                val deviceId = intent?.getStringExtra(EXTRA_DEVICE_ID)
                val message = intent?.getStringExtra(EXTRA_MESSAGE)
                val messageId = intent?.getStringExtra(EXTRA_MESSAGE_ID)
                if (!deviceId.isNullOrBlank() && !message.isNullOrBlank()) {
                    sendMessage(deviceId, message, messageId)
                } else if (!deviceId.isNullOrBlank()) {
                    reportSend(deviceId, messageId, false, "Empty message")
                }
            }
        }
        emitStatus()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        isCentralEnabled = false
        isAdvertising = false
        isScanning = false
        stopAdvertising()
        stopScan()
        disconnectAll()
        runCatching { unregisterReceiver(bondStateReceiver) }
        runCatching { unregisterReceiver(adapterStateReceiver) }
        super.onDestroy()
    }

    @SuppressLint("MissingPermission")
    private fun restoreStateFromPrefs() {
        if (prefs.getBoolean(PREF_ADVERTISING, false)) {
            startAdvertising()
        }
        isCentralEnabled = prefs.getBoolean(PREF_CENTRAL, false)
        if (isCentralEnabled) {
            startScan()
            reconnectBondedDevices()
        }
    }

    // The service outlives the Flutter activity, so a newly attached Dart side has to be
    // told about links that were established before it started listening.
    private fun emitCurrentConnections() {
        (activeConnections.keys + subscribedCentrals.keys).forEach { address ->
            BleEventBus.emit(
                mapOf(
                    "type" to "connected",
                    "deviceId" to address
                )
            )
        }
    }

    @SuppressLint("MissingPermission")
    private fun reconnectBondedDevices() {
        val knownDeviceIds = loadRegisteredDeviceIds()
        if (knownDeviceIds.isEmpty()) {
            return
        }
        val bondState = BluetoothDevice.BOND_BONDED
        adapter?.bondedDevices
            ?.filter { device ->
                device.bondState == bondState && knownDeviceIds.contains(device.address)
            }
            ?.forEach { connectGattIfNeeded(it) }
    }

    private fun loadRegisteredDeviceIds(): Set<String> {
        val flutterPrefs = getSharedPreferences(FLUTTER_PREFS_NAME, Context.MODE_PRIVATE)
        val raw = flutterPrefs.getString(FLUTTER_REGISTERED_DEVICES_KEY, null) ?: return emptySet()
        return runCatching {
            val array = JSONArray(raw)
            buildSet {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val identifier = item.optString("identifier")
                    if (identifier.isNotBlank()) {
                        add(identifier)
                    }
                }
            }
        }.getOrElse { emptySet() }
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertising() {
        // advertiseCallback is set from the start request on, so a second request while
        // the first is still pending (e.g. ACTION_RESTORE followed by
        // ACTION_START_ADVERTISING) doesn't start a second, unstoppable advertising set.
        if (!hasBlePermissions() || advertiseCallback != null) {
            return
        }
        val bleAdvertiser = advertiser ?: return
        if (!openGattServerIfNeeded()) {
            BleEventBus.emit(
                mapOf(
                    "type" to "error",
                    "message" to "Failed to open GATT server"
                )
            )
            return
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .build()
        // A 128-bit UUID plus a long (e.g. Korean UTF-8) device name exceeds the
        // 31-byte legacy payload, so the name goes into the scan response instead.
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(SERVICE_PARCEL_UUID)
            .build()
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(advertiseDeviceName)
            .build()
        val callback = newAdvertiseCallback()
        advertiseCallback = callback
        bleAdvertiser.startAdvertising(settings, data, scanResponse, callback)
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertising() {
        advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        advertiseCallback = null
        isAdvertising = false
        closeGattServer()
    }

    @SuppressLint("MissingPermission")
    private fun openGattServerIfNeeded(): Boolean {
        if (gattServer != null) {
            return true
        }
        val server = bluetoothManager.openGattServer(this, gattServerCallback) ?: return false
        // Writing a message or subscribing needs an encrypted link, i.e. a bonded peer.
        // Unbonded centrals get "insufficient encryption", which makes iOS (and other
        // stacks) start pairing, instead of chatting under a rotating random address.
        val characteristic = BluetoothGattCharacteristic(
            MESSAGE_CHARACTERISTIC_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE_ENCRYPTED
        )
        characteristic.addDescriptor(
            BluetoothGattDescriptor(
                CLIENT_CONFIG_DESCRIPTOR_UUID,
                BluetoothGattDescriptor.PERMISSION_READ_ENCRYPTED or
                    BluetoothGattDescriptor.PERMISSION_WRITE_ENCRYPTED
            )
        )
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(characteristic)
        server.addService(service)
        gattServer = server
        serverCharacteristic = characteristic
        return true
    }

    @SuppressLint("MissingPermission")
    private fun closeGattServer() {
        val server = gattServer ?: return
        gattServer = null
        serverCharacteristic = null
        val centrals = subscribedCentrals.values.toList()
        subscribedCentrals.clear()
        centralMtus.clear()
        preparedWrites.clear()
        failQueues(serverQueues, "GATT server closed")
        centrals.forEach { central ->
            runCatching { server.cancelConnection(central) }
            emitDisconnectedIfUnlinked(central.address)
        }
        runCatching { server.close() }
    }

    @SuppressLint("MissingPermission")
    private fun startScan() {
        if (!hasBlePermissions() || !isCentralEnabled || isScanning) {
            return
        }
        val bleScanner = scanner ?: return
        // Defer instead of tripping Android's scan-start limit (see ScanStartLimiter).
        val delay = scanStartLimiter.delayBeforeStart(SystemClock.elapsedRealtime())
        if (delay > 0) {
            handler.removeCallbacks(retryScan)
            handler.postDelayed(retryScan, delay)
            return
        }
        val filters = listOf(
            ScanFilter.Builder()
                .setServiceUuid(SERVICE_PARCEL_UUID)
                .build()
        )
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        bleScanner.startScan(filters, settings, scanCallback)
        isScanning = true
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        handler.removeCallbacks(retryScan)
        scanner?.stopScan(scanCallback)
        isScanning = false
    }

    @SuppressLint("MissingPermission")
    private fun connectDevice(deviceId: String?, pair: Boolean) {
        if (deviceId.isNullOrBlank() || !hasBlePermissions()) {
            return
        }
        val device = runCatching { adapter?.getRemoteDevice(deviceId) }.getOrNull() ?: return
        when {
            device.bondState == BluetoothDevice.BOND_BONDED -> connectGattIfNeeded(device)
            // Only a user-initiated connect may show the system pairing dialog;
            // replaying saved devices on launch must not.
            pair -> bondDevice(device)
        }
    }

    // Unbonded phones advertise with rotating random addresses, so the same peer would
    // get a new deviceId every few minutes. Bonding exchanges identity keys, after which
    // the stack resolves the peer to one stable address.
    @SuppressLint("MissingPermission")
    private fun bondDevice(device: BluetoothDevice) {
        val address = device.address ?: return
        if (!pendingBondAddresses.add(address)) {
            return
        }
        if (device.bondState == BluetoothDevice.BOND_BONDING) {
            return
        }
        if (!device.createBond()) {
            pendingBondAddresses.remove(address)
            emitError("Pairing with $address could not be started")
        }
    }

    @SuppressLint("MissingPermission")
    private fun connectGattIfNeeded(device: BluetoothDevice) {
        val address = device.address ?: return
        if (activeConnections.containsKey(address) || pendingConnections.containsKey(address)) {
            return
        }
        // Background (autoConnect) connections only work with identity addresses.
        // Unbonded peers advertise with a resolvable private address, which the stack
        // rejects for background connect (status 133/135), so connect directly instead.
        val autoConnect = device.bondState == BluetoothDevice.BOND_BONDED
        val gatt = device.connectGatt(this, autoConnect, gattCallback, BluetoothDevice.TRANSPORT_LE)
            ?: return
        pendingConnections[address] = gatt
    }

    @SuppressLint("MissingPermission")
    private fun disconnectDevice(deviceId: String?) {
        if (deviceId.isNullOrBlank()) {
            return
        }
        pendingBondAddresses.remove(deviceId)
        writableCharacteristics.remove(deviceId)
        listOfNotNull(pendingConnections.remove(deviceId), activeConnections.remove(deviceId))
            .forEach { gatt ->
                runCatching {
                    gatt.disconnect()
                    gatt.close()
                }
            }
        subscribedCentrals.remove(deviceId)?.let { central ->
            centralMtus.remove(deviceId)
            preparedWrites.remove(deviceId)
            runCatching { gattServer?.cancelConnection(central) }
        }
        clientQueues.remove(deviceId)?.failAll("Disconnected")
        serverQueues.remove(deviceId)?.failAll("Disconnected")
        // close() unregisters the client callback, so onConnectionStateChange won't report this.
        emitDisconnectedIfUnlinked(deviceId)
        emitStatus()
    }

    @SuppressLint("MissingPermission")
    private fun disconnectAll() {
        val entries = activeConnections.values.toList()
        val pending = pendingConnections.values.toList()
        activeConnections.clear()
        pendingConnections.clear()
        writableCharacteristics.clear()
        failQueues(clientQueues, "Disconnected")
        pending.forEach { runCatching { it.close() } }
        entries.forEach {
            runCatching {
                it.disconnect()
                it.close()
            }
            // close() unregisters the callback, so onConnectionStateChange won't report this.
            emitDisconnectedIfUnlinked(it.device.address)
        }
    }

    @SuppressLint("MissingPermission")
    private fun sendMessage(deviceId: String, message: String, messageId: String?) {
        val payload = message.toByteArray(Charsets.UTF_8)
        val gatt = activeConnections[deviceId]
        val characteristic = writableCharacteristics[deviceId]
        if (gatt == null || characteristic == null) {
            // Not our GATT client link; the peer may be a central subscribed to our server.
            notifyCentral(deviceId, payload, messageId)
            return
        }
        // Longer values than an attribute can hold are rejected by the peer.
        if (payload.size > MAX_ATTRIBUTE_LENGTH) {
            reportSend(
                deviceId,
                messageId,
                false,
                "Message too long (${payload.size}/$MAX_ATTRIBUTE_LENGTH bytes)"
            )
            return
        }
        clientQueue(deviceId).enqueue(
            GattOperationQueue.Operation(
                start = { writeMessage(gatt, characteristic, payload) },
                onComplete = { success, error -> reportSend(deviceId, messageId, success, error) }
            )
        )
    }

    @SuppressLint("MissingPermission")
    private fun writeMessage(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        payload: ByteArray
    ): Boolean {
        val writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(characteristic, payload, writeType) ==
                BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                characteristic.value = payload
                characteristic.writeType = writeType
                gatt.writeCharacteristic(characteristic)
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun notifyCentral(deviceId: String, payload: ByteArray, messageId: String?) {
        val central = subscribedCentrals[deviceId]
        val server = gattServer
        val characteristic = serverCharacteristic
        if (central == null || server == null || characteristic == null) {
            reportSend(deviceId, messageId, false, "No writable BLE connection for $deviceId")
            return
        }
        // A notification can't be split, so it must fit in a single ATT packet.
        val maxPayload = (centralMtus[deviceId] ?: DEFAULT_ATT_MTU) - ATT_HEADER_SIZE
        if (payload.size > maxPayload) {
            reportSend(deviceId, messageId, false, "Message too long (${payload.size}/$maxPayload bytes)")
            return
        }
        serverQueues.getOrPut(deviceId) { GattOperationQueue() }.enqueue(
            GattOperationQueue.Operation(
                start = {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        server.notifyCharacteristicChanged(central, characteristic, false, payload) ==
                            BluetoothStatusCodes.SUCCESS
                    } else {
                        @Suppress("DEPRECATION")
                        run {
                            characteristic.value = payload
                            server.notifyCharacteristicChanged(central, characteristic, false)
                        }
                    }
                },
                onComplete = { success, error -> reportSend(deviceId, messageId, success, error) }
            )
        )
    }

    private fun clientQueue(address: String) =
        clientQueues.getOrPut(address) { GattOperationQueue() }

    private fun failQueues(queues: ConcurrentHashMap<String, GattOperationQueue>, error: String) {
        val drained = queues.values.toList()
        queues.clear()
        drained.forEach { it.failAll(error) }
    }

    /**
     * Reports the outcome of a sendMessage call. Dart tracks each outgoing message by
     * [messageId]; without one, only failures are reported, as a generic error.
     */
    private fun reportSend(deviceId: String, messageId: String?, success: Boolean, error: String?) {
        if (messageId == null) {
            if (!success) {
                emitError("Sending to $deviceId failed: $error")
            }
            return
        }
        BleEventBus.emit(
            if (success) {
                mapOf("type" to "messageSent", "deviceId" to deviceId, "messageId" to messageId)
            } else {
                mapOf(
                    "type" to "messageFailed",
                    "deviceId" to deviceId,
                    "messageId" to messageId,
                    "error" to (error ?: "Unknown error")
                )
            }
        )
    }

    private fun emitMessage(deviceId: String, payload: ByteArray) {
        val message = payload.toString(Charsets.UTF_8)
        BleEventBus.emit(
            mapOf(
                "type" to "message",
                "deviceId" to deviceId,
                "message" to message,
                "receivedAt" to System.currentTimeMillis()
            )
        )
        notifyIncomingMessage(deviceId, message)
    }

    // Two bonded phones that both run central mode end up linked twice (each is the
    // other's central), so a peer only counts as disconnected once neither link is left.
    private fun emitDisconnectedIfUnlinked(address: String) {
        if (activeConnections.containsKey(address) || subscribedCentrals.containsKey(address)) {
            return
        }
        BleEventBus.emit(
            mapOf(
                "type" to "disconnected",
                "deviceId" to address
            )
        )
    }

    private fun emitError(message: String) {
        BleEventBus.emit(
            mapOf(
                "type" to "error",
                "message" to message
            )
        )
    }

    private fun emitStatus() {
        val connectionCount = (activeConnections.keys + subscribedCentrals.keys).size
        val status = when {
            adapter?.state != BluetoothAdapter.STATE_ON -> STATUS_BLUETOOTH_OFF
            connectionCount > 0 -> {
                buildString {
                    if (isAdvertising) {
                        append("advertising ")
                    }
                    if (isScanning) {
                        append("scanning ")
                    }
                    append("connected:$connectionCount")
                }.trim()
            }
            isAdvertising || isScanning -> {
                buildString {
                    if (isAdvertising) {
                        append("advertising ")
                    }
                    if (isScanning) {
                        append("scanning ")
                    }
                }.trim()
            }
            else -> "idle"
        }
        BleEventBus.emit(
            mapOf(
                "type" to "status",
                "status" to status
            )
        )
        updateNotification(status)
    }

    private fun updateNotification(content: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(content))
    }

    private fun buildNotification(content: String): Notification {
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Bluetooth Communicator")
            .setContentText(content)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Bluetooth background service",
            NotificationManager.IMPORTANCE_LOW
        )
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
        manager.createNotificationChannel(
            NotificationChannel(
                MESSAGE_CHANNEL_ID,
                "Bluetooth 메시지",
                NotificationManager.IMPORTANCE_DEFAULT
            )
        )
    }

    /**
     * Posts a notification for a message received while the app isn't in the
     * foreground; otherwise it would only show up once the user happens to open the app.
     * One notification per device (tagged with its address), opening the app on tap.
     */
    @SuppressLint("MissingPermission")
    private fun notifyIncomingMessage(deviceId: String, message: String) {
        val manager = NotificationManagerCompat.from(this)
        if (BleEventBus.appInForeground || !manager.areNotificationsEnabled()) {
            return
        }
        // Bonded peers have a name; fall back to the address.
        val title = runCatching { adapter?.getRemoteDevice(deviceId)?.name }.getOrNull() ?: deviceId
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification = NotificationCompat.Builder(this, MESSAGE_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(message)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .build()
        manager.notify(deviceId, MESSAGE_NOTIFICATION_ID, notification)
    }

    private fun hasBlePermissions(): Boolean {
        val permissions = listOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE
        )
        return permissions.all { permission ->
            ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
        }
    }

    // A new callback per start: after Bluetooth power-cycles, the framework still holds
    // the previous callback (it can't be stopped while the adapter is off), and starting
    // with it again fails with ADVERTISE_FAILED_ALREADY_STARTED.
    private var advertiseCallback: AdvertiseCallback? = null

    private fun newAdvertiseCallback() = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            if (this !== advertiseCallback) {
                return
            }
            isAdvertising = true
            emitStatus()
        }

        override fun onStartFailure(errorCode: Int) {
            if (this !== advertiseCallback) {
                return
            }
            if (errorCode == AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE && advertiseDeviceName) {
                // The device name doesn't fit even in the scan response; retry without it.
                advertiseDeviceName = false
                advertiseCallback = null
                startAdvertising()
                return
            }
            advertiseCallback = null
            isAdvertising = false
            BleEventBus.emit(
                mapOf(
                    "type" to "error",
                    "message" to "Advertising failed: $errorCode"
                )
            )
            emitStatus()
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanFailed(errorCode: Int) {
            if (errorCode == SCAN_FAILED_ALREADY_STARTED) {
                // This callback is still registered and scanning.
                return
            }
            // Without this, isScanning stayed true and every later startScan/scanNow
            // returned early: the app showed "scanning" while nothing was scanning.
            isScanning = false
            emitError("Scan failed (error $errorCode)")
            emitStatus()
            // Most failures are transient; the "too frequently" limit (error 6) is
            // measured over 30 s, so retry after that.
            handler.removeCallbacks(retryScan)
            if (isCentralEnabled) {
                handler.postDelayed(retryScan, SCAN_RETRY_DELAY_MS)
            }
        }

        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            val device = result?.device ?: return
            val address = device.address ?: return
            val knownDeviceIds = loadRegisteredDeviceIds()
            BleEventBus.emit(
                mapOf(
                    "type" to "discovered",
                    "deviceId" to address,
                    "name" to (result.scanRecord?.deviceName ?: device.name ?: "")
                )
            )
            if (
                isCentralEnabled &&
                device.bondState == BluetoothDevice.BOND_BONDED &&
                knownDeviceIds.contains(address)
            ) {
                connectGattIfNeeded(device)
            }
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val address = gatt.device.address ?: return
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    pendingConnections.remove(address)
                    activeConnections[address] = gatt
                    // The default MTU leaves 20 bytes per packet (6 Korean characters), and
                    // the peer's notifications can't be split, so negotiate a larger MTU
                    // before discovering services.
                    if (!gatt.requestMtu(MAX_ATT_MTU)) {
                        gatt.discoverServices()
                    }
                    BleEventBus.emit(
                        mapOf(
                            "type" to "connected",
                            "deviceId" to address
                        )
                    )
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    pendingConnections.remove(address)
                    val wasConnected = activeConnections.remove(address) != null
                    writableCharacteristics.remove(address)
                    clientQueues.remove(address)?.failAll("Disconnected")
                    runCatching { gatt.close() }
                    if (!wasConnected && status != BluetoothGatt.GATT_SUCCESS) {
                        emitError("Connection to $address failed (status $status)")
                    }
                    emitDisconnectedIfUnlinked(address)
                    if (
                        isCentralEnabled &&
                        gatt.device.bondState == BluetoothDevice.BOND_BONDED &&
                        loadRegisteredDeviceIds().contains(address)
                    ) {
                        connectGattIfNeeded(gatt.device)
                    }
                }
            }
            emitStatus()
        }

        @SuppressLint("MissingPermission")
        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            gatt.discoverServices()
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            val address = gatt.device.address ?: return
            clientQueues[address]?.complete(
                status == BluetoothGatt.GATT_SUCCESS,
                "Write failed (status $status)"
            )
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            val address = gatt.device.address ?: return
            clientQueues[address]?.complete(
                status == BluetoothGatt.GATT_SUCCESS,
                "Descriptor write failed (status $status)"
            )
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                return
            }
            val address = gatt.device.address ?: return
            val characteristic = gatt.getService(SERVICE_UUID)
                ?.getCharacteristic(MESSAGE_CHARACTERISTIC_UUID)
            if (characteristic != null) {
                writableCharacteristics[address] = characteristic
                gatt.setCharacteristicNotification(characteristic, true)
                val cccd = characteristic.getDescriptor(CLIENT_CONFIG_DESCRIPTOR_UUID)
                if (cccd != null) {
                    // Queued like the message writes, so a message sent right after
                    // connecting doesn't collide with the subscription.
                    clientQueue(address).enqueue(
                        GattOperationQueue.Operation(
                            start = { enableNotifications(gatt, cccd) },
                            onComplete = { success, error ->
                                if (!success) {
                                    emitError("Subscribing to $address failed: $error")
                                }
                            }
                        )
                    )
                }
            }
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid != MESSAGE_CHARACTERISTIC_UUID) {
                return
            }
            val address = gatt.device.address ?: return
            emitMessage(address, characteristic.value ?: return)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            if (characteristic.uuid != MESSAGE_CHARACTERISTIC_UUID) {
                return
            }
            val address = gatt.device.address ?: return
            emitMessage(address, value)
        }
    }

    @SuppressLint("MissingPermission")
    private fun enableNotifications(gatt: BluetoothGatt, cccd: BluetoothGattDescriptor): Boolean {
        val value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(cccd, value) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                cccd.value = value
                gatt.writeDescriptor(cccd)
            }
        }
    }

    // The stack tears down advertising, scans, GATT links, and the GATT server when
    // Bluetooth turns off, mostly without callbacks, so reset our state to match and
    // report the links as gone. Turning it back on restores the saved modes.
    private val adapterStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> onBluetoothOff()
                BluetoothAdapter.STATE_ON -> restoreStateFromPrefs()
            }
            emitStatus()
        }
    }

    private fun onBluetoothOff() {
        advertiseCallback = null
        isAdvertising = false
        isScanning = false
        pendingBondAddresses.clear()
        closeGattServer()
        disconnectAll()
    }

    private val bondStateReceiver = object : BroadcastReceiver() {
        @SuppressLint("MissingPermission")
        override fun onReceive(context: Context, intent: Intent) {
            val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            } ?: return
            val address = device.address ?: return
            val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
            if (!pendingBondAddresses.contains(address)) {
                return
            }
            when (state) {
                BluetoothDevice.BOND_BONDED -> {
                    pendingBondAddresses.remove(address)
                    connectGattIfNeeded(device)
                }
                BluetoothDevice.BOND_NONE -> {
                    pendingBondAddresses.remove(address)
                    emitError("Pairing with $address failed")
                }
            }
        }
    }

    // Peripheral role: a remote central writes messages to our characteristic and
    // subscribes to it to receive our replies as notifications.
    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            // This fires for every LE link to this phone (watches, other apps), so only
            // centrals that subscribed to our characteristic count as peers.
            if (newState != BluetoothProfile.STATE_DISCONNECTED) {
                return
            }
            val address = device.address ?: return
            centralMtus.remove(address)
            preparedWrites.remove(address)
            serverQueues.remove(address)?.failAll("Disconnected")
            if (subscribedCentrals.remove(address) != null) {
                emitDisconnectedIfUnlinked(address)
                emitStatus()
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            val address = device.address ?: return
            serverQueues[address]?.complete(
                status == BluetoothGatt.GATT_SUCCESS,
                "Notification failed (status $status)"
            )
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            val address = device.address ?: return
            centralMtus[address] = mtu
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            val address = device.address ?: return
            if (characteristic.uuid != MESSAGE_CHARACTERISTIC_UUID) {
                if (responseNeeded) {
                    gattServer?.sendResponse(
                        device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null
                    )
                }
                return
            }
            val bytes = value ?: ByteArray(0)
            if (preparedWrite) {
                // Long write: chunks arrive in order and are delivered on onExecuteWrite.
                preparedWrites.getOrPut(address) { ByteArrayOutputStream() }.write(bytes)
            } else {
                emitMessage(address, bytes)
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
        }

        @SuppressLint("MissingPermission")
        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            val address = device.address ?: return
            val buffer = preparedWrites.remove(address)
            if (execute && buffer != null) {
                emitMessage(address, buffer.toByteArray())
            }
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            descriptor: BluetoothGattDescriptor
        ) {
            val value = if (subscribedCentrals.containsKey(device.address)) {
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            } else {
                BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
            }
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            val address = device.address ?: return
            if (descriptor.uuid == CLIENT_CONFIG_DESCRIPTOR_UUID) {
                val subscribed = value?.contentEquals(
                    BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                ) == true
                val changed = if (subscribed) {
                    subscribedCentrals.put(address, device) == null
                } else {
                    subscribedCentrals.remove(address) != null
                }
                if (changed) {
                    if (subscribed) {
                        BleEventBus.emit(
                            mapOf(
                                "type" to "connected",
                                "deviceId" to address
                            )
                        )
                    } else {
                        serverQueues.remove(address)?.failAll("Unsubscribed")
                        emitDisconnectedIfUnlinked(address)
                    }
                    emitStatus()
                }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
        }
    }

    companion object {
        const val ACTION_RESTORE = "ble.action.RESTORE"
        const val ACTION_START_ADVERTISING = "ble.action.START_ADVERTISING"
        const val ACTION_STOP_ADVERTISING = "ble.action.STOP_ADVERTISING"
        const val ACTION_START_CENTRAL = "ble.action.START_CENTRAL"
        const val ACTION_STOP_CENTRAL = "ble.action.STOP_CENTRAL"
        const val ACTION_SCAN_NOW = "ble.action.SCAN_NOW"
        const val ACTION_CONNECT_DEVICE = "ble.action.CONNECT_DEVICE"
        const val ACTION_SEND_MESSAGE = "ble.action.SEND_MESSAGE"
        const val ACTION_DISCONNECT_DEVICE = "ble.action.DISCONNECT_DEVICE"

        const val EXTRA_DEVICE_ID = "extra.device.id"
        const val EXTRA_MESSAGE = "extra.message"
        const val EXTRA_MESSAGE_ID = "extra.message.id"
        const val EXTRA_PAIR = "extra.pair"

        // Status reported while the adapter is off; Dart shows a banner for it. iOS uses the
        // same string.
        const val STATUS_BLUETOOTH_OFF = "bluetooth-off"

        private const val PREFS_NAME = "ble_service_prefs"
        private const val PREF_ADVERTISING = "pref_advertising"
        private const val PREF_CENTRAL = "pref_central"
        private const val FLUTTER_PREFS_NAME = "FlutterSharedPreferences"
        private const val FLUTTER_REGISTERED_DEVICES_KEY =
            "flutter.prefs_registered_devices"
        private const val NOTIFICATION_CHANNEL_ID = "ble_background"
        private const val NOTIFICATION_ID = 2001
        const val MESSAGE_CHANNEL_ID = "ble_messages"
        const val MESSAGE_NOTIFICATION_ID = 3001
        private val SERVICE_UUID = UUID.fromString("1f9ed31d-b738-4d4c-a6d8-86dbf0f9c001")
        private val SERVICE_PARCEL_UUID = ParcelUuid(SERVICE_UUID)
        private val MESSAGE_CHARACTERISTIC_UUID =
            UUID.fromString("db912050-2e4e-4c4e-a543-e89121e57595")
        private const val DEFAULT_ATT_MTU = 23
        private const val MAX_ATT_MTU = 517
        private const val ATT_HEADER_SIZE = 3
        private const val MAX_ATTRIBUTE_LENGTH = 512
        private const val SCAN_RETRY_DELAY_MS = 30_000L
        private val CLIENT_CONFIG_DESCRIPTOR_UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
