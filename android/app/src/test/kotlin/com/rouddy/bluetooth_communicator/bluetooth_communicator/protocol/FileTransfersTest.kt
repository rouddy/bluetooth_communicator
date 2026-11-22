package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

/** A file read from memory; [failAt] makes reads from that offset fail. */
class MemorySource(private val data: ByteArray) : FileSource {
    private var position = 0
    var failAt: Int? = null
    var closed = false

    override fun read(maxBytes: Int, done: (ByteArray?) -> Unit) {
        if (failAt?.let { position >= it } == true) {
            done(null)
            return
        }
        val end = minOf(data.size, position + maxBytes)
        val chunk = data.copyOfRange(position, end)
        position = end
        done(chunk)
    }

    override fun close() {
        closed = true
    }
}

/** One phone's transfers, with files in memory. */
class Files(phone: Phone, scheduler: Scheduler) : FileTransferHost {
    data class Change(val state: TransferState, val bytes: Long)

    val transfers = FileTransfers(phone.engine, scheduler, this)
    val changes = mutableListOf<Change>()
    val stored = HashMap<Long, ByteArrayOutputStream>()
    val aborted = mutableListOf<Long>()
    var storable = true

    /** Holds each write in [heldWrites] instead of finishing it. */
    var holdWrites = false
    val heldWrites = mutableListOf<() -> Unit>()

    init {
        phone.caps = Capabilities(listOf(FileMessage.PATH), listOf(TEST_APP))
        phone.handler = handler@{ peerId, data, done ->
            if (data.path != FileMessage.PATH) {
                return@handler false
            }
            if (data.isReply) {
                transfers.onReply(peerId, data)
                done(DeliveryStatus.OK)
            } else {
                transfers.onRequest(peerId, data, done)
            }
            true
        }
    }

    override fun createSink(transfer: FileTransfer): FileSink? {
        if (!storable) {
            return null
        }
        val out = ByteArrayOutputStream()
        stored[transfer.id] = out
        return object : FileSink {
            override fun write(bytes: ByteArray, done: (Boolean) -> Unit) {
                val write = {
                    out.write(bytes)
                    done(true)
                }
                if (holdWrites) heldWrites += write else write()
            }

            override fun finish(done: (String?) -> Unit) = done("/received/${transfer.name}")

            override fun abort() {
                aborted += transfer.id
            }
        }
    }

    override fun onTransferChanged(transfer: FileTransfer) {
        changes += Change(transfer.state, transfer.bytes)
    }

    fun releaseWrites() {
        holdWrites = false
        val writes = heldWrites.toList()
        heldWrites.clear()
        writes.forEach { it() }
    }
}

class FileTransfersTest {
    private val scheduler = FakeScheduler()
    private val network = Network(scheduler).apply { maxFrameSize = 509 }
    private val a = network.phone("A", "AA:AA", PeerId(ByteArray(16) { 0x11 }))
    private val b = network.phone("B", "BB:BB", PeerId(ByteArray(16) { 0x77 }))
    private val filesA = Files(a, scheduler)
    private val filesB = Files(b, scheduler)
    private val content = ByteArray(40_000) { (it * 7).toByte() }
    private val source = MemorySource(content)

    /** More than the chunks one window holds. */
    private val big = ByteArray(100_000) { (it * 13).toByte() }

    private fun settle(ms: Long = 2_000) = scheduler.advance(ms)

    private fun pair(): Network.Connection {
        val connection = network.connect(a, b, userInitiated = true)
        settle()
        assertTrue(a.engine.isConnected(b.address))
        return connection
    }

    /** A offers [content] to B; returns both ends once B has the offer. */
    private fun offer(data: ByteArray = content, from: MemorySource = source): Pair<FileTransfer, FileTransfer> {
        val sent = filesA.transfers.offer(b.peerId, "사진.jpg", data.size.toLong(), "image/jpeg", from)
        settle()
        return sent to filesB.transfers.all().last()
    }

    @Test
    fun `a file goes through once the receiver's user accepts`() {
        pair()
        val (sent, offered) = offer()
        assertEquals(TransferState.WAITING, sent.state)
        assertEquals(TransferState.OFFERED, offered.state)
        assertEquals("사진.jpg", offered.name)
        assertEquals(40_000L, offered.size)
        assertEquals("image/jpeg", offered.mime)
        assertEquals(sent.transferId, offered.transferId)

        assertTrue(filesB.transfers.respond(offered.id, true))
        settle()

        assertEquals(TransferState.COMPLETED, offered.state)
        assertEquals("/received/사진.jpg", offered.path)
        assertArrayEquals(content, filesB.stored.getValue(offered.id).toByteArray())
        assertEquals(TransferState.COMPLETED, sent.state)
        assertTrue(source.closed)
        // Progress, chunk by chunk, on both phones.
        val progress = listOf(
            Files.Change(TransferState.TRANSFERRING, 0),
            Files.Change(TransferState.TRANSFERRING, 16_384),
            Files.Change(TransferState.TRANSFERRING, 32_768),
            Files.Change(TransferState.COMPLETED, 40_000)
        )
        assertEquals(listOf(Files.Change(TransferState.WAITING, 0)) + progress, filesA.changes)
        assertEquals(listOf(Files.Change(TransferState.OFFERED, 0)) + progress, filesB.changes)
        // A received file stays until it's dismissed; a sent one doesn't.
        assertTrue(filesA.transfers.all().isEmpty())
        assertEquals(listOf(offered), filesB.transfers.all())
        assertTrue(filesB.transfers.dismiss(offered.id))
        assertTrue(filesB.transfers.all().isEmpty())
    }

