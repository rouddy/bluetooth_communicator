package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.text.format.Formatter
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.FileMessage
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.FileSink
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.FileSource
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.FileTransfer
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.FileTransferHost
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.FileTransfers
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.PeerId
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.ProtocolEngine
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Scheduler
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.TransferState
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.Executors

/**
 * File transfer over `/file` (docs/protocol.md 10절) on Android: the files behind
 * [FileTransfers], the `fileTransfer` events, and the notifications for offers and
 * received files. Received files go to the cache (`received/`), from where the user
 * saves or shares them (MainActivity). File I/O runs on one background thread; every
 * call into [transfers] runs on the main looper with the engine.
 */
@SuppressLint("StaticFieldLeak") // Holds the application context only.
object FileShare : FileTransferHost {
    private const val TAG = "FileShare"
    const val CHANNEL_ID = "ble_file"
    private const val NOTIFICATION_ID = 3004
    private const val RECEIVED_DIR = "received"

    /** Received files left in the cache are deleted after this. */
    private const val KEEP_RECEIVED_MS = 24 * 60 * 60 * 1000L

    /** Free space kept beyond a file before accepting it. */
    private const val SPACE_MARGIN = 10L * 1024 * 1024

    private val handler = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private lateinit var context: Context
    lateinit var transfers: FileTransfers
        private set

    /** Transfers with a notification up. */
    private val notified = HashSet<Long>()

