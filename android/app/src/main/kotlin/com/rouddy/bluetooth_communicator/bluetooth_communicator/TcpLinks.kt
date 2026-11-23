package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Crypto
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.DeliveryStatus
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Envelope
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.MalformedException
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.PeerId
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.ProtocolEngine
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Role
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.TcpMessage
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.TcpStream
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.SecureRandom
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * `/tcp` (docs/protocol.md 10절): moves a session's frames from GATT to a TCP
 * connection while both phones are on Wi-Fi.
 *
 * Each side tells the other whether it's on Wi-Fi, at the session start and on every
 * change. The central, once both are, listens on a random port of its Wi-Fi address
 * and sends OFFER with a one-time token; the peripheral connects through its Wi-Fi
 * network and opens the stream with the token. Then the engine sends every new record
 * over TCP ([ProtocolEngine.tcpUp]) until the connection breaks, either phone leaves
 * Wi-Fi, or the session ends; the records go over Bluetooth again after that.
 *
 * Everything but the socket I/O runs on the main looper with the engine.
 */
object TcpLinks {
    private const val TAG = "TcpLinks"
    private const val CONNECT_TIMEOUT_MS = 3_000
    private const val ACCEPT_TIMEOUT_MS = 10_000
    private const val OPENING_TIMEOUT_MS = 3_000

    /** An idle side sends a keepalive this often; nothing heard for [READ_TIMEOUT_MS] ends the connection. */
    private const val KEEPALIVE_MS = 2_000L
    private const val READ_TIMEOUT_MS = 6_000
    private const val BUFFER_SIZE = 64 * 1024

    /** The central tries again after these; then it waits for a Wi-Fi change on either side. */
    private val RETRY_DELAYS_MS = longArrayOf(2_000, 10_000, 30_000, 60_000, 120_000, 300_000)

    /** A WIFI that wasn't delivered goes again after this. */
    private const val WIFI_RESEND_MS = 5_000L

    private val handler = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool { Thread(it, TAG).apply { isDaemon = true } }
    private val random = SecureRandom()
    private lateinit var engine: ProtocolEngine

    /** The Wi-Fi networks we're on, with their IPv4 address, and the one we use. */
    private val wifiNetworks = LinkedHashMap<Network, Inet4Address>()
    private var wifi: Pair<Network, Inet4Address>? = null

    /** The central listening for the peripheral of one OFFER. */
    private class Offer(val token: ByteArray) {
        var msgId = 0L

        @Volatile
        var server: ServerSocket? = null

        @Volatile
        var cancelled = false

        fun cancel() {
            cancelled = true
            runCatching { server?.close() }
        }
    }

    /** The peripheral connecting for one OFFER. */
    private class Attempt {
        @Volatile
        var socket: Socket? = null

        @Volatile
        var cancelled = false

        fun cancel() {
            cancelled = true
            runCatching { socket?.close() }
        }
    }

    /** The `/tcp` state of one session; a new session (even on the same link) gets a new one. */
    private class Session(val peerId: PeerId, val linkId: Int, val role: Role, val deviceId: String) {
        /** The peer's CAPS leave `/tcp` out (an iPhone, or an older app). */
        var unsupported = false
        var sentWifi: Boolean? = null
        var peerWifi = false
        var offer: Offer? = null
        var attempt: Attempt? = null
        var connection: Connection? = null
        var failures = 0
        var retry: Runnable? = null
    }

    private val sessions = HashMap<PeerId, Session>()

    /** The open connections by link, for the engine's frames. */
    private val connections = HashMap<Int, Connection>()

