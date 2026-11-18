package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.text.Html
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.ClipboardMessage
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.DeliveryStatus
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.EngineEvent
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Envelope
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.PeerId

/**
 * Clipboard sharing over `/clipboard` (docs/protocol.md 10절): answering a peer that
 * asks for this phone's clipboard, and asking a peer for its own. Everything runs on
 * the main looper with the engine.
 *
 * Since Android 10 only the app with window focus may read the clipboard, so a
 * request that arrives while the app isn't on screen posts a notification, gets a
 * WAITING answer, and is answered once the user opens the app from it.
 */
@SuppressLint("StaticFieldLeak") // Holds the application context only.
object ClipboardShare {
    const val CHANNEL_ID = "ble_clipboard"
    private const val NOTIFICATION_ID = 3003
    private const val PREF_SHARING = "pref_clipboard_sharing"

    /** How long our request waits for the final answer. */
    const val REQUEST_TIMEOUT_MS = 60_000L

    /** How long a peer's request waits for this phone's user; under its timeout. */
    private const val WAIT_FOR_USER_MS = 55_000L

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var context: Context

    private class Request(val peerId: PeerId, val deviceId: String, val msgId: Long)

    // Peers' requests waiting until the app has focus.
    private val waiting = mutableListOf<Request>()
    private val giveUpWaiting = Runnable {
        val expired = waiting.toList()
        waiting.clear()
        expired.forEach {
            cancelNotification(it.deviceId)
            reply(it, ClipboardMessage.reply(ClipboardMessage.UNAVAILABLE))
        }
    }

    // Our requests waiting for the final answer, by msgId.
    private class Pending(val deviceId: String, val timeout: Runnable)

    private val pending = HashMap<Long, Pending>()