    fun init(context: Context, engine: ProtocolEngine, scheduler: Scheduler) {
        this.context = context.applicationContext
        transfers = FileTransfers(engine, scheduler, this)
        this.context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "파일 전송", NotificationManager.IMPORTANCE_HIGH)
        )
        io.execute(::pruneReceived)
    }

    val fileProviderAuthority: String
        get() = "${context.packageName}.files"

    private val receivedDir: File
        get() = File(context.cacheDir, RECEIVED_DIR)

    /** Tells a newly attached Dart side the transfers in progress and the received files. */
    fun replay() {
        transfers.all().forEach { BleEventBus.emit(event(it)) }
    }

    // ------------------------------------------------------------ sending

    private class Opened(val name: String, val size: Long, val mime: String, val input: InputStream)

    /** Offers the document at [uri] to [deviceId]; [done] gets null, or an error code. */
    fun offerUri(deviceId: String, uri: Uri, done: (String?) -> Unit) = offer(deviceId, done) { openUri(uri) }

    /** Offers the file at [path] (tests, adb) to [deviceId]. */
    fun offerPath(deviceId: String, path: String, done: (String?) -> Unit) = offer(deviceId, done) {
        val file = File(path)
        Opened(file.name, file.length(), mimeFromName(file.name), file.inputStream())
    }

    private fun offer(deviceId: String, done: (String?) -> Unit, open: () -> Opened?) {
        val peerId = peerIdOf(deviceId)
        if (peerId == null) {
            done("NOT_PAIRED")
            return
        }
        io.execute {
            val opened = try {
                open()
            } catch (e: Exception) {
                Log.w(TAG, "Can't open the file to send", e)
                null
            }
            handler.post {
                if (opened == null) {
                    done("READ_FAILED")
                } else {
                    transfers.offer(peerId, opened.name, opened.size, opened.mime, StreamSource(opened.input))
                    done(null)
                }
            }
        }
    }

    // On the I/O thread: a document provider may have to fetch the file first.
    private fun openUri(uri: Uri): Opened? {
        val resolver = context.contentResolver
        var name: String? = null
        var size = -1L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 && !cursor.isNull(it) }?.let {
                    name = cursor.getString(it)
                }
                cursor.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 && !cursor.isNull(it) }?.let {
                    size = cursor.getLong(it)
                }
            }
        }
        // Kept open for the whole transfer, so it doesn't depend on the URI grant.
        val descriptor = resolver.openFileDescriptor(uri, "r") ?: return null
        if (size < 0) {
            size = descriptor.statSize
        }
        if (size < 0) {
            // The offer needs the size up front.
            descriptor.close()
            return null
        }
        val fileName = name?.takeIf { it.isNotBlank() } ?: uri.lastPathSegment ?: "file"
        val mime = resolver.getType(uri) ?: mimeFromName(fileName)
        return Opened(fileName, size, mime, ParcelFileDescriptor.AutoCloseInputStream(descriptor))
    }

    private fun mimeFromName(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: FileMessage.DEFAULT_MIME
    }

    private class StreamSource(private val input: InputStream) : FileSource {
        override fun read(maxBytes: Int, done: (ByteArray?) -> Unit) {
            io.execute {
                val result = try {
                    val buffer = ByteArray(maxBytes)
                    var filled = 0
                    while (filled < maxBytes) {
                        val count = input.read(buffer, filled, maxBytes - filled)
                        if (count < 0) {
                            break
                        }
                        filled += count
                    }
                    if (filled == maxBytes) buffer else buffer.copyOf(filled)
                } catch (e: IOException) {
                    Log.w(TAG, "Reading the file to send failed", e)
                    null
                }
                handler.post { done(result) }
            }
        }

        override fun close() {
            io.execute { runCatching { input.close() } }
        }
    }

    // ------------------------------------------------------------ receiving

    override fun createSink(transfer: FileTransfer): FileSink? {
        val dir = File(receivedDir, "${System.currentTimeMillis()}-${transfer.id}")
        return try {
            if (!dir.mkdirs()) {
                throw IOException("Can't create $dir")
            }
            if (dir.usableSpace < transfer.size + SPACE_MARGIN) {
                dir.delete()
                throw IOException("Not enough space for ${transfer.size} bytes")
            }
            val file = File(dir, transfer.name)
            CacheSink(dir, file, FileOutputStream(file))
        } catch (e: IOException) {
            Log.w(TAG, "Can't store ${transfer.name}", e)
            null
        }
    }

    private class CacheSink(private val dir: File, private val file: File, private val output: FileOutputStream) : FileSink {
        override fun write(bytes: ByteArray, done: (Boolean) -> Unit) {
            io.execute {
                val written = runCatching { output.write(bytes) }.isSuccess
                handler.post { done(written) }
            }
        }

        override fun finish(done: (String?) -> Unit) {
            io.execute {
                val closed = runCatching { output.close() }.isSuccess
                handler.post { done(if (closed) file.path else null) }
            }
        }

        override fun abort() {
            io.execute {
                runCatching { output.close() }
                dir.deleteRecursively()
            }
        }
    }

    private fun pruneReceived() {
        val cutoff = System.currentTimeMillis() - KEEP_RECEIVED_MS
        receivedDir.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.deleteRecursively() }
    }

    /** The received file [id], while the user may still save or share it. */
    fun receivedFile(id: Long): FileTransfer? =
        transfers[id]?.takeIf { !it.outgoing && it.state == TransferState.COMPLETED && it.path != null }

    /** A chooser that sends the received [transfer] to another app. */
    fun shareIntent(transfer: FileTransfer): Intent {
        val uri = FileProvider.getUriForFile(context, fileProviderAuthority, File(transfer.path!!))
        val send = Intent(Intent.ACTION_SEND)
            .setType(transfer.mime)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = ClipData.newRawUri(transfer.name, uri)
        return Intent.createChooser(send, "앱으로 보내기")
    }

    /** Copies [path] to the document the user created; [done] runs on the main looper. */
    fun copyTo(path: String, uri: Uri, done: (Boolean) -> Unit) {
        io.execute {
            val copied = try {
                File(path).inputStream().use { input ->
                    context.contentResolver.openOutputStream(uri, "w")?.use { output -> input.copyTo(output) } != null
                }
            } catch (e: Exception) {
                Log.w(TAG, "Saving $path failed", e)
                false
            }
            handler.post { done(copied) }
        }
    }

    // ------------------------------------------------------------ events

    override fun onTransferChanged(transfer: FileTransfer) {
        if (transfer.state == TransferState.FAILED) {
            // Kept for errors seen once that didn't come back (TODO 38).
            Log.w(
                TAG,
                "Transfer ${transfer.id} (${if (transfer.outgoing) "send" else "receive"} ${transfer.name}) with " +
                    "${transfer.peerId} failed: reason=${transfer.reason} status=${transfer.status} " +
                    "after ${transfer.bytes}/${transfer.size} bytes"
            )
        }
        BleEventBus.emit(event(transfer))
        if (transfer.outgoing) {
            return
        }
        when (transfer.state) {
            TransferState.OFFERED -> notify(
                transfer,
                "파일 받기 요청: ${peerName(transfer.peerId)}",
                "${transfer.name} (${Formatter.formatShortFileSize(context, transfer.size)}) · 눌러서 확인하세요",
                FileTransfers.ANSWER_TIMEOUT_MS
            )
            TransferState.TRANSFERRING -> cancelNotification(transfer)
            TransferState.COMPLETED -> {
                cancelNotification(transfer)
                notify(transfer, "파일을 받았습니다: ${transfer.name}", "눌러서 저장하거나 공유하세요", null)
            }
            else -> cancelNotification(transfer)
        }
    }

    private fun event(transfer: FileTransfer): Map<String, Any?> = mapOf(
        "type" to "fileTransfer",
        "id" to transfer.id,
        "deviceId" to deviceIdOf(transfer.peerId),
        "peerId" to transfer.peerId.toString(),
        "direction" to if (transfer.outgoing) "send" else "receive",
        "name" to transfer.name,
        "size" to transfer.size,
        "mime" to transfer.mime,
        "state" to when (transfer.state) {
            TransferState.OFFERED -> "offered"
            TransferState.WAITING -> "waiting"
            TransferState.TRANSFERRING -> "transferring"
            TransferState.COMPLETED -> "completed"
            TransferState.DECLINED -> "declined"
            TransferState.CANCELED -> "canceled"
            TransferState.FAILED -> "failed"
        },
        "bytes" to transfer.bytes,
        "byPeer" to transfer.byPeer,
        "reason" to transfer.reason,
        "status" to transfer.status,
        "path" to transfer.path
    )

    /** Only while the app isn't on screen; in the app, Dart shows the transfer. */
    @SuppressLint("MissingPermission") // Checked by areNotificationsEnabled.
    private fun notify(transfer: FileTransfer, title: String, text: String, timeoutMs: Long?) {
        val manager = NotificationManagerCompat.from(context)
        if (BleEventBus.appInForeground || !manager.areNotificationsEnabled()) {
            return
        }
        val openApp = PendingIntent.getActivity(
            context,
            2,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentIntent(openApp)
            .setAutoCancel(true)
        timeoutMs?.let(builder::setTimeoutAfter)
        manager.notify(tag(transfer), NOTIFICATION_ID, builder.build())
        notified += transfer.id
    }

    private fun cancelNotification(transfer: FileTransfer) {
        if (notified.remove(transfer.id)) {
            NotificationManagerCompat.from(context).cancel(tag(transfer), NOTIFICATION_ID)
        }
    }

    /** The app came to the front, where Dart shows every transfer. */
    fun clearNotifications() {
        val manager = NotificationManagerCompat.from(context)
        notified.forEach { manager.cancel(tagOf(it), NOTIFICATION_ID) }
        notified.clear()
    }

    private fun tag(transfer: FileTransfer) = tagOf(transfer.id)

    private fun tagOf(id: Long) = "file-$id"

    private fun peerName(peerId: PeerId): String =
        BleRuntime.store.peers().firstOrNull { it.peerId == peerId }?.name?.takeIf { it.isNotBlank() }
            ?: deviceIdOf(peerId)

    private fun peerIdOf(deviceId: String): PeerId? {
        val session = BleRuntime.engine.connectedSessions().firstOrNull { it.deviceId == deviceId }
        return session?.peerId ?: BleRuntime.store.peers().firstOrNull { it.deviceId == deviceId }?.peerId
    }

    private fun deviceIdOf(peerId: PeerId): String =
        BleRuntime.engine.connectedSessions().firstOrNull { it.peerId == peerId }?.deviceId
            ?: BleRuntime.store.peers().firstOrNull { it.peerId == peerId }?.deviceId
            ?: peerId.toString()
}
