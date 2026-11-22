package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FramesTest {
    private fun record(size: Int) = ByteArray(size) { (it * 7).toByte() }

    @Test
    fun `a record that fits in one frame costs one header byte`() {
        val frames = Frames.split(record(19), tid = 5, maxFrameSize = 20)

        assertEquals(1, frames.size)
        assertEquals(0xC5, frames[0][0].toInt() and 0xFF)
        assertEquals(20, frames[0].size)
    }

    @Test
    fun `split frames stay within the frame size and reassemble`() {
        for (maxFrameSize in listOf(20, 23, 182, 514)) {
            for (size in listOf(0, 1, 19, 20, 21, 100, 1000, 5000)) {
                val original = record(size)
                val frames = Frames.split(original, tid = 63, maxFrameSize = maxFrameSize)
                assertTrue(frames.all { it.size <= maxFrameSize })
                val reassembler = FrameReassembler(MAX_MESSAGE_SIZE)
                val completed = frames.mapNotNull(reassembler::accept)
                assertEquals("size $size at $maxFrameSize", 1, completed.size)
                assertArrayEquals(original, completed[0])
            }
        }
    }

    @Test
    fun `the first of several frames carries the record length`() {
        val frames = Frames.split(record(100), tid = 1, maxFrameSize = 20)

        assertEquals(0x81, frames.first()[0].toInt() and 0xFF)
        assertEquals(100L, ByteReader(frames.first(), 1).u32())
        assertEquals(0x41, frames.last()[0].toInt() and 0xFF)
        frames.subList(1, frames.size - 1).forEach { assertEquals(0x01, it[0].toInt()) }
    }

    @Test
    fun `frames of different tids may interleave`() {
        val big = record(200)
        val small = byteArrayOf(1, 2, 3)
        val bigFrames = Frames.split(big, tid = 1, maxFrameSize = 20)
        val smallFrames = Frames.split(small, tid = 2, maxFrameSize = 20)
        val reassembler = FrameReassembler(MAX_MESSAGE_SIZE)

        val completed = mutableListOf<ByteArray>()
        bigFrames.take(3).mapNotNullTo(completed, reassembler::accept)
        smallFrames.mapNotNullTo(completed, reassembler::accept)
        bigFrames.drop(3).mapNotNullTo(completed, reassembler::accept)

        assertEquals(2, completed.size)
        assertArrayEquals(small, completed[0])
        assertArrayEquals(big, completed[1])
    }

    @Test
    fun `a continuation without a start is dropped`() {
        val frames = Frames.split(record(100), tid = 3, maxFrameSize = 20)
        val reassembler = FrameReassembler(MAX_MESSAGE_SIZE)

        frames.drop(1).forEach { assertNull(reassembler.accept(it)) }
        assertTrue(reassembler.dropped > 0)
    }

    @Test
    fun `a new start on a tid in progress abandons the old record`() {
        val first = Frames.split(record(100), tid = 3, maxFrameSize = 20)
        val second = Frames.split(record(50), tid = 3, maxFrameSize = 20)
        val reassembler = FrameReassembler(MAX_MESSAGE_SIZE)

        first.take(2).forEach { assertNull(reassembler.accept(it)) }
        val completed = second.mapNotNull(reassembler::accept)

        assertEquals(1, completed.size)
        assertArrayEquals(record(50), completed[0])
    }

    @Test
    fun `a record longer than declared, or over the limit, is dropped`() {
        val reassembler = FrameReassembler(maxRecordSize = 64)
        // Declares 30 bytes but sends 15 + 19.
        val start = ByteWriter().u8(Frames.START or 4).u32(30).bytes(ByteArray(15)).toByteArray()
        val end = byteArrayOf((Frames.END or 4).toByte()) + ByteArray(19)
        assertNull(reassembler.accept(start))
        assertNull(reassembler.accept(end))

        val tooLong = Frames.split(record(65), tid = 0, maxFrameSize = 20)
        assertTrue(tooLong.map(reassembler::accept).all { it == null })
        assertNull(reassembler.accept(Frames.split(record(65), tid = 0, maxFrameSize = 100).single()))
    }

    @Test
    fun `an end that leaves the record short is dropped`() {
        val reassembler = FrameReassembler(MAX_MESSAGE_SIZE)
        val start = ByteWriter().u8(Frames.START or 4).u32(30).bytes(ByteArray(15)).toByteArray()
        val end = byteArrayOf((Frames.END or 4).toByte()) + ByteArray(5)

        assertNull(reassembler.accept(start))
        assertNull(reassembler.accept(end))
    }
}
