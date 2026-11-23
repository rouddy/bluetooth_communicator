package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaMessageTest {
    @Test
    fun `a request is the op byte`() {
        assertArrayEquals(byteArrayOf(1), MediaMessage.request(MediaMessage.OP_PLAY))
        assertEquals(MediaMessage.OP_NEXT, MediaMessage.decodeRequest(byteArrayOf(5)))
        assertNull(MediaMessage.decodeRequest(ByteArray(0)))
        assertNull(MediaMessage.decodeRequest(byteArrayOf(1, 2)))
    }

    @Test
    fun `only the ops of the spec are known`() {
        assertTrue(MediaMessage.isKnownOp(MediaMessage.OP_GET_STATE))
        assertTrue(MediaMessage.isKnownOp(MediaMessage.OP_PREVIOUS))
        assertFalse(MediaMessage.isKnownOp(7))
        assertEquals(MediaMessage.OP_PLAY_PAUSE, MediaMessage.decodeRequest(byteArrayOf(3)))
        assertEquals(200, MediaMessage.decodeRequest(byteArrayOf(200.toByte())))
    }

    @Test
    fun `a reply carries the result and the state`() {
        val payload = MediaMessage.reply(MediaMessage.OK, MediaMessage.STATE_PLAYING)
        assertArrayEquals(byteArrayOf(0, 1), payload)
        val reply = MediaMessage.decodeReply(payload)!!
        assertEquals(MediaMessage.OK, reply.result)
        assertEquals(MediaMessage.STATE_PLAYING, reply.state)
        assertNull(MediaMessage.decodeReply(byteArrayOf(0)))
    }

    @Test
    fun `names match the platform channel`() {
        assertEquals(
            listOf("getState", "play", "pause", "playPause", "stop", "next", "previous"),
            (0..6).map(MediaMessage::opName)
        )
        assertEquals(MediaMessage.OP_PLAY_PAUSE, MediaMessage.opOf("playPause"))
        assertNull(MediaMessage.opOf("rewind"))
        assertEquals("unsupportedOp", MediaMessage.resultName(MediaMessage.UNSUPPORTED_OP))
        assertEquals("notPlaying", MediaMessage.stateName(MediaMessage.STATE_NOT_PLAYING))
        assertEquals("unknown", MediaMessage.stateName(MediaMessage.STATE_UNKNOWN))
    }
}
