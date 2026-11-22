package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

/** An app identity: package name plus the SHA-256 of its signing certificate(s) (8절). */
data class AppIdentity(val packageName: String, val certHash: String) {
    init {
        require(certHash.length == 64) { "certHash must be 32 bytes of hex" }
    }
}

/** ACK statuses (7절) and the sender-local results (9절). */
object DeliveryStatus {
    const val OK = 0
    const val NO_RECEIVER = 1
    const val UNSUPPORTED = 2
    const val TOO_LARGE = 3
    const val BUSY = 4
    const val DENIED = 5
    const val MALFORMED = 6
    const val ERROR = 255

    /** Not sent before the TTL ran out; safe to retry. */
    const val EXPIRED_NOT_SENT = 1000

    /** Sent, but no ACK arrived; the peer may have received it. */
    const val EXPIRED_UNCONFIRMED = 1001
}

/** The plaintext of a SEALED record (7절). */
sealed class Envelope {
    abstract val msgId: Long
    abstract val flags: Int

    val ackRequested: Boolean
        get() = flags and FLAG_ACK_REQ != 0

    class Data(
        override val msgId: Long,
        override val flags: Int,
        val path: String,
        /** The request this answers when [FLAG_REPLY] is set, otherwise 0. */
        val replyTo: Long,
        val payload: ByteArray
    ) : Envelope() {
        val isReply: Boolean
            get() = flags and FLAG_REPLY != 0
    }

    class Ack(val refMsgId: Long, val status: Int) : Envelope() {
        override val msgId = 0L
        override val flags = 0
    }

    class Caps(
        override val msgId: Long,
        val builtins: List<String>,
        val apps: List<AppIdentity>
    ) : Envelope() {
        override val flags = 0
    }

    class Unpair(override val msgId: Long) : Envelope() {
        override val flags = FLAG_ACK_REQ
    }

    /** A type this version doesn't know; answered with UNSUPPORTED if it asks for an ACK. */
    class Unknown(val type: Int, override val msgId: Long, override val flags: Int) : Envelope()

    companion object {
        const val DATA = 0x01
        const val ACK = 0x02
        const val CAPS = 0x03
        const val UNPAIR = 0x04

        const val FLAG_ACK_REQ = 0x01
        const val FLAG_REPLY = 0x02

        const val MAX_PATH_BYTES = 255
        private const val CAPS_TAG_BUILTIN = 0x01
        private const val CAPS_TAG_APP = 0x02

        /** Bytes a DATA envelope adds around its payload, besides the path. */
        const val DATA_OVERHEAD = 6 + 1 + 4

        fun encode(envelope: Envelope): ByteArray {
            val type = when (envelope) {
                is Data -> DATA
                is Ack -> ACK
                is Caps -> CAPS
                is Unpair -> UNPAIR
                is Unknown -> envelope.type
            }
            val writer = ByteWriter().u8(type).u8(envelope.flags).u32(envelope.msgId)
            when (envelope) {
                is Data -> {
                    val path = envelope.path.toByteArray(Charsets.UTF_8)
                    require(path.size <= MAX_PATH_BYTES) { "Path longer than $MAX_PATH_BYTES bytes" }
                    writer.u8(path.size).bytes(path)
                    if (envelope.isReply) {
                        writer.u32(envelope.replyTo)
                    }
                    writer.bytes(envelope.payload)
                }
                is Ack -> writer.u32(envelope.refMsgId).u8(envelope.status)
                is Caps -> {
                    val tlv = Tlv.Writer(writer)
                    envelope.builtins.forEach { tlv.put(CAPS_TAG_BUILTIN, it.toByteArray(Charsets.UTF_8)) }
                    envelope.apps.forEach { app ->
                        val name = app.packageName.toByteArray(Charsets.UTF_8)
                        tlv.put(
                            CAPS_TAG_APP,
                            ByteWriter().u8(name.size).bytes(name).bytes(app.certHash.hexToBytes()).toByteArray()
                        )
                    }
                }
                is Unpair, is Unknown -> Unit
            }
            return writer.toByteArray()
        }

        /** Throws [MalformedException]. */
        fun decode(bytes: ByteArray): Envelope {
            val reader = ByteReader(bytes)
            val type = reader.u8()
            val flags = reader.u8()
            val msgId = reader.u32()
            return when (type) {
                DATA -> {
                    val path = reader.bytes(reader.u8()).toString(Charsets.UTF_8)
                    val replyTo = if (flags and FLAG_REPLY != 0) reader.u32() else 0L
                    Data(msgId, flags, path, replyTo, reader.rest())
                }
                ACK -> Ack(reader.u32(), reader.u8())
                CAPS -> {
                    val builtins = mutableListOf<String>()
                    val apps = mutableListOf<AppIdentity>()
                    Tlv.read(reader) { tag, value ->
                        when (tag) {
                            CAPS_TAG_BUILTIN -> builtins += value.toString(Charsets.UTF_8)
                            CAPS_TAG_APP -> {
                                val app = ByteReader(value)
                                val name = app.bytes(app.u8()).toString(Charsets.UTF_8)
                                apps += AppIdentity(name, app.bytes(32).toHex())
                            }
                        }
                    }
                    Caps(msgId, builtins, apps)
                }
                UNPAIR -> Unpair(msgId)
                else -> Unknown(type, msgId, flags)
            }
        }
    }
}
