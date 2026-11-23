package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

/**
 * The `/tcp` built-in path (docs/protocol.md 10절): two phones with a session that
 * are on Wi-Fi move their frames to a TCP connection, which is much faster than GATT.
 *
 * Each side tells the other whether it's on Wi-Fi (WIFI), at the session start and
 * whenever that changes. When both are, the central listens on a random port and
 * sends OFFER (its addresses, the port, and a one-time token); the peripheral
 * connects and opens the stream with the token. A peripheral that can't connect
 * answers the OFFER with a REPLY carrying `u8 result`.
 */
object TcpMessage {
    const val PATH = "/tcp"

    const val OP_WIFI = 0
    const val OP_OFFER = 1

    // Replies to an OFFER (only failures are answered; the central sees a success).
    const val RESULT_FAILED = 1
    const val RESULT_NO_WIFI = 2

    const val TOKEN_SIZE = 16
    private const val MAX_ADDRESSES = 8

    sealed class Request {
        class Wifi(val on: Boolean) : Request()

        class Offer(val port: Int, val token: ByteArray, val addresses: List<ByteArray>) : Request()
    }

    /** WIFI: `u8 on`. */
    fun wifi(on: Boolean): ByteArray = byteArrayOf(OP_WIFI.toByte(), if (on) 1 else 0)

    /** OFFER: `u16 port`, `token[16]`, `u8 count`, then per address `u8 len` (4 or 16) and its bytes. */
    fun offer(port: Int, token: ByteArray, addresses: List<ByteArray>): ByteArray {
        require(token.size == TOKEN_SIZE) { "Token of ${token.size} bytes" }
        require(addresses.size in 1..MAX_ADDRESSES) { "${addresses.size} addresses" }
        val writer = ByteWriter(4 + TOKEN_SIZE + addresses.sumOf { it.size + 1 })
            .u8(OP_OFFER)
            .u16(port)
            .bytes(token)
            .u8(addresses.size)
        addresses.forEach {
            require(it.size == 4 || it.size == 16) { "Address of ${it.size} bytes" }
            writer.u8(it.size).bytes(it)
        }
        return writer.toByteArray()
    }

    /**
     * Null for an op this version doesn't know (answered UNSUPPORTED); throws
     * [MalformedException] for a known op that doesn't decode. Bytes after the
     * fields are ignored, for later additions.
     */
    fun decodeRequest(payload: ByteArray): Request? {
        val reader = ByteReader(payload)
        return when (reader.u8()) {
            OP_WIFI -> Request.Wifi(reader.u8() != 0)
            OP_OFFER -> {
                val port = reader.u16()
                val token = reader.bytes(TOKEN_SIZE)
                val count = reader.u8()
                if (count == 0 || count > MAX_ADDRESSES) {
                    throw MalformedException("$count addresses")
                }
                val addresses = List(count) {
                    val length = reader.u8()
                    if (length != 4 && length != 16) {
                        throw MalformedException("Address of $length bytes")
                    }
                    reader.bytes(length)
                }
                if (port == 0) {
                    throw MalformedException("Port 0")
                }
                Request.Offer(port, token, addresses)
            }
            else -> null
        }
    }

    fun reply(result: Int): ByteArray = byteArrayOf(result.toByte())

    fun decodeReply(payload: ByteArray): Int? = if (payload.isNotEmpty()) payload[0].toInt() and 0xFF else null
}

/**
 * The TCP stream of `/tcp`. The peripheral opens it with [opening] (magic, version,
 * the OFFER's token), and the central answers [ACCEPTED]. After that each side
 * sends frames (4절) as `u32 length` and the frame; a length of 0 is a keepalive.
 * A TCP frame holds a whole record, since TCP has no ATT value limit.
 */
object TcpStream {
    private val MAGIC = byteArrayOf('R'.code.toByte(), 'B'.code.toByte(), 'C'.code.toByte(), 'T'.code.toByte())
    const val VERSION = 1
    const val OPENING_SIZE = 5 + TcpMessage.TOKEN_SIZE
    const val ACCEPTED = 1

    /** Frames on TCP: one record each, so up to [MAX_MESSAGE_SIZE] plus the frame header. */
    const val FRAME_SIZE = MAX_MESSAGE_SIZE + 5

    fun opening(token: ByteArray): ByteArray = ByteWriter(OPENING_SIZE).bytes(MAGIC).u8(VERSION).bytes(token).toByteArray()

    /** The token an [opening] carries, or null if it isn't one. */
    fun tokenOf(opening: ByteArray): ByteArray? {
        if (opening.size != OPENING_SIZE || !opening.copyOfRange(0, 4).contentEquals(MAGIC) || opening[4].toInt() != VERSION) {
            return null
        }
        return opening.copyOfRange(5, OPENING_SIZE)
    }

    /** `u32 length` before a frame. */
    fun lengthPrefix(length: Int): ByteArray = ByteWriter(4).u32(length.toLong()).toByteArray()

    /** The length a prefix announces, or null if no frame can be that long. */
    fun lengthOf(prefix: ByteArray): Int? {
        val length = ByteReader(prefix).u32()
        return if (length <= FRAME_SIZE) length.toInt() else null
    }
}
