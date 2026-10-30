package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

/**
 * The Frame layer (docs/protocol.md 4절): one frame per ATT packet. A record is split
 * into frames that share a transfer id (tid), and frames of different tids may
 * interleave.
 *
 * Header byte: bit7 S (first), bit6 E (last), bit0-5 tid. A first frame that isn't
 * also the last carries the record length (u32) after the header.
 */
object Frames {
    const val START = 0x80
    const val END = 0x40
    const val TID_MASK = 0x3F
    const val TID_COUNT = 64

    /** Smallest frame size that still fits a first frame's header and a data byte. */
    const val MIN_FRAME_SIZE = 6

    /** Splits [record] into frames of at most [maxFrameSize] bytes (the link's ATT MTU - 3). */
    fun split(record: ByteArray, tid: Int, maxFrameSize: Int): List<ByteArray> {
        require(tid in 0 until TID_COUNT) { "tid $tid out of range" }
        require(maxFrameSize >= MIN_FRAME_SIZE) { "Frame size $maxFrameSize too small" }
        if (record.size + 1 <= maxFrameSize) {
            return listOf(byteArrayOf((START or END or tid).toByte()) + record)
        }
        val frames = mutableListOf<ByteArray>()
        val firstChunk = maxFrameSize - 5
        frames += ByteWriter(maxFrameSize)
            .u8(START or tid)
            .u32(record.size.toLong())
            .bytes(record.copyOfRange(0, firstChunk))
            .toByteArray()
        var offset = firstChunk
        while (offset < record.size) {
            val chunk = minOf(maxFrameSize - 1, record.size - offset)
            val last = offset + chunk == record.size
            val header = (if (last) END else 0) or tid
            frames += byteArrayOf(header.toByte()) + record.copyOfRange(offset, offset + chunk)
            offset += chunk
        }
        return frames
    }
}

/**
 * Reassembles the frames received on one link, with a buffer per tid. Frames that
 * break the rules drop that tid's buffer; the sender's record is then lost, which
 * the delivery layer (ACK timeouts) deals with.
 */
class FrameReassembler(private val maxRecordSize: Int) {
    private class Buffer(val length: Int) {
        val data = java.io.ByteArrayOutputStream(length)
    }

    private val buffers = arrayOfNulls<Buffer>(Frames.TID_COUNT)

    /** Frames dropped so far, for diagnostics. */
    var dropped = 0
        private set

    /** Takes one frame; returns the record it completes, or null. */
    fun accept(frame: ByteArray): ByteArray? {
        if (frame.isEmpty()) {
            return drop(null)
        }
        val header = frame[0].toInt() and 0xFF
        val tid = header and Frames.TID_MASK
        val start = header and Frames.START != 0
        val end = header and Frames.END != 0
        if (start) {
            // A new start on a tid in progress abandons the old record.
            buffers[tid] = null
            if (end) {
                val record = frame.copyOfRange(1, frame.size)
                return if (record.size <= maxRecordSize) record else drop(tid)
            }
            if (frame.size < 5) {
                return drop(tid)
            }
            val length = ByteReader(frame, 1).u32()
            if (length > maxRecordSize) {
                return drop(tid)
            }
            val buffer = Buffer(length.toInt())
            buffer.data.write(frame, 5, frame.size - 5)
            if (buffer.data.size() > buffer.length) {
                return drop(tid)
            }
            buffers[tid] = buffer
            return null
        }
        // A continuation without a start.
        val buffer = buffers[tid] ?: return drop(null)
        buffer.data.write(frame, 1, frame.size - 1)
        if (buffer.data.size() > buffer.length) {
            return drop(tid)
        }
        if (!end) {
            return null
        }
        buffers[tid] = null
        return if (buffer.data.size() == buffer.length) buffer.data.toByteArray() else drop(null)
    }

    /** Drops every partial record, e.g. when the link goes away. */
    fun reset() {
        buffers.fill(null)
    }

    private fun drop(tid: Int?): ByteArray? {
        if (tid != null) {
            buffers[tid] = null
        }
        dropped++
        return null
    }
}
