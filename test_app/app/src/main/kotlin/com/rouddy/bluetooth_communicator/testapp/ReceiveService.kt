package com.rouddy.bluetooth_communicator.testapp

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.util.Log
import com.rouddy.bluetooth_communicator.api.IBleCommunicator
import com.rouddy.bluetooth_communicator.api.IBleListener

/**
 * Receives messages while the activity isn't registered as a listener. The
 * communicator binds it on demand (starting this app if needed).
 */
class ReceiveService : Service() {
    private val binder = object : IBleListener.Stub() {
        override fun onMessage(peerId: String, path: String, data: ByteArray, msgId: Long, replyTo: Long) {
            // Exported, so anyone could call it; accept only the communicator. (A real
            // app should also check the communicator's signing certificate.)
            val caller = packageManager.getPackagesForUid(Binder.getCallingUid())
            if (caller?.contains(IBleCommunicator.SERVICE_PACKAGE) != true) {
                Log.w(MainActivity.TAG, "Ignored a message from ${caller?.toList()}")
                return
            }
            val text = data.toString(Charsets.UTF_8)
            if (MessageLog.received(applicationContext, peerId, text, msgId, via = "service")) {
                Log.i(MainActivity.TAG, "Received via ReceiveService from $peerId #$msgId: $text")
            }
        }

        override fun onPeersChanged() = Unit
    }

    override fun onBind(intent: Intent?): IBinder = binder
}
