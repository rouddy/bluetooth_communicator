package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Posts native events to the Flutter EventSink on the main looper. Without a sink
 * (no Flutter UI) they're dropped: they describe state, which the next initialize
 * replays (BleRuntime.replay). Messages for other apps go through the AIDL service.
 */
object BleEventBus {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    /** Whether the Flutter activity is in the foreground (between onResume and onPause). */
    @Volatile
    var appInForeground = false
        set(value) {
            if (field == value) {
                return
            }
            field = value
            foregroundListener?.invoke(value)
        }

    /** Set by the service to adapt its scan mode; called on the main thread. */
    var foregroundListener: ((Boolean) -> Unit)? = null

    @Synchronized
    fun attach(eventSink: EventChannel.EventSink?) {
        sink = eventSink
    }

    @Synchronized
    fun detach() {
        sink = null
    }

    fun emit(event: Map<String, Any?>) {
        mainHandler.post {
            synchronized(BleEventBus) {
                sink?.success(event)
            }
        }
    }
}
