package com.rouddy.bluetooth_communicator.bluetooth_communicator

import io.flutter.plugin.common.EventChannel

object BleEventBus {
    private var sink: EventChannel.EventSink? = null

    @Synchronized
    fun attach(eventSink: EventChannel.EventSink?) {
        sink = eventSink
    }

    @Synchronized
    fun detach() {
        sink = null
    }

    @Synchronized
    fun emit(event: Map<String, Any?>) {
        sink?.success(event)
    }
}
