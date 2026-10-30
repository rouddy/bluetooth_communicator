package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.SecureRandom

class EngineTest {
    private val scheduler = FakeScheduler()
    private val network = Network(scheduler)

    // A has the lower peerId, so it's "low" in the link tie-break.
    private val a = network.phone("A", "AA:AA", PeerId(ByteArray(16) { 0x11 }))
    private val b = network.phone("B", "BB:BB", PeerId(ByteArray(16) { 0x77 }))

    private fun settle(ms: Long = 2_000) = scheduler.advance(ms)

    /** A pairs with B from A's connect button, then both are connected. */
    private fun pair(settleMs: Long = 2_000): Network.Connection {
        val connection = network.connect(a, b, userInitiated = true)
        settle(settleMs)
        assertTrue("A connected", a.engine.isConnected(b.address))
        assertTrue("B connected", b.engine.isConnected(a.address))
        return connection
    }

    @Test
    fun `app pairing shows the same code on both phones and stores the same key`() {
        pair()

        val requestA = a.eventsOf<EngineEvent.PairingRequest>().single()
        val requestB = b.eventsOf<EngineEvent.PairingRequest>().single()
        assertEquals(requestA.code, requestB.code)
        assertTrue(requestA.code.matches(Regex("\\d{6}")))
        assertEquals("B", requestA.name)
        assertEquals("A", requestB.name)
        assertFalse(requestA.repair)
        assertEquals(b.peerId, requestA.peerId)
        assertArrayEquals(a.store.keys[b.peerId], b.store.keys[a.peerId])
        assertEquals(EngineEvent.PairingResult(b.address, b.peerId, "paired"), a.eventsOf<EngineEvent.PairingResult>().single())
        assertEquals(EngineEvent.Connected(b.address, b.peerId, "B"), a.eventsOf<EngineEvent.Connected>().single())
        assertEquals(EngineEvent.Connected(a.address, a.peerId, "A"), b.eventsOf<EngineEvent.Connected>().single())
        assertEquals(StoredPeer(b.peerId, "B", b.address, Platform.ANDROID, PeerState.PAIRED), a.store.peers().single())
    }

    @Test
    fun `a reconnect authenticates with the key and asks nobody`() {
        pair().drop()
        a.events.clear()
        b.events.clear()

        network.connect(b, a)
        settle()

        assertTrue(a.engine.isConnected(b.address))
        assertTrue(b.engine.isConnected(a.address))
        assertTrue(a.eventsOf<EngineEvent.PairingRequest>().isEmpty())
        assertTrue(b.eventsOf<EngineEvent.PairingRequest>().isEmpty())
    }

    @Test
    fun `connecting on its own to a phone without a key is rejected without a prompt`() {
        val connection = network.connect(a, b)
        settle()

        assertFalse(connection.open)
        assertEquals(
            EngineEvent.PeerRejected(b.address, RejectReason.UNKNOWN_PEER, byPeer = false),
            a.eventsOf<EngineEvent.PeerRejected>().single()
        )
        assertEquals(
            EngineEvent.PeerRejected(a.address, RejectReason.UNKNOWN_PEER, byPeer = true),
            b.eventsOf<EngineEvent.PeerRejected>().single()
        )
        assertTrue(a.eventsOf<EngineEvent.PairingRequest>().isEmpty())
        assertTrue(b.eventsOf<EngineEvent.PairingRequest>().isEmpty())
    }

