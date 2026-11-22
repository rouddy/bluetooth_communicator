package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

/**
 * The `/clipboard` built-in path (docs/protocol.md 10절): one phone asks for the
 * other's clipboard text. The request is a DATA with `u8 op`; the answers are REPLY
 * DATAs with `u8 result` and, for [OK], the text in UTF-8. A [WAITING] answer is
 * followed by another one.
 */
object ClipboardMessage {
    const val PATH = "/clipboard"
    const val OP_GET_TEXT = 0

    const val OK = 0
    const val EMPTY = 1

    /** Can't read it right now; the user on that phone was asked. Another reply follows. */
    const val WAITING = 2

    /** Can't read it right now and can't ask (e.g. the iOS app isn't on screen). */
    const val UNAVAILABLE = 3

    /** Clipboard sharing is off there, or its user didn't allow the read. */
    const val DENIED = 4
    const val TOO_LARGE = 5
    const val NOT_TEXT = 6

    /** Fits one message with the envelope and SEALED overhead (MAX_MESSAGE_SIZE). */
    const val MAX_TEXT_BYTES = 60_000

    class Reply(val result: Int, val text: String?)

    fun request(): ByteArray = byteArrayOf(OP_GET_TEXT.toByte())

    /** Whether [payload] asks for the clipboard text (the only op in v1). */
    fun isGetText(payload: ByteArray) = payload.size == 1 && payload[0].toInt() == OP_GET_TEXT

    fun reply(result: Int): ByteArray = byteArrayOf(result.toByte())

    /** The answer for the clipboard holding [text]: OK, EMPTY, or TOO_LARGE. */
    fun replyWithText(text: String?): ByteArray {
        if (text.isNullOrEmpty()) {
            return reply(EMPTY)
        }
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_TEXT_BYTES) {
            return reply(TOO_LARGE)
        }
        return byteArrayOf(OK.toByte()) + bytes
    }

    fun decodeReply(payload: ByteArray): Reply? {
        if (payload.isEmpty()) {
            return null
        }
        val result = payload[0].toInt() and 0xFF
        val text = if (result == OK) payload.copyOfRange(1, payload.size).toString(Charsets.UTF_8) else null
        return Reply(result, text)
    }

    /** Names for the platform channel (`clipboard.result`). */
    fun resultName(result: Int): String = when (result) {
        OK -> "ok"
        EMPTY -> "empty"
        WAITING -> "waiting"
        UNAVAILABLE -> "unavailable"
        DENIED -> "denied"
        TOO_LARGE -> "tooLarge"
        NOT_TEXT -> "notText"
        else -> "unknown"
    }
}
