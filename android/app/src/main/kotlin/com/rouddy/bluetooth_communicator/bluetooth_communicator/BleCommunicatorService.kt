package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.Manifest
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Binder
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat
import com.rouddy.bluetooth_communicator.api.IBleCommunicator
import com.rouddy.bluetooth_communicator.api.IBleListener
import com.rouddy.bluetooth_communicator.api.IBleSendCallback
import com.rouddy.bluetooth_communicator.api.PeerInfo
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.AppIdentity
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.DeliveryStatus
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.PeerId
import java.util.concurrent.atomic.AtomicLong

/**
 * The exported AIDL service (docs/protocol.md 11절). Open to any app without a
 * permission; callers are identified by their uid's packages and signing
 * certificates, and can only talk to the same app on the peer. Requests run on the
 * main looper with the engine.
 */
class BleCommunicatorService : Service() {
    private val requestIds = AtomicLong()

    private val registry: AppRegistry
        get() = BleRuntime.registry

    private val binder = object : IBleCommunicator.Stub() {
        override fun getApiVersion() = IBleCommunicator.API_VERSION

        override fun getPeers(): List<PeerInfo> {
            val identities = callerIdentities()
            return BleRuntime.peerSnapshot
                .filter { summary -> summary.caps?.apps?.any { it in identities } == true }
                .map { summary ->
                    PeerInfo().apply {
                        peerId = summary.peer.peerId.toString()
                        name = summary.peer.name
                        connected = summary.connected
                    }
                }
        }

        override fun send(
            peerId: String?,
            path: String?,
            data: ByteArray?,
            replyTo: Long,
            ttlMillis: Long,
            callback: IBleSendCallback?
        ): Long {
            val requestId = requestIds.incrementAndGet()
            val report = { status: Int ->
                try {
                    callback?.onResult(requestId, status)
                } catch (e: Exception) {
                    Log.w(TAG, "Couldn't report request $requestId", e)
                }
            }
            val packageName = path?.substringBefore('/')
            // 8절: an app sends only under its own package name, so it can't reach
            // another app or the built-in paths (`/...`).
            if (path == null || path.startsWith("/") || packageName !in callerPackages()) {
                report(DeliveryStatus.DENIED)
                return requestId
            }
            val identity = registry.identity(packageName!!)
            val peer = peerId?.let { runCatching { PeerId.parse(it) }.getOrNull() }
            if (identity == null || peer == null || data == null || replyTo !in 0L..0xFFFF_FFFFL) {
                report(if (identity == null) DeliveryStatus.DENIED else DeliveryStatus.MALFORMED)
                return requestId
            }
            if (!registry.reserveSlot(packageName)) {
                report(DeliveryStatus.BUSY)
                return requestId
            }
            BleRuntime.post {
                BleRuntime.engine.send(peer, path, data, replyTo, ttlMillis, identity) { status ->
                    registry.releaseSlot(packageName)
                    report(status)
                }
            }
            return requestId
        }

        override fun registerListener(listener: IBleListener?) {
            listener ?: return
            val packages = callerPackages()
            BleRuntime.post { registry.register(listener, packages) }
        }

        override fun unregisterListener(listener: IBleListener?) {
            listener ?: return
            BleRuntime.post { registry.unregister(listener.asBinder()) }
        }
    }

    /** Valid only on the binder thread of the incoming call. */
    private fun callerPackages(): Set<String> =
        packageManager.getPackagesForUid(Binder.getCallingUid())?.toSet() ?: emptySet()

    private fun callerIdentities(): Set<AppIdentity> = callerPackages().mapNotNull(registry::identity).toSet()

    override fun onCreate() {
        super.onCreate()
        BleRuntime.init(this)
        ensureBluetoothService()
    }

    override fun onBind(intent: Intent?): IBinder = binder

    // Messages wait (up to their TTL) for the BLE service; start it if the user's
    // settings haven't already. Android may refuse while our app is in the
    // background; the boot receiver and the app itself start it too.
    private fun ensureBluetoothService() {
        if (BleRuntime.transport != null) {
            return
        }
        val granted = listOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE
        ).all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }
        if (!granted) {
            return
        }
        runCatching {
            startForegroundService(
                Intent(this, BluetoothBackgroundService::class.java)
                    .setAction(BluetoothBackgroundService.ACTION_RESTORE)
            )
        }.onFailure { Log.w(TAG, "Couldn't start the Bluetooth service", it) }
    }

    private companion object {
        const val TAG = "BleCommunicatorService"
    }
}