    @Test
    fun `a peer that deleted us is marked for re-pairing, which the connect button then does`() {
        pair().drop()
        b.store.remove(a.peerId)

        network.connect(a, b)
        settle()

        assertEquals(PeerState.REPAIR_NEEDED, a.store.peers().single().state)
        assertNotNull("K is kept", a.store.key(b.peerId))
        assertFalse(a.engine.shouldReconnect(b.address))
        assertTrue(
            a.eventsOf<EngineEvent.PeerRejected>()
                .contains(EngineEvent.PeerRejected(b.address, RejectReason.UNKNOWN_PEER, byPeer = true))
        )

        a.events.clear()
        network.connect(a, b, userInitiated = true)
        settle()

        assertTrue(a.eventsOf<EngineEvent.PairingRequest>().single().repair)
        assertTrue(a.engine.isConnected(b.address))
        assertEquals(PeerState.PAIRED, a.store.peers().single().state)
        assertArrayEquals(a.store.keys[b.peerId], b.store.keys[a.peerId])
    }

    @Test
    fun `either user can decline the pairing`() {
        b.approve = false
        val connection = network.connect(a, b, userInitiated = true)
        settle()

        assertFalse(connection.open)
        assertEquals("rejected", a.eventsOf<EngineEvent.PairingResult>().single().result)
        assertEquals("rejected", b.eventsOf<EngineEvent.PairingResult>().single().result)
        assertTrue(a.store.peers().isEmpty())
        assertTrue(b.store.peers().isEmpty())
    }

    @Test
    fun `an unanswered pairing times out after 60 seconds, not the handshake timeout`() {
        b.approve = null
        val connection = network.connect(a, b, userInitiated = true)
        settle(ProtocolEngine.HANDSHAKE_TIMEOUT_MS * 3)
        assertTrue("still waiting for B's user", connection.open)

        settle(ProtocolEngine.APPROVAL_TIMEOUT_MS)

        assertFalse(connection.open)
        assertEquals("timeout", a.eventsOf<EngineEvent.PairingResult>().single().result)
        assertEquals("timeout", b.eventsOf<EngineEvent.PairingResult>().single().result)
    }

    @Test
    fun `a pairing approved on one phone while the other is still deciding completes`() {
        b.approvalDelayMs = 20_000
        pair(settleMs = 25_000)

        assertTrue(a.engine.pendingApprovals().isEmpty())
        assertEquals(1, a.store.peers().size)
    }

    @Test
    fun `the approval prompt is listed until answered`() {
        b.approve = null
        network.connect(a, b, userInitiated = true)
        settle()

        val pending = b.engine.pendingApprovals().single()
        assertEquals(a.address, pending.deviceId)
        assertTrue(b.engine.respondPairing(a.address, true))
        settle()
        assertTrue(b.engine.pendingApprovals().isEmpty())
        assertTrue(a.engine.isConnected(b.address))
        assertFalse(b.engine.respondPairing(a.address, true))
    }

    @Test
    fun `losing the link while a prompt is up dismisses it`() {
        b.approve = null
        val connection = network.connect(a, b, userInitiated = true)
        settle()

        connection.drop()

        assertEquals(ProtocolEngine.RESULT_LINK_LOST, b.eventsOf<EngineEvent.PairingResult>().single().result)
    }

    @Test
    fun `data reaches the same app on the peer and is acknowledged`() {
        pair()

        val results = a.send(b, "hello".toByteArray())
        settle()

        assertEquals(listOf(DeliveryStatus.OK), results)
        val data = b.delivered.single()
        assertEquals("${TEST_APP.packageName}/chat", data.path)
        assertArrayEquals("hello".toByteArray(), data.payload)
        assertTrue(data.ackRequested)
    }

    @Test
    fun `the receiver's ACK status comes back to the sender`() {
        pair()
        b.deliverStatus = DeliveryStatus.DENIED

        val results = a.send(b, "x".toByteArray())
        settle()

        assertEquals(listOf(DeliveryStatus.DENIED), results)
    }

    @Test
    fun `an app missing from the peer's CAPS fails with NO_RECEIVER without sending`() {
        b.caps = Capabilities(emptyList(), emptyList())
        pair()

        val results = a.send(b, "x".toByteArray())
        settle()

        assertEquals(listOf(DeliveryStatus.NO_RECEIVER), results)
        assertTrue(b.delivered.isEmpty())
    }

