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
import androidx.core.content.ContextCompat
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.EngineEvent
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Role
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Owns advertising (with the GATT server), scanning, and GATT client connections, and
 * carries the protocol's frames for [BleRuntime.engine]: one link per GATT client
 * connection (we're central) and one per subscribed central (we're peripheral).
 * Everything that touches the engine runs on the main looper, so GATT callbacks post
 * their work there.
 */
class BluetoothBackgroundService : Service(), BleTransport {
    private val bluetoothManager by lazy {
        getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    }
    private val adapter: BluetoothAdapter?
        get() = bluetoothManager.adapter

    private val advertiser: BluetoothLeAdvertiser?
        get() = adapter?.bluetoothLeAdvertiser
    private val scanner: BluetoothLeScanner?
        get() = adapter?.bluetoothLeScanner

    private val engine
        get() = BleRuntime.engine

    private val activeConnections = ConcurrentHashMap<String, BluetoothGatt>()
    private val writableCharacteristics = ConcurrentHashMap<String, BluetoothGattCharacteristic>()
    private val clientMtus = ConcurrentHashMap<String, Int>()
    // Client connections whose engine link was dropped (e.g. as a duplicate) while
    // the peer stays linked to our GATT server. Android releases the Bluetooth
    // connection once no app on this phone holds it as a GATT client (the server
    // doesn't count), which would take the remaining link down a few seconds later.
    // So they stay open, unused, and are reused or closed when that link ends.
    private val idleClients = ConcurrentHashMap<String, BluetoothGatt>()

    // Addresses the user asked to connect to (the 연결 button). Only those links may
    // start an app pairing (6.3); cleared when the link comes up or the attempt ends.
    private val userInitiated = ConcurrentHashMap.newKeySet<String>()
    // connectGatt() calls that haven't connected yet, kept so they can be cancelled. A
    // pending autoConnect would otherwise complete whenever the device shows up again.
    private val pendingConnections = ConcurrentHashMap<String, BluetoothGatt>()
    private val pendingBondAddresses = ConcurrentHashMap.newKeySet<String>()
    // Nearby devices already reported to Dart: the name they were reported under and
    // when (elapsedRealtime).
    private val reportedNearby = ConcurrentHashMap<String, Pair<String, Long>>()

    @Volatile
    private var gattServer: BluetoothGattServer? = null

    @Volatile
    private var serverCharacteristic: BluetoothGattCharacteristic? = null
    private val subscribedCentrals = ConcurrentHashMap<String, BluetoothDevice>()
    private val centralMtus = ConcurrentHashMap<String, Int>()

    // Engine links. A peer reached in both roles has two GATT links (the engine
    // keeps one of them, 9절); they're told apart by role.
    private data class LinkTarget(val address: String, val role: Role)

    private val linkTargets = ConcurrentHashMap<Int, LinkTarget>()
    private val clientLinkIds = ConcurrentHashMap<String, Int>()
    private val serverLinkIds = ConcurrentHashMap<String, Int>()
    private var nextLinkId = 1

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

    @Volatile
    private var scanMode = ScanSettings.SCAN_MODE_LOW_POWER

    // Restarts the scan when the app moves between foreground and background. Debounced:
    // dialogs and permission prompts pause and resume the activity in quick succession.
    private val applyScanMode = Runnable {
        val wanted = if (BleEventBus.appInForeground) {
            ScanSettings.SCAN_MODE_LOW_LATENCY
        } else {
            ScanSettings.SCAN_MODE_LOW_POWER
        }
        if (isScanning && scanMode != wanted) {
            stopScan()
            startScan()
            emitStatus()
        }
    }
    private val retryScan = Runnable {
        startScan()
        emitStatus()
    }

    @Volatile
    private var advertiseDeviceName = true

