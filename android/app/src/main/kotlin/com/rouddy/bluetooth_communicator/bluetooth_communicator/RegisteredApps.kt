package com.rouddy.bluetooth_communicator.bluetooth_communicator

import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.AppIdentity
import org.json.JSONArray
import org.json.JSONObject

/**
 * An app that uses the AIDL service (docs/protocol.md 11절): it registered a
 * listener, or it declares a RECEIVE service. [certHash] is the certificate it was
 * registered with; another app installed under the same name is a new registration.
 */
data class RegisteredApp(
    val packageName: String,
    val certHash: String,
    val label: String,
    val registeredAt: Long,
    val lastUsedAt: Long
) {
    val identity: AppIdentity
        get() = AppIdentity(packageName, certHash)
}

/**
 * The registered apps, kept across restarts as JSON ([save] persists it; Android
 * keeps it in the `ble_apps` prefs). An app leaves the list when it's uninstalled
 * ([remove], from the package broadcasts) or found missing at startup
 * ([reconcile]). Not thread-safe: [AppRegistry] uses it on the main looper, and
 * [PackageRemovedReceiver] only while the registry isn't running.
 */
class RegisteredApps(
    saved: String?,
    private val save: (String) -> Unit,
    private val clock: () -> Long
) {
    private val apps = LinkedHashMap<String, RegisteredApp>()

    init {
        runCatching { JSONArray(saved ?: "[]") }.getOrNull()?.let { array ->
            for (i in 0 until array.length()) {
                val json = array.optJSONObject(i) ?: continue
                val packageName = json.optString(KEY_PACKAGE)
                val certHash = json.optString(KEY_CERT)
                if (packageName.isEmpty() || certHash.isEmpty()) {
                    continue
                }
                apps[packageName] = RegisteredApp(
                    packageName = packageName,
                    certHash = certHash,
                    label = json.optString(KEY_LABEL).ifEmpty { packageName },
                    registeredAt = json.optLong(KEY_REGISTERED_AT),
                    lastUsedAt = json.optLong(KEY_LAST_USED_AT)
                )
            }
        }
    }

    /** In registration order. */
    fun list(): List<RegisteredApp> = apps.values.toList()

    operator fun get(packageName: String): RegisteredApp? = apps[packageName]

    /**
     * Registers [identity], or refreshes its label. A known package with another
     * certificate is another app under the same name: it replaces the old entry.
     * Returns whether the list changed.
     */
    fun register(identity: AppIdentity, label: String): Boolean {
        val known = apps[identity.packageName]
        val now = clock()
        val updated = when {
            known == null || known.certHash != identity.certHash ->
                RegisteredApp(identity.packageName, identity.certHash, label, now, now)
            known.label != label -> known.copy(label = label)
            else -> return false
        }
        apps[identity.packageName] = updated
        persist()
        return true
    }

    /**
     * Marks [packageName] used (it sent a message). Saved at most every
     * [USE_SAVE_INTERVAL_MS], so a chatty app doesn't rewrite the prefs each time.
     * Returns whether the list changed.
     */
    fun used(packageName: String): Boolean {
        val known = apps[packageName] ?: return false
        val now = clock()
        if (now - known.lastUsedAt < USE_SAVE_INTERVAL_MS) {
            return false
        }
        apps[packageName] = known.copy(lastUsedAt = now)
        persist()
        return true
    }

    /** The app was uninstalled. Returns whether it was registered. */
    fun remove(packageName: String): Boolean {
        if (apps.remove(packageName) == null) {
            return false
        }
        persist()
        return true
    }

    /**
     * Drops the apps that aren't installed anymore, or are installed with another
     * certificate (removed and reinstalled while nothing was listening). [installed]
     * is the identity installed now, or null. Returns the dropped packages.
     */
    fun reconcile(installed: (String) -> AppIdentity?): List<String> {
        val gone = apps.values.filter { installed(it.packageName) != it.identity }.map { it.packageName }
        if (gone.isNotEmpty()) {
            gone.forEach(apps::remove)
            persist()
        }
        return gone
    }

    private fun persist() {
        val array = JSONArray()
        apps.values.forEach { app ->
            array.put(
                JSONObject()
                    .put(KEY_PACKAGE, app.packageName)
                    .put(KEY_CERT, app.certHash)
                    .put(KEY_LABEL, app.label)
                    .put(KEY_REGISTERED_AT, app.registeredAt)
                    .put(KEY_LAST_USED_AT, app.lastUsedAt)
            )
        }
        save(array.toString())
    }

    companion object {
        const val PREFS_NAME = "ble_apps"
        const val PREF_APPS = "apps"
        const val USE_SAVE_INTERVAL_MS = 60_000L

        private const val KEY_PACKAGE = "package"
        private const val KEY_CERT = "cert"
        private const val KEY_LABEL = "label"
        private const val KEY_REGISTERED_AT = "registeredAt"
        private const val KEY_LAST_USED_AT = "lastUsedAt"
    }
}
