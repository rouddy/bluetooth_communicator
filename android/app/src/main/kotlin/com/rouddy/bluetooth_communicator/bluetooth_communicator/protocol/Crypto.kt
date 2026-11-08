package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * A pair key K. It's only ever used as an HMAC key (6.4), so on Android it can live
 * in the Keystore as a non-exportable HMAC key; tests use [RawPeerKey].
 */
fun interface PeerKey {
    fun hmac(data: ByteArray): ByteArray
}

class RawPeerKey(private val key: ByteArray) : PeerKey {
    override fun hmac(data: ByteArray) = Crypto.hmac(key, data)
}

/** SHA-256, HMAC-SHA256, HKDF, AES-256-GCM, and P-256 ECDH, from the platform JCA. */
object Crypto {
    const val KEY_SIZE = 32
    private const val GCM_TAG_BITS = 128

    fun sha256(vararg parts: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        parts.forEach(digest::update)
        return digest.digest()
    }

    fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        parts.forEach(mac::update)
        return mac.doFinal()
    }

    /** RFC 5869 with SHA-256. */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * 32) { "Invalid HKDF length $length" }
        val prk = hmac(if (salt.isEmpty()) ByteArray(32) else salt, ikm)
        val out = java.io.ByteArrayOutputStream(length)
        var block = ByteArray(0)
        var counter = 1
        while (out.size() < length) {
            block = hmac(prk, block, info, byteArrayOf(counter.toByte()))
            out.write(block)
            counter++
        }
        return out.toByteArray().copyOf(length)
    }

    /** `counter (u32 LE) ‖ 0x00 × 8` (5절). */
    fun nonce(counter: Long): ByteArray = ByteWriter(12).u32(counter).bytes(ByteArray(8)).toByteArray()

    /** Returns the ciphertext followed by the 16-byte tag. */
    fun seal(key: ByteArray, counter: Long, aad: ByteArray, plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce(counter)))
        cipher.updateAAD(aad)
        return cipher.doFinal(plaintext)
    }

    /** Returns null if the tag doesn't verify. */
    fun open(key: ByteArray, counter: Long, aad: ByteArray, sealed: ByteArray): ByteArray? = runCatching {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce(counter)))
        cipher.updateAAD(aad)
        cipher.doFinal(sealed)
    }.getOrNull()

    fun constantTimeEquals(a: ByteArray, b: ByteArray) = MessageDigest.isEqual(a, b)

    /** A P-256 key pair; [publicKey] is the X9.62 uncompressed point (65 bytes). */
    class EcKeyPair internal constructor(
        val publicKey: ByteArray,
        internal val privateKey: PrivateKey,
        internal val params: ECParameterSpec
    )

    fun generateEcKeyPair(random: SecureRandom): EcKeyPair {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"), random)
        val pair = generator.generateKeyPair()
        val public = pair.public as ECPublicKey
        val encoded = byteArrayOf(0x04) + fieldBytes(public.w.affineX) + fieldBytes(public.w.affineY)
        return EcKeyPair(encoded, pair.private, public.params)
    }

    /**
     * The ECDH shared secret (the x coordinate, 32 bytes), or null if [peerPublicKey]
     * isn't a valid point on P-256.
     */
    fun ecdh(own: EcKeyPair, peerPublicKey: ByteArray): ByteArray? {
        if (peerPublicKey.size != 65 || peerPublicKey[0] != 0x04.toByte()) {
            return null
        }
        val x = BigInteger(1, peerPublicKey.copyOfRange(1, 33))
        val y = BigInteger(1, peerPublicKey.copyOfRange(33, 65))
        // Checked here instead of trusting each provider to reject invalid-curve points.
        if (!isOnP256(x, y)) {
            return null
        }
        return runCatching {
            val public = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), own.params))
            val agreement = KeyAgreement.getInstance("ECDH")
            agreement.init(own.privateKey)
            agreement.doPhase(public, true)
            agreement.generateSecret()
        }.getOrNull()
    }

    private val P256_P = BigInteger("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff", 16)
    private val P256_B = BigInteger("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b", 16)

    private fun isOnP256(x: BigInteger, y: BigInteger): Boolean {
        if (x.signum() < 0 || x >= P256_P || y.signum() < 0 || y >= P256_P) {
            return false
        }
        // y² = x³ - 3x + b (mod p)
        val left = y.multiply(y).mod(P256_P)
        val right = x.pow(3).subtract(x.multiply(BigInteger.valueOf(3))).add(P256_B).mod(P256_P)
        return left == right
    }

    private fun fieldBytes(value: BigInteger): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == 32 -> bytes
            bytes.size > 32 -> bytes.copyOfRange(bytes.size - 32, bytes.size)
            else -> ByteArray(32 - bytes.size) + bytes
        }
    }
}

/**
 * The receive side's replay protection for SEALED counters (5절): the highest counter
 * seen plus a bitmap of the 64 below it. Records can complete out of counter order
 * because frames of different records interleave.
 */
class ReplayWindow {
    private var highest = -1L
    private var seen = 0L

    /** Whether [counter] is new and not older than the window. */
    fun accepts(counter: Long): Boolean {
        if (counter > highest) {
            return true
        }
        val age = highest - counter
        return age < SIZE && (seen ushr age.toInt()) and 1L == 0L
    }

    /** Records [counter]; call only after the record decrypted. */
    fun mark(counter: Long) {
        if (counter > highest) {
            val shift = counter - highest
            seen = if (shift >= SIZE) 0L else seen shl shift.toInt()
            seen = seen or 1L
            highest = counter
        } else {
            seen = seen or (1L shl (highest - counter).toInt())
        }
    }

    private companion object {
        const val SIZE = 64
    }
}