    @Test
    fun `declining ends the transfer on both phones`() {
        pair()
        val (sent, offered) = offer()

        assertTrue(filesB.transfers.respond(offered.id, false))
        settle()

        assertEquals(TransferState.DECLINED, offered.state)
        assertFalse(offered.byPeer)
        assertEquals(TransferState.DECLINED, sent.state)
        assertTrue(sent.byPeer)
        assertTrue(source.closed)
        assertTrue(filesA.transfers.all().isEmpty())
        assertTrue(filesB.transfers.all().isEmpty())
    }

    @Test
    fun `the receiver's user has two minutes to answer`() {
        pair()
        val (sent, offered) = offer()

        scheduler.advance(FileTransfers.ANSWER_TIMEOUT_MS)
        settle()

        assertEquals(TransferState.FAILED, offered.state)
        assertEquals(TransferFailure.TIMEOUT, offered.reason)
        assertEquals(TransferState.FAILED, sent.state)
        assertEquals(TransferFailure.TIMEOUT, sent.reason)
    }

    @Test
    fun `the sender stops waiting for an answer that can't come`() {
        val connection = pair()
        val (sent, _) = offer()
        connection.drop()

        scheduler.advance(FileTransfers.SENDER_ANSWER_TIMEOUT_MS)

        assertEquals(TransferState.FAILED, sent.state)
        assertEquals(TransferFailure.TIMEOUT, sent.reason)
    }

    @Test
    fun `the sender can cancel while the file is on its way`() {
        pair()
        filesB.holdWrites = true
        val (sent, offered) = offer()
        filesB.transfers.respond(offered.id, true)
        settle()
        assertEquals(TransferState.TRANSFERRING, offered.state)

        assertTrue(filesA.transfers.cancel(sent.id))
        settle()

        assertEquals(TransferState.CANCELED, sent.state)
        assertFalse(sent.byPeer)
        assertEquals(TransferState.CANCELED, offered.state)
        assertTrue(offered.byPeer)
        assertEquals(listOf(offered.id), filesB.aborted)
        // Writes that end afterwards change nothing.
        filesB.releaseWrites()
        settle()
        assertEquals(TransferState.CANCELED, offered.state)
        assertFalse(filesA.transfers.cancel(sent.id))
    }

    @Test
    fun `the receiver can cancel while the file is on its way`() {
        pair()
        filesB.holdWrites = true
        val (sent, offered) = offer()
        filesB.transfers.respond(offered.id, true)
        settle()

        assertTrue(filesB.transfers.cancel(offered.id))
        settle()

        assertEquals(TransferState.CANCELED, offered.state)
        assertFalse(offered.byPeer)
        assertEquals(TransferState.CANCELED, sent.state)
        assertTrue(sent.byPeer)
        assertTrue(source.closed)
    }

    @Test
    fun `a peer without file transfer is told apart`() {
        b.caps = Capabilities(emptyList(), listOf(TEST_APP))
        pair()

        val sent = filesA.transfers.offer(b.peerId, "a.txt", 1, "text/plain", MemorySource(byteArrayOf(1)))
        settle()

        assertEquals(TransferState.FAILED, sent.state)
        assertEquals(TransferFailure.UNSUPPORTED, sent.reason)
        assertEquals(DeliveryStatus.NO_RECEIVER, sent.status)
        assertTrue(filesB.transfers.all().isEmpty())
    }

    @Test
    fun `an empty file is done once it's accepted`() {
        pair()
        val (sent, offered) = offer(ByteArray(0), MemorySource(ByteArray(0)))

        filesB.transfers.respond(offered.id, true)
        settle()

        assertEquals(TransferState.COMPLETED, offered.state)
        assertEquals(0, filesB.stored.getValue(offered.id).size())
        assertEquals(TransferState.COMPLETED, sent.state)
    }

    @Test
    fun `a file that can't be stored fails on both phones`() {
        pair()
        filesB.storable = false
        val (sent, offered) = offer()

        filesB.transfers.respond(offered.id, true)
        settle()

        assertEquals(TransferState.FAILED, offered.state)
        assertEquals(TransferFailure.STORAGE, offered.reason)
        assertEquals(TransferState.FAILED, sent.state)
        assertEquals(TransferFailure.PEER, sent.reason)
    }

