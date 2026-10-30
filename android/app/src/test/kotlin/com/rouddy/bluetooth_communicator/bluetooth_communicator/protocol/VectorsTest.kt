package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.SecureRandom
import java.security.spec.ECPrivateKeySpec

/**
 * test_vectors/protocol_v1.json, shared with the iOS tests (RunnerTests) and generated
 * from the spec by test_vectors/generate.py: both platforms must produce these bytes.
 */
class VectorsTest {
    private val vectors = JSONObject(File("../../test_vectors/protocol_v1.json").readText())
    private val handshake = vectors.getJSONObject("handshake")

    private fun JSONObject.hex(key: String) = getString(key).hexToBytes()

    private val peerC = PeerId(handshake.hex("peerIdC"))
    private val peerP = PeerId(handshake.hex("peerIdP"))
    private val key = RawPeerKey(handshake.hex("pairKey"))

    private fun hello(json: JSONObject, peerId: PeerId) = Record.Hello(
        version = 1,
        peerId = peerId,
        nonce = json.hex("nonce"),
        name = json.getString("name"),
        platform = json.getInt("platform"),
        appVersion = json.getString("appVersion"),
        maxMessageSize = json.getLong("maxMessageSize")
    )

    @Test
    fun `HELLO encodes to the shared bytes`() {
        val helloC = handshake.getJSONObject("helloC")
        assertArrayEquals(helloC.hex("bytes"), Record.encode(hello(helloC, peerC)))
        val decoded = Record.decode(handshake.getJSONObject("helloP").hex("bytes")) as Record.Hello
        assertEquals(peerP, decoded.peerId)
        assertEquals("RouddySE", decoded.name)
        assertEquals(Platform.IOS, decoded.platform)
    }

    @Test
    fun `the handshake derivations match`() {
        val tHello = Derivation.tHello(
            handshake.getJSONObject("helloC").hex("bytes"),
            handshake.getJSONObject("helloP").hex("bytes")
        )
        assertArrayEquals(handshake.hex("tHello"), tHello)
        val publicP = handshake.hex("publicKeyP")
        val publicC = handshake.hex("publicKeyC")
        assertArrayEquals(handshake.hex("commit"), Derivation.commit(publicP))
        assertArrayEquals(handshake.hex("sharedSecret"), Crypto.ecdh(keyPair(handshake.hex("privateKeyC"), publicC), publicP))
        assertArrayEquals(handshake.hex("sharedSecret"), Crypto.ecdh(keyPair(handshake.hex("privateKeyP"), publicP), publicC))
        val tPair = Derivation.tPair(tHello, publicP, publicC)
        assertArrayEquals(handshake.hex("tPair"), tPair)
        assertArrayEquals(handshake.hex("pairKey"), Derivation.pairKey(handshake.hex("sharedSecret"), tPair))
        assertEquals(handshake.getString("code"), Derivation.code(tPair))
        assertArrayEquals(handshake.hex("confirmMacC"), Derivation.confirmMac(key, peerC, tPair))
        assertArrayEquals(handshake.hex("confirmMacP"), Derivation.confirmMac(key, peerP, tPair))
        assertArrayEquals(handshake.hex("authMacC"), Derivation.authMac(key, peerC, tHello))
        assertArrayEquals(handshake.hex("authMacP"), Derivation.authMac(key, peerP, tHello))
        assertArrayEquals(handshake.hex("sessionKeyCtoP"), Derivation.sessionKey(key, peerC, peerP, tHello))
        assertArrayEquals(handshake.hex("sessionKeyPtoC"), Derivation.sessionKey(key, peerP, peerC, tHello))
    }

    @Test
    fun `a SEALED record encrypts to the shared bytes and back`() {
        val sealed = vectors.getJSONObject("sealed")
        val counter = sealed.getLong("counter")
        val body = Crypto.seal(sealed.hex("key"), counter, Record.sealedHeader(counter), sealed.hex("envelope"))
        assertArrayEquals(sealed.hex("record"), Record.encode(Record.Sealed(counter, body)))
        val decoded = Record.decode(sealed.hex("record")) as Record.Sealed
        assertArrayEquals(sealed.hex("envelope"), Crypto.open(sealed.hex("key"), counter, decoded.header, decoded.body))
    }

    @Test
    fun `envelopes and records encode to the shared bytes`() {
        val envelopes = vectors.getJSONObject("envelopes")
        val app = AppIdentity("com.example.app", "ab".repeat(32))
        mapOf(
            "dataRequest" to Envelope.Data(41, Envelope.FLAG_ACK_REQ, "/control/media", 0, byteArrayOf(1)),
            "dataReply" to Envelope.Data(7, Envelope.FLAG_REPLY, "/control/media", 41, byteArrayOf(0, 1)),
            "ack" to Envelope.Ack(41, DeliveryStatus.NO_RECEIVER),
            "caps" to Envelope.Caps(9, listOf("/control/media"), listOf(app)),
            "unpair" to Envelope.Unpair(10)
        ).forEach { (name, envelope) ->
            assertArrayEquals(name, envelopes.hex(name), Envelope.encode(envelope))
            assertArrayEquals(name, envelopes.hex(name), Envelope.encode(Envelope.decode(envelopes.hex(name))))
        }
        val records = vectors.getJSONObject("records")
        assertArrayEquals(records.hex("auth"), Record.encode(Record.Auth(ByteArray(32) { 0xAA.toByte() })))
        assertArrayEquals(records.hex("pairRequest"), Record.encode(Record.PairRequest))
        assertArrayEquals(records.hex("reject"), Record.encode(Record.Reject(RejectReason.ALREADY_CONNECTED)))
    }

    @Test
    fun `a record splits into the shared frames`() {
        val frames = vectors.getJSONObject("frames")
        val expected = frames.getJSONArray("frames").let { array -> List(array.length()) { array.getString(it).hexToBytes() } }
        val actual = Frames.split(frames.hex("record"), frames.getInt("tid"), frames.getInt("maxFrameSize"))
        assertEquals(expected.size, actual.size)
        expected.zip(actual).forEach { (e, a) -> assertArrayEquals(e, a) }
        val reassembler = FrameReassembler(MAX_MESSAGE_SIZE)
        assertArrayEquals(frames.hex("record"), actual.mapNotNull(reassembler::accept).single())
    }

    /** A JCA key pair from a raw P-256 scalar; the public half is given. */
    private fun keyPair(scalar: ByteArray, publicKey: ByteArray): Crypto.EcKeyPair {
        val params = Crypto.generateEcKeyPair(SecureRandom()).params
        val private = KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, scalar), params))
        return Crypto.EcKeyPair(publicKey, private, params)
    }
}
