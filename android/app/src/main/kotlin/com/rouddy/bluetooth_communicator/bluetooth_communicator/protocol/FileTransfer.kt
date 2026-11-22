package com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol

/**
 * The `/file` built-in path (docs/protocol.md 10절): one file to a peer whose user
 * approves it. The sender's messages are DATAs with ACK_REQ and `u8 op`; the
 * receiver answers the OFFER with REPLY DATAs carrying `u8 result`. A transfer is
 * named by the msgId of its OFFER (the transferId).
 */
object FileMessage {
    const val PATH = "/file"

    const val OP_OFFER = 0
    const val OP_CHUNK = 1
    const val OP_CANCEL = 2

    // Replies to an OFFER.
    const val ACCEPTED = 0
    const val DECLINED = 1

    /** The receiver's user canceled after accepting. */
    const val CANCELED = 2

    /** The receiver couldn't store the file. */
    const val FAILED = 3

    /** The receiver's user didn't answer in time. */
    const val TIMEOUT = 4

    const val MAX_NAME_BYTES = 255
    const val MAX_MIME_BYTES = 255

    /** Data per CHUNK; with its headers well inside MAX_MESSAGE_SIZE. */
    const val CHUNK_SIZE = 16 * 1024

    /** A file extension kept when a long name is shortened, at most this long. */
    private const val MAX_EXTENSION_BYTES = 16

    const val DEFAULT_MIME = "application/octet-stream"

    sealed class Request {
        class Offer(val size: Long, val name: String, val mime: String) : Request()

        class Chunk(val transferId: Long, val offset: Long, val data: ByteArray) : Request()

        class Cancel(val transferId: Long) : Request()
    }

    /** OFFER: `u64 size`, `u8 nameLen`, name, `u8 mimeLen`, mime. */
    fun offer(size: Long, name: String, mime: String): ByteArray {
        val nameBytes = nameBytes(name)
        val mimeBytes = truncateUtf8(mime, MAX_MIME_BYTES)
        return ByteWriter(11 + nameBytes.size + mimeBytes.size)
            .u8(OP_OFFER)
            .u64(size)
            .u8(nameBytes.size)
            .bytes(nameBytes)
            .u8(mimeBytes.size)
            .bytes(mimeBytes)
            .toByteArray()
    }

    /** CHUNK: `u32 transferId`, `u64 offset`, the data. */
    fun chunk(transferId: Long, offset: Long, data: ByteArray): ByteArray =
        ByteWriter(13 + data.size).u8(OP_CHUNK).u32(transferId).u64(offset).bytes(data).toByteArray()

    /** CANCEL: `u32 transferId`. */
    fun cancel(transferId: Long): ByteArray = ByteWriter(5).u8(OP_CANCEL).u32(transferId).toByteArray()

    /**
     * Null for an op this version doesn't know (answered UNSUPPORTED); throws
     * [MalformedException] for a known op that doesn't decode. Bytes after an OFFER's
     * fields are ignored, for later additions.
     */
    fun decodeRequest(payload: ByteArray): Request? {
        val reader = ByteReader(payload)
        return when (reader.u8()) {
            OP_OFFER -> {
                val size = reader.u64()
                val name = reader.bytes(reader.u8()).toString(Charsets.UTF_8)
                val mime = reader.bytes(reader.u8()).toString(Charsets.UTF_8)
                if (size < 0 || name.isEmpty()) {
                    throw MalformedException("Bad OFFER")
                }
                Request.Offer(size, name, mime)
            }
            OP_CHUNK -> {
                val transferId = reader.u32()
                val offset = reader.u64()
                val data = reader.rest()
                if (offset < 0 || data.isEmpty()) {
                    throw MalformedException("Bad CHUNK")
                }
                Request.Chunk(transferId, offset, data)
            }
            OP_CANCEL -> Request.Cancel(reader.u32())
            else -> null
        }
    }

    fun reply(result: Int): ByteArray = byteArrayOf(result.toByte())

    fun decodeReply(payload: ByteArray): Int? = if (payload.isEmpty()) null else payload[0].toInt() and 0xFF

