package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import java.nio.ByteBuffer
import java.util.UUID

const val PROTOCOL_VERSION = 1

/** Largest reassembled record this implementation accepts (HELLO maxMessageSize). */
const val MAX_MESSAGE_SIZE = 65_536

/** The 16-byte public id an install generates once (docs/protocol.md 2절). */
class PeerId(bytes: ByteArray) : Comparable<PeerId> {
    private val value = bytes.copyOf()

    init {
        require(value.size == SIZE) { "peerId must be $SIZE bytes" }
    }

    val bytes: ByteArray
        get() = value.copyOf()

    /** Unsigned byte order; decides low/high for the link tie-break (9절). */
    override fun compareTo(other: PeerId): Int {
        for (i in 0 until SIZE) {
            val diff = (value[i].toInt() and 0xFF) - (other.value[i].toInt() and 0xFF)
            if (diff != 0) {
                return diff
            }
        }
        return 0
    }

    override fun equals(other: Any?) = other is PeerId && value.contentEquals(other.value)

    override fun hashCode() = value.contentHashCode()

    /** The UUID form used on the platform channel and over AIDL. */
    override fun toString(): String {
        val buffer = ByteBuffer.wrap(value)
        return UUID(buffer.long, buffer.long).toString()
    }

    companion object {
        const val SIZE = 16

        fun parse(text: String): PeerId {
            val uuid = UUID.fromString(text)
            return PeerId(
                ByteBuffer.allocate(SIZE)
                    .putLong(uuid.mostSignificantBits)
                    .putLong(uuid.leastSignificantBits)
                    .array()
            )
        }

        fun random(random: java.security.SecureRandom): PeerId =
            PeerId(ByteArray(SIZE).also(random::nextBytes))
    }
}

object Platform {
    const val ANDROID = 1
    const val IOS = 2
}

/** REJECT reasons (6.5). */
object RejectReason {
    const val UNKNOWN_PEER = 1
    const val BAD_MAC = 2
    const val ALREADY_CONNECTED = 3
    const val USER_REJECTED = 4
    const val TIMEOUT = 5
    const val CANNOT_PROMPT = 6
    const val COMMIT_MISMATCH = 7
    const val UNSUPPORTED_VERSION = 8

    /** Names for the platform channel (`peerRejected.reason`). */
    fun name(reason: Int): String = when (reason) {
        UNKNOWN_PEER -> "unknownPeer"
        BAD_MAC -> "badMac"
        ALREADY_CONNECTED -> "alreadyConnected"
        USER_REJECTED -> "userRejected"
        TIMEOUT -> "timeout"
        CANNOT_PROMPT -> "cannotPrompt"
        COMMIT_MISMATCH -> "commitMismatch"
        UNSUPPORTED_VERSION -> "unsupportedVersion"
        else -> "unknown($reason)"
    }
}

/** A record (5절). [Sealed] carries an Envelope; the others are the plaintext handshake. */
sealed class Record {
    class Hello(
        val version: Int,
        val peerId: PeerId,
        val nonce: ByteArray,
        val name: String? = null,
        val platform: Int? = null,
        val appVersion: String? = null,
        val maxMessageSize: Long? = null
    ) : Record()

    class Auth(val mac: ByteArray) : Record()

    object PairRequest : Record()

    class PairCommit(val commit: ByteArray) : Record()

    class PairKey(val publicKey: ByteArray) : Record()

    class PairConfirm(val mac: ByteArray) : Record()

    class Reject(val reason: Int) : Record()

    /** [header] is bytes 0-5 (the AES-GCM AAD); [body] is the ciphertext plus the tag. */
    class Sealed(val counter: Long, val body: ByteArray) : Record() {
        val header: ByteArray
            get() = sealedHeader(counter)
    }

