package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.RemoteException
import android.util.Log
import androidx.core.content.ContextCompat
import com.rouddy.bluetooth_communicator.api.IBleCommunicator
import com.rouddy.bluetooth_communicator.api.IBleListener
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.AppIdentity
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Capabilities
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Crypto
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.DeliveryStatus
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Envelope
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.PeerId
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.toHex
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * The apps on this phone that use the AIDL service (docs/protocol.md 8절, 11절):
 * who can receive (a registered listener, or a declared RECEIVE service), what that
 * makes our CAPS, and handing them messages. State changes on the main looper; the
 * certificate lookups also run on binder threads.
 */
class AppRegistry(private val context: Context) : AppRouter {
    private val packageManager = context.packageManager
    private val handler = Handler(Looper.getMainLooper())

    private class Listener(val listener: IBleListener, val packages: Set<String>, val death: IBinder.DeathRecipient)

    private val listeners = LinkedHashMap<IBinder, Listener>()
    private val certHashes = ConcurrentHashMap<String, String>()
    private val queued = ConcurrentHashMap<String, AtomicInteger>()
    private val receivers = HashMap<String, ReceiverConnection>()

    @Volatile
    private var caps = Capabilities(emptyList(), emptyList())

    init {
        caps = computeCaps()
        // Installing, updating, or removing an app can change who receives, and with
        // which certificate.
        ContextCompat.registerReceiver(
            context,
            object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    intent.data?.schemeSpecificPart?.let(certHashes::remove)
                    refreshCaps()
                }
            },
            IntentFilter().apply {
                addAction(Intent.ACTION_PACKAGE_ADDED)
                addAction(Intent.ACTION_PACKAGE_REPLACED)
                addAction(Intent.ACTION_PACKAGE_REMOVED)
                addDataScheme("package")
            },
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
    }

    /** An app's identity, or null if it isn't installed (or isn't visible to us). */
    fun identity(packageName: String): AppIdentity? = certHash(packageName)?.let { AppIdentity(packageName, it) }

    /**
     * SHA-256 of the signing certificate; with several signers, of their sorted
     * hashes concatenated (11절).
     */
    fun certHash(packageName: String): String? {
        certHashes[packageName]?.let { return it }
        val signers = runCatching {
            packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                .signingInfo?.apkContentsSigners
        }.getOrNull()
        if (signers.isNullOrEmpty()) {
            return null
        }
        val hashes = signers.map { Crypto.sha256(it.toByteArray()) }.sortedBy { it.toHex() }
        val hash = (if (hashes.size == 1) hashes[0] else Crypto.sha256(*hashes.toTypedArray())).toHex()
        certHashes[packageName] = hash
        return hash
    }

    /** 9절: at most [MAX_QUEUED] messages per app wait at a time. */
    fun reserveSlot(packageName: String): Boolean {
        val count = queued.getOrPut(packageName) { AtomicInteger() }
        if (count.incrementAndGet() > MAX_QUEUED) {
            count.decrementAndGet()
            return false
        }
        return true
    }

    fun releaseSlot(packageName: String) {
        queued[packageName]?.decrementAndGet()
    }

    fun register(listener: IBleListener, packages: Set<String>) {
        val binder = listener.asBinder()
        unregister(binder)
        val death = IBinder.DeathRecipient { handler.post { unregister(binder) } }
        if (runCatching { binder.linkToDeath(death, 0) }.isFailure) {
            return
        }
        listeners[binder] = Listener(listener, packages, death)
        refreshCaps()
    }

    fun unregister(binder: IBinder) {
        val removed = listeners.remove(binder) ?: return
        runCatching { binder.unlinkToDeath(removed.death, 0) }
        refreshCaps()
    }

    override fun localCaps(): Capabilities = caps

    private fun refreshCaps() {
        val updated = computeCaps()
        if (updated != caps) {
            caps = updated
            BleRuntime.engine.capsChanged()
        }
    }

    private fun computeCaps(): Capabilities {
        val receiving = listeners.values.flatMap { it.packages }.toSet() + receiveServices().map { it.packageName }
        val apps = receiving.filter { it != context.packageName }.sorted().mapNotNull(::identity)
        return Capabilities(emptyList(), apps)
    }

    private fun receiveServices(packageName: String? = null): List<ComponentName> {
        val intent = Intent(IBleCommunicator.ACTION_RECEIVE)
        packageName?.let(intent::setPackage)
        return packageManager.queryIntentServices(intent, 0).mapNotNull { info ->
            info.serviceInfo?.let { ComponentName(it.packageName, it.name) }
        }
    }

    /**
     * 8절, receiving side: the sender's CAPS must declare the package, with the
     * certificate it has here; then a listener or the RECEIVE service gets it.
     */
    override fun deliver(peerId: PeerId, data: Envelope.Data, done: (Int) -> Unit) {
        val packageName = data.path.substringBefore('/')
        val declared = BleRuntime.engine.capsOf(peerId)?.apps?.firstOrNull { it.packageName == packageName }
        if (declared == null) {
            done(DeliveryStatus.DENIED)
            return
        }
        val local = certHash(packageName)
        if (local == null) {
            done(DeliveryStatus.NO_RECEIVER)
            return
        }
        if (local != declared.certHash) {
            done(DeliveryStatus.DENIED)
            return
        }
        val targets = listeners.values.filter { packageName in it.packages }
        var delivered = false
        targets.forEach { target ->
            try {
                target.listener.onMessage(peerId.toString(), data.path, data.payload, data.msgId, data.replyTo)
                delivered = true
            } catch (e: RemoteException) {
                unregister(target.listener.asBinder())
            }
        }
        if (delivered) {
            done(DeliveryStatus.OK)
            return
        }
        val component = receiveServices(packageName).firstOrNull()
        if (component == null) {
            done(DeliveryStatus.NO_RECEIVER)
            return
        }
        receivers.getOrPut(packageName) { ReceiverConnection(packageName, component) }
            .deliver(peerId, data, done)
    }

    override fun onPeersChanged() {
        listeners.values.toList().forEach { target ->
            try {
                target.listener.onPeersChanged()
            } catch (e: RemoteException) {
                unregister(target.listener.asBinder())
            }
        }
    }

    /**
     * A bound RECEIVE service (like Wear OS's WearableListenerService). The binding
     * starts the app if needed, and is kept for [IDLE_UNBIND_MS] after the last
     * message.
     */
    private inner class ReceiverConnection(
        private val packageName: String,
        private val component: ComponentName
    ) : ServiceConnection {
        private var remote: IBleListener? = null
        private var bound = false
        private val waiting = mutableListOf<(IBleListener?) -> Unit>()
        private val unbind = Runnable { close() }
        private val connectTimeout = Runnable {
            Log.w(TAG, "$component didn't connect")
            close()
        }

        fun deliver(peerId: PeerId, data: Envelope.Data, done: (Int) -> Unit) {
            val send = { target: IBleListener? ->
                val status = try {
                    target?.onMessage(peerId.toString(), data.path, data.payload, data.msgId, data.replyTo)
                    if (target == null) DeliveryStatus.NO_RECEIVER else DeliveryStatus.OK
                } catch (e: RemoteException) {
                    DeliveryStatus.NO_RECEIVER
                }
                done(status)
            }
            handler.removeCallbacks(unbind)
            handler.postDelayed(unbind, IDLE_UNBIND_MS)
            remote?.let {
                send(it)
                return
            }
            waiting += send
            if (!bound) {
                bound = runCatching {
                    context.bindService(Intent(IBleCommunicator.ACTION_RECEIVE).setComponent(component), this, Context.BIND_AUTO_CREATE)
                }.getOrDefault(false)
                if (!bound) {
                    close()
                    return
                }
                handler.postDelayed(connectTimeout, CONNECT_TIMEOUT_MS)
            }
        }

        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            handler.removeCallbacks(connectTimeout)
            val target = IBleListener.Stub.asInterface(service)
            remote = target
            val pending = waiting.toList()
            waiting.clear()
            pending.forEach { it(target) }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            remote = null
        }

        override fun onBindingDied(name: ComponentName) = close()

        override fun onNullBinding(name: ComponentName) = close()

        private fun close() {
            handler.removeCallbacks(unbind)
            handler.removeCallbacks(connectTimeout)
            if (bound) {
                runCatching { context.unbindService(this) }
            }
            bound = false
            remote = null
            receivers.remove(packageName)
            val pending = waiting.toList()
            waiting.clear()
            pending.forEach { it(null) }
        }
    }

    companion object {
        private const val TAG = "AppRegistry"
        const val MAX_QUEUED = 32
        private const val IDLE_UNBIND_MS = 10_000L
        private const val CONNECT_TIMEOUT_MS = 5_000L
    }
}