    /**
     * [name] in at most [MAX_NAME_BYTES] of UTF-8. A longer name keeps its extension
     * (from the last '.', if that's at most [MAX_EXTENSION_BYTES]) and loses the end
     * of the part before it.
     */
    fun nameBytes(name: String): ByteArray {
        val bytes = name.toByteArray(Charsets.UTF_8)
        if (bytes.size <= MAX_NAME_BYTES) {
            return bytes
        }
        val dot = bytes.lastIndexOf('.'.code.toByte())
        if (dot <= 0 || bytes.size - dot > MAX_EXTENSION_BYTES) {
            return truncateUtf8(name, MAX_NAME_BYTES)
        }
        val extension = bytes.copyOfRange(dot, bytes.size)
        val base = bytes.copyOf(dot).toString(Charsets.UTF_8)
        return truncateUtf8(base, MAX_NAME_BYTES - extension.size) + extension
    }

    /**
     * A name that's safe as one path component on this phone: no separators, control
     * characters, or characters file systems reject, and no leading dots or spaces.
     */
    fun safeFileName(name: String): String {
        val cleaned = StringBuilder(name.length)
        for (char in name) {
            cleaned.append(if (char.code < 0x20 || char.code == 0x7F || char in "/\\:*?\"<>|") '_' else char)
        }
        val trimmed = cleaned.trimStart('.', ' ').trimEnd(' ').toString()
        return trimmed.ifEmpty { "file" }
    }

    /** [mime] if it looks like `type/subtype` (lowercased), else [DEFAULT_MIME]. */
    fun safeMime(mime: String): String {
        val lower = mime.lowercase()
        val slash = lower.indexOf('/')
        if (slash <= 0 || slash == lower.length - 1 || lower.indexOf('/', slash + 1) >= 0) {
            return DEFAULT_MIME
        }
        val allowed = { char: Char -> char in 'a'..'z' || char in '0'..'9' || char in "!#$&^_.+-" }
        val valid = lower.withIndex().all { (index, char) -> index == slash || allowed(char) }
        return if (valid) lower else DEFAULT_MIME
    }
}

enum class TransferState {
    /** Receiving: waiting for this phone's user. */
    OFFERED,

    /** Sending: waiting for the peer's user. */
    WAITING,
    TRANSFERRING,
    COMPLETED,
    DECLINED,
    CANCELED,
    FAILED;

    val finished: Boolean
        get() = ordinal >= COMPLETED.ordinal
}

/** Why a transfer failed ([FileTransfer.reason]; `fileTransfer.reason` on the channel). */
object TransferFailure {
    /** Nobody answered the offer in time, or the chunks stopped coming. */
    const val TIMEOUT = "timeout"

    /** The peer's app has no `/file` (an older version). */
    const val UNSUPPORTED = "unsupported"

    /** A message couldn't be sent before its TTL ran out. */
    const val NOT_CONNECTED = "notConnected"

    /** A message was sent, but its ACK never came. */
    const val LINK_LOST = "linkLost"

    /** This phone couldn't store the file. */
    const val STORAGE = "storage"

    /** This phone couldn't read the file. */
    const val READ = "read"

    /** The peer failed: couldn't store it, or answered something unexpected. */
    const val PEER = "peer"

    /** The peer has too many offers waiting. */
    const val BUSY = "busy"

    /** The peer was removed, or removed this phone. */
    const val UNPAIRED = "unpaired"

    fun of(status: Int): String = when (status) {
        DeliveryStatus.NO_RECEIVER, DeliveryStatus.UNSUPPORTED -> UNSUPPORTED
        DeliveryStatus.BUSY -> BUSY
        DeliveryStatus.EXPIRED_NOT_SENT -> NOT_CONNECTED
        DeliveryStatus.EXPIRED_UNCONFIRMED -> LINK_LOST
        else -> PEER
    }
}

/** Reads the file to send, front to back. */
interface FileSource {
    /** Up to [maxBytes] of the next bytes; empty at the end, null on an error. */
    fun read(maxBytes: Int, done: (ByteArray?) -> Unit)

    fun close()
}