    fun init(context: Context, engine: ProtocolEngine) {
        this.engine = engine
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            // A Wi-Fi without internet access still connects the two phones.
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        runCatching {
            context.getSystemService(ConnectivityManager::class.java).registerNetworkCallback(
                request,
                object : ConnectivityManager.NetworkCallback() {
                    override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                        val address = properties.linkAddresses.map { it.address }
                            .filterIsInstance<Inet4Address>()
                            .firstOrNull { !it.isLinkLocalAddress && !it.isLoopbackAddress }
                        if (address == null) {
                            wifiNetworks.remove(network)
                        } else {
                            wifiNetworks[network] = address
                        }
                        wifiChanged()
                    }

                    override fun onLost(network: Network) {
                        wifiNetworks.remove(network)
                        wifiChanged()
                    }
                },
                handler
            )
        }.onFailure { Log.w(TAG, "Can't watch Wi-Fi; staying on Bluetooth", it) }
    }

    // ------------------------------------------------------------ engine host

    fun writeFrame(linkId: Int, frame: ByteArray) {
        val connection = connections[linkId]
        if (connection == null) {
            // Can't happen (tcpDown comes with every removal), but never strand the record.
            handler.post { engine.tcpDown(linkId) }
        } else {
            connection.write(frame)
        }
    }

    /** The engine ended the session that had this connection. */
    fun closeTcp(linkId: Int) {
        val connection = connections.remove(linkId) ?: return
        connection.close()
        sessions.values.filter { it.connection === connection }.forEach { it.connection = null }
        Log.i(TAG, "Closed TCP on link $linkId: the session ended (${connection.stats()})")
    }

    // ------------------------------------------------------------ sessions

    /** A session started (EngineEvent.Connected, called from inside the engine). */
    fun onSessionStarted(peerId: PeerId) {
        val info = engine.session(peerId) ?: return
        sessions.remove(peerId)?.let(::end)
        val session = Session(peerId, info.linkId, info.role, info.deviceId)
        sessions[peerId] = session
        // Out of the engine's call; the WIFI waits for the peer's CAPS anyway.
        handler.post { sendWifi(session) }
    }

    /** Some session may have ended (EngineEvent.Disconnected); forget those that did. */
    fun onSessionsChanged() {
        sessions.values.filter { !isLive(it) }.forEach {
            sessions.remove(it.peerId)
            end(it)
        }
    }

    private fun isLive(session: Session) = engine.session(session.peerId)?.linkId == session.linkId

    private fun isCurrent(session: Session) = sessions[session.peerId] === session && isLive(session)

    private fun end(session: Session) {
        cancelRetry(session)
        session.offer?.cancel()
        session.offer = null
        session.attempt?.cancel()
        session.attempt = null
        session.connection?.let {
            // The engine already closed TCP for that session (closeTcp).
            connections.remove(it.linkId, it)
            it.close()
        }
        session.connection = null
    }

    // ------------------------------------------------------------ Wi-Fi

    private fun wifiChanged() {
        val current = wifiNetworks.entries.firstOrNull()?.let { it.key to it.value }
        if (current == wifi) {
            return
        }
        val previous = wifi
        wifi = current
        Log.i(TAG, "Wi-Fi: ${current?.second?.hostAddress ?: "off"} (was ${previous?.second?.hostAddress ?: "off"})")
        sessions.values.toList().forEach { session ->
            // Connections and offers were on the old address.
            stopTcp(session, "Wi-Fi changed")
            session.failures = 0
            cancelRetry(session)
            // Said again even if still on: a new address means the peer should drop its end.
            session.sentWifi = null
            sendWifi(session)
            maybeOffer(session)
        }
    }

    private fun sendWifi(session: Session) {
        val on = wifi != null
        if (session.unsupported || session.sentWifi == on || !isCurrent(session)) {
            return
        }
        session.sentWifi = on
        val sentAt = SystemClock.elapsedRealtime()
        engine.send(session.peerId, TcpMessage.PATH, TcpMessage.wifi(on), 0, 0, null) { status ->
            Log.d(TAG, "WIFI ${if (on) "on" else "off"} to ${session.deviceId}: status $status after ${SystemClock.elapsedRealtime() - sentAt} ms")
            when (status) {
                DeliveryStatus.OK -> Unit
                DeliveryStatus.NO_RECEIVER, DeliveryStatus.UNSUPPORTED -> {
                    session.unsupported = true
                    Log.i(TAG, "${session.deviceId} doesn't do /tcp; staying on Bluetooth")
                }
                else -> if (session.sentWifi == on) {
                    session.sentWifi = null
                    handler.postDelayed({ sendWifi(session) }, WIFI_RESEND_MS)
                }
            }
        }
    }

    // ------------------------------------------------------------ messages

    fun onRequest(peerId: PeerId, data: Envelope.Data, done: (Int) -> Unit) {
        val request = try {
            TcpMessage.decodeRequest(data.payload)
        } catch (e: MalformedException) {
            done(DeliveryStatus.MALFORMED)
            return
        }
        if (request == null) {
            done(DeliveryStatus.UNSUPPORTED)
            return
        }
        val session = sessions[peerId]?.takeIf(::isCurrent)
        if (session == null) {
            done(DeliveryStatus.OK)
            return
        }
        when (request) {
            is TcpMessage.Request.Wifi -> {
                Log.i(TAG, "${session.deviceId} says Wi-Fi ${if (request.on) "on" else "off"}")
                session.peerWifi = request.on
                // Off: its end is gone. On again: it may have moved to another address.
                // Before the ACK, so that goes over Bluetooth already.
                stopTcp(session, "the peer's Wi-Fi changed")
                session.failures = 0
                cancelRetry(session)
                done(DeliveryStatus.OK)
                maybeOffer(session)
            }
            is TcpMessage.Request.Offer -> {
                done(DeliveryStatus.OK)
                onOffer(session, data.msgId, request)
            }
        }
    }

    fun onReply(peerId: PeerId, data: Envelope.Data) {
        val session = sessions[peerId] ?: return
        val offer = session.offer?.takeIf { it.msgId == data.replyTo } ?: return
        val result = TcpMessage.decodeReply(data.payload)
        if (result == TcpMessage.RESULT_NO_WIFI) {
            session.peerWifi = false
        }
        offerFailed(session, offer, "the peer couldn't connect (result $result)")
    }

    // ------------------------------------------------------------ central

    private fun maybeOffer(session: Session) {
        val address = wifi?.second ?: return
        if (session.role != Role.CENTRAL || session.unsupported || !session.peerWifi) {
            return
        }
        if (session.connection != null || session.offer != null || session.retry != null || !isCurrent(session)) {
            return
        }
        val offer = Offer(ByteArray(TcpMessage.TOKEN_SIZE).also(random::nextBytes))
        session.offer = offer
        io.execute { listen(session, offer, address) }
    }

    /** Listens on a random port until the peripheral with the token connects (I/O thread). */
    private fun listen(session: Session, offer: Offer, address: Inet4Address) {
        val server = try {
            ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(address, 0), 4)
            }
        } catch (e: IOException) {
            handler.post { offerFailed(session, offer, "listen: ${e.message}") }
            return
        }
        offer.server = server
        if (offer.cancelled) {
            runCatching { server.close() }
            return
        }
        handler.post { sendOffer(session, offer, address, server.localPort) }
        val deadline = SystemClock.elapsedRealtime() + ACCEPT_TIMEOUT_MS
        try {
            while (true) {
                val left = deadline - SystemClock.elapsedRealtime()
                if (left <= 0) {
                    throw SocketTimeoutException("nobody connected")
                }
                server.soTimeout = left.toInt()
                val socket = server.accept()
                if (opened(socket, offer.token)) {
                    runCatching { server.close() }
                    handler.post { connected(session, offer, socket) }
                    return
                }
                runCatching { socket.close() }
            }
        } catch (e: IOException) {
            runCatching { server.close() }
            if (!offer.cancelled) {
                handler.post { offerFailed(session, offer, "accept: ${e.message}") }
            }
        }
    }

    /** Reads a connection's opening and accepts it if it has the token (I/O thread). */
    private fun opened(socket: Socket, token: ByteArray): Boolean = try {
        socket.soTimeout = OPENING_TIMEOUT_MS
        socket.tcpNoDelay = true
        val opening = ByteArray(TcpStream.OPENING_SIZE)
        DataInputStream(socket.getInputStream()).readFully(opening)
        val received = TcpStream.tokenOf(opening)
        if (received != null && Crypto.constantTimeEquals(received, token)) {
            socket.getOutputStream().apply {
                write(TcpStream.ACCEPTED)
                flush()
            }
            true
        } else {
            Log.w(TAG, "Refused a connection from ${socket.inetAddress?.hostAddress}: wrong opening")
            false
        }
    } catch (e: IOException) {
        Log.w(TAG, "A connection from ${socket.inetAddress?.hostAddress} didn't open: ${e.message}")
        false
    }

    private fun sendOffer(session: Session, offer: Offer, address: Inet4Address, port: Int) {
        if (session.offer !== offer || !isCurrent(session)) {
            offer.cancel()
            return
        }
        Log.i(TAG, "Offering TCP to ${session.deviceId} at ${address.hostAddress}:$port")
        val payload = TcpMessage.offer(port, offer.token, listOf(address.address))
        val sentAt = SystemClock.elapsedRealtime()
        offer.msgId = engine.send(session.peerId, TcpMessage.PATH, payload, 0, 0, null) { status ->
            Log.d(TAG, "OFFER to ${session.deviceId}: status $status after ${SystemClock.elapsedRealtime() - sentAt} ms")
            if (status != DeliveryStatus.OK) {
                handler.post { offerFailed(session, offer, "OFFER not delivered (status $status)") }
            }
        }
    }

    private fun offerFailed(session: Session, offer: Offer, reason: String) {
        if (session.offer !== offer) {
            return
        }
        session.offer = null
        offer.cancel()
        Log.i(TAG, "TCP offer to ${session.deviceId} failed: $reason")
        scheduleRetry(session)
    }

    private fun scheduleRetry(session: Session) {
        if (session.role != Role.CENTRAL || session.retry != null || !isCurrent(session)) {
            return
        }
        if (session.failures >= RETRY_DELAYS_MS.size) {
            Log.i(TAG, "No more TCP offers to ${session.deviceId} until a Wi-Fi change")
            return
        }
        val retry = Runnable {
            session.retry = null
            maybeOffer(session)
        }
        session.retry = retry
        handler.postDelayed(retry, RETRY_DELAYS_MS[session.failures++])
    }

    private fun cancelRetry(session: Session) {
        session.retry?.let(handler::removeCallbacks)
        session.retry = null
    }

    // ------------------------------------------------------------ peripheral

    private fun onOffer(session: Session, msgId: Long, offer: TcpMessage.Request.Offer) {
        if (session.role != Role.PERIPHERAL) {
            return
        }
        val network = wifi?.first
        if (network == null) {
            reply(session, msgId, TcpMessage.RESULT_NO_WIFI)
            return
        }
        // The central gave up on whatever we had.
        stopTcp(session, "a new offer")
        val attempt = Attempt()
        session.attempt = attempt
        Log.i(TAG, "Connecting to ${session.deviceId} at port ${offer.port}")
        io.execute { connect(session, attempt, network, msgId, offer) }
    }

    /** Connects through the Wi-Fi network (not the default one, which may be mobile data) (I/O thread). */
    private fun connect(session: Session, attempt: Attempt, network: Network, msgId: Long, offer: TcpMessage.Request.Offer) {
        for (bytes in offer.addresses) {
            if (attempt.cancelled) {
                return
            }
            val target = InetSocketAddress(InetAddress.getByAddress(bytes), offer.port)
            val socket = try {
                network.socketFactory.createSocket()
            } catch (e: IOException) {
                Log.w(TAG, "No socket on the Wi-Fi network: ${e.message}")
                break
            }
            attempt.socket = socket
            try {
                socket.tcpNoDelay = true
                socket.connect(target, CONNECT_TIMEOUT_MS)
                socket.soTimeout = OPENING_TIMEOUT_MS
                socket.getOutputStream().apply {
                    write(TcpStream.opening(offer.token))
                    flush()
                }
                if (socket.getInputStream().read() == TcpStream.ACCEPTED) {
                    handler.post { connected(session, attempt, socket) }
                    return
                }
                Log.w(TAG, "$target didn't accept the opening")
            } catch (e: IOException) {
                Log.w(TAG, "Couldn't connect to $target: ${e.message}")
            }
            runCatching { socket.close() }
        }
        handler.post {
            if (session.attempt === attempt) {
                session.attempt = null
                if (isCurrent(session)) {
                    reply(session, msgId, TcpMessage.RESULT_FAILED)
                }
            }
        }
    }

    private fun reply(session: Session, msgId: Long, result: Int) {
        engine.send(session.peerId, TcpMessage.PATH, TcpMessage.reply(result), msgId, 0, null) {}
    }

    // ------------------------------------------------------------ both

    /** The stream is open; [owner] is the Offer or Attempt it belongs to. */
    private fun connected(session: Session, owner: Any, socket: Socket) {
        val stillWanted = (owner is Offer && session.offer === owner) || (owner is Attempt && session.attempt === owner)
        if (!stillWanted || !isCurrent(session)) {
            runCatching { socket.close() }
            return
        }
        session.offer = null
        session.attempt = null
        val connection = Connection(session.linkId, session.peerId, socket)
        // Registered first: tcpUp sends queued records right away.
        connections[session.linkId] = connection
        if (!engine.tcpUp(session.linkId)) {
            connections.remove(session.linkId)
            connection.close()
            return
        }
        session.connection = connection
        session.failures = 0
        Log.i(TAG, "TCP to ${session.deviceId} is up: ${socket.localSocketAddress} - ${socket.remoteSocketAddress}")
        connection.start()
    }

    /** Ends TCP for [session] from our side; its records go over Bluetooth again. */
    private fun stopTcp(session: Session, reason: String) {
        session.offer?.cancel()
        session.offer = null
        session.attempt?.cancel()
        session.attempt = null
        val connection = session.connection ?: return
        session.connection = null
        connections.remove(connection.linkId, connection)
        connection.close()
        Log.i(TAG, "Closed TCP to ${session.deviceId}: $reason (${connection.stats()})")
        engine.tcpDown(connection.linkId)
    }

    private fun onConnectionLost(connection: Connection, reason: String) {
        if (connections[connection.linkId] !== connection) {
            return
        }
        connections.remove(connection.linkId)
        val session = sessions[connection.peerId]?.takeIf { it.connection === connection }
        Log.i(TAG, "TCP to ${session?.deviceId ?: connection.linkId} broke: $reason (${connection.stats()})")
        engine.tcpDown(connection.linkId)
        session ?: return
        session.connection = null
        scheduleRetry(session)
    }

    /** One TCP connection: a reader and a writer thread. */
    private class Connection(val linkId: Int, val peerId: PeerId, private val socket: Socket) {
        private val queue = LinkedBlockingQueue<ByteArray>()
        private val openedAt = SystemClock.elapsedRealtime()

        @Volatile
        private var closed = false

        @Volatile
        private var bytesIn = 0L

        @Volatile
        private var bytesOut = 0L

        fun start() {
            socket.soTimeout = READ_TIMEOUT_MS
            io.execute(::readLoop)
            io.execute(::writeLoop)
        }

        /** Queues one frame; the engine hears when it's written (one at a time). */
        fun write(frame: ByteArray) {
            if (closed) {
                // The engine hears tcpDown for this connection anyway.
                return
            }
            queue.offer(frame)
        }

        fun close() {
            closed = true
            queue.clear()
            queue.offer(STOP)
            runCatching { socket.close() }
        }

        fun stats(): String {
            val seconds = (SystemClock.elapsedRealtime() - openedAt) / 1000.0
            return "%.1f s, %d bytes in, %d out".format(seconds, bytesIn, bytesOut)
        }

        private fun readLoop() {
            try {
                val input = DataInputStream(BufferedInputStream(socket.getInputStream(), BUFFER_SIZE))
                val prefix = ByteArray(4)
                while (!closed) {
                    input.readFully(prefix)
                    val length = TcpStream.lengthOf(prefix) ?: throw IOException("frame too long")
                    if (length == 0) {
                        continue
                    }
                    val frame = ByteArray(length)
                    input.readFully(frame)
                    bytesIn += length
                    handler.post {
                        if (connections[linkId] === this) {
                            engine.tcpFrameReceived(linkId, frame)
                        }
                    }
                }
            } catch (e: Exception) {
                fail(if (e is java.io.EOFException) "closed by the peer" else "read: ${e.message}")
            }
        }

        private fun writeLoop() {
            try {
                val output = BufferedOutputStream(socket.getOutputStream(), BUFFER_SIZE)
                while (!closed) {
                    val frame = queue.poll(KEEPALIVE_MS, TimeUnit.MILLISECONDS)
                    if (frame === STOP) {
                        break
                    }
                    if (frame == null) {
                        output.write(TcpStream.lengthPrefix(0))
                        output.flush()
                        continue
                    }
                    output.write(TcpStream.lengthPrefix(frame.size))
                    output.write(frame)
                    output.flush()
                    bytesOut += frame.size
                    handler.post {
                        if (connections[linkId] === this) {
                            engine.tcpFrameWritten(linkId, true)
                        }
                    }
                }
            } catch (e: Exception) {
                fail("write: ${e.message}")
            }
        }

        private fun fail(reason: String) {
            if (closed) {
                return
            }
            close()
            handler.post { onConnectionLost(this, reason) }
        }

        companion object {
            private val STOP = ByteArray(0)
        }
    }
}
