package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val methodChannelName = "com.rouddy.bluetooth_communicator/bluetooth_control"
    private val eventChannelName = "com.rouddy.bluetooth_communicator/bluetooth_events"
    private val permissionRequestCode = 1001
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        if (hasRequiredPermissions()) {
                            startServiceAction(BluetoothBackgroundService.ACTION_RESTORE)
                            result.success(true)
                        } else {
                            requestRequiredPermissions(result)
                        }
                    }
                    "checkPermissions" -> {
                        result.success(hasRequiredPermissions())
                    }
                    "requestPermissions" -> {
                        if (hasRequiredPermissions()) {
                            startServiceAction(BluetoothBackgroundService.ACTION_RESTORE)
                            result.success(true)
                        } else {
                            requestRequiredPermissions(result)
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
                            deviceId
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

    private fun hasRequiredPermissions(): Boolean {
        val permissions = getRequiredPermissions()
        return permissions.all {
            ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun getRequiredPermissions(): List<String> {
        val list = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            list.add(Manifest.permission.BLUETOOTH_SCAN)
            list.add(Manifest.permission.BLUETOOTH_CONNECT)
            list.add(Manifest.permission.BLUETOOTH_ADVERTISE)
        } else {
            list.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            list.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        return list
    }

    private fun requestRequiredPermissions(result: MethodChannel.Result?) {
        val missingPermissions = getRequiredPermissions().filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missingPermissions.isEmpty()) {
            startServiceAction(BluetoothBackgroundService.ACTION_RESTORE)
            result?.success(true)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            missingPermissions.toTypedArray(),
            permissionRequestCode
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == permissionRequestCode) {
            val allGranted = grantResults.isNotEmpty() && grantResults.all {
                it == PackageManager.PERMISSION_GRANTED
            }
            if (allGranted) {
                startServiceAction(BluetoothBackgroundService.ACTION_RESTORE)
            }
            pendingPermissionResult?.success(allGranted)
            pendingPermissionResult = null
        }
    }

    private fun startServiceAction(
        action: String,
        deviceId: String? = null,
        message: String? = null
    ) {
        if (!hasRequiredPermissions()) {
            BleEventBus.emit(
                mapOf(
                    "type" to "error",
                    "message" to "Cannot start service: BLE or Notification permissions are missing."
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
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
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