/** Writes a received file, front to back. */
interface FileSink {
    fun write(bytes: ByteArray, done: (Boolean) -> Unit)

    /** All bytes are written; [done] gets the file's path, or null on an error. */
    fun finish(done: (String?) -> Unit)

    /** Deletes what was written. */
    fun abort()
}

interface FileTransferHost {
    /** Where an accepted file goes; null if it can't be stored. */
    fun createSink(transfer: FileTransfer): FileSink?

    /** [transfer] changed: its state, or its progress. */
    fun onTransferChanged(transfer: FileTransfer)
}

/** One file going to ([outgoing]) or coming from a peer. [id] is local to this phone. */
class FileTransfer(
    val id: Long,
    val peerId: PeerId,
    val outgoing: Boolean,
    val name: String,
    val size: Long,
    val mime: String
) {
    /** The msgId of the OFFER; 0 until it's sent. */
    var transferId = 0L
        internal set
    var state = if (outgoing) TransferState.WAITING else TransferState.OFFERED
        internal set

    /** Sending: bytes the peer confirmed. Receiving: bytes written. */
    var bytes = 0L
        internal set

    /** For [TransferState.DECLINED] and [TransferState.CANCELED]: the peer's user did it. */
    var byPeer = false
        internal set

    /** For [TransferState.FAILED]: a [TransferFailure]. */
    var reason: String? = null
        internal set

    /** The delivery status behind a failure, if one was. */
    var status: Int? = null
        internal set

    /** Receiving, once [TransferState.COMPLETED]: where the file is. */
    var path: String? = null
        internal set

    internal var source: FileSource? = null
    internal var sink: FileSink? = null
    internal var timer: Cancellable? = null

    /** Sending: bytes read and handed to the engine. Receiving: bytes given to the sink. */
    internal var nextOffset = 0L

    /** Sending: chunks waiting for their ACK. */
    internal var outstanding = 0
    internal var reading = false
}

/**
 * The transfers over `/file` (docs/protocol.md 10절), both ways, on top of the
 * engine's delivery: the receiver's user approves an OFFER, then the sender keeps up
 * to [WINDOW] chunks in flight, each acknowledged once it's written. A short link loss
 * is covered by the engine resending within the TTL.
 *
 * Like the engine, not thread-safe: the host calls it, and answers the [FileSource]
 * and [FileSink] callbacks, on the engine's thread.
 */