    @Test
    fun `CAPS changes reach connected peers`() {
        b.caps = Capabilities(emptyList(), emptyList())
        pair()
        b.caps = Capabilities(emptyList(), listOf(TEST_APP))
        b.engine.capsChanged()
        settle()

        assertEquals(listOf(TEST_APP), a.engine.peerSummaries().single().caps?.apps)
        assertEquals(listOf(DeliveryStatus.OK), a.send(b, "x".toByteArray()).also { settle() })
    }

    @Test
    fun `a long message is split into 20-byte frames and reassembled`() {
        pair()
        val payload = ByteArray(10_000).also(SecureRandom()::nextBytes)

        val results = a.send(b, payload)
        settle(20_000)

        assertEquals(listOf(DeliveryStatus.OK), results)
        assertArrayEquals(payload, b.delivered.single().payload)
    }

    @Test
    fun `a message over the peer's maximum fails locally with TOO_LARGE`() {
        pair()

        val results = a.send(b, ByteArray(MAX_MESSAGE_SIZE))
        settle()

        assertEquals(listOf(DeliveryStatus.TOO_LARGE), results)
    }

    @Test
    fun `a command overtakes a long message in progress`() {
        pair()

        val long = a.send(b, ByteArray(5_000))
        scheduler.advance(20)
        val command = mutableListOf<Int>()
        a.engine.send(b.peerId, "/control/media", byteArrayOf(1), 0, 0, null) { command += it }
        settle(20_000)

        assertEquals(listOf(DeliveryStatus.OK), long)
        assertEquals(listOf(DeliveryStatus.OK), command)
        assertEquals(listOf("/control/media", "${TEST_APP.packageName}/chat"), b.delivered.map { it.path })
    }

    @Test
    fun `a reply is not acknowledged and carries what it answers`() {
        pair()

        val results = mutableListOf<Int>()
        b.engine.send(a.peerId, "/control/media", byteArrayOf(0, 1), replyTo = 41, ttlMs = 0, app = null) { results += it }
        settle()

        assertEquals(listOf(DeliveryStatus.OK), results)
        val reply = a.delivered.single()
        assertTrue(reply.isReply)
        assertFalse(reply.ackRequested)
        assertEquals(41L, reply.replyTo)
    }

    @Test
    fun `a message sent while the peer is away waits for it within the TTL`() {
        pair().drop()

        val results = a.send(b, "later".toByteArray())
        settle(5_000)
        assertTrue(results.isEmpty())
        network.connect(a, b)
        settle()

        assertEquals(listOf(DeliveryStatus.OK), results)
        assertEquals(1, b.delivered.size)
    }

    @Test
    fun `a message that couldn't be sent within the TTL expires as not sent`() {
        pair().drop()

        val results = a.send(b, "never".toByteArray(), ttlMs = 5_000)
        settle(10_000)

        assertEquals(listOf(DeliveryStatus.EXPIRED_NOT_SENT), results)
    }

    @Test
    fun `a message without an ACK expires as unconfirmed`() {
        pair()
        b.deliverStatus = null

        val results = a.send(b, "x".toByteArray())
        settle(ProtocolEngine.ACK_TIMEOUT_MS + 1_000)

        assertEquals(listOf(DeliveryStatus.EXPIRED_UNCONFIRMED), results)
        assertEquals(1, b.delivered.size)
    }

    @Test
    fun `an unacknowledged message is resent on the next session and delivered once`() {
        val connection = pair()
        b.deliverStatus = null

        val results = a.send(b, "once".toByteArray())
        settle(500)
        assertEquals(1, b.delivered.size)
        connection.drop()
        network.connect(a, b)
        settle(500)
        // B is still handing over the first copy; the resent one isn't delivered again.
        b.heldDeliveries.single()(DeliveryStatus.OK)
        settle()

        assertEquals(listOf(DeliveryStatus.OK), results)
        assertEquals(1, b.delivered.size)
    }

