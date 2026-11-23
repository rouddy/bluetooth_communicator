package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

/**
 * The `/control/media` built-in path (docs/protocol.md 10절): one phone presses a
 * media key on the other, or asks whether it's playing. The request is a DATA with
 * `u8 op`; the answer is a REPLY DATA with `u8 result` and `u8 state`.
 */
object MediaMessage {
    const val PATH = "/control/media"

    const val OP_GET_STATE = 0
    const val OP_PLAY = 1
    const val OP_PAUSE = 2
    const val OP_PLAY_PAUSE = 3
    const val OP_STOP = 4
    const val OP_NEXT = 5
    const val OP_PREVIOUS = 6

    const val OK = 0
    const val FAILED = 1
    const val UNSUPPORTED_OP = 2

    const val STATE_UNKNOWN = 0
    const val STATE_PLAYING = 1
    const val STATE_NOT_PLAYING = 2

    class Reply(val result: Int, val state: Int)

    fun request(op: Int): ByteArray = byteArrayOf(op.toByte())

    /** The op [payload] asks for, or null if it isn't a request. */
    fun decodeRequest(payload: ByteArray): Int? = if (payload.size == 1) payload[0].toInt() and 0xFF else null

    fun isKnownOp(op: Int) = op in OP_GET_STATE..OP_PREVIOUS

    fun reply(result: Int, state: Int): ByteArray = byteArrayOf(result.toByte(), state.toByte())

    fun decodeReply(payload: ByteArray): Reply? {
        if (payload.size < 2) {
            return null
        }
        return Reply(payload[0].toInt() and 0xFF, payload[1].toInt() and 0xFF)
    }

    private val opNames = listOf("getState", "play", "pause", "playPause", "stop", "next", "previous")

    /** Names for the platform channel (`controlMedia.op`, `mediaControl.op`). */
    fun opName(op: Int): String = opNames.getOrNull(op) ?: "unknown"

    fun opOf(name: String): Int? = opNames.indexOf(name).takeIf { it >= 0 }

    /** Names for the platform channel (`mediaControl.result`). */
    fun resultName(result: Int): String = when (result) {
        OK -> "ok"
        FAILED -> "failed"
        UNSUPPORTED_OP -> "unsupportedOp"
        else -> "unknown"
    }

    /** Names for the platform channel (`mediaControl.state`). */
    fun stateName(state: Int): String = when (state) {
        STATE_PLAYING -> "playing"
        STATE_NOT_PLAYING -> "notPlaying"
        else -> "unknown"
    }
}
