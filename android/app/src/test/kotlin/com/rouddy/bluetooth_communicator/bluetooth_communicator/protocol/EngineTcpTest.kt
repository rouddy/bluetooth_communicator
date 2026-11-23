package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The engine's side of `/tcp`: records over a link's TCP connection, and falling back. */
class EngineTcpTest {
    private val scheduler = FakeScheduler()
    private val network = Network(scheduler)

    private val a = network.phone("A", "AA:AA", PeerId(ByteArray(16) { 0x11 }))
    private val b = network.phone("B", "BB:BB", PeerId(ByteArray(16) { 0x77 }))

    private fun settle(ms: Long = 2_000) = scheduler.advance(ms)

    /** A pairs with B as central; then the TCP connection comes up. */
    private fun pairOverTcp(): Network.Connection {
        network.maxFrameSize = 512
        val connection = network.connect(a, b, userInitiated = true)
        settle()
        assertTrue(a.engine.isConnected(b.address))
        assertEquals(true to true, connection.tcpUp())
        // The switch waits for a `/ping` over Bluetooth.
        settle()
        assertTrue(a.engine.session(b.peerId)!!.tcp)
        return connection
    }

    private fun Network.Connection.framesFrom(phone: Phone, tcp: Boolean) =
        (if (tcp) tcpFrames else bleFrames).count { it.first === phone }

    @Test
    fun `after tcpUp a message goes over TCP as one frame and is acknowledged there`() {
        val connection = pairOverTcp()
        val bleBefore = connection.framesFrom(a, tcp = false) + connection.framesFrom(b, tcp = false)

        val results = a.send(b, ByteArray(3_000) { it.toByte() })
        settle()

        assertEquals(listOf(DeliveryStatus.OK), results)
        assertEquals(3_000, b.delivered.single().payload.size)
        // The data from A and the ACK from B, whole; nothing more on Bluetooth.
        assertEquals(1, connection.framesFrom(a, tcp = true))
        assertEquals(1, connection.framesFrom(b, tcp = true))
        assertTrue(connection.tcpFrames.first().second.size > 3_000)
        assertEquals(bleBefore, connection.framesFrom(a, tcp = false) + connection.framesFrom(b, tcp = false))
    }

    @Test
    fun `records that start on TCP arrive after what Bluetooth still carries`() {
        network.maxFrameSize = 512
        val connection = network.connect(a, b, userInitiated = true)
        settle()
        // A's notifications sit in the stack for a while after they count as sent.
        network.deliveryDelayMs = 300

        val first = a.send(b, ByteArray(3_000) { 1 })
        scheduler.advance(3)
        connection.tcpUp()
        assertFalse(a.engine.session(b.peerId)!!.tcp)
        val second = a.send(b, ByteArray(100) { 2 })
        settle()

        assertEquals(listOf(3_000, 100), b.delivered.map { it.payload.size })
        assertEquals(listOf(DeliveryStatus.OK), first)
        assertEquals(listOf(DeliveryStatus.OK), second)
        assertTrue(a.engine.session(b.peerId)!!.tcp)
        // The second went over TCP.
        assertTrue(connection.tcpFrames.any { it.first === a && it.second.size > 100 })
    }

    @Test
    fun `the switch to TCP goes ahead if Bluetooth never confirms it`() {
        network.maxFrameSize = 512
        val connection = network.connect(a, b, userInitiated = true)
        settle()
        connection.delivers = false

        connection.tcpUp()
        val results = a.send(b, "late".toByteArray(), ttlMs = ProtocolEngine.MAX_TTL_MS)
        settle(ProtocolEngine.TCP_SWITCH_TIMEOUT_MS - 1_000)
        assertTrue(results.isEmpty())
        settle(2_000)

        assertTrue(a.engine.session(b.peerId)!!.tcp)
        assertEquals(listOf(DeliveryStatus.OK), results)
    }

    @Test
    fun `the peers list says which sessions use TCP`() {
        val connection = pairOverTcp()
        assertTrue(a.engine.peerSummaries().single().tcp)
        assertTrue(a.engine.session(b.peerId)!!.tcp)
        assertEquals(Role.CENTRAL, a.engine.session(b.peerId)!!.role)
        assertEquals(Role.PERIPHERAL, b.engine.session(a.peerId)!!.role)

        connection.tcpDown()

        assertFalse(a.engine.peerSummaries().single().tcp)
        assertFalse(b.engine.session(a.peerId)!!.tcp)
        assertTrue(a.engine.isConnected(b.address))
    }

