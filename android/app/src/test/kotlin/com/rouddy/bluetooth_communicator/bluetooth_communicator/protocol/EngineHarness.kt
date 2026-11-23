package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import java.util.PriorityQueue

val TEST_APP = AppIdentity("com.example.test", "ab".repeat(32))

/** Virtual time: tasks run in order of due time when the test advances the clock. */
class FakeScheduler : Scheduler {
    private class Task(val at: Long, val seq: Long, val action: () -> Unit) {
        var cancelled = false
    }

    private var time = 0L
    private var seq = 0L
    private val tasks = PriorityQueue<Task>(compareBy<Task>({ it.at }, { it.seq }))

    override fun now() = time

    override fun schedule(delayMs: Long, action: () -> Unit): Cancellable {
        val task = Task(time + delayMs, seq++, action)
        tasks.add(task)
        return Cancellable { task.cancelled = true }
    }

    fun advance(ms: Long) {
        val end = time + ms
        while (true) {
            val task = tasks.peek() ?: break
            if (task.at > end) {
                break
            }
            tasks.poll()
            time = task.at
            if (!task.cancelled) {
                task.action()
            }
        }
        time = end
    }
}

class InMemoryPeerStore(override val localPeerId: PeerId) : PeerStore {
    private var msgId = 0L
    val peerMap = LinkedHashMap<PeerId, StoredPeer>()
    val keys = HashMap<PeerId, ByteArray>()

    override fun nextMsgId() = ++msgId

    override fun peers() = peerMap.values.toList()

    override fun key(peerId: PeerId) = keys[peerId]?.let(::RawPeerKey)

    override fun savePaired(peer: StoredPeer, key: ByteArray) {
        peerMap.values.filter { it.deviceId == peer.deviceId && it.peerId != peer.peerId }.forEach {
            remove(it.peerId)
        }
        peerMap[peer.peerId] = peer
        keys[peer.peerId] = key
    }

    override fun update(peer: StoredPeer) {
        peerMap[peer.peerId] = peer
    }

    override fun deleteKey(peerId: PeerId) {
        keys.remove(peerId)
    }

    override fun remove(peerId: PeerId) {
        peerMap.remove(peerId)
        keys.remove(peerId)
    }
}

/** One phone: an engine plus a host that records what it's told. */
class Phone(
    val name: String,
    val address: String,
    peerId: PeerId,
    private val scheduler: FakeScheduler,
    private val network: Network
) : EngineHost {
    val store = InMemoryPeerStore(peerId)
    val engine = ProtocolEngine(this, store, scheduler)
    val events = mutableListOf<EngineEvent>()
    val delivered = mutableListOf<Envelope.Data>()

    /** Answers pairing prompts after [approvalDelayMs]; null leaves them unanswered. */
    var approve: Boolean? = true
    var approvalDelayMs = 0L

    var caps = Capabilities(listOf("/control/media"), listOf(TEST_APP))

    /** Status for each delivery; null holds the delivery open in [heldDeliveries]. */
    var deliverStatus: Int? = DeliveryStatus.OK
    val heldDeliveries = mutableListOf<(Int) -> Unit>()

    val peerId: PeerId
        get() = store.localPeerId

    override fun writeFrame(linkId: Int, frame: ByteArray) = network.write(this, linkId, frame)

    override fun closeLink(linkId: Int) = network.close(this, linkId)

    override fun writeTcpFrame(linkId: Int, frame: ByteArray) = network.writeTcp(this, linkId, frame)

    /** Links whose TCP connection the engine closed (its session ended). */
    val closedTcp = mutableListOf<Int>()

    override fun closeTcp(linkId: Int) {
        closedTcp += linkId
        network.closeTcp(this, linkId)
    }

    override fun localIdentity() = LocalIdentity(name, Platform.ANDROID, "test")

    override fun localCaps() = caps

    /** Takes a delivery before the default handling when it returns true. */
    var handler: ((PeerId, Envelope.Data, (Int) -> Unit) -> Boolean)? = null

    override fun deliver(peerId: PeerId, data: Envelope.Data, done: (Int) -> Unit) {
        if (handler?.invoke(peerId, data, done) == true) {
            return
        }
        delivered += data
        val status = deliverStatus
        if (status == null) {
            heldDeliveries += done
        } else {
            done(status)
        }
    }

    val logs = mutableListOf<String>()

    override fun log(message: String) {
        logs += "${scheduler.now()} $message"
    }

    override fun onEvent(event: EngineEvent) {
        events += event
        val answer = approve
        if (event is EngineEvent.PairingRequest && answer != null) {
            scheduler.schedule(approvalDelayMs) { engine.respondPairing(event.deviceId, answer) }
        }
    }

    inline fun <reified T : EngineEvent> eventsOf(): List<T> = events.filterIsInstance<T>()

    fun send(to: Phone, payload: ByteArray, path: String = "${TEST_APP.packageName}/chat", ttlMs: Long = 0): MutableList<Int> {
        val results = mutableListOf<Int>()
        engine.send(to.peerId, path, payload, 0, ttlMs, TEST_APP) { results += it }
        return results
    }
}

