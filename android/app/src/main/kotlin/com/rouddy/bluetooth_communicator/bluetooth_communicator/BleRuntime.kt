package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Cancellable
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Capabilities
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.DeliveryStatus
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.EngineEvent
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.EngineHost
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Envelope
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.LocalIdentity
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.PeerId
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.PeerState
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Platform
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.ProtocolEngine
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.RejectReason
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Scheduler

/** The GATT side of the engine; [BluetoothBackgroundService] while it runs. */
interface BleTransport {
    fun writeFrame(linkId: Int, frame: ByteArray)

    fun closeLink(linkId: Int)

    fun onEngineEvent(event: EngineEvent)
}

/** Routes messages to and from other apps (the AIDL service). */
interface AppRouter {
    fun localCaps(): Capabilities

    fun deliver(peerId: PeerId, data: Envelope.Data, done: (Int) -> Unit)

    fun onPeersChanged()
}

/**
 * The process-wide protocol engine and its host. The engine outlives the BLE service
 * (an AIDL client may queue a message before the service starts), and every call
 * into it runs on the main looper.
 */
@SuppressLint("StaticFieldLeak") // Holds the application context only.
object BleRuntime : EngineHost {
    private const val TAG = "BleRuntime"
    const val PAIRING_CHANNEL_ID = "ble_pairing"
    private const val PAIRING_NOTIFICATION_ID = 3002

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var context: Context
    lateinit var store: AndroidPeerStore
        private set
    lateinit var engine: ProtocolEngine
        private set

    var transport: BleTransport? = null
    var router: AppRouter? = null

    private val scheduler = object : Scheduler {
        override fun now() = SystemClock.elapsedRealtime()

        override fun schedule(delayMs: Long, action: () -> Unit): Cancellable {
            val runnable = Runnable(action)
            handler.postDelayed(runnable, delayMs)
            return Cancellable { handler.removeCallbacks(runnable) }
        }
    }