    companion object {
        const val HELLO = 0x01
        const val AUTH = 0x02
        const val PAIR_REQUEST = 0x03
        const val PAIR_COMMIT = 0x04
        const val PAIR_KEY = 0x05
        const val PAIR_CONFIRM = 0x06
        const val REJECT = 0x07
        const val SEALED = 0x10

        const val MAC_SIZE = 32
        const val PUBLIC_KEY_SIZE = 65
        const val NONCE_SIZE = 16
        const val GCM_TAG_SIZE = 16
        const val MAX_NAME_BYTES = 64

        private const val TAG_PEER_ID = 0x01
        private const val TAG_NONCE = 0x02
        private const val TAG_NAME = 0x03
        private const val TAG_PLATFORM = 0x04
        private const val TAG_APP_VERSION = 0x05
        private const val TAG_MAX_MESSAGE_SIZE = 0x06

        fun sealedHeader(counter: Long): ByteArray =
            ByteWriter(6).u8(PROTOCOL_VERSION).u8(SEALED).u32(counter).toByteArray()

        fun encode(record: Record): ByteArray {
            val type = when (record) {
                is Hello -> HELLO
                is Auth -> AUTH
                PairRequest -> PAIR_REQUEST
                is PairCommit -> PAIR_COMMIT
                is PairKey -> PAIR_KEY
                is PairConfirm -> PAIR_CONFIRM
                is Reject -> REJECT
                is Sealed -> SEALED
            }
            val version = if (record is Hello) record.version else PROTOCOL_VERSION
            val writer = ByteWriter().u8(version).u8(type)
            when (record) {
                is Hello -> {
                    val tlv = Tlv.Writer(writer)
                    tlv.put(TAG_PEER_ID, record.peerId.bytes)
                    tlv.put(TAG_NONCE, record.nonce)
                    record.name?.let { tlv.put(TAG_NAME, truncateUtf8(it, MAX_NAME_BYTES)) }
                    record.platform?.let { tlv.put(TAG_PLATFORM, byteArrayOf(it.toByte())) }
                    record.appVersion?.let { tlv.put(TAG_APP_VERSION, it.toByteArray(Charsets.UTF_8)) }
                    record.maxMessageSize?.let {
                        tlv.put(TAG_MAX_MESSAGE_SIZE, ByteWriter(4).u32(it).toByteArray())
                    }
                }
                is Auth -> writer.bytes(record.mac)
                PairRequest -> Unit
                is PairCommit -> writer.bytes(record.commit)
                is PairKey -> writer.bytes(record.publicKey)
                is PairConfirm -> writer.bytes(record.mac)
                is Reject -> writer.u8(record.reason)
                is Sealed -> writer.u32(record.counter).bytes(record.body)
            }
            return writer.toByteArray()
        }

        /** Throws [MalformedException]. Records of other versions than v1 (except HELLO) are malformed. */
        fun decode(bytes: ByteArray): Record {
            val reader = ByteReader(bytes)
            val version = reader.u8()
            val type = reader.u8()
            if (type != HELLO && version != PROTOCOL_VERSION) {
                throw MalformedException("Unsupported record version $version")
            }
            return when (type) {
                HELLO -> decodeHello(version, reader)
                AUTH -> Auth(reader.exact(MAC_SIZE))
                PAIR_REQUEST -> PairRequest.also { reader.end() }
                PAIR_COMMIT -> PairCommit(reader.exact(MAC_SIZE))
                PAIR_KEY -> PairKey(reader.exact(PUBLIC_KEY_SIZE))
                PAIR_CONFIRM -> PairConfirm(reader.exact(MAC_SIZE))
                REJECT -> Reject(reader.u8()).also { reader.end() }
                SEALED -> {
                    val counter = reader.u32()
                    if (reader.remaining < GCM_TAG_SIZE) {
                        throw MalformedException("SEALED shorter than its tag")
                    }
                    Sealed(counter, reader.rest())
                }
                else -> throw MalformedException("Unknown record type $type")
            }
        }

        private fun decodeHello(version: Int, reader: ByteReader): Hello {
            var peerId: PeerId? = null
            var nonce: ByteArray? = null
            var name: String? = null
            var platform: Int? = null
            var appVersion: String? = null
            var maxMessageSize: Long? = null
            Tlv.read(reader) { tag, value ->
                when (tag) {
                    TAG_PEER_ID -> peerId = PeerId(value.requireSize(PeerId.SIZE))
                    TAG_NONCE -> nonce = value.requireSize(NONCE_SIZE)
                    TAG_NAME -> name = value.toString(Charsets.UTF_8)
                    TAG_PLATFORM -> platform = value.requireSize(1)[0].toInt() and 0xFF
                    TAG_APP_VERSION -> appVersion = value.toString(Charsets.UTF_8)
                    TAG_MAX_MESSAGE_SIZE -> maxMessageSize = ByteReader(value.requireSize(4)).u32()
                }
            }
            return Hello(
                version = version,
                peerId = peerId ?: throw MalformedException("HELLO without peerId"),
                nonce = nonce ?: throw MalformedException("HELLO without nonce"),
                name = name,
                platform = platform,
                appVersion = appVersion,
                maxMessageSize = maxMessageSize
            )
        }

        private fun ByteReader.exact(size: Int): ByteArray = bytes(size).also { end() }

        private fun ByteReader.end() {
            if (remaining != 0) {
                throw MalformedException("$remaining trailing bytes")
            }
        }
    }
}

internal fun ByteArray.requireSize(size: Int): ByteArray {
    if (this.size != size) {
        throw MalformedException("Expected $size bytes, got ${this.size}")
    }
    return this
}

/** `u8 tag, u16 len, value[len]`, repeated; HELLO and CAPS use it. */
object Tlv {
    class Writer(private val writer: ByteWriter) {
        fun put(tag: Int, value: ByteArray) {
            require(value.size <= 0xFFFF) { "TLV value too long" }
            writer.u8(tag).u16(value.size).bytes(value)
        }
    }

    /** Calls [onEntry] for each entry; callers skip tags they don't know. */
    fun read(reader: ByteReader, onEntry: (tag: Int, value: ByteArray) -> Unit) {
        while (reader.remaining > 0) {
            val tag = reader.u8()
            val length = reader.u16()
            onEntry(tag, reader.bytes(length))
        }
    }
}