    @Test
    fun `a repeated msgId gets the remembered ACK without a second delivery`() {
        val connection = pair()
        // The ACK is lost, so A resends after reconnecting.
        var dropAcks = true
        network.lose = { from, _ -> from === b && dropAcks && b.delivered.isNotEmpty() }

        val results = a.send(b, "dup".toByteArray())
        settle(500)
        dropAcks = false
        connection.drop()
        network.connect(a, b)
        settle()

        assertEquals(listOf(DeliveryStatus.OK), results)
        assertEquals(1, b.delivered.size)
    }

    @Test
    fun `at most four messages wait for an ACK at a time`() {
        pair()
        b.deliverStatus = null

        repeat(6) { a.send(b, byteArrayOf(it.toByte())) }
        settle(500)

        assertEquals(4, b.delivered.size)
        b.heldDeliveries.toList().forEach { it(DeliveryStatus.OK) }
        settle(500)
        assertEquals(6, b.delivered.size)
    }

    @Test
    fun `deleting a peer sends UNPAIR, and both forget the key`() {
        val connection = pair()
        var done = false

        a.engine.removePeer(b.peerId) { done = true }
        settle()

        assertTrue(done)
        assertFalse(connection.open)
        assertTrue(a.store.peers().isEmpty())
        assertNull(b.store.key(a.peerId))
        assertEquals(PeerState.UNPAIRED_BY_PEER, b.store.peers().single().state)
        assertEquals(EngineEvent.PeerUnpaired(a.address, a.peerId), b.eventsOf<EngineEvent.PeerUnpaired>().single())
        assertFalse(b.engine.shouldReconnect(a.address))
    }

    @Test
    fun `after a deletion, connecting from the other phone asks both users again`() {
        val connection = pair()
        a.engine.removePeer(b.peerId) {}
        settle()
        assertFalse(connection.open)
        a.events.clear()
        b.events.clear()

        // B taps 연결; neither side may authenticate with a leftover key.
        network.connect(b, a, userInitiated = true)
        settle()

        assertEquals(1, a.eventsOf<EngineEvent.PairingRequest>().size)
        assertEquals(1, b.eventsOf<EngineEvent.PairingRequest>().size)
        assertTrue(a.engine.isConnected(b.address))
        assertEquals(PeerState.PAIRED, b.store.peers().single().state)
    }

    @Test
    fun `after a deletion, the peer's own reconnect attempt is refused`() {
        val connection = pair()
        // UNPAIR doesn't arrive: B keeps its key and tries again on its own.
        connection.drop()
        a.engine.removePeer(b.peerId) {}
        b.events.clear()

        val again = network.connect(b, a)
        settle()

        assertFalse(again.open)
        assertFalse(a.engine.isConnected(b.address))
        assertEquals(PeerState.REPAIR_NEEDED, b.store.peers().single().state)
        assertTrue(a.store.peers().isEmpty())
    }

    @Test
    fun `deleting a peer that isn't connected forgets it right away`() {
        pair().drop()
        var done = false

        a.engine.removePeer(b.peerId) { done = true }

        assertTrue(done)
        assertTrue(a.store.peers().isEmpty())
    }

    @Test
    fun `an AUTH that doesn't verify is rejected and stops reconnects on both sides`() {
        pair().drop()
        b.store.keys[a.peerId] = ByteArray(32)

        network.connect(a, b)
        settle()

        assertEquals(PeerState.BAD_MAC, a.store.peers().single().state)
        assertEquals(PeerState.BAD_MAC, b.store.peers().single().state)
        assertFalse(a.engine.isConnected(b.address))
        assertFalse(a.engine.shouldReconnect(b.address))
    }

