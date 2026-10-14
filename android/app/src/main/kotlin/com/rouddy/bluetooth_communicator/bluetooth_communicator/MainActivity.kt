package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val methodChannelName = "com.rouddy.bluetooth_communicator/bluetooth_control"
    private val eventChannelName = "com.rouddy.bluetooth_communicator/bluetooth_events"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Dart requests the runtime permissions (permission_handler) before
                    // calling this; returns false if they still aren't granted.
                    "initialize" -> {
                        if (hasBlePermissions()) {
                            startServiceAction(BluetoothBackgroundService.ACTION_RESTORE)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "setAdvertisingEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        startServiceAction(
                            if (enabled) {
                                BluetoothBackgroundService.ACTION_START_ADVERTISING
                            } else {
                                BluetoothBackgroundService.ACTION_STOP_ADVERTISING
                            }
                        )
                        result.success(null)
                    }
                    "setCentralEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        startServiceAction(
                            if (enabled) {
                                BluetoothBackgroundService.ACTION_START_CENTRAL
                            } else {
                                BluetoothBackgroundService.ACTION_STOP_CENTRAL
                            }
                        )
                        result.success(null)
                    }
                    "scanNow" -> {
                        startServiceAction(BluetoothBackgroundService.ACTION_SCAN_NOW)
                        result.success(null)
                    }
                    "connectDevice" -> {
                        val deviceId = call.argument<String>("deviceId")
                        startServiceAction(
                            BluetoothBackgroundService.ACTION_CONNECT_DEVICE,
                            deviceId,
                            pair = call.argument<Boolean>("pair") == true
                        )
                        result.success(null)
                    }
                    "sendMessage" -> {
                        val deviceId = call.argument<String>("deviceId")
                        val message = call.argument<String>("message")
                        startServiceAction(
                            BluetoothBackgroundService.ACTION_SEND_MESSAGE,
                            deviceId,
                            message
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    BleEventBus.attach(events)
                }

                override fun onCancel(arguments: Any?) {
                    BleEventBus.detach()
                }
            })
    }

    // Notification permission is deliberately not required: the foreground service runs
    // without it, only its notification is hidden.
    private fun hasBlePermissions(): Boolean {
        val permissions = listOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE
        )
        return permissions.all {
            ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun startServiceAction(
        action: String,
        deviceId: String? = null,
        message: String? = null,
        pair: Boolean = false
    ) {
        if (!hasBlePermissions()) {
            BleEventBus.emit(
                mapOf(
                    "type" to "error",
                    "message" to "Cannot start service: Bluetooth permissions are missing."
                )
            )
            return
        }

        val intent = Intent(this, BluetoothBackgroundService::class.java).apply {
            this.action = action
            if (deviceId != null) {
                putExtra(BluetoothBackgroundService.EXTRA_DEVICE_ID, deviceId)
            }
            if (message != null) {
                putExtra(BluetoothBackgroundService.EXTRA_MESSAGE, message)
            }
            if (pair) {
                putExtra(BluetoothBackgroundService.EXTRA_PAIR, true)
            }
        }
        try {
            startForegroundService(intent)
        } catch (e: Exception) {
            e.printStackTrace()
            BleEventBus.emit(
                mapOf(
                    "type" to "error",
                    "message" to "Failed to start service: ${e.message}"
                )
            )
        }
    }
}
