package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

object BleEventBus {
    private const val PREFS_NAME = "ble_service_prefs"
    private const val PREF_PENDING_MESSAGES = "pending_messages"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var pendingMessages: PendingMessageStore? = null

    /** Whether the Flutter activity is in the foreground (between onResume and onPause). */
    @Volatile
    var appInForeground = false

    /** Sets up the persistent store; called by both the service and the activity. */
    @Synchronized
    fun init(context: Context) {
        if (pendingMessages != null) {
            return
        }
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        pendingMessages = PendingMessageStore(
            load = { prefs.getString(PREF_PENDING_MESSAGES, null) },
            save = { prefs.edit().putString(PREF_PENDING_MESSAGES, it).apply() }
        )
    }

    /** Attaches the Flutter sink and first delivers messages that arrived without one. */
    @Synchronized
    fun attach(eventSink: EventChannel.EventSink?) {
        sink = eventSink
        if (eventSink == null) {
            return
        }
        pendingMessages?.drain()?.forEach {
            eventSink.success(
                mapOf(
                    "type" to "message",
                    "deviceId" to it.deviceId,
                    "message" to it.message,
                    "receivedAt" to it.receivedAt
                )
            )
        }
    }

    @Synchronized
    fun detach() {
        sink = null
    }

    fun emit(event: Map<String, Any?>) {
        mainHandler.post {
            synchronized(BleEventBus) {
                val current = sink
                if (current != null) {
                    current.success(event)
                } else if (event["type"] == "message") {
                    // Other events describe state that's replayed on the next initialize;
                    // a message is lost unless it's kept.
                    pendingMessages?.add(
                        PendingMessage(
                            deviceId = event["deviceId"] as? String ?: return@synchronized,
                            message = event["message"] as? String ?: return@synchronized,
                            receivedAt = event["receivedAt"] as? Long ?: System.currentTimeMillis()
                        )
                    )
                }
            }
        }
    }
}
