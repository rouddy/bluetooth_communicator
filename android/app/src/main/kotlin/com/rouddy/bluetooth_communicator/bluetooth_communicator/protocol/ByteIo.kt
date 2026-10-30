package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import java.io.ByteArrayOutputStream

/** Thrown for bytes that don't decode as the expected structure. */
class MalformedException(message: String) : Exception(message)

/** Writes little-endian integers (docs/protocol.md 1절). u32 values are Longs. */
class ByteWriter(capacity: Int = 64) {
    private val out = ByteArrayOutputStream(capacity)

    fun u8(value: Int) = apply { out.write(value and 0xFF) }

    fun u16(value: Int) = apply {
        u8(value)
        u8(value ushr 8)
    }

    fun u32(value: Long) = apply {
        for (shift in 0 until 32 step 8) {
            u8((value ushr shift).toInt())
        }
    }

    fun bytes(value: ByteArray) = apply { out.write(value) }

    fun toByteArray(): ByteArray = out.toByteArray()
}

class ByteReader(private val data: ByteArray, private var position: Int = 0) {
    val remaining: Int
        get() = data.size - position

    fun u8(): Int {
        need(1)
        return data[position++].toInt() and 0xFF
    }

    fun u16(): Int = u8() or (u8() shl 8)

    fun u32(): Long {
        var value = 0L
        for (shift in 0 until 32 step 8) {
            value = value or (u8().toLong() shl shift)
        }
        return value
    }

    fun bytes(count: Int): ByteArray {
        need(count)
        return data.copyOfRange(position, position + count).also { position += count }
    }

    fun rest(): ByteArray = bytes(remaining)

    private fun need(count: Int) {
        if (count < 0 || remaining < count) {
            throw MalformedException("Needed $count bytes, $remaining left")
        }
    }
}

fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

fun String.hexToBytes(): ByteArray {
    require(length % 2 == 0) { "Odd hex length" }
    return ByteArray(length / 2) { substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}

/** Cuts [text] to at most [maxBytes] of UTF-8 without splitting a character. */
fun truncateUtf8(text: String, maxBytes: Int): ByteArray {
    val bytes = text.toByteArray(Charsets.UTF_8)
    if (bytes.size <= maxBytes) {
        return bytes
    }
    var end = maxBytes
    // Back up over continuation bytes (10xxxxxx) to the start of the cut character.
    while (end > 0 && (bytes[end].toInt() and 0xC0) == 0x80) {
        end--
    }
    return bytes.copyOf(end)
}