    @Synchronized
    fun init(context: Context) {
        if (::engine.isInitialized) {
            return
        }
        this.context = context.applicationContext
        store = AndroidPeerStore(this.context)
        engine = ProtocolEngine(this, store, scheduler)
        this.context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(PAIRING_CHANNEL_ID, "기기 연결 요청", NotificationManager.IMPORTANCE_HIGH)
        )
    }

    /** Runs [block] on the engine's thread. */
    fun post(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            handler.post(block)
        }
    }

    /** Tells a newly attached Dart side the current sessions, peers, and prompts. */
    fun replay() {
        engine.connectedSessions().forEach(::onDartEvent)
        BleEventBus.emit(peersEvent())
        engine.pendingApprovals().forEach(::onDartEvent)
    }

    override fun writeFrame(linkId: Int, frame: ByteArray) {
        val current = transport
        if (current == null) {
            handler.post { engine.frameWritten(linkId, false) }
        } else {
            current.writeFrame(linkId, frame)
        }
    }

    override fun closeLink(linkId: Int) {
        transport?.closeLink(linkId)
    }

    override fun localIdentity(): LocalIdentity {
        // Samsung and others let the user name the phone; that's what HELLO shows.
        val name = Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            ?.takeIf { it.isNotBlank() }
            ?: Build.MODEL
        val version = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull() ?: ""
        return LocalIdentity(name, Platform.ANDROID, version)
    }

    override fun localCaps(): Capabilities = router?.localCaps() ?: Capabilities(emptyList(), emptyList())

    override fun deliver(peerId: PeerId, data: Envelope.Data, done: (Int) -> Unit) {
        val target = router
        when {
            // No built-in paths yet (/control/media is a later step).
            data.path.startsWith("/") -> done(DeliveryStatus.UNSUPPORTED)
            target == null -> done(DeliveryStatus.NO_RECEIVER)
            else -> target.deliver(peerId, data, done)
        }
    }

    override fun onEvent(event: EngineEvent) {
        if (event is EngineEvent.PeersChanged) {
            schedulePeersEvent()
        } else {
            onDartEvent(event)
        }
        when (event) {
            is EngineEvent.PairingRequest -> notifyPairing(event)
            is EngineEvent.PairingResult -> cancelPairingNotification(event.deviceId)
            else -> Unit
        }
        transport?.onEngineEvent(event)
        if (event is EngineEvent.PeersChanged || event is EngineEvent.Connected || event is EngineEvent.Disconnected) {
            router?.onPeersChanged()
        }
    }

    override fun log(message: String) {
        Log.d(TAG, message)
    }

    private fun onDartEvent(event: EngineEvent) {
        val map: Map<String, Any?> = when (event) {
            is EngineEvent.Connected -> mapOf(
                "type" to "connected",
                "deviceId" to event.deviceId,
                "peerId" to event.peerId.toString(),
                "name" to event.name
            )
            is EngineEvent.Disconnected -> mapOf("type" to "disconnected", "deviceId" to event.deviceId)
            is EngineEvent.PairingRequest -> mapOf(
                "type" to "pairingRequest",
                "deviceId" to event.deviceId,
                "peerId" to event.peerId.toString(),
                "name" to event.name,
                "code" to event.code,
                "repair" to event.repair
            )
            is EngineEvent.PairingResult -> mapOf(
                "type" to "pairingResult",
                "deviceId" to event.deviceId,
                "peerId" to event.peerId.toString(),
                "result" to event.result
            )
            is EngineEvent.PeerRejected -> mapOf(
                "type" to "peerRejected",
                "deviceId" to event.deviceId,
                "reason" to RejectReason.name(event.reason),
                "byPeer" to event.byPeer
            )
            is EngineEvent.PeerUnpaired -> mapOf("type" to "peerUnpaired", "deviceId" to event.deviceId)
            is EngineEvent.Error -> mapOf("type" to "error", "message" to event.message)
            EngineEvent.PeersChanged -> peersEvent()
        }
        BleEventBus.emit(map)
    }

    private var peersEventPending = false

    // A session start changes the peers several times in a row; send one list.
    private fun schedulePeersEvent() {
        if (peersEventPending) {
            return
        }
        peersEventPending = true
        handler.post {
            peersEventPending = false
            BleEventBus.emit(peersEvent())
        }
    }

    fun peersEvent(): Map<String, Any?> = mapOf(
        "type" to "peers",
        "peers" to engine.peerSummaries().map { summary ->
            mapOf(
                "peerId" to summary.peer.peerId.toString(),
                "deviceId" to summary.peer.deviceId,
                "name" to summary.peer.name,
                "platform" to summary.peer.platform,
                "state" to when (summary.peer.state) {
                    PeerState.PAIRED -> "paired"
                    PeerState.REPAIR_NEEDED -> "repairNeeded"
                    PeerState.BAD_MAC -> "badMac"
                    PeerState.UNPAIRED_BY_PEER -> "unpairedByPeer"
                },
                "connected" to summary.connected
            )
        }
    )

    /**
     * 6.3: the peripheral's user has to approve too. If the app isn't on screen, a
     * notification brings it up; Dart gets the prompt again on attach (replay).
     */
    @SuppressLint("MissingPermission")
    private fun notifyPairing(request: EngineEvent.PairingRequest) {
        val manager = NotificationManagerCompat.from(context)
        if (BleEventBus.appInForeground || !manager.areNotificationsEnabled()) {
            return
        }
        val openApp = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val name = request.name.ifBlank { request.deviceId }
        val notification = NotificationCompat.Builder(context, PAIRING_CHANNEL_ID)
            .setContentTitle(if (request.repair) "다시 연결 요청: $name" else "연결 요청: $name")
            .setContentText("확인 코드 ${request.code} · 눌러서 승인하세요")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setTimeoutAfter(ProtocolEngine.APPROVAL_TIMEOUT_MS)
            .build()
        manager.notify(request.deviceId, PAIRING_NOTIFICATION_ID, notification)
    }

    private fun cancelPairingNotification(deviceId: String) {
        NotificationManagerCompat.from(context).cancel(deviceId, PAIRING_NOTIFICATION_ID)
    }
}
