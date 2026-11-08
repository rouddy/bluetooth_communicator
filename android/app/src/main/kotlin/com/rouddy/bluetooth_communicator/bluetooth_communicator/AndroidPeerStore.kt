package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.content.Context
import android.security.keystore.KeyProperties
import android.security.keystore.KeyProtection
import android.util.Base64
import android.util.Log
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.PeerId
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.PeerKey
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.PeerState
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.PeerStore
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.RawPeerKey
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.StoredPeer
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec

/**
 * This install's peerId, the msgId counter, and the app-paired peers, in their own
 * prefs file ([PREFS_NAME], excluded from backups: a restored copy would make two
 * phones with one peerId). Each K is imported into the Android Keystore as a
 * non-exportable HMAC key (6.6); without user-authentication requirements, so it
 * works in the background and while locked.
 */
class AndroidPeerStore(context: Context) : PeerStore {
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val keyStore: KeyStore? = runCatching {
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
    }.getOrNull()

    override val localPeerId: PeerId = prefs.getString(PREF_PEER_ID, null)?.let(PeerId::parse)
        ?: PeerId.random(SecureRandom()).also {
            prefs.edit().putString(PREF_PEER_ID, it.toString()).commit()
        }

    private val peers: MutableList<StoredPeer> = load()

    @Synchronized
    override fun nextMsgId(): Long {
        var next = prefs.getLong(PREF_MSG_ID, 0L) + 1
        if (next > 0xFFFF_FFFFL) {
            next = 1
        }
        prefs.edit().putLong(PREF_MSG_ID, next).apply()
        return next
    }

    @Synchronized
    override fun peers(): List<StoredPeer> = peers.toList()

    @Synchronized
    override fun key(peerId: PeerId): PeerKey? {
        val alias = alias(peerId)
        if (runCatching { keyStore?.containsAlias(alias) }.getOrNull() == true) {
            return KeystorePeerKey(alias)
        }
        return prefs.getString(fallbackKey(peerId), null)?.let { RawPeerKey(Base64.decode(it, Base64.NO_WRAP)) }
    }

    @Synchronized
    override fun savePaired(peer: StoredPeer, key: ByteArray) {
        // A reinstalled peer gets a new peerId under the same address; replace it.
        peers.filter { it.deviceId == peer.deviceId && it.peerId != peer.peerId }.forEach { removeLocked(it.peerId) }
        storeKey(peer.peerId, key)
        upsert(peer)
    }

    @Synchronized
    override fun update(peer: StoredPeer) = upsert(peer)

    @Synchronized
    override fun deleteKey(peerId: PeerId) {
        runCatching { keyStore?.deleteEntry(alias(peerId)) }
        prefs.edit().remove(fallbackKey(peerId)).apply()
    }

    @Synchronized
    override fun remove(peerId: PeerId) = removeLocked(peerId)

    private fun removeLocked(peerId: PeerId) {
        deleteKey(peerId)
        if (peers.removeAll { it.peerId == peerId }) {
            save()
        }
    }

    private fun storeKey(peerId: PeerId, key: ByteArray) {
        val imported = runCatching {
            keyStore!!.setEntry(
                alias(peerId),
                KeyStore.SecretKeyEntry(SecretKeySpec(key, KeyProperties.KEY_ALGORITHM_HMAC_SHA256)),
                KeyProtection.Builder(KeyProperties.PURPOSE_SIGN).build()
            )
        }
        if (imported.isSuccess) {
            prefs.edit().remove(fallbackKey(peerId)).apply()
            return
        }
        // 15절 lists Keystore HMAC import as unverified on some devices. Rather than
        // fail the pairing, keep K in app-private prefs and say so in the log.
        Log.w(TAG, "Keystore import failed; storing the key in app prefs", imported.exceptionOrNull())
        prefs.edit().putString(fallbackKey(peerId), Base64.encodeToString(key, Base64.NO_WRAP)).apply()
    }

    private fun upsert(peer: StoredPeer) {
        val index = peers.indexOfFirst { it.peerId == peer.peerId }
        if (index >= 0) {
            peers[index] = peer
        } else {
            peers += peer
        }
        save()
    }

    private fun load(): MutableList<StoredPeer> {
        val raw = prefs.getString(PREF_PEERS, null) ?: return mutableListOf()
        return runCatching {
            val array = JSONArray(raw)
            MutableList(array.length()) { index ->
                val item = array.getJSONObject(index)
                StoredPeer(
                    peerId = PeerId.parse(item.getString("peerId")),
                    name = item.optString("name"),
                    deviceId = item.getString("deviceId"),
                    platform = item.optInt("platform"),
                    state = runCatching { PeerState.valueOf(item.getString("state")) }.getOrDefault(PeerState.PAIRED)
                )
            }
        }.getOrElse { mutableListOf() }
    }

    private fun save() {
        val array = JSONArray()
        peers.forEach {
            array.put(
                JSONObject()
                    .put("peerId", it.peerId.toString())
                    .put("name", it.name)
                    .put("deviceId", it.deviceId)
                    .put("platform", it.platform)
                    .put("state", it.state.name)
            )
        }
        prefs.edit().putString(PREF_PEERS, array.toString()).apply()
    }

    private inner class KeystorePeerKey(private val alias: String) : PeerKey {
        override fun hmac(data: ByteArray): ByteArray {
            val mac = Mac.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256)
            mac.init(keyStore!!.getKey(alias, null) as SecretKey)
            return mac.doFinal(data)
        }
    }

    private fun alias(peerId: PeerId) = "rbc_peer_$peerId"

    private fun fallbackKey(peerId: PeerId) = "key_$peerId"

    companion object {
        const val PREFS_NAME = "ble_identity"
        private const val TAG = "AndroidPeerStore"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val PREF_PEER_ID = "peer_id"
        private const val PREF_MSG_ID = "msg_id"
        private const val PREF_PEERS = "peers"
    }
}
