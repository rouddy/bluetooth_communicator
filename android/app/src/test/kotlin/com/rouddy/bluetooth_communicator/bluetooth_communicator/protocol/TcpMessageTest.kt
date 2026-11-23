package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TcpMessageTest {
    private val token = ByteArray(TcpMessage.TOKEN_SIZE) { it.toByte() }

    @Test
    fun `WIFI says whether the phone is on Wi-Fi`() {
        assertArrayEquals(byteArrayOf(0, 1), TcpMessage.wifi(true))
        assertArrayEquals(byteArrayOf(0, 0), TcpMessage.wifi(false))
        assertTrue((TcpMessage.decodeRequest(byteArrayOf(0, 1)) as TcpMessage.Request.Wifi).on)
        assertFalse((TcpMessage.decodeRequest(byteArrayOf(0, 0)) as TcpMessage.Request.Wifi).on)
        assertThrows(MalformedException::class.java) { TcpMessage.decodeRequest(byteArrayOf(0)) }
    }

    @Test
    fun `OFFER carries the port, the token, and the addresses`() {
        val v4 = byteArrayOf(192.toByte(), 168.toByte(), 1, 10)
        val v6 = ByteArray(16) { (0x20 + it).toByte() }
        val payload = TcpMessage.offer(0xC350, token, listOf(v4, v6))
        assertArrayEquals(
            byteArrayOf(1, 0x50, 0xC3.toByte()) + token + byteArrayOf(2, 4) + v4 + byteArrayOf(16) + v6,
            payload
        )
        val offer = TcpMessage.decodeRequest(payload) as TcpMessage.Request.Offer
        assertEquals(0xC350, offer.port)
        assertArrayEquals(token, offer.token)
        assertEquals(2, offer.addresses.size)
        assertArrayEquals(v4, offer.addresses[0])
        assertArrayEquals(v6, offer.addresses[1])
    }

    @Test
    fun `an OFFER that doesn't decode is malformed, and an unknown op isn't`() {
        val good = TcpMessage.offer(5000, token, listOf(byteArrayOf(10, 0, 0, 1)))
        assertThrows(MalformedException::class.java) { TcpMessage.decodeRequest(good.copyOf(good.size - 1)) }
        // No addresses.
        val none = byteArrayOf(1, 0x88.toByte(), 0x13) + token + byteArrayOf(0)
        assertThrows(MalformedException::class.java) { TcpMessage.decodeRequest(none) }
        // An address that's neither IPv4 nor IPv6.
        val odd = byteArrayOf(1, 0x88.toByte(), 0x13) + token + byteArrayOf(1, 3, 1, 2, 3)
        assertThrows(MalformedException::class.java) { TcpMessage.decodeRequest(odd) }
        // Port 0.
        val zero = byteArrayOf(1, 0, 0) + token + byteArrayOf(1, 4, 10, 0, 0, 1)
        assertThrows(MalformedException::class.java) { TcpMessage.decodeRequest(zero) }
        assertNull(TcpMessage.decodeRequest(byteArrayOf(9, 1)))
        // Later additions after the fields are ignored.
        assertTrue(TcpMessage.decodeRequest(good + byteArrayOf(7, 7)) is TcpMessage.Request.Offer)
    }

    @Test
    fun `a reply is the result byte`() {
        assertArrayEquals(byteArrayOf(2), TcpMessage.reply(TcpMessage.RESULT_NO_WIFI))
        assertEquals(TcpMessage.RESULT_FAILED, TcpMessage.decodeReply(byteArrayOf(1)))
        assertNull(TcpMessage.decodeReply(ByteArray(0)))
    }

    @Test
    fun `the stream opens with the magic, the version, and the token`() {
        val opening = TcpStream.opening(token)
        assertEquals(TcpStream.OPENING_SIZE, opening.size)
        assertArrayEquals(byteArrayOf('R'.code.toByte(), 'B'.code.toByte(), 'C'.code.toByte(), 'T'.code.toByte(), 1), opening.copyOf(5))
        assertArrayEquals(token, TcpStream.tokenOf(opening))
        val wrongMagic = opening.copyOf().also { it[0] = 'X'.code.toByte() }
        assertNull(TcpStream.tokenOf(wrongMagic))
        val wrongVersion = opening.copyOf().also { it[4] = 2 }
        assertNull(TcpStream.tokenOf(wrongVersion))
        assertNull(TcpStream.tokenOf(opening.copyOf(opening.size - 1)))
    }

    @Test
    fun `frames on the stream have a length prefix that fits a whole record`() {
        assertArrayEquals(byteArrayOf(0x10, 0x27, 0, 0), TcpStream.lengthPrefix(10_000))
        assertEquals(10_000, TcpStream.lengthOf(TcpStream.lengthPrefix(10_000)))
        assertEquals(0, TcpStream.lengthOf(TcpStream.lengthPrefix(0)))
        assertEquals(TcpStream.FRAME_SIZE, TcpStream.lengthOf(TcpStream.lengthPrefix(TcpStream.FRAME_SIZE)))
        assertNull(TcpStream.lengthOf(TcpStream.lengthPrefix(TcpStream.FRAME_SIZE + 1)))
        // The largest record goes out as one frame.
        val record = ByteArray(MAX_MESSAGE_SIZE)
        assertEquals(1, Frames.split(record, 0, TcpStream.FRAME_SIZE).size)
    }
}