class FileTransfers(
    private val engine: ProtocolEngine,
    private val scheduler: Scheduler,
    private val host: FileTransferHost
) {
    companion object {
        /** Chunks a sender keeps unacknowledged; leaves the engine room for others. */
        const val WINDOW = 3

        /** How long the receiver's user has to answer an offer. */
        const val ANSWER_TIMEOUT_MS = 120_000L

        /** How long the sender waits for that answer; more, as the answer travels. */
        const val SENDER_ANSWER_TIMEOUT_MS = ANSWER_TIMEOUT_MS + 10_000L

        /** How long the receiver waits for the next chunk; over the chunks' TTL. */
        const val IDLE_TIMEOUT_MS = 90_000L

        /** Offers and transfers from one peer, unfinished, before more get BUSY. */
        const val MAX_INCOMING_PER_PEER = 4
    }

    private var nextId = 1L
    private val transfers = LinkedHashMap<Long, FileTransfer>()

    operator fun get(id: Long): FileTransfer? = transfers[id]

    /** The unfinished transfers, and received files nobody has dismissed. */
    fun all(): List<FileTransfer> = transfers.values.toList()

    // ---------------------------------------------------------------- sending

    /** Offers [source] to [peerId]; its user decides. */
    fun offer(peerId: PeerId, name: String, size: Long, mime: String, source: FileSource): FileTransfer {
        val transfer = FileTransfer(nextId++, peerId, true, name, size, mime)
        transfer.source = source
        transfers[transfer.id] = transfer
        host.onTransferChanged(transfer)
        // The ACK only says the offer arrived; the answer comes as a reply.
        val msgId = engine.send(peerId, FileMessage.PATH, FileMessage.offer(size, name, mime), 0, 0, null) { status ->
            if (status != DeliveryStatus.OK && transfer.state == TransferState.WAITING) {
                fail(transfer, TransferFailure.of(status), status, notifyPeer = status == DeliveryStatus.EXPIRED_UNCONFIRMED)
            }
        }
        // A local failure can come before send returns.
        if (!transfer.state.finished) {
            transfer.transferId = msgId
            transfer.timer = scheduler.schedule(SENDER_ANSWER_TIMEOUT_MS) {
                if (transfer.state == TransferState.WAITING) {
                    fail(transfer, TransferFailure.TIMEOUT, notifyPeer = true)
                }
            }
        }
        return transfer
    }

    /** The peer's answer to one of our offers. */
    fun onReply(peerId: PeerId, data: Envelope.Data) {
        val transfer = transfers.values.firstOrNull {
            it.outgoing && it.peerId == peerId && it.transferId == data.replyTo
        } ?: return
        when (FileMessage.decodeReply(data.payload) ?: return) {
            FileMessage.ACCEPTED -> {
                if (transfer.state != TransferState.WAITING) {
                    return
                }
                transfer.timer?.cancel()
                transfer.timer = null
                transfer.state = TransferState.TRANSFERRING
                if (transfer.size == 0L) {
                    finish(transfer, TransferState.COMPLETED)
                } else {
                    host.onTransferChanged(transfer)
                    pump(transfer)
                }
            }
            FileMessage.DECLINED -> finish(transfer, TransferState.DECLINED, byPeer = true)
            FileMessage.CANCELED -> finish(transfer, TransferState.CANCELED, byPeer = true)
            FileMessage.TIMEOUT -> finish(transfer, TransferState.FAILED, TransferFailure.TIMEOUT)
            else -> finish(transfer, TransferState.FAILED, TransferFailure.PEER)
        }
    }

    private fun pump(transfer: FileTransfer) {
        val source = transfer.source ?: return
        if (transfer.state != TransferState.TRANSFERRING || transfer.reading ||
            transfer.outstanding >= WINDOW || transfer.nextOffset >= transfer.size
        ) {
            return
        }
        transfer.reading = true
        val length = minOf(FileMessage.CHUNK_SIZE.toLong(), transfer.size - transfer.nextOffset).toInt()
        source.read(length) { read ->
            transfer.reading = false
            if (transfer.state != TransferState.TRANSFERRING) {
                return@read
            }
            if (read == null || read.isEmpty()) {
                // An error, or the file got shorter than offered.
                fail(transfer, TransferFailure.READ, notifyPeer = true)
                return@read
            }
            val data = if (read.size > length) read.copyOf(length) else read
            val offset = transfer.nextOffset
            transfer.nextOffset += data.size
            transfer.outstanding++
            engine.send(
                transfer.peerId,
                FileMessage.PATH,
                FileMessage.chunk(transfer.transferId, offset, data),
                0,
                ProtocolEngine.MAX_TTL_MS,
                null,
                bulk = true
            ) { status -> onChunkResult(transfer, data.size, status) }
            pump(transfer)
        }
    }

    private fun onChunkResult(transfer: FileTransfer, length: Int, status: Int) {
        transfer.outstanding--
        if (transfer.state != TransferState.TRANSFERRING) {
            return
        }
        when (status) {
            DeliveryStatus.OK -> {
                transfer.bytes += length
                if (transfer.bytes >= transfer.size) {
                    finish(transfer, TransferState.COMPLETED)
                } else {
                    host.onTransferChanged(transfer)
                    pump(transfer)
                }
            }
            // The receiver dropped the transfer; its CANCELED reply may still be coming.
            DeliveryStatus.DENIED -> finish(transfer, TransferState.CANCELED, byPeer = true)
            else -> fail(transfer, TransferFailure.of(status), status, notifyPeer = true)
        }
    }

    // ---------------------------------------------------------------- receiving

    /** A `/file` request from [peerId]; [done] gets the ACK status. */
    fun onRequest(peerId: PeerId, data: Envelope.Data, done: (Int) -> Unit) {
        val request = try {
            FileMessage.decodeRequest(data.payload)
        } catch (e: MalformedException) {
            done(DeliveryStatus.MALFORMED)
            return
        }
        when (request) {
            null -> done(DeliveryStatus.UNSUPPORTED)
            is FileMessage.Request.Offer -> onOffer(peerId, data.msgId, request, done)
            is FileMessage.Request.Chunk -> onChunk(peerId, request, done)
            is FileMessage.Request.Cancel -> {
                incoming(peerId, request.transferId)?.let {
                    finish(it, TransferState.CANCELED, byPeer = true)
                }
                done(DeliveryStatus.OK)
            }
        }
    }

    private fun incoming(peerId: PeerId, transferId: Long) = transfers.values.firstOrNull {
        !it.outgoing && it.peerId == peerId && it.transferId == transferId
    }

    private fun onOffer(peerId: PeerId, msgId: Long, offer: FileMessage.Request.Offer, done: (Int) -> Unit) {
        if (incoming(peerId, msgId) != null) {
            done(DeliveryStatus.OK)
            return
        }
        val waiting = transfers.values.count { !it.outgoing && it.peerId == peerId && !it.state.finished }
        if (waiting >= MAX_INCOMING_PER_PEER) {
            done(DeliveryStatus.BUSY)
            return
        }
        val transfer = FileTransfer(
            nextId++,
            peerId,
            false,
            FileMessage.safeFileName(offer.name),
            offer.size,
            FileMessage.safeMime(offer.mime)
        )
        transfer.transferId = msgId
        transfers[transfer.id] = transfer
        transfer.timer = scheduler.schedule(ANSWER_TIMEOUT_MS) {
            if (transfer.state == TransferState.OFFERED) {
                reply(transfer, FileMessage.TIMEOUT)
                finish(transfer, TransferState.FAILED, TransferFailure.TIMEOUT)
            }
        }
        done(DeliveryStatus.OK)
        host.onTransferChanged(transfer)
    }

    /** This phone's user answers the offer [id]. */
    fun respond(id: Long, accept: Boolean): Boolean {
        val transfer = transfers[id]?.takeIf { !it.outgoing && it.state == TransferState.OFFERED } ?: return false
        transfer.timer?.cancel()
        transfer.timer = null
        if (!accept) {
            reply(transfer, FileMessage.DECLINED)
            finish(transfer, TransferState.DECLINED)
            return true
        }
        val sink = host.createSink(transfer)
        if (sink == null) {
            reply(transfer, FileMessage.FAILED)
            finish(transfer, TransferState.FAILED, TransferFailure.STORAGE)
            return true
        }
        transfer.sink = sink
        transfer.state = TransferState.TRANSFERRING
        reply(transfer, FileMessage.ACCEPTED)
        if (transfer.size == 0L) {
            complete(transfer, sink) {}
            return true
        }
        armIdleTimer(transfer)
        host.onTransferChanged(transfer)
        return true
    }

    private fun onChunk(peerId: PeerId, chunk: FileMessage.Request.Chunk, done: (Int) -> Unit) {
        val transfer = incoming(peerId, chunk.transferId)
        val sink = transfer?.sink
        if (transfer == null || sink == null || transfer.state != TransferState.TRANSFERRING) {
            done(DeliveryStatus.DENIED)
            return
        }
        val end = chunk.offset + chunk.data.size
        if (end <= transfer.nextOffset) {
            // A retransmission of what we have.
            done(DeliveryStatus.OK)
            return
        }
        if (chunk.offset != transfer.nextOffset || end > transfer.size) {
            fail(transfer, TransferFailure.PEER, DeliveryStatus.MALFORMED, notifyPeer = true)
            done(DeliveryStatus.MALFORMED)
            return
        }
        transfer.nextOffset = end
        armIdleTimer(transfer)
        sink.write(chunk.data) { written ->
            when {
                transfer.state != TransferState.TRANSFERRING -> done(DeliveryStatus.DENIED)
                !written -> {
                    fail(transfer, TransferFailure.STORAGE, notifyPeer = true)
                    done(DeliveryStatus.ERROR)
                }
                else -> {
                    transfer.bytes += chunk.data.size
                    if (transfer.bytes < transfer.size) {
                        done(DeliveryStatus.OK)
                        host.onTransferChanged(transfer)
                    } else {
                        complete(transfer, sink, done)
                    }
                }
            }
        }
    }

    /** Every byte is written; the last chunk's ACK waits for the file to be closed. */
    private fun complete(transfer: FileTransfer, sink: FileSink, done: (Int) -> Unit) {
        transfer.timer?.cancel()
        transfer.timer = null
        sink.finish { path ->
            when {
                transfer.state != TransferState.TRANSFERRING -> done(DeliveryStatus.DENIED)
                path == null -> {
                    fail(transfer, TransferFailure.STORAGE, notifyPeer = true)
                    done(DeliveryStatus.ERROR)
                }
                else -> {
                    transfer.path = path
                    finish(transfer, TransferState.COMPLETED)
                    done(DeliveryStatus.OK)
                }
            }
        }
    }

    private fun armIdleTimer(transfer: FileTransfer) {
        transfer.timer?.cancel()
        transfer.timer = scheduler.schedule(IDLE_TIMEOUT_MS) {
            if (transfer.state == TransferState.TRANSFERRING) {
                fail(transfer, TransferFailure.TIMEOUT, notifyPeer = true)
            }
        }
    }

    // ---------------------------------------------------------------- both

    /** Stops the unfinished transfer [id], telling the peer; an offer is declined. */
    fun cancel(id: Long): Boolean {
        val transfer = transfers[id]?.takeIf { !it.state.finished } ?: return false
        if (transfer.state == TransferState.OFFERED) {
            return respond(id, false)
        }
        if (transfer.outgoing) {
            sendCancel(transfer)
        } else {
            reply(transfer, FileMessage.CANCELED)
        }
        finish(transfer, TransferState.CANCELED)
        return true
    }

    /** Forgets the finished transfer [id] (a received file stays until dismissed). */
    fun dismiss(id: Long): Boolean {
        val transfer = transfers[id]?.takeIf { it.state.finished } ?: return false
        transfers.remove(transfer.id)
        return true
    }

    /** [peerId] is gone (removed, or it removed us); its unfinished transfers end. */
    fun peerRemoved(peerId: PeerId) {
        transfers.values.filter { it.peerId == peerId && !it.state.finished }.forEach {
            finish(it, TransferState.FAILED, TransferFailure.UNPAIRED)
        }
    }

    private fun reply(transfer: FileTransfer, result: Int) {
        engine.send(transfer.peerId, FileMessage.PATH, FileMessage.reply(result), transfer.transferId, 0, null) {}
    }

    private fun sendCancel(transfer: FileTransfer) {
        if (transfer.transferId != 0L) {
            engine.send(transfer.peerId, FileMessage.PATH, FileMessage.cancel(transfer.transferId), 0, 0, null) {}
        }
    }

    /** Fails [transfer]; with [notifyPeer], tells the peer to stop too. */
    private fun fail(transfer: FileTransfer, reason: String, status: Int? = null, notifyPeer: Boolean = false) {
        if (transfer.state.finished) {
            return
        }
        if (notifyPeer) {
            if (transfer.outgoing) {
                sendCancel(transfer)
            } else {
                reply(transfer, FileMessage.FAILED)
            }
        }
        finish(transfer, TransferState.FAILED, reason, status)
    }

    private fun finish(
        transfer: FileTransfer,
        state: TransferState,
        reason: String? = null,
        status: Int? = null,
        byPeer: Boolean = false
    ) {
        if (transfer.state.finished) {
            return
        }
        transfer.state = state
        transfer.reason = reason
        transfer.status = status
        transfer.byPeer = byPeer
        transfer.timer?.cancel()
        transfer.timer = null
        transfer.source?.close()
        transfer.source = null
        if (state != TransferState.COMPLETED) {
            transfer.sink?.abort()
        }
        transfer.sink = null
        // A received file waits for the user to save or share it (dismiss).
        if (transfer.outgoing || state != TransferState.COMPLETED) {
            transfers.remove(transfer.id)
        }
        host.onTransferChanged(transfer)
    }
}
