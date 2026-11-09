package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardMessageTest {
    @Test
    fun `the request asks for the text`() {
        assertArrayEquals(byteArrayOf(0), ClipboardMessage.request())
        assertTrue(ClipboardMessage.isGetText(ClipboardMessage.request()))
        assertFalse(ClipboardMessage.isGetText(byteArrayOf(1)))
        assertFalse(ClipboardMessage.isGetText(byteArrayOf()))
    }

    @Test
    fun `a reply carries the text after its result`() {
        val reply = ClipboardMessage.decodeReply(ClipboardMessage.replyWithText("복사한 텍스트"))!!
        assertEquals(ClipboardMessage.OK, reply.result)
        assertEquals("복사한 텍스트", reply.text)
    }

    @Test
    fun `no text, or too much, is answered without it`() {
        assertEquals(ClipboardMessage.EMPTY, ClipboardMessage.decodeReply(ClipboardMessage.replyWithText(null))!!.result)
        assertEquals(ClipboardMessage.EMPTY, ClipboardMessage.decodeReply(ClipboardMessage.replyWithText(""))!!.result)
        val tooLarge = ClipboardMessage.decodeReply(ClipboardMessage.replyWithText("가".repeat(20_001)))!!
        assertEquals(ClipboardMessage.TOO_LARGE, tooLarge.result)
        assertNull(tooLarge.text)
        assertEquals(ClipboardMessage.OK, ClipboardMessage.decodeReply(ClipboardMessage.replyWithText("가".repeat(20_000)))!!.result)
    }

    @Test
    fun `the longest text still fits one message`() {
        val payload = ClipboardMessage.replyWithText("a".repeat(ClipboardMessage.MAX_TEXT_BYTES))
        val envelope = Envelope.encode(Envelope.Data(1, Envelope.FLAG_REPLY, ClipboardMessage.PATH, 1, payload))
        assertTrue(envelope.size + ProtocolEngine.SEALED_OVERHEAD <= MAX_MESSAGE_SIZE)
    }

    @Test
    fun `an empty reply is malformed`() {
        assertNull(ClipboardMessage.decodeReply(byteArrayOf()))
        assertEquals("waiting", ClipboardMessage.resultName(ClipboardMessage.WAITING))
    }
}