    fun init(context: Context) {
        this.context = context.applicationContext
        this.context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "클립보드 요청", NotificationManager.IMPORTANCE_HIGH)
        )
    }

    private val prefs
        get() = context.getSharedPreferences("ble_service_prefs", Context.MODE_PRIVATE)

    /** Whether peers may read this phone's clipboard (the 클립보드 공유 setting). */
    var sharingEnabled: Boolean
        get() = prefs.getBoolean(PREF_SHARING, true)
        set(value) {
            prefs.edit().putBoolean(PREF_SHARING, value).apply()
        }

    // ------------------------------------------------------------ answering

    fun onRequest(peerId: PeerId, data: Envelope.Data, done: (Int) -> Unit) {
        if (!ClipboardMessage.isGetText(data.payload)) {
            done(DeliveryStatus.UNSUPPORTED)
            return
        }
        // The ACK says the request arrived; the clipboard comes in the reply.
        done(DeliveryStatus.OK)
        val request = Request(peerId, deviceIdOf(peerId), data.msgId)
        when {
            !sharingEnabled -> reply(request, ClipboardMessage.reply(ClipboardMessage.DENIED))
            BleEventBus.appHasFocus -> answer(request)
            !NotificationManagerCompat.from(context).areNotificationsEnabled() ->
                reply(request, ClipboardMessage.reply(ClipboardMessage.UNAVAILABLE))
            else -> {
                waiting.removeAll { it.peerId == peerId }
                waiting += request
                notifyRequest(request)
                reply(request, ClipboardMessage.reply(ClipboardMessage.WAITING))
                handler.removeCallbacks(giveUpWaiting)
                handler.postDelayed(giveUpWaiting, WAIT_FOR_USER_MS)
            }
        }
    }

    /** The app's window got focus: it may read the clipboard now. */
    fun onFocus() {
        if (waiting.isEmpty()) {
            return
        }
        val requests = waiting.toList()
        waiting.clear()
        handler.removeCallbacks(giveUpWaiting)
        requests.forEach {
            cancelNotification(it.deviceId)
            answer(it)
        }
    }

    private fun answer(request: Request) {
        val payload = readClipboard()
        reply(request, payload) { status ->
            if (status == DeliveryStatus.OK && ClipboardMessage.decodeReply(payload)?.result == ClipboardMessage.OK) {
                BleEventBus.emit(mapOf("type" to "clipboardShared", "deviceId" to request.deviceId))
            }
        }
    }

    private fun readClipboard(): ByteArray {
        val clip = context.getSystemService(ClipboardManager::class.java).primaryClip
        if (clip == null || clip.itemCount == 0) {
            return ClipboardMessage.reply(ClipboardMessage.EMPTY)
        }
        val item = clip.getItemAt(0)
        val text = item.text?.toString()
            ?: item.htmlText?.let { Html.fromHtml(it, Html.FROM_HTML_MODE_LEGACY).toString() }
            // A URI to text content; an image's URI isn't text.
            ?: if (clip.description.hasMimeType("text/*")) item.coerceToText(context)?.toString() else null
        return if (text == null) {
            ClipboardMessage.reply(ClipboardMessage.NOT_TEXT)
        } else {
            ClipboardMessage.replyWithText(text)
        }
    }

    private fun reply(request: Request, payload: ByteArray, onResult: ((Int) -> Unit)? = null) {
        BleRuntime.engine.send(request.peerId, ClipboardMessage.PATH, payload, request.msgId, 0, null) {
            onResult?.invoke(it)
        }
    }

    @SuppressLint("MissingPermission") // Checked by areNotificationsEnabled.
    private fun notifyRequest(request: Request) {
        val name = BleRuntime.store.peers().firstOrNull { it.peerId == request.peerId }?.name
            ?.takeIf { it.isNotBlank() } ?: request.deviceId
        val openApp = PendingIntent.getActivity(
            context,
            1,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle("클립보드 요청: $name")
            .setContentText("눌러서 이 기기의 클립보드를 보냅니다")
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setTimeoutAfter(WAIT_FOR_USER_MS)
            .build()
        NotificationManagerCompat.from(context).notify(request.deviceId, NOTIFICATION_ID, notification)
    }

    private fun cancelNotification(deviceId: String) {
        NotificationManagerCompat.from(context).cancel(deviceId, NOTIFICATION_ID)
    }

    // ------------------------------------------------------------ asking

    /** Asks the peer at [deviceId] for its clipboard; answered by `clipboard` events. */
    fun request(deviceId: String) {
        val peerId = peerIdOf(deviceId)
        if (peerId == null) {
            emit(deviceId, "failed", status = DeliveryStatus.EXPIRED_NOT_SENT)
            return
        }
        var msgId = 0L
        var failedEarly: Int? = null
        msgId = BleRuntime.engine.send(
            peerId, ClipboardMessage.PATH, ClipboardMessage.request(), 0, REQUEST_TIMEOUT_MS, null
        ) { status ->
            if (status == DeliveryStatus.OK) {
                return@send
            }
            // A local failure can come before send returns the msgId.
            if (msgId == 0L) {
                failedEarly = status
            } else {
                finish(msgId)?.let { emit(it, "failed", status = status) }
            }
        }
        failedEarly?.let {
            emit(deviceId, "failed", status = it)
            return
        }
        if (msgId == 0L) {
            emit(deviceId, "failed", status = DeliveryStatus.MALFORMED)
            return
        }
        val id = msgId
        val timeout = Runnable { finish(id)?.let { emit(it, "timeout") } }
        pending[id] = Pending(deviceId, timeout)
        handler.postDelayed(timeout, REQUEST_TIMEOUT_MS)
    }

    fun onReply(data: Envelope.Data) {
        val request = pending[data.replyTo] ?: return
        val reply = ClipboardMessage.decodeReply(data.payload) ?: return
        if (reply.result == ClipboardMessage.WAITING) {
            emit(request.deviceId, "waiting")
            return
        }
        finish(data.replyTo)
        emit(request.deviceId, ClipboardMessage.resultName(reply.result), reply.text)
    }

    /** Ends our request [msgId]; returns its device, or null if it already ended. */
    private fun finish(msgId: Long): String? {
        val request = pending.remove(msgId) ?: return null
        handler.removeCallbacks(request.timeout)
        return request.deviceId
    }

    private fun emit(deviceId: String, result: String, text: String? = null, status: Int? = null) {
        BleEventBus.emit(
            mapOf("type" to "clipboard", "deviceId" to deviceId, "result" to result, "text" to text, "status" to status)
        )
    }

    private fun peerIdOf(deviceId: String): PeerId? {
        val session = BleRuntime.engine.connectedSessions().firstOrNull { it.deviceId == deviceId }
        return session?.peerId ?: BleRuntime.store.peers().firstOrNull { it.deviceId == deviceId }?.peerId
    }

    private fun deviceIdOf(peerId: PeerId): String {
        val session: EngineEvent.Connected? = BleRuntime.engine.connectedSessions().firstOrNull { it.peerId == peerId }
        return session?.deviceId
            ?: BleRuntime.store.peers().firstOrNull { it.peerId == peerId }?.deviceId
            ?: peerId.toString()
    }
}