/**
 * Connects engines in memory. Each frame takes 1 ms; a write completes when the
 * frame arrives. Closing a link (the central's job) also takes it down on the other
 * side, as when the GATT link drops.
 */
class Network(private val scheduler: FakeScheduler) {
    inner class Connection(
        val central: Phone,
        val centralLink: Int,
        val peripheral: Phone,
        val peripheralLink: Int
    ) {
        var open = true

        /** False when the far end's app died but Bluetooth stayed connected. */
        var delivers = true

        /** The next [dropCount] frames [dropFrom] writes on this connection vanish. */
        var dropFrom: Phone? = null
        var dropCount = 0

        /** The next [repeatCount] frames [repeatFrom] writes on this connection arrive twice. */
        var repeatFrom: Phone? = null
        var repeatCount = 0

        fun drop() {
            if (!open) {
                return
            }
            open = false
            central.engine.linkDown(centralLink)
            peripheral.engine.linkDown(peripheralLink)
        }

        /** The TCP connection of `/tcp`; its frames arrive at once. */
        var tcpOpen = false

        /** Frames each phone wrote on TCP, and on Bluetooth. */
        val tcpFrames = mutableListOf<Pair<Phone, ByteArray>>()
        val bleFrames = mutableListOf<Pair<Phone, ByteArray>>()

        /** TCP frames for which this returns true vanish (their write still succeeds). */
        var loseTcp: (from: Phone, frame: ByteArray) -> Boolean = { _, _ -> false }

        fun tcpUp(): Pair<Boolean, Boolean> {
            tcpOpen = true
            return central.engine.tcpUp(centralLink) to peripheral.engine.tcpUp(peripheralLink)
        }

        /** The connection broke; both hosts notice. */
        fun tcpDown() {
            if (!tcpOpen) {
                return
            }
            tcpOpen = false
            central.engine.tcpDown(centralLink)
            peripheral.engine.tcpDown(peripheralLink)
        }
    }

    val connections = mutableListOf<Connection>()
    private var nextLinkId = 1
    var maxFrameSize = 20

    /** Frames for which this returns true vanish (their write still succeeds). */
    var lose: (from: Phone, frame: ByteArray) -> Boolean = { _, _ -> false }

    /**
     * How much later than its write a frame arrives, like an Android peripheral's
     * notification: reported sent once queued in the stack, delivered later.
     */
    var deliveryDelayMs = 0L

    fun phone(name: String, address: String, peerId: PeerId) = Phone(name, address, peerId, scheduler, this)

