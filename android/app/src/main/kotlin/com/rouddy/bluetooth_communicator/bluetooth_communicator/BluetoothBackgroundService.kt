package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
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
import android.os.Build
import android.os.IBinder
import android.os.ParcelUuid
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
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
    private val connectingAddresses = ConcurrentHashMap.newKeySet<String>()
    private val prefs by lazy { getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) }

    @Volatile
    private var isAdvertising = false

    @Volatile
    private var isCentralEnabled = false

    @Volatile
    private var isScanning = false

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("Running"))
    }

    @SuppressLint("MissingPermission")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_RESTORE -> restoreStateFromPrefs()
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
            ACTION_CONNECT_DEVICE -> connectDevice(intent.getStringExtra(EXTRA_DEVICE_ID))
            ACTION_SEND_MESSAGE -> {
                val deviceId = intent.getStringExtra(EXTRA_DEVICE_ID)
                val message = intent.getStringExtra(EXTRA_MESSAGE)
                if (!deviceId.isNullOrBlank() && !message.isNullOrBlank()) {
                    sendMessage(deviceId, message)
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

    @SuppressLint("MissingPermission")
    private fun reconnectBondedDevices() {
        val bondState = BluetoothDevice.BOND_BONDED
        adapter?.bondedDevices
            ?.filter { device -> device.bondState == bondState }
            ?.forEach { connectGattIfNeeded(it) }
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertising() {
        if (!hasBlePermissions() || isAdvertising) {
            return
        }
        val bleAdvertiser = advertiser ?: return
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        bleAdvertiser.startAdvertising(settings, data, advertiseCallback)
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertising() {
        advertiser?.stopAdvertising(advertiseCallback)
        isAdvertising = false
    }

    @SuppressLint("MissingPermission")
    private fun startScan() {
        if (!hasBlePermissions() || !isCentralEnabled || isScanning) {
            return
        }
        val bleScanner = scanner ?: return
        val filters = listOf(
            ScanFilter.Builder()
                .setServiceUuid(ParcelUuid(SERVICE_UUID))
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
        scanner?.stopScan(scanCallback)
        isScanning = false
    }

    @SuppressLint("MissingPermission")
    private fun connectDevice(deviceId: String?) {
        if (deviceId.isNullOrBlank() || !hasBlePermissions()) {
            return
        }
        val device = runCatching { adapter?.getRemoteDevice(deviceId) }.getOrNull() ?: return
        connectGattIfNeeded(device)
    }

    @SuppressLint("MissingPermission")
    private fun connectGattIfNeeded(device: BluetoothDevice) {
        val address = device.address ?: return
        if (activeConnections.containsKey(address) || connectingAddresses.contains(address)) {
            return
        }
        connectingAddresses.add(address)
        device.connectGatt(this, true, gattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    @SuppressLint("MissingPermission")
    private fun disconnectAll() {
        val entries = activeConnections.values.toList()
        activeConnections.clear()
        writableCharacteristics.clear()
        connectingAddresses.clear()
        entries.forEach {
            runCatching {
                it.disconnect()
                it.close()
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun sendMessage(deviceId: String, message: String) {
        val gatt = activeConnections[deviceId]
        val characteristic = writableCharacteristics[deviceId]
        if (gatt == null || characteristic == null) {
            BleEventBus.emit(
                mapOf(
                    "type" to "error",
                    "message" to "No writable BLE connection for $deviceId"
                )
            )
            return
        }
        val payload = message.toByteArray(Charsets.UTF_8)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(
                characteristic,
                payload,
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            )
        } else {
            characteristic.value = payload
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            gatt.writeCharacteristic(characteristic)
        }
    }

    private fun emitStatus() {
        val status = when {
            activeConnections.isNotEmpty() -> {
                buildString {
                    if (isAdvertising) {
                        append("advertising ")
                    }
                    if (isScanning) {
                        append("scanning ")
                    }
                    append("connected:${activeConnections.size}")
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
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Bluetooth background service",
            NotificationManager.IMPORTANCE_LOW
        )
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }

    private fun hasBlePermissions(): Boolean {
        val required = mutableListOf(
            Manifest.permission.BLUETOOTH,
            Manifest.permission.BLUETOOTH_ADMIN
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            required += Manifest.permission.BLUETOOTH_SCAN
            required += Manifest.permission.BLUETOOTH_ADVERTISE
            required += Manifest.permission.BLUETOOTH_CONNECT
        }
        return required.all { permission ->
            ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            isAdvertising = true
            emitStatus()
        }

        override fun onStartFailure(errorCode: Int) {
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
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            val device = result?.device ?: return
            val address = device.address ?: return
            BleEventBus.emit(
                mapOf(
                    "type" to "discovered",
                    "deviceId" to address,
                    "name" to (device.name ?: "")
                )
            )
            if (isCentralEnabled && device.bondState == BluetoothDevice.BOND_BONDED) {
                connectGattIfNeeded(device)
            }
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val address = gatt.device.address ?: return
            when (newState) {
                android.bluetooth.BluetoothProfile.STATE_CONNECTED -> {
                    connectingAddresses.remove(address)
                    activeConnections[address] = gatt
                    gatt.discoverServices()
                    BleEventBus.emit(
                        mapOf(
                            "type" to "connected",
                            "deviceId" to address
                        )
                    )
                }
                android.bluetooth.BluetoothProfile.STATE_DISCONNECTED -> {
                    connectingAddresses.remove(address)
                    activeConnections.remove(address)
                    writableCharacteristics.remove(address)
                    runCatching { gatt.close() }
                    BleEventBus.emit(
                        mapOf(
                            "type" to "disconnected",
                            "deviceId" to address
                        )
                    )
                    if (isCentralEnabled) {
                        connectGattIfNeeded(gatt.device)
                    }
                }
            }
            emitStatus()
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
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid != MESSAGE_CHARACTERISTIC_UUID) {
                return
            }
            val address = gatt.device.address ?: return
            val message = characteristic.value?.toString(Charsets.UTF_8) ?: return
            BleEventBus.emit(
                mapOf(
                    "type" to "message",
                    "deviceId" to address,
                    "message" to message
                )
            )
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            if (characteristic.uuid != MESSAGE_CHARACTERISTIC_UUID) {
                return
            }
            val address = gatt.device.address ?: return
            val message = value.toString(Charsets.UTF_8)
            BleEventBus.emit(
                mapOf(
                    "type" to "message",
                    "deviceId" to address,
                    "message" to message
                )
            )
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

        const val EXTRA_DEVICE_ID = "extra.device.id"
        const val EXTRA_MESSAGE = "extra.message"

        private const val PREFS_NAME = "ble_service_prefs"
        private const val PREF_ADVERTISING = "pref_advertising"
        private const val PREF_CENTRAL = "pref_central"
        private const val NOTIFICATION_CHANNEL_ID = "ble_background"
        private const val NOTIFICATION_ID = 2001
        private val SERVICE_UUID = UUID.fromString("1f9ed31d-b738-4d4c-a6d8-86dbf0f9c001")
        private val MESSAGE_CHARACTERISTIC_UUID =
            UUID.fromString("db912050-2e4e-4c4e-a543-e89121e57595")
    }
}
