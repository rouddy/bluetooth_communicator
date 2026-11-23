package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.DeliveryStatus
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.EngineEvent
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Envelope
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.MediaMessage
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.PeerId

/**
 * Remote media keys over `/control/media` (docs/protocol.md 10절): pressing a key on
 * this phone for a peer, and pressing one on a peer. Keys go to the active media
 * session through [AudioManager.dispatchMediaKeyEvent], which needs no permission.
 * Everything runs on the main looper with the engine.
 */
@SuppressLint("StaticFieldLeak") // Holds the application context only.
object MediaControl {
    private const val TAG = "MediaControl"

    /** How long our command waits for the answer; also its TTL. */
    const val REQUEST_TIMEOUT_MS = 10_000L

    /** The player takes a moment to start or stop; the answer's state is read after this. */
    private const val SETTLE_MS = 600L

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var context: Context

    fun init(context: Context) {
        this.context = context.applicationContext
    }

    private val audio get() = context.getSystemService(AudioManager::class.java)

    // ------------------------------------------------------------ answering

    fun onRequest(peerId: PeerId, data: Envelope.Data, done: (Int) -> Unit) {
        val op = MediaMessage.decodeRequest(data.payload)
        if (op == null) {
            done(DeliveryStatus.MALFORMED)
            return
        }
        // The ACK says the command arrived; its outcome comes in the reply.
        done(DeliveryStatus.OK)
        val keyCode = keyCodeOf(op)
        when {
            op == MediaMessage.OP_GET_STATE -> reply(peerId, data.msgId, MediaMessage.OK)
            keyCode == null -> reply(peerId, data.msgId, MediaMessage.UNSUPPORTED_OP)
            else -> {
                val pressed = runCatching { pressKey(keyCode) }
                    .onFailure { Log.w(TAG, "Couldn't press ${MediaMessage.opName(op)}", it) }
                    .isSuccess
                if (pressed) {
                    handler.postDelayed({ reply(peerId, data.msgId, MediaMessage.OK) }, SETTLE_MS)
                } else {
                    reply(peerId, data.msgId, MediaMessage.FAILED)
                }
            }
        }
    }

    private fun keyCodeOf(op: Int): Int? = when (op) {
        MediaMessage.OP_PLAY -> KeyEvent.KEYCODE_MEDIA_PLAY
        MediaMessage.OP_PAUSE -> KeyEvent.KEYCODE_MEDIA_PAUSE
        MediaMessage.OP_PLAY_PAUSE -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
        MediaMessage.OP_STOP -> KeyEvent.KEYCODE_MEDIA_STOP
        MediaMessage.OP_NEXT -> KeyEvent.KEYCODE_MEDIA_NEXT
        MediaMessage.OP_PREVIOUS -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
        else -> null
    }

    private fun pressKey(keyCode: Int) {
        val time = SystemClock.uptimeMillis()
        audio.dispatchMediaKeyEvent(KeyEvent(time, time, KeyEvent.ACTION_DOWN, keyCode, 0))
        audio.dispatchMediaKeyEvent(KeyEvent(time, time, KeyEvent.ACTION_UP, keyCode, 0))
    }

    private fun state(): Int =
        if (audio.isMusicActive) MediaMessage.STATE_PLAYING else MediaMessage.STATE_NOT_PLAYING

    private fun reply(peerId: PeerId, requestId: Long, result: Int) {
        val payload = MediaMessage.reply(result, state())
        BleRuntime.engine.send(peerId, MediaMessage.PATH, payload, requestId, 0, null) {}
    }

    // ------------------------------------------------------------ asking

    // Our commands waiting for their answer, by msgId.
    private class Pending(val deviceId: String, val op: Int, val timeout: Runnable)

    private val pending = HashMap<Long, Pending>()

    /** Presses [op] on the peer at [deviceId]; answered by a `mediaControl` event. */
    fun request(deviceId: String, op: Int) {
        val peerId = peerIdOf(deviceId)
        if (peerId == null) {
            emit(deviceId, op, "undelivered", status = DeliveryStatus.EXPIRED_NOT_SENT)
            return
        }
        // A peer that told us what it supports and left this out (an iPhone) can't do it.
        val caps = BleRuntime.engine.capsOf(peerId)
        if (caps != null && MediaMessage.PATH !in caps.builtins) {
            emit(deviceId, op, "unsupported")
            return
        }
        var msgId = 0L
        var failedEarly: Int? = null
        msgId = BleRuntime.engine.send(
            peerId, MediaMessage.PATH, MediaMessage.request(op), 0, REQUEST_TIMEOUT_MS, null
        ) { status ->
            if (status == DeliveryStatus.OK) {
                return@send
            }
            // A local failure can come before send returns the msgId.
            if (msgId == 0L) {
                failedEarly = status
            } else {
                finish(msgId)?.let { emitFailure(it.deviceId, it.op, status) }
            }
        }
        failedEarly?.let {
            emitFailure(deviceId, op, it)
            return
        }
        if (msgId == 0L) {
            emit(deviceId, op, "undelivered", status = DeliveryStatus.MALFORMED)
            return
        }
        val id = msgId
        val timeout = Runnable { finish(id)?.let { emit(it.deviceId, it.op, "timeout") } }
        pending[id] = Pending(deviceId, op, timeout)
        handler.postDelayed(timeout, REQUEST_TIMEOUT_MS)
    }

    fun onReply(data: Envelope.Data) {
        val reply = MediaMessage.decodeReply(data.payload) ?: return
        val request = finish(data.replyTo) ?: return
        emit(request.deviceId, request.op, MediaMessage.resultName(reply.result), MediaMessage.stateName(reply.state))
    }

    private fun emitFailure(deviceId: String, op: Int, status: Int) {
        if (status == DeliveryStatus.UNSUPPORTED) {
            emit(deviceId, op, "unsupported")
        } else {
            emit(deviceId, op, "undelivered", status = status)
        }
    }

    /** Ends our command [msgId]; returns it, or null if it already ended. */
    private fun finish(msgId: Long): Pending? {
        val request = pending.remove(msgId) ?: return null
        handler.removeCallbacks(request.timeout)
        return request
    }

    private fun emit(deviceId: String, op: Int, result: String, state: String? = null, status: Int? = null) {
        BleEventBus.emit(
            mapOf(
                "type" to "mediaControl",
                "deviceId" to deviceId,
                "op" to MediaMessage.opName(op),
                "result" to result,
                "state" to state,
                "status" to status
            )
        )
    }

    private fun peerIdOf(deviceId: String): PeerId? {
        val session: EngineEvent.Connected? = BleRuntime.engine.connectedSessions().firstOrNull { it.deviceId == deviceId }
        return session?.peerId ?: BleRuntime.store.peers().firstOrNull { it.deviceId == deviceId }?.peerId
    }
}