    fun connect(
        central: Phone,
        peripheral: Phone,
        userInitiated: Boolean = false,
        prepare: (Connection) -> Unit = {}
    ): Connection {
        val connection = Connection(central, nextLinkId++, peripheral, nextLinkId++)
        prepare(connection)
        connections += connection
        // The peripheral sees the subscription before the central's CCCD write completes.
        peripheral.engine.linkUp(connection.peripheralLink, Role.PERIPHERAL, central.address, maxFrameSize, false)
        central.engine.linkUp(connection.centralLink, Role.CENTRAL, peripheral.address, maxFrameSize, userInitiated)
        return connection
    }

    /**
     * The peripheral's app restarted while Bluetooth stayed connected and iOS restored
     * the subscription: [restarted] takes over the peripheral end under a new link, and
     * the central's link carries on as if nothing happened.
     */
    fun restore(connection: Connection, restarted: Phone): Connection {
        connection.open = false
        connections.remove(connection)
        val restored = Connection(connection.central, connection.centralLink, restarted, nextLinkId++)
        connections += restored
        restarted.engine.linkUp(restored.peripheralLink, Role.PERIPHERAL, connection.central.address, maxFrameSize, false)
        return restored
    }

    private fun find(phone: Phone, linkId: Int) = connections.first {
        (it.central === phone && it.centralLink == linkId) || (it.peripheral === phone && it.peripheralLink == linkId)
    }

    fun write(from: Phone, linkId: Int, frame: ByteArray) {
        val connection = find(from, linkId)
        connection.bleFrames += from to frame
        scheduler.schedule(1) {
            // Like Android's GATT: an attribute value over 512 bytes is rejected.
            if (!connection.open || frame.size > Frames.MAX_FRAME_SIZE) {
                from.engine.frameWritten(linkId, false)
                return@schedule
            }
            from.engine.frameWritten(linkId, true)
            if (connection.dropFrom === from && connection.dropCount > 0) {
                connection.dropCount--
                return@schedule
            }
            if (!connection.delivers || lose(from, frame)) {
                return@schedule
            }
            val times = if (connection.repeatFrom === from && connection.repeatCount > 0) {
                connection.repeatCount--
                2
            } else {
                1
            }
            val deliver = {
                repeat(times) {
                    if (from === connection.central) {
                        connection.peripheral.engine.frameReceived(connection.peripheralLink, frame)
                    } else {
                        connection.central.engine.frameReceived(connection.centralLink, frame)
                    }
                }
            }
            if (deliveryDelayMs > 0) {
                scheduler.schedule(deliveryDelayMs) { deliver() }
            } else {
                deliver()
            }
        }
    }

    fun close(from: Phone, linkId: Int) {
        val connection = find(from, linkId)
        if (!connection.open) {
            return
        }
        connection.open = false
        scheduler.schedule(1) {
            if (from === connection.central) {
                connection.peripheral.engine.linkDown(connection.peripheralLink)
            } else {
                connection.central.engine.linkDown(connection.centralLink)
            }
        }
    }

    fun writeTcp(from: Phone, linkId: Int, frame: ByteArray) {
        val connection = find(from, linkId)
        connection.tcpFrames += from to frame
        scheduler.schedule(0) {
            if (!connection.tcpOpen) {
                from.engine.tcpFrameWritten(linkId, false)
                return@schedule
            }
            from.engine.tcpFrameWritten(linkId, true)
            if (connection.loseTcp(from, frame)) {
                return@schedule
            }
            if (from === connection.central) {
                connection.peripheral.engine.tcpFrameReceived(connection.peripheralLink, frame)
            } else {
                connection.central.engine.tcpFrameReceived(connection.centralLink, frame)
            }
        }
    }

    /** One side closed the TCP connection; the other notices a moment later. */
    fun closeTcp(from: Phone, linkId: Int) {
        val connection = find(from, linkId)
        if (!connection.tcpOpen) {
            return
        }
        connection.tcpOpen = false
        scheduler.schedule(1) {
            if (from === connection.central) {
                connection.peripheral.engine.tcpDown(connection.peripheralLink)
            } else {
                connection.central.engine.tcpDown(connection.centralLink)
            }
        }
    }
}
