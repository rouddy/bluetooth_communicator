package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

enum class Role { CENTRAL, PERIPHERAL }

fun interface Cancellable {
    fun cancel()
}

/** Time and timers; tests drive them with a virtual clock. */
interface Scheduler {
    /** Monotonic milliseconds. */
    fun now(): Long

    fun schedule(delayMs: Long, action: () -> Unit): Cancellable
}

enum class PeerState {
    /** Has K; reconnected automatically. */
    PAIRED,

    /** Has K, but the peer answered UNKNOWN_PEER (it deleted us or reinstalled). */
    REPAIR_NEEDED,

    /** Has K, but an AUTH didn't verify; possibly an attack, so no automatic reconnects. */
    BAD_MAC,

    /** The peer sent UNPAIR; K is gone. */
    UNPAIRED_BY_PEER
}

data class StoredPeer(
    val peerId: PeerId,
    val name: String,
    val deviceId: String,
    val platform: Int,
    val state: PeerState
)

/** Peers that went through app pairing, and their keys (6.6). */
interface PeerStore {
    val localPeerId: PeerId

    /** The next msgId (9절): increases across all peers and restarts, never 0. */
    fun nextMsgId(): Long

    fun peers(): List<StoredPeer>

    fun key(peerId: PeerId): PeerKey?

    /** Stores K and the peer, replacing entries with the same peerId or deviceId. */
    fun savePaired(peer: StoredPeer, key: ByteArray)

    fun update(peer: StoredPeer)

    fun deleteKey(peerId: PeerId)

    /** Forgets the peer and its key. */
    fun remove(peerId: PeerId)
}

class LocalIdentity(val name: String, val platform: Int, val appVersion: String)

/** What this phone can receive, sent to peers as CAPS (7절). */
data class Capabilities(val builtins: List<String>, val apps: List<AppIdentity>)

sealed class EngineEvent {
    /** A session was established (6.1); `connected` on the platform channel. */
    data class Connected(val deviceId: String, val peerId: PeerId, val name: String) : EngineEvent()

    /** No established link to [deviceId] is left. */
    data class Disconnected(val deviceId: String) : EngineEvent()

    /** Both sides show [code] and wait for the user (6.3). */
    data class PairingRequest(
        val deviceId: String,
        val peerId: PeerId,
        val name: String,
        val code: String,
        val repair: Boolean
    ) : EngineEvent()

    /** The end of an app pairing: `paired`, or why it failed. */
    data class PairingResult(val deviceId: String, val peerId: PeerId, val result: String) : EngineEvent()

    /** A REJECT was sent ([byPeer] false) or received. */
    data class PeerRejected(val deviceId: String, val reason: Int, val byPeer: Boolean) : EngineEvent()

    /** The peer removed this phone (UNPAIR). */
    data class PeerUnpaired(val deviceId: String, val peerId: PeerId) : EngineEvent()

    /** The stored peers, their connection state, or their CAPS changed. */
    object PeersChanged : EngineEvent()

    data class Error(val message: String) : EngineEvent()
}

interface EngineHost {
    /** Writes one frame; answer with [ProtocolEngine.frameWritten]. */
    fun writeFrame(linkId: Int, frame: ByteArray)

    /** Drops the link. The engine has already forgotten it. */
    fun closeLink(linkId: Int)

    fun localIdentity(): LocalIdentity

    /** Whether the user can be asked to approve a pairing right now. */
    fun canPrompt(): Boolean = true

    fun localCaps(): Capabilities

    /** Hands a received DATA to its target; [done] gets the ACK status. */
    fun deliver(peerId: PeerId, data: Envelope.Data, done: (Int) -> Unit)

    fun onEvent(event: EngineEvent)

    fun log(message: String) {}
}

data class PeerSummary(
    val peer: StoredPeer,
    val connected: Boolean,
    val caps: Capabilities?
)

/** The derivations of 6.3 and 6.4. */
object Derivation {
    private val COMMIT = "rbc-commit-v1".toByteArray()
    private val PAIR_KEY = "rbc-pair-key-v1".toByteArray()
    private val CODE = "rbc-code-v1".toByteArray()
    private val CONFIRM = "rbc-confirm-v1".toByteArray()
    private val AUTH = "rbc-auth-v1".toByteArray()
    private val SESSION = "rbc-session-v1".toByteArray()

    fun tHello(helloC: ByteArray, helloP: ByteArray) = Crypto.sha256(helloC, helloP)

    fun commit(publicKeyP: ByteArray) = Crypto.sha256(COMMIT, publicKeyP)

    fun tPair(tHello: ByteArray, publicKeyP: ByteArray, publicKeyC: ByteArray) =
        Crypto.sha256(tHello, publicKeyP, publicKeyC)

    fun pairKey(sharedSecret: ByteArray, tPair: ByteArray) =
        Crypto.hkdf(sharedSecret, tPair, PAIR_KEY, Crypto.KEY_SIZE)

    /** Six digits from the first four bytes (u32 LE) of H("rbc-code-v1" ‖ T_pair). */
    fun code(tPair: ByteArray): String {
        val value = ByteReader(Crypto.sha256(CODE, tPair)).u32()
        return "%06d".format(value % 1_000_000)
    }

    fun confirmMac(key: PeerKey, sender: PeerId, tPair: ByteArray) =
        key.hmac(CONFIRM + sender.bytes + tPair)

    fun authMac(key: PeerKey, sender: PeerId, tHello: ByteArray) =
        key.hmac(AUTH + sender.bytes + tHello)

    /** k(from→to), used for the SEALED records [from] sends. */
    fun sessionKey(key: PeerKey, from: PeerId, to: PeerId, tHello: ByteArray) =
        key.hmac(SESSION + from.bytes + to.bytes + tHello)
}

/**
 * The protocol of docs/protocol.md for every link of this phone: framing, the
 * handshake and app pairing, SEALED records, one link per peer, and delivery (ACK,
 * dedup, retransmission, TTL, flow control, CAPS, UNPAIR).
 *
 * Not thread-safe: call it from one thread (the Android service uses the main
 * looper). It has no Android dependencies, so it's tested on the JVM.
 */
