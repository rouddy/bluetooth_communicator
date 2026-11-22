package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.Manifest
import android.app.NotificationManager
import android.content.ActivityNotFoundException
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

    // File pickers in flight: the device to send to, or the received file to save.
    private var pendingPick: Pair<String, MethodChannel.Result>? = null
    private var pendingSave: Pair<String, MethodChannel.Result>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        BleRuntime.init(this)

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
                    "removeDevice" -> {
                        startServiceAction(
                            BluetoothBackgroundService.ACTION_REMOVE_DEVICE,
                            call.argument<String>("deviceId")
                        )
                        result.success(null)
                    }
                    "requestClipboard" -> {
                        val deviceId = call.argument<String>("deviceId")
                        if (deviceId == null) {
                            result.error("BAD_ARGS", "deviceId is required", null)
                        } else {
                            BleRuntime.post { ClipboardShare.request(deviceId) }
                            result.success(null)
                        }
                    }
                    "setClipboardSharing" -> {
                        ClipboardShare.sharingEnabled = call.argument<Boolean>("enabled") != false
                        result.success(null)
                    }
                    "sendFile" -> sendFile(call.argument("deviceId"), call.argument("path"), result)
                    "respondFile" -> {
                        val id = call.argument<Number>("id")?.toLong()
                        val accept = call.argument<Boolean>("accept") == true
                        id?.let { BleRuntime.post { FileShare.transfers.respond(it, accept) } }
                        result.success(null)
                    }
                    "cancelFile" -> {
                        call.argument<Number>("id")?.toLong()?.let { BleRuntime.post { FileShare.transfers.cancel(it) } }
                        result.success(null)
                    }
                    "dismissFile" -> {
                        call.argument<Number>("id")?.toLong()?.let { BleRuntime.post { FileShare.transfers.dismiss(it) } }
                        result.success(null)
                    }
                    "exportFile" -> exportFile(call.argument<Number>("id")?.toLong(), call.argument("action"), result)
                    "respondPairing" -> {
                        val started = startServiceAction(
                            BluetoothBackgroundService.ACTION_RESPOND_PAIRING,
                            call.argument<String>("deviceId"),
                            accept = call.argument<Boolean>("accept") == true
                        )
                        if (started) {
                            result.success(null)
                        } else {
                            result.error("SERVICE_UNAVAILABLE", "Bluetooth service unavailable", null)
                        }
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

    override fun onResume() {
        super.onResume()
        BleEventBus.appInForeground = true
        // Pairing prompts and file transfers show in the app now (replayed on
        // attach); clear their notifications.
        val manager = getSystemService(NotificationManager::class.java)
        manager.activeNotifications
            .filter { it.notification.channelId == BleRuntime.PAIRING_CHANNEL_ID }
            .forEach { manager.cancel(it.tag, it.id) }
        FileShare.clearNotifications()
    }

    /**
     * Offers a file to [deviceId]: the one at [path] (tests), or one the user picks.
     * Answers true once offered, false if the picker was closed.
     */
    private fun sendFile(deviceId: String?, path: String?, result: MethodChannel.Result) {
        val offered = { error: String? ->
            if (error == null) {
                result.success(true)
            } else {
                result.error(error, "Can't send the file", null)
            }
        }
        when {
            deviceId == null -> result.error("BAD_ARGS", "deviceId is required", null)
            path != null -> FileShare.offerPath(deviceId, path, offered)
            pendingPick != null || pendingSave != null -> result.error("BUSY", "A file picker is already open", null)
            else -> {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("*/*")
                if (startForResult(intent, REQUEST_PICK_FILE, result)) {
                    pendingPick = deviceId to result
                }
            }
        }
    }

    /** Saves ([action] `save`) or shares (`share`) the received file [id]. */
    private fun exportFile(id: Long?, action: String?, result: MethodChannel.Result) {
        val transfer = id?.let(FileShare::receivedFile)
        when {
            transfer == null -> result.error("NOT_FOUND", "No received file $id", null)
            action == "share" -> try {
                startActivity(FileShare.shareIntent(transfer))
                result.success(true)
            } catch (e: Exception) {
                result.error("EXPORT_FAILED", e.message, null)
            }
            action != "save" -> result.error("BAD_ARGS", "Unknown action $action", null)
            pendingPick != null || pendingSave != null -> result.error("BUSY", "A file picker is already open", null)
            else -> {
                // The user picks where; Downloads, Drive, and so on.
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .setType(transfer.mime)
                    .putExtra(Intent.EXTRA_TITLE, transfer.name)
                if (startForResult(intent, REQUEST_SAVE_FILE, result)) {
                    pendingSave = transfer.path!! to result
                }
            }
        }
    }

    private fun startForResult(intent: Intent, requestCode: Int, result: MethodChannel.Result): Boolean = try {
        startActivityForResult(intent, requestCode)
        true
    } catch (e: ActivityNotFoundException) {
        result.error("NO_PICKER", e.message, null)
        false
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val uri = data?.data.takeIf { resultCode == RESULT_OK }
        when (requestCode) {
            REQUEST_PICK_FILE -> {
                val (deviceId, result) = pendingPick ?: return
                pendingPick = null
                if (uri == null) {
                    result.success(false)
                    return
                }
                FileShare.offerUri(deviceId, uri) { error ->
                    if (error == null) {
                        result.success(true)
                    } else {
                        result.error(error, "Can't send the file", null)
                    }
                }
            }
            REQUEST_SAVE_FILE -> {
                val (path, result) = pendingSave ?: return
                pendingSave = null
                if (uri == null) {
                    result.success(false)
                    return
                }
                FileShare.copyTo(path, uri) { copied ->
                    if (copied) {
                        result.success(true)
                    } else {
                        result.error("EXPORT_FAILED", "Can't save the file", null)
                    }
                }
            }
            else -> super.onActivityResult(requestCode, resultCode, data)
        }
    }

    // Clipboard requests that arrived while the app wasn't on screen wait for this
    // (ClipboardShare): only the focused app may read the clipboard.
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        BleEventBus.appHasFocus = hasFocus
        if (hasFocus) {
            BleRuntime.post { ClipboardShare.onFocus() }
        }
    }

    override fun onPause() {
        BleEventBus.appInForeground = false
        super.onPause()
    }

    // When the activity is destroyed its engine goes with it, but the event channel's
    // onCancel isn't called, so BleEventBus would keep sending to a dead sink. Detach.
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        BleEventBus.detach()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private companion object {
        const val REQUEST_PICK_FILE = 4101
        const val REQUEST_SAVE_FILE = 4102
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
        pair: Boolean = false,
        accept: Boolean = false
    ): Boolean {
        if (!hasBlePermissions()) {
            BleEventBus.emit(
                mapOf(
                    "type" to "error",
                    "message" to "Cannot start service: Bluetooth permissions are missing."
                )
            )
            return false
        }

        val intent = Intent(this, BluetoothBackgroundService::class.java).apply {
            this.action = action
            if (deviceId != null) {
                putExtra(BluetoothBackgroundService.EXTRA_DEVICE_ID, deviceId)
            }
            if (pair) {
                putExtra(BluetoothBackgroundService.EXTRA_PAIR, true)
            }
            putExtra(BluetoothBackgroundService.EXTRA_ACCEPT, accept)
        }
        return try {
            startForegroundService(intent)
            true
        } catch (e: Exception) {
            e.printStackTrace()
            BleEventBus.emit(
                mapOf(
                    "type" to "error",
                    "message" to "Failed to start service: ${e.message}"
                )
            )
            false
        }
    }
}