    override fun onCreate() {
        super.onCreate()
        BleRuntime.init(this)
        BleRuntime.transport = this
        BleEventBus.foregroundListener = {
            handler.removeCallbacks(applyScanMode)
            handler.postDelayed(applyScanMode, SCAN_MODE_DEBOUNCE_MS)
        }
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
                BleRuntime.replay()
                // A newly attached Dart side has an empty nearby list; report everything
                // again instead of only changes.
                reportedNearby.clear()
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
            ACTION_SCAN_NOW -> {
                reportedNearby.clear()
                startScan()
            }
            ACTION_CONNECT_DEVICE -> connectDevice(
                intent?.getStringExtra(EXTRA_DEVICE_ID),
                intent?.getBooleanExtra(EXTRA_PAIR, false) == true
            )
            ACTION_REMOVE_DEVICE -> removeDevice(intent?.getStringExtra(EXTRA_DEVICE_ID))
            ACTION_RESPOND_PAIRING -> intent?.getStringExtra(EXTRA_DEVICE_ID)?.let {
                engine.respondPairing(it, intent.getBooleanExtra(EXTRA_ACCEPT, false))
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
        BleRuntime.transport = null
        BleEventBus.foregroundListener = null
        handler.removeCallbacks(applyScanMode)
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

    // Automatic connects (on restore, scan results, and disconnects) only target
    // app-paired peers the engine has no link to (6.3, 9절), and only bonded ones:
    // the bond keeps their address stable and the link encrypted.
    @SuppressLint("MissingPermission")
    private fun reconnectBondedDevices() {
        adapter?.bondedDevices?.forEach(::reconnectIfNeeded)
    }

    // When of the last automatic connect per address (elapsedRealtime). A peer that
    // turns links away would otherwise be retried on every scan result.
    private val lastAutoConnect = ConcurrentHashMap<String, Long>()
    private val retryScheduled = ConcurrentHashMap.newKeySet<String>()

    @SuppressLint("MissingPermission")
    private fun reconnectIfNeeded(device: BluetoothDevice) {
        val address = device.address ?: return
        if (
            !isCentralEnabled ||
            device.bondState != BluetoothDevice.BOND_BONDED ||
            !engine.shouldReconnect(address) ||
            activeConnections.containsKey(address) ||
            pendingConnections.containsKey(address)
        ) {
            return
        }
        val wait = (lastAutoConnect[address] ?: Long.MIN_VALUE / 2) + AUTO_CONNECT_INTERVAL_MS -
            SystemClock.elapsedRealtime()
        if (wait > 0) {
            if (retryScheduled.add(address)) {
                handler.postDelayed({
                    retryScheduled.remove(address)
                    reconnectIfNeeded(device)
                }, wait)
            }
            return
        }
        lastAutoConnect[address] = SystemClock.elapsedRealtime()
        connectGattIfNeeded(device)
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
        // Writing a frame or subscribing needs an encrypted link, i.e. a bonded peer.
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
        failQueues(serverQueues, "GATT server closed")
        centrals.forEach { central -> runCatching { server.cancelConnection(central) } }
        serverLinkIds.keys.toList().forEach(::dropServerLink)
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
        // Fast discovery while the user is looking at the app; in the background the
        // scan only needs to notice peers eventually (reconnects use autoConnect).
        val mode = if (BleEventBus.appInForeground) {
            ScanSettings.SCAN_MODE_LOW_LATENCY
        } else {
            ScanSettings.SCAN_MODE_LOW_POWER
        }
        val settings = ScanSettings.Builder()
            .setScanMode(mode)
            .build()
        bleScanner.startScan(filters, settings, scanCallback)
        scanMode = mode
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
        if (pair) {
            userInitiated.add(deviceId)
        }
        when {
            device.bondState == BluetoothDevice.BOND_BONDED -> connectGattIfNeeded(device, userRequested = pair)
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
            userInitiated.remove(address)
            emitError("Pairing with $address could not be started")
            emitDisconnected(address)
            return
        }
        BleEventBus.emit(mapOf("type" to "bonding", "deviceId" to address))
    }

    @SuppressLint("MissingPermission")
    private fun connectGattIfNeeded(device: BluetoothDevice, userRequested: Boolean = false) {
        val address = device.address ?: return
        if (activeConnections.containsKey(address)) {
            return
        }
        idleClients.remove(address)?.let { gatt ->
            // Still connected and subscribed; a new handshake is enough.
            activeConnections[address] = gatt
            clientLinkUp(address)
            return
        }
        pendingConnections[address]?.let { pending ->
            if (!userRequested) {
                return
            }
            // A background connect may take minutes; the user is waiting, so connect
            // directly instead.
            pendingConnections.remove(address)
            runCatching { pending.close() }
        }
        // 9절: a peer already linked to our GATT server needs no second link.
        if (!userRequested && engine.hasLiveLink(address)) {
            return
        }
        // Background (autoConnect) connections only work with identity addresses, i.e.
        // bonded peers; a user-requested connect goes direct, so it fails fast.
        val autoConnect = !userRequested && device.bondState == BluetoothDevice.BOND_BONDED
        val gatt = device.connectGatt(this, autoConnect, gattCallback, BluetoothDevice.TRANSPORT_LE)
            ?: return
        pendingConnections[address] = gatt
    }

    /** Deletes the peer (UNPAIR first if connected, 6.6), then drops every link to it. */
    private fun removeDevice(deviceId: String?) {
        if (deviceId.isNullOrBlank()) {
            return
        }
        val peers = BleRuntime.store.peers().filter { it.deviceId == deviceId }
        if (peers.isEmpty()) {
            disconnectDevice(deviceId)
            return
        }
        var remaining = peers.size
        peers.forEach { peer ->
            engine.removePeer(peer.peerId) {
                remaining--
                if (remaining == 0) {
                    disconnectDevice(deviceId)
                }
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun disconnectDevice(deviceId: String) {
        pendingBondAddresses.remove(deviceId)
        userInitiated.remove(deviceId)
        listOfNotNull(
            pendingConnections.remove(deviceId),
            activeConnections.remove(deviceId),
            idleClients.remove(deviceId)
        )
            .forEach { gatt ->
                runCatching {
                    gatt.disconnect()
                    gatt.close()
                }
            }
        // close() unregisters the client callback, so onConnectionStateChange won't report this.
        dropClientLink(deviceId)
        subscribedCentrals.remove(deviceId)?.let { central ->
            centralMtus.remove(deviceId)
            runCatching { gattServer?.cancelConnection(central) }
        }
        serverQueues.remove(deviceId)?.failAll("Disconnected")
        dropServerLink(deviceId)
        emitDisconnected(deviceId)
        emitStatus()
    }

    @SuppressLint("MissingPermission")
    private fun disconnectAll() {
        val entries = activeConnections.values.toList() + idleClients.values
        val pending = pendingConnections.values.toList()
        val addresses = activeConnections.keys + pendingConnections.keys + clientLinkIds.keys + idleClients.keys
        activeConnections.clear()
        pendingConnections.clear()
        idleClients.clear()
        userInitiated.clear()
        pending.forEach { runCatching { it.close() } }
        entries.forEach {
            runCatching {
                it.disconnect()
                it.close()
            }
        }
        // close() unregisters the callback, so onConnectionStateChange won't report this.
        addresses.forEach(::dropClientLink)
    }

    /** Forgets our client link to [address]: its writes fail, and the engine drops it. */
    private fun dropClientLink(address: String) {
        writableCharacteristics.remove(address)
        clientMtus.remove(address)
        clientQueues.remove(address)?.failAll("Disconnected")
        clientLinkIds.remove(address)?.let { linkId ->
            linkTargets.remove(linkId)
            engine.linkDown(linkId)
        }
    }

    private fun dropServerLink(address: String) {
        serverLinkIds.remove(address)?.let { linkId ->
            linkTargets.remove(linkId)
            engine.linkDown(linkId)
        }
    }

    private fun clientLinkUp(address: String) {
        if (!activeConnections.containsKey(address)) {
            return
        }
        clientLinkIds.remove(address)?.let { old ->
            linkTargets.remove(old)
            engine.linkDown(old)
        }
        val linkId = nextLinkId++
        clientLinkIds[address] = linkId
        linkTargets[linkId] = LinkTarget(address, Role.CENTRAL)
        engine.linkUp(linkId, Role.CENTRAL, address, attMtu(address) - ATT_HEADER_SIZE, userInitiated.remove(address))
    }

    private fun serverLinkUp(address: String) {
        if (serverLinkIds.containsKey(address)) {
            return
        }
        val linkId = nextLinkId++
        serverLinkIds[address] = linkId
        linkTargets[linkId] = LinkTarget(address, Role.PERIPHERAL)
        engine.linkUp(linkId, Role.PERIPHERAL, address, attMtu(address) - ATT_HEADER_SIZE, false)
    }

    // The ATT MTU belongs to the Bluetooth connection, which both roles share. A
    // central that subscribes over an existing connection doesn't renegotiate it, so
    // the server never hears onMtuChanged; use what the client side learned.
    private fun attMtu(address: String) = clientMtus[address] ?: centralMtus[address] ?: DEFAULT_ATT_MTU

    // BleTransport: the engine's frames go out as a characteristic write (we're the
    // central) or a notification (we're the peripheral), one GATT operation at a time.
    override fun writeFrame(linkId: Int, frame: ByteArray) {
        val target = linkTargets[linkId]
        if (target == null) {
            handler.post { engine.frameWritten(linkId, false) }
            return
        }
        val done: (Boolean, String?) -> Unit = { success, _ -> handler.post { engine.frameWritten(linkId, success) } }
        when (target.role) {
            Role.CENTRAL -> {
                val gatt = activeConnections[target.address]
                val characteristic = writableCharacteristics[target.address]
                if (gatt == null || characteristic == null) {
                    done(false, null)
                    return
                }
                clientQueue(target.address).enqueue(
                    GattOperationQueue.Operation(start = { writeFrame(gatt, characteristic, frame) }, onComplete = done)
                )
            }
            Role.PERIPHERAL -> {
                val central = subscribedCentrals[target.address]
                val server = gattServer
                val characteristic = serverCharacteristic
                if (central == null || server == null || characteristic == null) {
                    done(false, null)
                    return
                }
                serverQueues.getOrPut(target.address) { GattOperationQueue() }.enqueue(
                    GattOperationQueue.Operation(start = { notifyFrame(server, central, characteristic, frame) }, onComplete = done)
                )
            }
        }
    }

    @SuppressLint("MissingPermission")
    override fun closeLink(linkId: Int) {
        val target = linkTargets.remove(linkId) ?: return
        when (target.role) {
            Role.CENTRAL -> {
                clientLinkIds.remove(target.address, linkId)
                clientQueues.remove(target.address)?.failAll("Link closed")
                val gatt = activeConnections.remove(target.address)
                if (gatt != null && engine.hasLiveLink(target.address)) {
                    idleClients[target.address] = gatt
                } else {
                    gatt?.let {
                        runCatching {
                            it.disconnect()
                            it.close()
                        }
                    }
                    writableCharacteristics.remove(target.address)
                    clientMtus.remove(target.address)
                }
            }
            // The protocol leaves closing to the central; this only happens when a
            // pairing key couldn't be stored.
            Role.PERIPHERAL -> {
                serverLinkIds.remove(target.address, linkId)
                subscribedCentrals[target.address]?.let { runCatching { gattServer?.cancelConnection(it) } }
            }
        }
        emitStatus()
    }

    override fun onEngineEvent(event: EngineEvent) {
        if (event is EngineEvent.Disconnected) {
            // The link an idle client was kept for ended; reuse the client or let go.
            handler.post { releaseIdleClient(event.deviceId) }
        }
        if (event is EngineEvent.Connected || event is EngineEvent.Disconnected) {
            emitStatus()
        }
    }

    @SuppressLint("MissingPermission")
    private fun releaseIdleClient(address: String) {
        if (engine.hasLiveLink(address)) {
            return
        }
        val gatt = idleClients[address] ?: return
        if (isCentralEnabled && engine.shouldReconnect(address)) {
            connectGattIfNeeded(gatt.device)
            return
        }
        idleClients.remove(address)
        writableCharacteristics.remove(address)
        clientMtus.remove(address)
        runCatching {
            gatt.disconnect()
            gatt.close()
        }
    }

    @SuppressLint("MissingPermission")
    private fun writeFrame(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        frame: ByteArray
    ): Boolean {
        val writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(characteristic, frame, writeType) ==
                BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                characteristic.value = frame
                characteristic.writeType = writeType
                gatt.writeCharacteristic(characteristic)
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun notifyFrame(
        server: BluetoothGattServer,
        central: BluetoothDevice,
        characteristic: BluetoothGattCharacteristic,
        frame: ByteArray
    ): Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        server.notifyCharacteristicChanged(central, characteristic, false, frame) == BluetoothStatusCodes.SUCCESS
    } else {
        @Suppress("DEPRECATION")
        run {
            characteristic.value = frame
            server.notifyCharacteristicChanged(central, characteristic, false)
        }
    }

    private fun clientQueue(address: String) =
        clientQueues.getOrPut(address) { GattOperationQueue() }

    private fun failQueues(queues: ConcurrentHashMap<String, GattOperationQueue>, error: String) {
        val drained = queues.values.toList()
        queues.clear()
        drained.forEach { it.failAll(error) }
    }

    /** Ends Dart's connecting state for an attempt that never reached a session. */
    private fun emitDisconnected(address: String) {
        if (!engine.isConnected(address)) {
            BleEventBus.emit(mapOf("type" to "disconnected", "deviceId" to address))
        }
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
        // Peers with a session, over both roles.
        val connectionCount = engine.connectedSessions().map { it.deviceId }.toSet().size
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
        // Structured, so both platforms report the same thing (Dart builds the label);
        // the string above is only the foreground-service notification text.
        BleEventBus.emit(
            mapOf(
                "type" to "status",
                "advertising" to isAdvertising,
                "scanning" to isScanning,
                "connectedCount" to connectionCount,
                "bluetoothOn" to (adapter?.state == BluetoothAdapter.STATE_ON)
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
        // The chat's message notifications are gone.
        manager.deleteNotificationChannel(OLD_MESSAGE_CHANNEL_ID)
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
            val name = result.scanRecord?.deviceName ?: device.name ?: ""
            // A peer advertises several times a second; each event rebuilt Dart UI. Report
            // a device when it's new or renamed, and otherwise every NEARBY_REFRESH_MS
            // so Dart can drop devices that stopped advertising.
            val now = SystemClock.elapsedRealtime()
            val reported = reportedNearby[address]
            if (reported == null || reported.first != name || now - reported.second >= NEARBY_REFRESH_MS) {
                reportedNearby[address] = name to now
                BleEventBus.emit(
                    mapOf(
                        "type" to "discovered",
                        "deviceId" to address,
                        "name" to name
                    )
                )
            }
            reconnectIfNeeded(device)
        }
    }

    // GATT callbacks arrive on binder threads; their work runs on the main looper with
    // the engine. Values are copied first: the deprecated callbacks reuse buffers.
    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            handler.post { onClientConnectionStateChange(gatt, status, newState) }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            handler.post {
                val address = gatt.device.address ?: return@post
                if (activeConnections[address] !== gatt) {
                    return@post
                }
                clientMtus[address] = mtu
                clientLinkIds[address]?.let { engine.setMaxFrameSize(it, mtu - ATT_HEADER_SIZE) }
                serverLinkIds[address]?.let { engine.setMaxFrameSize(it, mtu - ATT_HEADER_SIZE) }
                if (!writableCharacteristics.containsKey(address)) {
                    gatt.discoverServices()
                }
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            val address = gatt.device.address ?: return
            handler.post {
                clientQueues[address]?.complete(
                    status == BluetoothGatt.GATT_SUCCESS,
                    "Write failed (status $status)"
                )
            }
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            val address = gatt.device.address ?: return
            handler.post {
                clientQueues[address]?.complete(
                    status == BluetoothGatt.GATT_SUCCESS,
                    "Descriptor write failed (status $status)"
                )
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            handler.post { onClientServicesDiscovered(gatt, status) }
        }

        // The peer's GATT database changed, typically because its app restarted and
        // registered a new server while Bluetooth stayed connected (other apps hold
        // the connection). Our session went with the old server: discover and
        // subscribe again, which starts a new handshake on this link.
        override fun onServiceChanged(gatt: BluetoothGatt) {
            handler.post {
                val address = gatt.device.address ?: return@post
                if (activeConnections[address] !== gatt) {
                    return@post
                }
                writableCharacteristics.remove(address)
                gatt.discoverServices()
            }
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid == MESSAGE_CHARACTERISTIC_UUID) {
                onClientFrame(gatt, characteristic.value?.copyOf() ?: return)
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            if (characteristic.uuid == MESSAGE_CHARACTERISTIC_UUID) {
                onClientFrame(gatt, value.copyOf())
            }
        }
    }

    private fun onClientFrame(gatt: BluetoothGatt, frame: ByteArray) {
        val address = gatt.device.address ?: return
        handler.post { clientLinkIds[address]?.let { engine.frameReceived(it, frame) } }
    }

    @SuppressLint("MissingPermission")
    private fun onClientConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
        val address = gatt.device.address ?: return
        if (idleClients[address] === gatt) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                idleClients.remove(address)
                writableCharacteristics.remove(address)
                clientMtus.remove(address)
                runCatching { gatt.close() }
                reconnectIfNeeded(gatt.device)
            }
            return
        }
        // Callbacks queued before a close() can still arrive; they're about a gatt
        // object we no longer use.
        val current = pendingConnections[address] === gatt || activeConnections[address] === gatt
        if (!current) {
            return
        }
        when (newState) {
            BluetoothProfile.STATE_CONNECTED -> {
                pendingConnections.remove(address)
                activeConnections[address] = gatt
                // The default MTU leaves 20 bytes per frame; negotiate a larger one before
                // discovering services.
                if (!gatt.requestMtu(MAX_ATT_MTU)) {
                    gatt.discoverServices()
                }
            }
            BluetoothProfile.STATE_DISCONNECTED -> {
                pendingConnections.remove(address)
                val wasConnected = activeConnections.remove(address) != null
                dropClientLink(address)
                runCatching { gatt.close() }
                userInitiated.remove(address)
                if (!wasConnected && status != BluetoothGatt.GATT_SUCCESS) {
                    emitError("Connection to $address failed (status $status)")
                }
                emitDisconnected(address)
                reconnectIfNeeded(gatt.device)
            }
        }
        emitStatus()
    }

    @SuppressLint("MissingPermission")
    private fun onClientServicesDiscovered(gatt: BluetoothGatt, status: Int) {
        val address = gatt.device.address ?: return
        if (status != BluetoothGatt.GATT_SUCCESS || activeConnections[address] !== gatt) {
            return
        }
        val characteristic = gatt.getService(SERVICE_UUID)?.getCharacteristic(MESSAGE_CHARACTERISTIC_UUID)
        if (characteristic == null) {
            // Same service, older protocol (the characteristic UUID changed with it):
            // nothing to talk to.
            emitError("$address runs an incompatible version of the app")
            activeConnections.remove(address)
            userInitiated.remove(address)
            runCatching {
                gatt.disconnect()
                gatt.close()
            }
            emitDisconnected(address)
            emitStatus()
            return
        }
        writableCharacteristics[address] = characteristic
        gatt.setCharacteristicNotification(characteristic, true)
        val cccd = characteristic.getDescriptor(CLIENT_CONFIG_DESCRIPTOR_UUID) ?: return
        // Queued like the frame writes. The link is usable once the peer can notify us.
        clientQueue(address).enqueue(
            GattOperationQueue.Operation(
                start = { enableNotifications(gatt, cccd) },
                onComplete = { success, error ->
                    handler.post {
                        if (success) {
                            clientLinkUp(address)
                        } else {
                            emitError("Subscribing to $address failed: $error")
                        }
                    }
                }
            )
        )
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

    @SuppressLint("MissingPermission")
    private fun onBluetoothOff() {
        // "Bluetooth off" can leave LE running (adapter state BLE_ON on Samsung), with
        // our advertising set and scan still alive. Stop them while the advertiser and
        // scanner can still be reached; dropping the callback alone leaked the old
        // advertising set, which then ran next to the new one after Bluetooth came
        // back (two addresses for the same phone).
        advertiseCallback?.let { callback -> runCatching { advertiser?.stopAdvertising(callback) } }
        runCatching { scanner?.stopScan(scanCallback) }
        handler.removeCallbacks(retryScan)
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
            val previous =
                intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.ERROR)
            if (
                state == BluetoothDevice.BOND_NONE &&
                previous == BluetoothDevice.BOND_BONDED &&
                !pendingBondAddresses.contains(address)
            ) {
                // The pairing went away: removed in this phone's settings, or removed on
                // the peer, which the stack detects as "bond loss" (key missing) on the
                // next encryption and then drops here too. The address belongs to that
                // bond, so a pending background connect to it can never succeed.
                pendingConnections.remove(address)?.let { runCatching { it.close() } }
                BleEventBus.emit(mapOf("type" to "bondLost", "deviceId" to address))
                emitDisconnected(address)
                emitStatus()
                return
            }
            if (!pendingBondAddresses.contains(address)) {
                return
            }
            when (state) {
                BluetoothDevice.BOND_BONDED -> {
                    pendingBondAddresses.remove(address)
                    // Only the 연결 button bonds, so this connect is the user's.
                    connectGattIfNeeded(device, userRequested = true)
                }
                BluetoothDevice.BOND_NONE -> {
                    pendingBondAddresses.remove(address)
                    userInitiated.remove(address)
                    emitError("Pairing with $address failed")
                    // Ends the 연결 중/페어링 중 state in Dart.
                    emitDisconnected(address)
                }
            }
        }
    }

    // Peripheral role: a remote central subscribes to our characteristic, writes its
    // frames to it, and gets ours as notifications. Work runs on the main looper.
    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            // This fires for every LE link to this phone (watches, other apps); only
            // centrals that subscribed have a link.
            if (newState != BluetoothProfile.STATE_DISCONNECTED) {
                return
            }
            val address = device.address ?: return
            handler.post {
                centralMtus.remove(address)
                serverQueues.remove(address)?.failAll("Disconnected")
                subscribedCentrals.remove(address)
                dropServerLink(address)
                // The peer is gone in both roles; reconnect from our side if it's ours to.
                reconnectIfNeeded(device)
                emitStatus()
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            val address = device.address ?: return
            handler.post {
                serverQueues[address]?.complete(
                    status == BluetoothGatt.GATT_SUCCESS,
                    "Notification failed (status $status)"
                )
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            val address = device.address ?: return
            handler.post {
                centralMtus[address] = mtu
                serverLinkIds[address]?.let { engine.setMaxFrameSize(it, mtu - ATT_HEADER_SIZE) }
                clientLinkIds[address]?.let { engine.setMaxFrameSize(it, mtu - ATT_HEADER_SIZE) }
            }
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
            // Every frame fits in one ATT write (4절), so long writes aren't supported.
            if (characteristic.uuid != MESSAGE_CHARACTERISTIC_UUID || preparedWrite) {
                if (responseNeeded) {
                    gattServer?.sendResponse(
                        device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null
                    )
                }
                return
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            }
            val frame = value?.copyOf() ?: return
            handler.post {
                // A central that resubscribed on a surviving connection may write first.
                if (!serverLinkIds.containsKey(address) && subscribedCentrals.containsKey(address)) {
                    serverLinkUp(address)
                }
                serverLinkIds[address]?.let { engine.frameReceived(it, frame) }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, 0, null)
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
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
            if (descriptor.uuid != CLIENT_CONFIG_DESCRIPTOR_UUID) {
                return
            }
            val subscribed = value?.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == true
            handler.post {
                if (subscribed) {
                    subscribedCentrals[address] = device
                    serverLinkUp(address)
                } else if (subscribedCentrals.remove(address) != null) {
                    serverQueues.remove(address)?.failAll("Unsubscribed")
                    dropServerLink(address)
                }
                emitStatus()
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
        const val ACTION_REMOVE_DEVICE = "ble.action.REMOVE_DEVICE"
        const val ACTION_RESPOND_PAIRING = "ble.action.RESPOND_PAIRING"

        const val EXTRA_DEVICE_ID = "extra.device.id"
        const val EXTRA_PAIR = "extra.pair"
        const val EXTRA_ACCEPT = "extra.accept"

        // Status reported while the adapter is off; Dart shows a banner for it. iOS uses the
        // same string.
        const val STATUS_BLUETOOTH_OFF = "bluetooth-off"

        private const val PREFS_NAME = "ble_service_prefs"
        private const val PREF_ADVERTISING = "pref_advertising"
        private const val PREF_CENTRAL = "pref_central"
        private const val NOTIFICATION_CHANNEL_ID = "ble_background"
        private const val NOTIFICATION_ID = 2001
        private const val OLD_MESSAGE_CHANNEL_ID = "ble_messages"
        private val SERVICE_UUID = UUID.fromString("1f9ed31d-b738-4d4c-a6d8-86dbf0f9c001")
        private val SERVICE_PARCEL_UUID = ParcelUuid(SERVICE_UUID)
        // Protocol v1 frames. Changed from the raw-UTF-8 chat characteristic
        // (db912050-…) so old and new builds don't misread each other (14절).
        private val MESSAGE_CHARACTERISTIC_UUID =
            UUID.fromString("002069ac-115d-4391-8772-13e44df757fc")
        private const val DEFAULT_ATT_MTU = 23
        private const val MAX_ATT_MTU = 517
        private const val ATT_HEADER_SIZE = 3
        private const val SCAN_RETRY_DELAY_MS = 30_000L
        private const val SCAN_MODE_DEBOUNCE_MS = 2_000L
        private const val NEARBY_REFRESH_MS = 30_000L
        private const val AUTO_CONNECT_INTERVAL_MS = 10_000L
        private val CLIENT_CONFIG_DESCRIPTOR_UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