    @Test
    fun `TCP needs an established session`() {
        val connection = network.connect(a, b, userInitiated = true)

        assertFalse(a.engine.tcpUp(connection.centralLink))
        assertFalse(a.engine.tcpUp(999))
    }

    @Test
    fun `a message TCP swallowed is sent again over Bluetooth and delivered once`() {
        val connection = pairOverTcp()
        connection.loseTcp = { from, _ -> from === a }

        val results = a.send(b, "lost".toByteArray())
        settle(100)
        assertTrue(b.delivered.isEmpty())
        connection.tcpDown()
        settle()

        assertEquals(listOf(DeliveryStatus.OK), results)
        assertEquals(1, b.delivered.size)
    }

    @Test
    fun `an ACK TCP swallowed comes again after the resend, without a second delivery`() {
        val connection = pairOverTcp()
        connection.loseTcp = { from, _ -> from === b }

        val results = a.send(b, "acked".toByteArray())
        settle(100)
        assertEquals(1, b.delivered.size)
        assertTrue(results.isEmpty())
        connection.tcpDown()
        settle()

        assertEquals(listOf(DeliveryStatus.OK), results)
        assertEquals(1, b.delivered.size)
    }

    @Test
    fun `a record waiting for its TCP write goes over Bluetooth when the connection drops`() {
        val connection = pairOverTcp()
        val bleBefore = connection.framesFrom(a, tcp = false)

        val results = a.send(b, "moved".toByteArray())
        // The write hasn't completed when the connection breaks; it then fails late.
        connection.tcpDown()
        settle()

        assertEquals(listOf(DeliveryStatus.OK), results)
        assertEquals(1, b.delivered.size)
        assertTrue(connection.framesFrom(a, tcp = false) > bleBefore)
    }

    @Test
    fun `a handshake record that comes over TCP is dropped`() {
        val connection = pairOverTcp()
        val hello = Record.encode(
            Record.Hello(
                version = PROTOCOL_VERSION,
                peerId = b.peerId,
                nonce = ByteArray(Record.NONCE_SIZE),
                name = "spoof",
                platform = Platform.ANDROID,
                appVersion = "x",
                maxMessageSize = MAX_MESSAGE_SIZE.toLong(),
                nonceC = null
            )
        )

        a.engine.tcpFrameReceived(connection.centralLink, Frames.split(hello, 9, TcpStream.FRAME_SIZE).single())
        settle()

        assertTrue(a.engine.isConnected(b.address))
        assertTrue(a.logs.any { "came over TCP" in it })
        assertEquals(listOf(DeliveryStatus.OK), a.send(b, "still".toByteArray()).also { settle() })
    }

    @Test
    fun `the session ending closes its TCP connection`() {
        val connection = pairOverTcp()

        connection.drop()
        settle()

        assertEquals(listOf(connection.centralLink), a.closedTcp)
        assertEquals(listOf(connection.peripheralLink), b.closedTcp)
        assertFalse(a.engine.hasLiveLink(b.address))
    }

    @Test
    fun `a ping TCP swallowed doesn't count the link as dead`() {
        val connection = pairOverTcp()
        // The Wi-Fi went away silently: nothing crosses TCP any more.
        connection.loseTcp = { _, _ -> true }

        settle(ProtocolEngine.IDLE_PROBE_MS + 500)
        connection.tcpDown()
        settle(ProtocolEngine.IDLE_PROBE_TIMEOUT_MS + 1_000)

        assertTrue(connection.open)
        assertTrue(a.engine.isConnected(b.address))
        assertTrue(b.engine.isConnected(a.address))
    }

    @Test
    fun `bulk records don't wait for a small MTU to grow on TCP`() {
        val connection = pairOverTcp()
        network.maxFrameSize = 20
        connection.drop()
        val fresh = network.connect(a, b)
        settle(500)
        fresh.tcpUp()

        val results = mutableListOf<Int>()
        a.engine.send(b.peerId, "${TEST_APP.packageName}/chat", ByteArray(4_000), 0, 0, TEST_APP, bulk = true) { results += it }
        settle(200)

        assertEquals(listOf(DeliveryStatus.OK), results)
    }
}