    @Test
    fun `a file that can't be read is canceled on the receiver`() {
        pair()
        source.failAt = FileMessage.CHUNK_SIZE
        val (sent, offered) = offer()

        filesB.transfers.respond(offered.id, true)
        settle()

        assertEquals(TransferState.FAILED, sent.state)
        assertEquals(TransferFailure.READ, sent.reason)
        assertEquals(TransferState.CANCELED, offered.state)
        assertEquals(listOf(offered.id), filesB.aborted)
    }

    @Test
    fun `the receiver gives up when the chunks stop coming`() {
        val connection = pair()
        filesB.holdWrites = true
        val (sent, offered) = offer(big, MemorySource(big))
        filesB.transfers.respond(offered.id, true)
        settle()
        connection.drop()
        filesB.releaseWrites()

        scheduler.advance(FileTransfers.IDLE_TIMEOUT_MS)

        // The chunks in flight were sent, but their ACKs never came.
        assertEquals(TransferState.FAILED, sent.state)
        assertEquals(TransferFailure.LINK_LOST, sent.reason)
        assertEquals(TransferState.FAILED, offered.state)
        assertEquals(TransferFailure.TIMEOUT, offered.reason)
        assertEquals(listOf(offered.id), filesB.aborted)
    }

    @Test
    fun `a transfer carries on after a short link loss`() {
        val connection = pair()
        filesB.holdWrites = true
        val (sent, offered) = offer(big, MemorySource(big))
        filesB.transfers.respond(offered.id, true)
        settle()
        // The first chunks are written, but their ACKs are lost with the link.
        connection.drop()
        filesB.releaseWrites()
        settle(5_000)

        network.connect(a, b)
        settle()

        assertEquals(TransferState.COMPLETED, sent.state)
        assertEquals(TransferState.COMPLETED, offered.state)
        assertArrayEquals(big, filesB.stored.getValue(offered.id).toByteArray())
    }

    @Test
    fun `a peer can't flood this phone with offers`() {
        pair()
        val sent = List(FileTransfers.MAX_INCOMING_PER_PEER + 1) {
            filesA.transfers.offer(b.peerId, "$it.txt", 1, "text/plain", MemorySource(byteArrayOf(1)))
        }
        settle()

        assertEquals(FileTransfers.MAX_INCOMING_PER_PEER, filesB.transfers.all().size)
        assertEquals(TransferState.FAILED, sent.last().state)
        assertEquals(TransferFailure.BUSY, sent.last().reason)
    }

    @Test
    fun `chunks that don't belong to an accepted transfer are refused`() {
        pair()
        val (_, offered) = offer()
        val statuses = mutableListOf<Int>()
        fun request(payload: ByteArray) = filesB.transfers.onRequest(
            a.peerId, Envelope.Data(900, Envelope.FLAG_ACK_REQ, FileMessage.PATH, 0, payload)
        ) { statuses += it }

        request(FileMessage.chunk(offered.transferId, 0, byteArrayOf(1)))
        request(FileMessage.chunk(12345, 0, byteArrayOf(1)))
        request(byteArrayOf(9))
        request(byteArrayOf())

        assertEquals(
            listOf(DeliveryStatus.DENIED, DeliveryStatus.DENIED, DeliveryStatus.UNSUPPORTED, DeliveryStatus.MALFORMED),
            statuses
        )
        assertEquals(TransferState.OFFERED, offered.state)
    }

    @Test
    fun `a chunk out of order fails the transfer`() {
        pair()
        val (sent, offered) = offer()
        filesB.transfers.respond(offered.id, true)
        val statuses = mutableListOf<Int>()

        filesB.transfers.onRequest(
            a.peerId,
            Envelope.Data(900, Envelope.FLAG_ACK_REQ, FileMessage.PATH, 0, FileMessage.chunk(sent.transferId, 100, byteArrayOf(1)))
        ) { statuses += it }
        settle()

        assertEquals(listOf(DeliveryStatus.MALFORMED), statuses)
        assertEquals(TransferState.FAILED, offered.state)
        assertEquals(TransferState.FAILED, sent.state)
        assertEquals(TransferFailure.PEER, sent.reason)
    }

    @Test
    fun `removing the peer ends its transfers`() {
        pair()
        val (sent, offered) = offer()

        filesA.transfers.peerRemoved(b.peerId)
        filesB.transfers.peerRemoved(a.peerId)

        assertEquals(TransferState.FAILED, sent.state)
        assertEquals(TransferFailure.UNPAIRED, sent.reason)
        assertEquals(TransferState.FAILED, offered.state)
        assertTrue(filesB.transfers.all().isEmpty())
    }
}
