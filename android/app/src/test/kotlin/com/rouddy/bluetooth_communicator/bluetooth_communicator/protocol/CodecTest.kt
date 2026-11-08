package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class CodecTest {
    private val peerId = PeerId.parse("00112233-4455-6677-8899-aabbccddeeff")

    @Test
    fun `peerId round-trips through its UUID form and orders unsigned`() {
        assertEquals("00112233-4455-6677-8899-aabbccddeeff", peerId.toString())
        assertArrayEquals("00112233445566778899aabbccddeeff".hexToBytes(), peerId.bytes)
        val high = PeerId(ByteArray(16) { if (it == 0) 0x80.toByte() else 0 })
        val low = PeerId(ByteArray(16) { if (it == 0) 0x7F else 0 })
        assertTrue(low < high)
    }

    @Test
    fun `HELLO round-trips and skips unknown tags`() {
        val hello = Record.Hello(
            version = 1,
            peerId = peerId,
            nonce = ByteArray(16) { it.toByte() },
            name = "재홍의 S23",
            platform = Platform.ANDROID,
            appVersion = "1.0.0",
            maxMessageSize = 65_536
        )
        val bytes = Record.encode(hello) + byteArrayOf(0x7E, 2, 0, 9, 9)

        val decoded = Record.decode(bytes) as Record.Hello

        assertEquals(peerId, decoded.peerId)
        assertArrayEquals(hello.nonce, decoded.nonce)
        assertEquals("재홍의 S23", decoded.name)
        assertEquals(Platform.ANDROID, decoded.platform)
        assertEquals("1.0.0", decoded.appVersion)
        assertEquals(65_536L, decoded.maxMessageSize)
    }

    @Test
    fun `HELLO keeps the sender's version and cuts long names at a character`() {
        val name = "가".repeat(30) // 90 bytes of UTF-8
        val bytes = Record.encode(Record.Hello(3, peerId, ByteArray(16), name = name))

        assertEquals(3, bytes[0].toInt())
        val decoded = Record.decode(bytes) as Record.Hello
        assertEquals(3, decoded.version)
        assertEquals("가".repeat(21), decoded.name)
    }

    @Test(expected = MalformedException::class)
    fun `HELLO without a nonce is malformed`() {
        val writer = ByteWriter().u8(1).u8(Record.HELLO)
        Tlv.Writer(writer).put(0x01, peerId.bytes)
        Record.decode(writer.toByteArray())
    }

    @Test
    fun `handshake records round-trip`() {
        val mac = ByteArray(32) { 1 }
        assertArrayEquals(mac, (Record.decode(Record.encode(Record.Auth(mac))) as Record.Auth).mac)
        assertSame(Record.PairRequest, Record.decode(Record.encode(Record.PairRequest)))
        assertArrayEquals(
            mac,
            (Record.decode(Record.encode(Record.PairCommit(mac))) as Record.PairCommit).commit
        )
        val key = ByteArray(65) { 4 }
        assertArrayEquals(
            key,
            (Record.decode(Record.encode(Record.PairKey(key))) as Record.PairKey).publicKey
        )
        assertEquals(
            RejectReason.BAD_MAC,
            (Record.decode(Record.encode(Record.Reject(RejectReason.BAD_MAC))) as Record.Reject).reason
        )
        assertArrayEquals(byteArrayOf(1, 0x07, 2), Record.encode(Record.Reject(2)))
    }

    @Test
    fun `SEALED header is version, type, and the counter`() {
        val sealed = Record.Sealed(0x01020304, ByteArray(20))
        val bytes = Record.encode(sealed)

        assertArrayEquals(byteArrayOf(1, 0x10, 4, 3, 2, 1), bytes.copyOf(6))
        assertArrayEquals(bytes.copyOf(6), sealed.header)
        assertEquals(0x01020304L, (Record.decode(bytes) as Record.Sealed).counter)
    }

    @Test(expected = MalformedException::class)
    fun `a record of another version is malformed`() {
        Record.decode(byteArrayOf(2, Record.AUTH.toByte()) + ByteArray(32))
    }

    @Test(expected = MalformedException::class)
    fun `an AUTH with trailing bytes is malformed`() {
        Record.decode(byteArrayOf(1, Record.AUTH.toByte()) + ByteArray(33))
    }

    @Test
    fun `DATA round-trips with and without a reply reference`() {
        val request = Envelope.Data(41, Envelope.FLAG_ACK_REQ, "/control/media", 0, byteArrayOf(1))
        val bytes = Envelope.encode(request)
        assertArrayEquals(
            byteArrayOf(1, 1, 41, 0, 0, 0, 14) + "/control/media".toByteArray() + byteArrayOf(1),
            bytes
        )

        val reply = Envelope.decode(
            Envelope.encode(Envelope.Data(7, Envelope.FLAG_REPLY, "/control/media", 41, byteArrayOf(0, 1)))
        ) as Envelope.Data
        assertTrue(reply.isReply)
        assertEquals(41L, reply.replyTo)
        assertArrayEquals(byteArrayOf(0, 1), reply.payload)
    }

    @Test
    fun `ACK, CAPS, and UNPAIR round-trip`() {
        val ack = Envelope.decode(Envelope.encode(Envelope.Ack(41, DeliveryStatus.NO_RECEIVER))) as Envelope.Ack
        assertEquals(41L, ack.refMsgId)
        assertEquals(DeliveryStatus.NO_RECEIVER, ack.status)

        val app = AppIdentity("com.example.app", "ab".repeat(32))
        val caps = Envelope.decode(
            Envelope.encode(Envelope.Caps(9, listOf("/control/media"), listOf(app)))
        ) as Envelope.Caps
        assertEquals(9L, caps.msgId)
        assertEquals(listOf("/control/media"), caps.builtins)
        assertEquals(listOf(app), caps.apps)

        val unpair = Envelope.decode(Envelope.encode(Envelope.Unpair(10)))
        assertTrue(unpair is Envelope.Unpair && unpair.ackRequested)
    }

    @Test
    fun `an unknown envelope type keeps its id for the ACK`() {
        val unknown = Envelope.decode(byteArrayOf(0x55, 1, 5, 0, 0, 0)) as Envelope.Unknown
        assertEquals(0x55, unknown.type)
        assertEquals(5L, unknown.msgId)
        assertTrue(unknown.ackRequested)
    }

    @Test
    fun `truncateUtf8 never splits a character`() {
        assertEquals("ab", truncateUtf8("ab가", 4).toString(Charsets.UTF_8))
        assertEquals("ab가", truncateUtf8("ab가", 5).toString(Charsets.UTF_8))
    }
}
