package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.SecureRandom

class CryptoTest {
    private val random = SecureRandom()

    @Test
    fun `HMAC-SHA256 matches RFC 4231 test case 2`() {
        assertEquals(
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
            Crypto.hmac("Jefe".toByteArray(), "what do ya want for nothing?".toByteArray()).toHex()
        )
    }

    @Test
    fun `HKDF-SHA256 matches RFC 5869 test case 1`() {
        val okm = Crypto.hkdf(
            ikm = ByteArray(22) { 0x0b },
            salt = "000102030405060708090a0b0c".hexToBytes(),
            info = "f0f1f2f3f4f5f6f7f8f9".hexToBytes(),
            length = 42
        )
        assertEquals(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            okm.toHex()
        )
    }

    @Test
    fun `the GCM nonce is the counter followed by zeros`() {
        assertArrayEquals("040302010000000000000000".hexToBytes(), Crypto.nonce(0x01020304))
    }

    @Test
    fun `AES-GCM opens what it sealed, and nothing that was changed`() {
        val key = ByteArray(32).also(random::nextBytes)
        val aad = Record.sealedHeader(7)
        val sealed = Crypto.seal(key, 7, aad, "hello".toByteArray())

        assertEquals(5 + 16, sealed.size)
        assertArrayEquals("hello".toByteArray(), Crypto.open(key, 7, aad, sealed))
        assertNull(Crypto.open(key, 8, Record.sealedHeader(8), sealed))
        assertNull(Crypto.open(key, 7, Record.sealedHeader(8), sealed))
        assertNull(Crypto.open(ByteArray(32), 7, aad, sealed))
        val tampered = sealed.copyOf().also { it[0] = (it[0] + 1).toByte() }
        assertNull(Crypto.open(key, 7, aad, tampered))
    }

    @Test
    fun `ECDH gives both sides the same secret`() {
        val alice = Crypto.generateEcKeyPair(random)
        val bob = Crypto.generateEcKeyPair(random)

        assertEquals(65, alice.publicKey.size)
        assertEquals(0x04, alice.publicKey[0].toInt())
        val shared = Crypto.ecdh(alice, bob.publicKey)
        assertNotNull(shared)
        assertEquals(32, shared!!.size)
        assertArrayEquals(shared, Crypto.ecdh(bob, alice.publicKey))
    }

    @Test
    fun `ECDH rejects points that are not on the curve`() {
        val alice = Crypto.generateEcKeyPair(random)
        val bob = Crypto.generateEcKeyPair(random)
        val offCurve = bob.publicKey.copyOf().also { it[64] = (it[64] + 1).toByte() }

        assertNull(Crypto.ecdh(alice, offCurve))
        assertNull(Crypto.ecdh(alice, ByteArray(65)))
        assertNull(Crypto.ecdh(alice, bob.publicKey.copyOf(33)))
    }

    @Test
    fun `the replay window takes new and out-of-order counters once`() {
        val window = ReplayWindow()
        listOf(0L, 2L, 1L, 5L).forEach {
            assertTrue("counter $it", window.accepts(it))
            window.mark(it)
        }
        listOf(0L, 1L, 2L, 5L).forEach { assertFalse("replayed $it", window.accepts(it)) }
        assertTrue(window.accepts(3))

        window.mark(100)
        assertFalse("older than the window", window.accepts(36))
        assertTrue(window.accepts(37))
        assertFalse(window.accepts(100))
    }

    @Test
    fun `constant-time compare`() {
        assertTrue(Crypto.constantTimeEquals(byteArrayOf(1, 2), byteArrayOf(1, 2)))
        assertFalse(Crypto.constantTimeEquals(byteArrayOf(1, 2), byteArrayOf(1, 3)))
    }
}