class ProtocolEngine(
    private val host: EngineHost,
    private val store: PeerStore,
    private val scheduler: Scheduler,
    private val random: java.security.SecureRandom = java.security.SecureRandom()
) {
    companion object {
        const val PRIORITY_HANDSHAKE = 0
        const val PRIORITY_ACK = 1
        const val PRIORITY_CONTROL = 2
        const val PRIORITY_DATA = 3
        private const val PRIORITY_COUNT = 4

        const val HANDSHAKE_TIMEOUT_MS = 10_000L
        const val APPROVAL_TIMEOUT_MS = 60_000L
        const val ACK_TIMEOUT_MS = 10_000L
        const val UNPAIR_TIMEOUT_MS = 3_000L
        const val DEDUP_MS = 120_000L
        const val CONTROL_TTL_MS = 10_000L
        const val DEFAULT_TTL_MS = 30_000L
        const val MAX_TTL_MS = 60_000L
        const val MAX_IN_FLIGHT = 4
        const val MAX_DECRYPT_FAILURES = 5
        const val RETRY_DELAY_MS = 1_000L
        const val PROBE_TIMEOUT_MS = 3_000L

        /** A built-in path that only gets an ACK: proof that a link is alive. */
        const val PING_PATH = "/ping"
        private const val MAX_COUNTER = 0xFFFF_FFFFL

        /** SEALED header and tag around an envelope. */
        const val SEALED_OVERHEAD = 6 + Record.GCM_TAG_SIZE

        const val RESULT_PAIRED = "paired"
        const val RESULT_LINK_LOST = "linkLost"

        fun pairingFailure(reason: Int): String = when (reason) {
            RejectReason.USER_REJECTED -> "rejected"
            RejectReason.TIMEOUT -> "timeout"
            RejectReason.CANNOT_PROMPT -> "cannotPrompt"
            RejectReason.COMMIT_MISMATCH -> "mismatch"
            RejectReason.BAD_MAC -> "badMac"
            else -> RejectReason.name(reason)
        }
    }

    private enum class Phase { AWAIT_HELLO, AWAIT_AUTH, PAIRING, ESTABLISHED, DONE }

    private class Pairing(val repair: Boolean) {
        var keyPair: Crypto.EcKeyPair? = null
        var commit: ByteArray? = null
        var key: ByteArray? = null
        var tPair: ByteArray? = null
        var code: String? = null
        var localApproved = false
        var peerConfirmed = false
        var approvalTimer: Cancellable? = null
    }

    private class Session(val sendKey: ByteArray, val receiveKey: ByteArray) {
        var sendCounter = 0L
        val window = ReplayWindow()
        var decryptFailures = 0
    }

    private class OutgoingRecord(
        val bytes: ByteArray,
        val priority: Int,
        val onWritten: ((Boolean) -> Unit)?
    ) {
        var frames: List<ByteArray>? = null
        var next = 0
        var tid = -1
    }

    private inner class Link(
        val id: Int,
        val role: Role,
        val deviceId: String,
        val userInitiated: Boolean,
        var maxFrameSize: Int
    ) {
        val reassembler = FrameReassembler(MAX_MESSAGE_SIZE)
        var phase = Phase.AWAIT_HELLO
        var ownHello: ByteArray? = null
        var peerHello: Record.Hello? = null
        var tHello: ByteArray? = null
        var pairing: Pairing? = null
        var session: Session? = null
        var handshakeTimer: Cancellable? = null
        var closed = false

        /** HELLOs received; a deferred decision about an older HELLO is dropped. */
        var helloCount = 0

        /** `/ping` msgIds waiting for their ACK. */
        val probes = HashMap<Long, () -> Unit>()

        val peerId: PeerId?
            get() = peerHello?.peerId

        val peerName: String
            get() = peerHello?.name ?: ""

        // Frame scheduling (4절, 9절): one queue per priority. The head record of the
        // highest non-empty priority sends its next frame, so handshakes, ACKs, and
        // commands slip in between the frames of a long record.
        private val queues = Array(PRIORITY_COUNT) { ArrayDeque<OutgoingRecord>() }
        private val tidsInUse = BooleanArray(Frames.TID_COUNT)
        private var nextTid = 0
        private var writing: OutgoingRecord? = null
        private var pumping = false
        private var pumpAgain = false

        fun enqueue(record: OutgoingRecord) {
            queues[record.priority].addLast(record)
            pump()
        }

        fun frameWritten(success: Boolean) {
            val record = writing ?: return
            writing = null
            if (!success) {
                queues[record.priority].remove(record)
                tidsInUse[record.tid] = false
                record.onWritten?.invoke(false)
            } else {
                record.next++
                if (record.next == record.frames!!.size) {
                    queues[record.priority].remove(record)
                    tidsInUse[record.tid] = false
                    record.onWritten?.invoke(true)
                }
            }
            pump()
        }

        fun failAll() {
            val records = queues.flatMap { it.toList() }
            queues.forEach { it.clear() }
            writing = null
            tidsInUse.fill(false)
            records.forEach { it.onWritten?.invoke(false) }
        }

        private fun pump() {
            // A host that completes a write synchronously calls frameWritten from
            // inside writeFrame; loop instead of recursing.
            if (pumping) {
                pumpAgain = true
                return
            }
            pumping = true
            try {
                do {
                    pumpAgain = false
                    startNextFrame()
                } while (pumpAgain)
            } finally {
                pumping = false
            }
        }

        private fun startNextFrame() {
            if (writing != null || closed) {
                return
            }
            val record = queues.firstOrNull { it.isNotEmpty() }?.first() ?: return
            if (record.frames == null) {
                record.tid = allocateTid()
                record.frames = Frames.split(record.bytes, record.tid, maxFrameSize)
            }
            writing = record
            host.writeFrame(id, record.frames!![record.next])
        }

        private fun allocateTid(): Int {
            for (step in 0 until Frames.TID_COUNT) {
                val tid = (nextTid + step) % Frames.TID_COUNT
                if (!tidsInUse[tid]) {
                    tidsInUse[tid] = true
                    nextTid = (tid + 1) % Frames.TID_COUNT
                    return tid
                }
            }
            error("No free tid") // At most one record per priority is in progress.
        }
    }

    private class Received(var status: Int?, val at: Long)

    private class Outgoing(
        val msgId: Long,
        val envelope: Envelope,
        val priority: Int,
        val app: AppIdentity?,
        val callback: (Int) -> Unit
    ) {
        var written = false
        var done = false
        var ttlTimer: Cancellable? = null
        var ackTimer: Cancellable? = null
    }

    /** Delivery state per peer; outlives links so sends can wait for a reconnect. */
    private inner class PeerChannel(val peerId: PeerId) {
        var link: Link? = null
        var caps: Capabilities? = null
        var capsMsgId = -1L
        var maxMessageSize = MAX_MESSAGE_SIZE.toLong()
        val outbox = ArrayDeque<Outgoing>()
        val inFlight = LinkedHashMap<Long, Outgoing>()
        val received = HashMap<Long, Received>()
        var retryScheduled = false
    }

    private val links = HashMap<Int, Link>()
    private val channels = HashMap<PeerId, PeerChannel>()

    // ---------------------------------------------------------------- links

    /**
     * A link became usable: for a central, its CCCD subscription succeeded; for a
     * peripheral, the central subscribed. [maxFrameSize] is ATT MTU - 3 (capped at
     * [Frames.MAX_FRAME_SIZE]).
     */
    fun linkUp(linkId: Int, role: Role, deviceId: String, maxFrameSize: Int, userInitiated: Boolean) {
        links.remove(linkId)?.let(::teardown)
        val link = Link(linkId, role, deviceId, userInitiated, maxFrameSize.coerceIn(Frames.MIN_FRAME_SIZE, Frames.MAX_FRAME_SIZE))
        links[linkId] = link
        host.log("Link $linkId up: $role to $deviceId, frames of ${link.maxFrameSize} bytes, user=$userInitiated")
        if (role == Role.CENTRAL) {
            sendHello(link)
        } else {
            armHandshakeTimer(link)
        }
    }

    fun hasLink(linkId: Int) = links.containsKey(linkId)

    /** The ATT MTU changed; frames split from now on use the new size. */
    fun setMaxFrameSize(linkId: Int, maxFrameSize: Int) {
        links[linkId]?.maxFrameSize = maxFrameSize.coerceIn(Frames.MIN_FRAME_SIZE, Frames.MAX_FRAME_SIZE)
    }

    fun frameReceived(linkId: Int, frame: ByteArray) {
        val link = links[linkId] ?: return
        val record = link.reassembler.accept(frame) ?: return
        onRecord(link, record)
    }

    fun frameWritten(linkId: Int, success: Boolean) {
        links[linkId]?.frameWritten(success)
    }

    /** The link went away (disconnect, unsubscribe, Bluetooth off). */
    fun linkDown(linkId: Int) {
        links.remove(linkId)?.let(::teardown)
    }

    /**
     * Whether the host should (re)connect to [deviceId] on its own: a paired peer
     * that has no link left (9절: not while another link to it exists).
     */
    fun shouldReconnect(deviceId: String): Boolean {
        val peer = store.peers().firstOrNull { it.deviceId == deviceId && it.state == PeerState.PAIRED }
            ?: return false
        return links.values.none { it.isLive() && (it.deviceId == deviceId || it.peerId == peer.peerId) }
    }

    /** Whether some link to [deviceId] is up or handshaking (any role). */
    fun hasLiveLink(deviceId: String) = links.values.any { it.isLive() && it.deviceId == deviceId }

    fun isConnected(deviceId: String) = links.values.any { it.phase == Phase.ESTABLISHED && it.deviceId == deviceId }

    fun connectedSessions(): List<EngineEvent.Connected> = links.values
        .filter { it.phase == Phase.ESTABLISHED }
        .map { EngineEvent.Connected(it.deviceId, it.peerId!!, it.peerName) }

    /** Pairings waiting for this user's answer, to show again when the UI attaches. */
    fun pendingApprovals(): List<EngineEvent.PairingRequest> = links.values.mapNotNull { link ->
        val pairing = link.pairing ?: return@mapNotNull null
        val code = pairing.code ?: return@mapNotNull null
        if (pairing.localApproved) {
            return@mapNotNull null
        }
        EngineEvent.PairingRequest(link.deviceId, link.peerId!!, link.peerName, code, pairing.repair)
    }

    fun peerSummaries(): List<PeerSummary> = store.peers().map { peer ->
        val channel = channels[peer.peerId]
        PeerSummary(peer, channel?.link?.phase == Phase.ESTABLISHED, channel?.caps)
    }

    /** The last CAPS [peerId] sent (kept across its sessions), or null if none yet. */
    fun capsOf(peerId: PeerId): Capabilities? = channels[peerId]?.caps

    private fun Link.isLive() = !closed && phase != Phase.DONE

    private fun close(link: Link) {
        if (link.closed) {
            return
        }
        links.remove(link.id)
        teardown(link)
        host.closeLink(link.id)
    }

    private fun teardown(link: Link) {
        host.log("Link ${link.id} to ${link.deviceId} down (${link.phase})")
        link.closed = true
        link.handshakeTimer?.cancel()
        link.pairing?.let { pairing ->
            pairing.approvalTimer?.cancel()
            // The UI is showing (or may show) its approval prompt; dismiss it.
            if (pairing.code != null) {
                link.peerId?.let { host.onEvent(EngineEvent.PairingResult(link.deviceId, it, RESULT_LINK_LOST)) }
            }
        }
        link.pairing = null
        // Requeue unacknowledged messages first, in order; the write failures that
        // failAll reports for them are then ignored.
        endSession(link)
        link.failAll()
        link.reassembler.reset()
        link.phase = Phase.DONE
        emitDisconnectedIfUnlinked(link.deviceId)
    }

    private fun emitDisconnectedIfUnlinked(deviceId: String) {
        if (links.values.none { it.phase == Phase.ESTABLISHED && it.deviceId == deviceId && !it.closed }) {
            host.onEvent(EngineEvent.Disconnected(deviceId))
        }
    }

    private fun sendRecord(link: Link, bytes: ByteArray, priority: Int, onWritten: ((Boolean) -> Unit)? = null) {
        if (link.closed) {
            onWritten?.invoke(false)
            return
        }
        link.enqueue(OutgoingRecord(bytes, priority, onWritten))
    }

    // ---------------------------------------------------------------- handshake

    private fun sendHello(link: Link) {
        link.phase = Phase.AWAIT_HELLO
        link.peerHello = null
        link.tHello = null
        link.pairing = null
        val bytes = ownHello()
        link.ownHello = bytes
        sendRecord(link, bytes, PRIORITY_HANDSHAKE)
        armHandshakeTimer(link)
    }

    private fun ownHello(): ByteArray {
        val identity = host.localIdentity()
        return Record.encode(
            Record.Hello(
                version = PROTOCOL_VERSION,
                peerId = store.localPeerId,
                nonce = ByteArray(Record.NONCE_SIZE).also(random::nextBytes),
                name = identity.name,
                platform = identity.platform,
                appVersion = identity.appVersion,
                maxMessageSize = MAX_MESSAGE_SIZE.toLong()
            )
        )
    }

    /**
     * 6.5: a central closes a link whose handshake doesn't finish in time. A
     * peripheral can't close it, but stops counting it as a link to that peer, or a
     * central that silently gave up (e.g. it dropped a duplicate link) would block
     * reconnects until Bluetooth disconnects. A new HELLO_c revives it.
     */
    private fun armHandshakeTimer(link: Link) {
        link.handshakeTimer?.cancel()
        link.handshakeTimer = scheduler.schedule(HANDSHAKE_TIMEOUT_MS) {
            if (!link.isLive() || link.phase == Phase.ESTABLISHED) {
                return@schedule
            }
            when (link.role) {
                Role.CENTRAL -> {
                    host.onEvent(EngineEvent.Error("Handshake with ${link.deviceId} timed out"))
                    close(link)
                }
                Role.PERIPHERAL -> {
                    link.pairing = null
                    link.phase = Phase.DONE
                    emitDisconnectedIfUnlinked(link.deviceId)
                }
            }
        }
    }

    private fun onRecord(link: Link, bytes: ByteArray) {
        if (link.closed) {
            return
        }
        val record = try {
            Record.decode(bytes)
        } catch (e: MalformedException) {
            host.log("Dropped a malformed record from ${link.deviceId}: ${e.message}")
            return
        }
        when (record) {
            is Record.Hello -> onHello(link, record, bytes)
            is Record.Sealed -> onSealed(link, record)
            else -> if (link.phase != Phase.ESTABLISHED && link.phase != Phase.DONE) {
                onHandshakeRecord(link, record)
            }
        }
    }

    private fun onHello(link: Link, hello: Record.Hello, bytes: ByteArray) {
        if (hello.peerId == store.localPeerId) {
            host.log("Ignored a HELLO with this phone's own peerId")
            return
        }
        link.helloCount++
        host.log("HELLO from ${link.deviceId} (${hello.peerId}, ${hello.name}) on link ${link.id} in ${link.phase}")
        when (link.role) {
            Role.PERIPHERAL -> {
                // A new HELLO_c restarts the handshake, e.g. the peer app restarted (6.5).
                if (link.phase != Phase.AWAIT_HELLO) {
                    resetPeripheral(link)
                }
                link.peerHello = hello
                if (hello.version < PROTOCOL_VERSION) {
                    reject(link, RejectReason.UNSUPPORTED_VERSION)
                    return
                }
                resolveOtherLink(link) {
                    val own = ownHello()
                    link.ownHello = own
                    link.tHello = Derivation.tHello(bytes, own)
                    link.phase = Phase.AWAIT_AUTH
                    sendRecord(link, own, PRIORITY_HANDSHAKE)
                    armHandshakeTimer(link)
                }
            }
            Role.CENTRAL -> {
                if (link.phase == Phase.DONE) {
                    return
                }
                if (link.phase != Phase.AWAIT_HELLO) {
                    // A peripheral never sends HELLO unprompted; start over.
                    endSession(link)
                    sendHello(link)
                    return
                }
                link.peerHello = hello
                link.tHello = Derivation.tHello(link.ownHello!!, bytes)
                if (hello.version < PROTOCOL_VERSION) {
                    reject(link, RejectReason.UNSUPPORTED_VERSION)
                    return
                }
                resolveOtherLink(link) { continueAsCentral(link) }
            }
        }
    }

    private fun resetPeripheral(link: Link) {
        link.pairing?.let { pairing ->
            pairing.approvalTimer?.cancel()
            if (pairing.code != null) {
                link.peerId?.let { host.onEvent(EngineEvent.PairingResult(link.deviceId, it, RESULT_LINK_LOST)) }
            }
        }
        link.pairing = null
        val wasEstablished = link.phase == Phase.ESTABLISHED
        endSession(link)
        link.phase = Phase.AWAIT_HELLO
        if (wasEstablished) {
            emitDisconnectedIfUnlinked(link.deviceId)
        }
    }

    /** 6.1: AUTH if we have K, app pairing if the user asked for this link, else REJECT. */
    private fun continueAsCentral(link: Link) {
        val peerId = link.peerId!!
        val stored = store.peers().firstOrNull { it.peerId == peerId }
        val key = store.key(peerId)
        host.log("Central on link ${link.id}: key=${key != null}, state=${stored?.state}, user=${link.userInitiated}")
        when {
            key != null && (stored?.state == PeerState.PAIRED || !link.userInitiated) -> sendAuth(link, key)
            link.userInitiated -> {
                link.pairing = Pairing(repair = key != null)
                link.phase = Phase.PAIRING
                sendRecord(link, Record.encode(Record.PairRequest), PRIORITY_HANDSHAKE)
            }
            else -> {
                // Connected on our own to a phone we hold no key for: it reinstalled
                // the app (new peerId) under the address of a peer we know.
                store.peers()
                    .filter { it.deviceId == link.deviceId && it.state == PeerState.PAIRED }
                    .forEach { markState(it.peerId, PeerState.REPAIR_NEEDED) }
                reject(link, RejectReason.UNKNOWN_PEER)
            }
        }
    }

    private fun sendAuth(link: Link, key: PeerKey) {
        link.phase = Phase.AWAIT_AUTH
        val mac = Derivation.authMac(key, store.localPeerId, link.tHello!!)
        sendRecord(link, Record.encode(Record.Auth(mac)), PRIORITY_HANDSHAKE)
    }

    private fun onHandshakeRecord(link: Link, record: Record) {
        if (record is Record.Reject) {
            onReject(link, record.reason)
            return
        }
        when (link.phase) {
            Phase.AWAIT_AUTH -> when {
                record is Record.Auth && link.role == Role.CENTRAL -> onAuthAsCentral(link, record)
                record is Record.Auth -> onAuthAsPeripheral(link, record)
                record is Record.PairRequest && link.role == Role.PERIPHERAL -> startPairingAsPeripheral(link)
                else -> host.log("Unexpected ${record.javaClass.simpleName} from ${link.deviceId}")
            }
            Phase.PAIRING -> onPairingRecord(link, record)
            else -> host.log("Unexpected ${record.javaClass.simpleName} from ${link.deviceId}")
        }
    }

    private fun onAuthAsCentral(link: Link, auth: Record.Auth) {
        val peerId = link.peerId!!
        val key = store.key(peerId) ?: run {
            reject(link, RejectReason.UNKNOWN_PEER)
            return
        }
        if (!Crypto.constantTimeEquals(Derivation.authMac(key, peerId, link.tHello!!), auth.mac)) {
            markState(peerId, PeerState.BAD_MAC)
            reject(link, RejectReason.BAD_MAC)
            return
        }
        establish(link, key)
    }

    private fun onAuthAsPeripheral(link: Link, auth: Record.Auth) {
        val peerId = link.peerId!!
        val key = store.key(peerId) ?: run {
            reject(link, RejectReason.UNKNOWN_PEER)
            return
        }
        if (!Crypto.constantTimeEquals(Derivation.authMac(key, peerId, link.tHello!!), auth.mac)) {
            markState(peerId, PeerState.BAD_MAC)
            reject(link, RejectReason.BAD_MAC)
            return
        }
        val mac = Derivation.authMac(key, store.localPeerId, link.tHello!!)
        sendRecord(link, Record.encode(Record.Auth(mac)), PRIORITY_HANDSHAKE)
        establish(link, key)
    }

    /** Sends REJECT and ends the handshake; a central then closes the link (6.1). */
    private fun reject(link: Link, reason: Int) {
        val central = link.role == Role.CENTRAL
        sendRecord(link, Record.encode(Record.Reject(reason)), PRIORITY_HANDSHAKE) {
            if (central) {
                close(link)
            }
        }
        handshakeEnded(link, reason, byPeer = false)
    }

    private fun onReject(link: Link, reason: Int) {
        handshakeEnded(link, reason, byPeer = true)
        if (link.role == Role.CENTRAL) {
            close(link)
        }
    }

    private fun handshakeEnded(link: Link, reason: Int, byPeer: Boolean) {
        host.log("Handshake on link ${link.id} ended: ${RejectReason.name(reason)}${if (byPeer) " from the peer" else ""}")
        link.handshakeTimer?.cancel()
        val pairing = link.pairing
        link.pairing = null
        pairing?.approvalTimer?.cancel()
        link.phase = Phase.DONE
        val peerId = link.peerId
        if (peerId != null) {
            if (byPeer && reason == RejectReason.UNKNOWN_PEER) {
                // The peer has no key for us: it deleted us, or reinstalled. Keep K
                // (the REJECT isn't authenticated) but stop reconnecting (6.5).
                markState(peerId, PeerState.REPAIR_NEEDED)
            }
            if (reason == RejectReason.BAD_MAC && pairing == null) {
                // Either side of a failed AUTH: possibly an attack, so no automatic
                // reconnects and no automatic re-pairing (6.5).
                markState(peerId, PeerState.BAD_MAC)
            }
            if (pairing != null) {
                host.onEvent(EngineEvent.PairingResult(link.deviceId, peerId, pairingFailure(reason)))
            }
        }
        if (reason != RejectReason.ALREADY_CONNECTED) {
            host.onEvent(EngineEvent.PeerRejected(link.deviceId, reason, byPeer))
        }
        emitDisconnectedIfUnlinked(link.deviceId)
    }

    private fun markState(peerId: PeerId, state: PeerState) {
        val stored = store.peers().firstOrNull { it.peerId == peerId } ?: return
        if (stored.state != state) {
            store.update(stored.copy(state = state))
            host.onEvent(EngineEvent.PeersChanged)
        }
    }

    // ---------------------------------------------------------------- app pairing (6.3)

    private fun startPairingAsPeripheral(link: Link) {
        if (!host.canPrompt()) {
            reject(link, RejectReason.CANNOT_PROMPT)
            return
        }
        val pairing = Pairing(repair = store.key(link.peerId!!) != null)
        host.log("Pairing requested on link ${link.id} (repair=${pairing.repair})")
        val keyPair = Crypto.generateEcKeyPair(random)
        pairing.keyPair = keyPair
        link.pairing = pairing
        link.phase = Phase.PAIRING
        sendRecord(link, Record.encode(Record.PairCommit(Derivation.commit(keyPair.publicKey))), PRIORITY_HANDSHAKE)
    }

    private fun onPairingRecord(link: Link, record: Record) {
        val pairing = link.pairing ?: return
        when (record) {
            is Record.PairCommit -> if (link.role == Role.CENTRAL && pairing.commit == null) {
                pairing.commit = record.commit
                val keyPair = Crypto.generateEcKeyPair(random)
                pairing.keyPair = keyPair
                sendRecord(link, Record.encode(Record.PairKey(keyPair.publicKey)), PRIORITY_HANDSHAKE)
            }
            is Record.PairKey -> if (pairing.key == null) {
                val own = pairing.keyPair ?: return
                when (link.role) {
                    Role.CENTRAL -> {
                        if (!Crypto.constantTimeEquals(Derivation.commit(record.publicKey), pairing.commit ?: return)) {
                            reject(link, RejectReason.COMMIT_MISMATCH)
                            return
                        }
                        derive(link, pairing, publicKeyP = record.publicKey, publicKeyC = own.publicKey)
                    }
                    Role.PERIPHERAL -> {
                        sendRecord(link, Record.encode(Record.PairKey(own.publicKey)), PRIORITY_HANDSHAKE)
                        derive(link, pairing, publicKeyP = own.publicKey, publicKeyC = record.publicKey)
                    }
                }
            }
            is Record.PairConfirm -> {
                val key = pairing.key ?: return
                if (pairing.peerConfirmed) {
                    return
                }
                val expected = Derivation.confirmMac(RawPeerKey(key), link.peerId!!, pairing.tPair!!)
                if (!Crypto.constantTimeEquals(expected, record.mac)) {
                    reject(link, RejectReason.BAD_MAC)
                    return
                }
                pairing.peerConfirmed = true
                finishPairingIfReady(link, pairing)
            }
            else -> host.log("Unexpected ${record.javaClass.simpleName} while pairing with ${link.deviceId}")
        }
    }

    private fun derive(link: Link, pairing: Pairing, publicKeyP: ByteArray, publicKeyC: ByteArray) {
        val peerPublic = if (link.role == Role.CENTRAL) publicKeyP else publicKeyC
        val shared = Crypto.ecdh(pairing.keyPair!!, peerPublic) ?: run {
            reject(link, RejectReason.COMMIT_MISMATCH)
            return
        }
        val tPair = Derivation.tPair(link.tHello!!, publicKeyP, publicKeyC)
        pairing.tPair = tPair
        pairing.key = Derivation.pairKey(shared, tPair)
        val code = Derivation.code(tPair)
        pairing.code = code
        // Waiting for the users doesn't count against the handshake timeout.
        link.handshakeTimer?.cancel()
        pairing.approvalTimer = scheduler.schedule(APPROVAL_TIMEOUT_MS) {
            if (link.pairing === pairing && link.isLive()) {
                reject(link, RejectReason.TIMEOUT)
            }
        }
        host.onEvent(EngineEvent.PairingRequest(link.deviceId, link.peerId!!, link.peerName, code, pairing.repair))
    }

    /** The user's answer to the [EngineEvent.PairingRequest] for [deviceId]. */
    fun respondPairing(deviceId: String, accept: Boolean): Boolean {
        val link = links.values.firstOrNull {
            it.isLive() && it.deviceId == deviceId && it.pairing?.let { p -> p.key != null && !p.localApproved } == true
        } ?: return false
        val pairing = link.pairing!!
        if (!accept) {
            reject(link, RejectReason.USER_REJECTED)
            return true
        }
        pairing.localApproved = true
        val mac = Derivation.confirmMac(RawPeerKey(pairing.key!!), store.localPeerId, pairing.tPair!!)
        sendRecord(link, Record.encode(Record.PairConfirm(mac)), PRIORITY_HANDSHAKE)
        finishPairingIfReady(link, pairing)
        return true
    }

    private fun finishPairingIfReady(link: Link, pairing: Pairing) {
        if (!pairing.localApproved || !pairing.peerConfirmed) {
            return
        }
        pairing.approvalTimer?.cancel()
        val peerId = link.peerId!!
        val hello = link.peerHello!!
        store.savePaired(
            StoredPeer(peerId, hello.name ?: "", link.deviceId, hello.platform ?: 0, PeerState.PAIRED),
            pairing.key!!
        )
        link.pairing = null
        host.onEvent(EngineEvent.PairingResult(link.deviceId, peerId, RESULT_PAIRED))
        host.onEvent(EngineEvent.PeersChanged)
        link.phase = Phase.AWAIT_AUTH
        armHandshakeTimer(link)
        if (link.role == Role.CENTRAL) {
            val key = store.key(peerId) ?: run {
                host.onEvent(EngineEvent.Error("The pairing key for ${link.deviceId} could not be stored"))
                close(link)
                return
            }
            sendAuth(link, key)
        }
    }

    // ---------------------------------------------------------------- one link per peer (9절)

    /**
     * Called once [link] knows its peer (from its HELLO): if another live link to the
     * same peer exists, one of them goes. [proceed] continues [link]'s handshake if it
     * stays, possibly later.
     *
     * Each phone decides when the second of its two links learns the peer, so the
     * loser is always still handshaking and can be dropped cleanly: its central
     * closes it, or its peripheral answers REJECT(ALREADY_CONNECTED).
     *
     * - The other link is handshaking too: both phones keep the link whose central is
     *   the lower peerId, so they agree without talking.
     * - The other link is established: it stays if it's alive, which a `/ping`
     *   answers. When the peer's app restarted while Bluetooth stayed connected
     *   (other apps hold the connection, e.g. Samsung's), nothing reports the old
     *   session as gone, and turning the new link away would lock the peer out.
     *
     * The phones can disagree when one already sees the first link as established;
     * then both links go, and the automatic reconnect makes a new one (9절).
     */
    private fun resolveOtherLink(link: Link, proceed: () -> Unit) {
        val peerId = link.peerId ?: return proceed()
        val other = links.values.firstOrNull { it !== link && it.isLive() && it.peerId == peerId }
        if (other == null) {
            proceed()
            return
        }
        if (other.phase != Phase.ESTABLISHED) {
            val keepRole = if (store.localPeerId < peerId) Role.CENTRAL else Role.PERIPHERAL
            if (link.role == keepRole && other.role != keepRole) {
                dropDuplicate(other)
                proceed()
            } else {
                dropDuplicate(link)
            }
            return
        }
        val generation = link.helloCount
        host.log("Checking the established link to ${other.deviceId} before accepting another")
        probe(other) { alive ->
            if (!link.isLive() || link.helloCount != generation) {
                return@probe
            }
            if (alive) {
                dropDuplicate(link)
            } else {
                host.log("The established link to ${other.deviceId} is dead; replacing it")
                dropDead(other)
                proceed()
            }
        }
    }

    /** Sends a `/ping` on [link]; [done] gets whether its ACK came back in time. */
    private fun probe(link: Link, done: (Boolean) -> Unit) {
        val msgId = store.nextMsgId()
        var finished = false
        var timer: Cancellable? = null
        val finish = { alive: Boolean ->
            if (!finished) {
                finished = true
                timer?.cancel()
                link.probes.remove(msgId)
                done(alive)
            }
        }
        timer = scheduler.schedule(PROBE_TIMEOUT_MS) { finish(false) }
        link.probes[msgId] = { finish(true) }
        val ping = Envelope.Data(msgId, Envelope.FLAG_ACK_REQ, PING_PATH, 0, ByteArray(0))
        sendSealed(link, ping, PRIORITY_CONTROL) { written ->
            if (!written) {
                finish(false)
            }
        }
    }

    /** Ends an established [link] whose peer no longer answers. */
    private fun dropDead(link: Link) {
        when (link.role) {
            Role.CENTRAL -> close(link)
            Role.PERIPHERAL -> {
                link.handshakeTimer?.cancel()
                endSession(link)
                link.phase = Phase.DONE
                emitDisconnectedIfUnlinked(link.deviceId)
            }
        }
    }

    private fun dropDuplicate(link: Link) {
        host.log("Dropping the duplicate ${link.role} link to ${link.deviceId}")
        when (link.role) {
            Role.CENTRAL -> close(link)
            Role.PERIPHERAL -> {
                sendRecord(link, Record.encode(Record.Reject(RejectReason.ALREADY_CONNECTED)), PRIORITY_HANDSHAKE)
                link.handshakeTimer?.cancel()
                link.pairing?.approvalTimer?.cancel()
                link.pairing = null
                link.phase = Phase.DONE
            }
        }
    }

    // ---------------------------------------------------------------- sessions

    private fun establish(link: Link, key: PeerKey) {
        val peerId = link.peerId!!
        val tHello = link.tHello!!
        link.handshakeTimer?.cancel()
        link.session = Session(
            sendKey = Derivation.sessionKey(key, store.localPeerId, peerId, tHello),
            receiveKey = Derivation.sessionKey(key, peerId, store.localPeerId, tHello)
        )
        link.phase = Phase.ESTABLISHED
        host.log("Session with ${link.deviceId} on link ${link.id} (${link.role})")
        val hello = link.peerHello!!
        val stored = store.peers().firstOrNull { it.peerId == peerId }
        val updated = StoredPeer(
            peerId,
            hello.name ?: stored?.name ?: "",
            link.deviceId,
            hello.platform ?: stored?.platform ?: 0,
            PeerState.PAIRED
        )
        if (updated != stored) {
            store.update(updated)
        }
        val channel = channel(peerId)
        channel.link = link
        channel.maxMessageSize = (hello.maxMessageSize ?: MAX_MESSAGE_SIZE.toLong()).coerceAtMost(MAX_MESSAGE_SIZE.toLong())
        host.onEvent(EngineEvent.Connected(link.deviceId, peerId, link.peerName))
        host.onEvent(EngineEvent.PeersChanged)
        sendCaps(channel)
        pumpChannel(channel)
    }

    /** Forgets [link]'s session; unacknowledged messages wait for the next one. */
    private fun endSession(link: Link) {
        link.session ?: return
        link.session = null
        val channel = link.peerId?.let { channels[it] } ?: return
        if (channel.link !== link) {
            return
        }
        channel.link = null
        // 9절: resend the same msgIds, in their original order, on the next session.
        val pending = channel.inFlight.values.toList()
        channel.inFlight.clear()
        pending.forEach {
            it.ackTimer?.cancel()
            it.ackTimer = null
        }
        pending.asReversed().forEach { channel.outbox.addFirst(it) }
        host.onEvent(EngineEvent.PeersChanged)
    }

    private fun channel(peerId: PeerId) = channels.getOrPut(peerId) { PeerChannel(peerId) }

    private fun sendSealed(link: Link, envelope: Envelope, priority: Int, onWritten: ((Boolean) -> Unit)? = null) {
        val session = link.session
        if (session == null || link.closed) {
            onWritten?.invoke(false)
            return
        }
        if (session.sendCounter > MAX_COUNTER) {
            // 5절: the counter can't wrap; a central starts a new session.
            if (link.role == Role.CENTRAL) {
                close(link)
            }
            onWritten?.invoke(false)
            return
        }
        val counter = session.sendCounter++
        val header = Record.sealedHeader(counter)
        val body = Crypto.seal(session.sendKey, counter, header, Envelope.encode(envelope))
        sendRecord(link, Record.encode(Record.Sealed(counter, body)), priority, onWritten)
    }

    private fun onSealed(link: Link, record: Record.Sealed) {
        val session = link.session ?: return
        if (link.phase != Phase.ESTABLISHED || !session.window.accepts(record.counter)) {
            return
        }
        val plain = Crypto.open(session.receiveKey, record.counter, record.header, record.body)
        if (plain == null) {
            session.decryptFailures++
            host.log("A SEALED record from ${link.deviceId} didn't decrypt")
            if (session.decryptFailures >= MAX_DECRYPT_FAILURES && link.role == Role.CENTRAL) {
                host.onEvent(EngineEvent.Error("Too many undecryptable records from ${link.deviceId}"))
                close(link)
            }
            return
        }
        session.decryptFailures = 0
        session.window.mark(record.counter)
        val envelope = try {
            Envelope.decode(plain)
        } catch (e: MalformedException) {
            host.log("Dropped a malformed envelope from ${link.deviceId}: ${e.message}")
            return
        }
        onEnvelope(link, channel(link.peerId!!), envelope)
    }

    // ---------------------------------------------------------------- delivery (7절, 9절)

    private fun onEnvelope(link: Link, channel: PeerChannel, envelope: Envelope) {
        when (envelope) {
            is Envelope.Ack -> {
                link.probes.remove(envelope.refMsgId)?.let {
                    it()
                    return
                }
                val outgoing = channel.inFlight.remove(envelope.refMsgId) ?: return
                complete(outgoing, envelope.status)
                pumpChannel(channel)
            }
            is Envelope.Caps -> if (envelope.msgId >= channel.capsMsgId) {
                channel.caps = Capabilities(envelope.builtins, envelope.apps)
                channel.capsMsgId = envelope.msgId
                host.onEvent(EngineEvent.PeersChanged)
                pumpChannel(channel)
            }
            is Envelope.Data -> onData(link, channel, envelope)
            is Envelope.Unpair -> onUnpair(link, channel, envelope)
            is Envelope.Unknown -> if (envelope.ackRequested) {
                sendSealed(link, Envelope.Ack(envelope.msgId, DeliveryStatus.UNSUPPORTED), PRIORITY_ACK)
            }
        }
    }

    private fun onData(link: Link, channel: PeerChannel, data: Envelope.Data) {
        if (data.path == PING_PATH) {
            if (data.ackRequested) {
                sendSealed(link, Envelope.Ack(data.msgId, DeliveryStatus.OK), PRIORITY_ACK)
            }
            return
        }
        if (!data.ackRequested) {
            host.deliver(channel.peerId, data) {}
            return
        }
        val now = scheduler.now()
        channel.received.values.removeAll { now - it.at > DEDUP_MS }
        val seen = channel.received[data.msgId]
        if (seen != null) {
            // A retransmission: don't deliver again, just repeat the ACK (once known).
            seen.status?.let { sendSealed(link, Envelope.Ack(data.msgId, it), PRIORITY_ACK) }
            return
        }
        val entry = Received(null, now)
        channel.received[data.msgId] = entry
        host.deliver(channel.peerId, data) { status ->
            entry.status = status
            channel.link?.let { sendSealed(it, Envelope.Ack(data.msgId, status), PRIORITY_ACK) }
        }
    }

    private fun onUnpair(link: Link, channel: PeerChannel, unpair: Envelope.Unpair) {
        val peerId = channel.peerId
        host.log("UNPAIR from ${link.deviceId} on link ${link.id}")
        store.deleteKey(peerId)
        store.peers().firstOrNull { it.peerId == peerId }?.let {
            store.update(it.copy(state = PeerState.UNPAIRED_BY_PEER))
        }
        failOutbox(channel, DeliveryStatus.EXPIRED_NOT_SENT)
        sendSealed(link, Envelope.Ack(unpair.msgId, DeliveryStatus.OK), PRIORITY_ACK) {
            // The central closes the link (7절); a peripheral just stops using it.
            if (link.role == Role.CENTRAL) {
                close(link)
            } else if (!link.closed) {
                endSession(link)
                link.phase = Phase.DONE
                emitDisconnectedIfUnlinked(link.deviceId)
            }
        }
        host.onEvent(EngineEvent.PeerUnpaired(link.deviceId, peerId))
        host.onEvent(EngineEvent.PeersChanged)
    }

    /**
     * Sends [payload] to [path] on [peerId]. [callback] gets an ACK status or a local
     * result ([DeliveryStatus]) exactly once. Returns the msgId, or 0 if it failed
     * right away. [app] is the sending app, checked against the peer's CAPS.
     */
    fun send(
        peerId: PeerId,
        path: String,
        payload: ByteArray,
        replyTo: Long,
        ttlMs: Long,
        app: AppIdentity?,
        callback: (Int) -> Unit
    ): Long {
        if (path.isEmpty() || path.toByteArray(Charsets.UTF_8).size > Envelope.MAX_PATH_BYTES) {
            callback(DeliveryStatus.MALFORMED)
            return 0
        }
        val control = path.startsWith("/control")
        val ttl = if (ttlMs <= 0) {
            if (control) CONTROL_TTL_MS else DEFAULT_TTL_MS
        } else {
            ttlMs.coerceAtMost(MAX_TTL_MS)
        }
        val msgId = store.nextMsgId()
        // A reply isn't acknowledged (9절).
        val flags = if (replyTo != 0L) Envelope.FLAG_REPLY else Envelope.FLAG_ACK_REQ
        val outgoing = Outgoing(
            msgId,
            Envelope.Data(msgId, flags, path, replyTo, payload),
            if (control) PRIORITY_CONTROL else PRIORITY_DATA,
            app,
            callback
        )
        val channel = channel(peerId)
        channel.outbox.addLast(outgoing)
        outgoing.ttlTimer = scheduler.schedule(ttl) { expire(channel, outgoing) }
        pumpChannel(channel)
        return msgId
    }

    private fun pumpChannel(channel: PeerChannel) {
        val link = channel.link?.takeIf { it.phase == Phase.ESTABLISHED && !it.closed } ?: return
        while (channel.inFlight.size < MAX_IN_FLIGHT) {
            val next = channel.outbox.firstOrNull() ?: return
            val data = next.envelope as? Envelope.Data
            if (data != null) {
                // Wait for the peer's CAPS (sent right after the session starts).
                val caps = channel.caps ?: return
                if (!allows(caps, data.path, next.app)) {
                    channel.outbox.removeFirst()
                    complete(next, DeliveryStatus.NO_RECEIVER)
                    continue
                }
            }
            if (Envelope.encode(next.envelope).size + SEALED_OVERHEAD > channel.maxMessageSize) {
                channel.outbox.removeFirst()
                complete(next, DeliveryStatus.TOO_LARGE)
                continue
            }
            channel.outbox.removeFirst()
            channel.inFlight[next.msgId] = next
            sendSealed(link, next.envelope, next.priority) { written -> onOutgoingWritten(channel, next, written) }
        }
    }

    private fun onOutgoingWritten(channel: PeerChannel, outgoing: Outgoing, written: Boolean) {
        if (outgoing.done || channel.inFlight[outgoing.msgId] !== outgoing) {
            return
        }
        if (!written) {
            // Try again shortly; if the link is going away, endSession requeues it anyway.
            channel.inFlight.remove(outgoing.msgId)
            channel.outbox.addFirst(outgoing)
            if (!channel.retryScheduled) {
                channel.retryScheduled = true
                scheduler.schedule(RETRY_DELAY_MS) {
                    channel.retryScheduled = false
                    pumpChannel(channel)
                }
            }
            return
        }
        outgoing.written = true
        if (!outgoing.envelope.ackRequested) {
            channel.inFlight.remove(outgoing.msgId)
            complete(outgoing, DeliveryStatus.OK)
            pumpChannel(channel)
            return
        }
        outgoing.ackTimer?.cancel()
        outgoing.ackTimer = scheduler.schedule(ACK_TIMEOUT_MS) {
            if (!outgoing.done && channel.inFlight.remove(outgoing.msgId) != null) {
                complete(outgoing, DeliveryStatus.EXPIRED_UNCONFIRMED)
                pumpChannel(channel)
            }
        }
    }

    private fun allows(caps: Capabilities, path: String, app: AppIdentity?): Boolean {
        if (path.startsWith("/")) {
            return caps.builtins.contains(path)
        }
        return app != null && app.packageName == path.substringBefore('/') && caps.apps.contains(app)
    }

    private fun expire(channel: PeerChannel, outgoing: Outgoing) {
        if (outgoing.done) {
            return
        }
        channel.outbox.remove(outgoing)
        channel.inFlight.remove(outgoing.msgId)
        complete(
            outgoing,
            if (outgoing.written) DeliveryStatus.EXPIRED_UNCONFIRMED else DeliveryStatus.EXPIRED_NOT_SENT
        )
        pumpChannel(channel)
    }

    private fun complete(outgoing: Outgoing, status: Int) {
        if (outgoing.done) {
            return
        }
        outgoing.done = true
        outgoing.ttlTimer?.cancel()
        outgoing.ackTimer?.cancel()
        outgoing.callback(status)
    }

    private fun failOutbox(channel: PeerChannel, status: Int) {
        val pending = channel.outbox.toList() + channel.inFlight.values
        channel.outbox.clear()
        channel.inFlight.clear()
        pending.forEach { complete(it, status) }
    }

    private fun sendCaps(channel: PeerChannel) {
        val link = channel.link ?: return
        val caps = host.localCaps()
        sendSealed(link, Envelope.Caps(store.nextMsgId(), caps.builtins, caps.apps), PRIORITY_CONTROL)
    }

    /** What this phone can receive changed; tell every connected peer. */
    fun capsChanged() {
        channels.values.filter { it.link?.phase == Phase.ESTABLISHED }.forEach(::sendCaps)
    }

    /**
     * Forgets [peerId] (the user deleted it, 6.6): sends UNPAIR if connected and waits
     * for its ACK (at most [UNPAIR_TIMEOUT_MS]), then deletes K. [done] runs after that.
     */
    fun removePeer(peerId: PeerId, done: () -> Unit) {
        val channel = channels[peerId]
        val link = channel?.link?.takeIf { it.phase == Phase.ESTABLISHED && !it.closed }
        host.log("Removing $peerId (${if (link == null) "not connected" else "UNPAIR on link ${link.id}"})")
        if (channel == null || link == null) {
            forget(peerId)
            done()
            return
        }
        val msgId = store.nextMsgId()
        val unpair = Outgoing(msgId, Envelope.Unpair(msgId), PRIORITY_CONTROL, null) {
            forget(peerId)
            if (link.role == Role.CENTRAL) {
                close(link)
            } else if (!link.closed) {
                endSession(link)
                link.phase = Phase.DONE
                emitDisconnectedIfUnlinked(link.deviceId)
            }
            done()
        }
        unpair.ttlTimer = scheduler.schedule(UNPAIR_TIMEOUT_MS) {
            channel.outbox.remove(unpair)
            channel.inFlight.remove(msgId)
            complete(unpair, DeliveryStatus.EXPIRED_UNCONFIRMED)
        }
        // Ahead of queued messages; it's the last thing this peer gets.
        channel.outbox.addFirst(unpair)
        pumpChannel(channel)
    }

    private fun forget(peerId: PeerId) {
        channels.remove(peerId)?.let { failOutbox(it, DeliveryStatus.EXPIRED_NOT_SENT) }
        store.remove(peerId)
        host.onEvent(EngineEvent.PeersChanged)
    }
}
