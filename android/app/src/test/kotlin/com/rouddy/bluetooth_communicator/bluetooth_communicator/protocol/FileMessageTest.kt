package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class FileMessageTest {
    @Test
    fun `an offer carries the size, name, and type`() {
        val offer = FileMessage.decodeRequest(FileMessage.offer(5_000_000_000, "사진.jpg", "image/jpeg"))
            as FileMessage.Request.Offer
        assertEquals(5_000_000_000, offer.size)
        assertEquals("사진.jpg", offer.name)
        assertEquals("image/jpeg", offer.mime)
    }

    @Test
    fun `a chunk carries its transfer and offset`() {
        val chunk = FileMessage.decodeRequest(FileMessage.chunk(0xFFFF_FFFFL, 1L shl 40, byteArrayOf(1, 2, 3)))
            as FileMessage.Request.Chunk
        assertEquals(0xFFFF_FFFFL, chunk.transferId)
        assertEquals(1L shl 40, chunk.offset)
        assertArrayEquals(byteArrayOf(1, 2, 3), chunk.data)
        val cancel = FileMessage.decodeRequest(FileMessage.cancel(41)) as FileMessage.Request.Cancel
        assertEquals(41L, cancel.transferId)
    }

    @Test
    fun `an unknown op is not malformed, a broken one is`() {
        assertNull(FileMessage.decodeRequest(byteArrayOf(9)))
        listOf(
            byteArrayOf(),
            FileMessage.offer(1, "a", "").copyOf(5),
            FileMessage.chunk(1, 0, byteArrayOf()),
            // An empty name.
            ByteWriter().u8(FileMessage.OP_OFFER).u64(1).u8(0).u8(0).toByteArray(),
            // A size from 2^63 up.
            ByteWriter().u8(FileMessage.OP_OFFER).u64(-1).u8(1).bytes("a".toByteArray()).u8(0).toByteArray()
        ).forEach {
            try {
                FileMessage.decodeRequest(it)
                fail("Decoded ${it.toHex()}")
            } catch (expected: MalformedException) {
            }
        }
    }

    @Test
    fun `bytes after an offer are left for later versions`() {
        val offer = FileMessage.decodeRequest(FileMessage.offer(3, "a.txt", "text/plain") + byteArrayOf(7, 7))
            as FileMessage.Request.Offer
        assertEquals("a.txt", offer.name)
    }

    @Test
    fun `a long name keeps its extension`() {
        val bytes = FileMessage.nameBytes("가".repeat(100) + ".jpg")
        assertTrue(bytes.size <= FileMessage.MAX_NAME_BYTES)
        val name = bytes.toString(Charsets.UTF_8)
        assertEquals("가".repeat(83) + ".jpg", name)
        // No extension worth keeping: just cut, on a character boundary.
        assertEquals("가".repeat(85), FileMessage.nameBytes("가".repeat(100)).toString(Charsets.UTF_8))
        assertEquals("short.txt", FileMessage.nameBytes("short.txt").toString(Charsets.UTF_8))
    }

    @Test
    fun `a received name can't leave its directory`() {
        assertEquals("_.._etc_passwd", FileMessage.safeFileName("../../etc/passwd"))
        assertEquals("a_b_c", FileMessage.safeFileName("a\u0000b\\c"))
        assertEquals("file", FileMessage.safeFileName(".."))
        assertEquals("file", FileMessage.safeFileName("  "))
        assertEquals("hidden", FileMessage.safeFileName(".hidden"))
        assertEquals("보고서 최종.pdf", FileMessage.safeFileName("보고서 최종.pdf "))
    }

    @Test
    fun `only a plain type passes as the mime type`() {
        assertEquals("image/jpeg", FileMessage.safeMime("image/JPEG"))
        assertEquals("application/vnd.ms-excel", FileMessage.safeMime("application/vnd.ms-excel"))
        listOf("", "text", "/plain", "text/", "a/b/c", "text/plain; charset=utf-8").forEach {
            assertEquals(it, FileMessage.DEFAULT_MIME, FileMessage.safeMime(it))
        }
    }

    @Test
    fun `the largest chunk fits one message`() {
        val payload = FileMessage.chunk(0xFFFF_FFFFL, Long.MAX_VALUE, ByteArray(FileMessage.CHUNK_SIZE))
        val envelope = Envelope.encode(Envelope.Data(0xFFFF_FFFFL, Envelope.FLAG_ACK_REQ, FileMessage.PATH, 0, payload))
        assertTrue(envelope.size + ProtocolEngine.SEALED_OVERHEAD <= MAX_MESSAGE_SIZE)
    }

    @Test
    fun `replies are one result byte`() {
        assertEquals(FileMessage.DECLINED, FileMessage.decodeReply(FileMessage.reply(FileMessage.DECLINED)))
        assertNull(FileMessage.decodeReply(byteArrayOf()))
    }
}
