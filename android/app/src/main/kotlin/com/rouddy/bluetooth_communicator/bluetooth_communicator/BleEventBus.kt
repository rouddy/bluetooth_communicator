package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

object BleEventBus {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

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