    @Test
    fun `two links made at the same time end as one, whose central is the lower peerId`() {
        pair().drop()
        a.events.clear()
        b.events.clear()

        val fromA = network.connect(a, b)
        val fromB = network.connect(b, a)
        settle()

        assertTrue(fromA.open)
        assertFalse(fromB.open)
        assertTrue(a.engine.isConnected(b.address))
        assertTrue(b.engine.isConnected(a.address))
        assertEquals(listOf(DeliveryStatus.OK), a.send(b, "x".toByteArray()).also { settle() })
        assertEquals(listOf(DeliveryStatus.OK), b.send(a, "y".toByteArray()).also { settle() })
    }

    @Test
    fun `a second link to a connected peer is turned away and the first keeps working`() {
        val first = pair()
        // B is the higher peerId; its link would win a tie, but A's is established.
        val second = network.connect(b, a)
        settle()

        assertTrue(first.open)
        assertFalse(second.open)
        assertTrue(a.eventsOf<EngineEvent.PeerRejected>().isEmpty())
        assertTrue(b.eventsOf<EngineEvent.Disconnected>().none { it.deviceId == a.address })
        assertEquals(listOf(DeliveryStatus.OK), b.send(a, "y".toByteArray()).also { settle() })
        assertFalse(b.engine.shouldReconnect(a.address))
    }

    @Test
    fun `a peer whose app restarted under a live connection replaces its dead session`() {
        val old = pair()
        // B's app restarts. Other apps keep Bluetooth connected, so A's link never
        // goes down; it just stops reaching anyone.
        old.delivers = false
        val restarted = network.phone("B", b.address, b.peerId)
        restarted.store.peerMap.putAll(b.store.peerMap)
        restarted.store.keys.putAll(b.store.keys)

        val fresh = network.connect(restarted, a)
        settle(ProtocolEngine.PROBE_TIMEOUT_MS + 2_000)

        assertTrue(fresh.open)
        assertTrue(a.engine.isConnected(b.address))
        assertTrue(restarted.engine.isConnected(a.address))
        assertEquals(listOf(DeliveryStatus.OK), a.send(restarted, "hi".toByteArray()).also { settle() })
        assertEquals(1, restarted.delivered.size)
    }

    @Test
    fun `a peripheral link that never finishes stops blocking reconnects`() {
        pair().drop()
        // A's central closes its side silently (e.g. it was a duplicate) and B never hears.
        network.lose = { from, _ -> from === a }
        network.connect(a, b)
        settle(500)
        assertFalse(b.engine.shouldReconnect(a.address))

        settle(ProtocolEngine.HANDSHAKE_TIMEOUT_MS)

        assertTrue(b.engine.shouldReconnect(a.address))
    }

    @Test
    fun `a new HELLO during a session starts the handshake over`() {
        val connection = pair()
        a.events.clear()
        // A's app restarted on the same link: its central sends a fresh HELLO.
        a.engine.linkUp(connection.centralLink, Role.CENTRAL, b.address, network.maxFrameSize, false)
        settle()

        assertTrue(a.engine.isConnected(b.address))
        assertTrue(b.engine.isConnected(a.address))
        assertEquals(listOf(DeliveryStatus.OK), b.send(a, "after".toByteArray()).also { settle() })
    }

    @Test
    fun `a central that gets no answer gives up after the handshake timeout`() {
        b.approve = null
        network.lose = { from, _ -> from === b }
        val connection = network.connect(a, b, userInitiated = true)

        settle(ProtocolEngine.HANDSHAKE_TIMEOUT_MS + 1_000)

        assertFalse(connection.open)
        assertTrue(a.eventsOf<EngineEvent.Error>().single().message.contains("timed out"))
    }

    @Test
    fun `the pairing code is six digits of the code hash`() {
        val tPair = ByteArray(32) { it.toByte() }
        val hash = Crypto.sha256("rbc-code-v1".toByteArray(), tPair)
        val expected = ByteReader(hash).u32() % 1_000_000

        assertEquals("%06d".format(expected), Derivation.code(tPair))
    }
}
