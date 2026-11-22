package com.rouddy.bluetooth_communicator.bluetooth_communicator

import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.AppIdentity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RegisteredAppsTest {
    private var saved: String? = null
    private var now = 1_000L

    private val chat = AppIdentity("com.example.chat", "a".repeat(64))
    private val model = AppIdentity("com.example.model", "b".repeat(64))

    private fun apps() = RegisteredApps(saved, save = { saved = it }, clock = { now })

    @Test
    fun `registered apps survive a restart in registration order`() {
        val apps = apps()
        assertTrue(apps.register(chat, "Chat"))
        now = 2_000
        assertTrue(apps.register(model, "Model"))

        val restored = apps().list()

        assertEquals(listOf("com.example.chat", "com.example.model"), restored.map { it.packageName })
        assertEquals(RegisteredApp("com.example.chat", chat.certHash, "Chat", 1_000, 1_000), restored[0])
        assertEquals(model, restored[1].identity)
    }

    @Test
    fun `registering again keeps the entry and only refreshes the label`() {
        val apps = apps()
        apps.register(chat, "Chat")
        now = 5_000

        assertFalse(apps.register(chat, "Chat"))
        assertTrue(apps.register(chat, "Chat 2"))

        assertEquals(RegisteredApp("com.example.chat", chat.certHash, "Chat 2", 1_000, 1_000), apps["com.example.chat"])
    }

    @Test
    fun `another certificate under the same name is a new registration`() {
        val apps = apps()
        apps.register(chat, "Chat")
        now = 9_000

        assertTrue(apps.register(chat.copy(certHash = "c".repeat(64)), "Impostor"))

        val entry = apps()["com.example.chat"]!!
        assertEquals("c".repeat(64), entry.certHash)
        assertEquals(9_000L, entry.registeredAt)
    }

    @Test
    fun `an uninstalled app leaves the list`() {
        val apps = apps()
        apps.register(chat, "Chat")
        apps.register(model, "Model")

        assertTrue(apps.remove("com.example.chat"))
        assertFalse(apps.remove("com.example.chat"))
        assertFalse(apps.remove("com.example.unknown"))

        assertEquals(listOf(model), apps().list().map { it.identity })
    }

    @Test
    fun `reconcile drops apps that are gone or were reinstalled with another certificate`() {
        val apps = apps()
        apps.register(chat, "Chat")
        apps.register(model, "Model")
        apps.register(AppIdentity("com.example.kept", "d".repeat(64)), "Kept")

        val installed = mapOf(
            "com.example.model" to model.copy(certHash = "e".repeat(64)),
            "com.example.kept" to AppIdentity("com.example.kept", "d".repeat(64))
        )
        val gone = apps.reconcile { installed[it] }

        assertEquals(listOf("com.example.chat", "com.example.model"), gone)
        assertEquals(listOf("com.example.kept"), apps().list().map { it.packageName })
        assertEquals(emptyList<String>(), apps.reconcile { installed[it] })
    }

    @Test
    fun `use is saved at most once a minute`() {
        val apps = apps()
        apps.register(chat, "Chat")
        val writes = saved

        now += 30_000
        assertFalse(apps.used("com.example.chat"))
        assertEquals(writes, saved)

        now += RegisteredApps.USE_SAVE_INTERVAL_MS
        assertTrue(apps.used("com.example.chat"))
        assertEquals(now, apps()["com.example.chat"]!!.lastUsedAt)
        assertFalse(apps.used("com.example.unknown"))
    }

    @Test
    fun `a corrupt or partial save is ignored`() {
        saved = "not json"
        assertEquals(emptyList<RegisteredApp>(), apps().list())

        saved = """[{"package":"com.example.chat"},{"package":"com.example.model","cert":"${model.certHash}"}]"""
        val restored = apps()
        assertNull(restored["com.example.chat"])
        assertEquals("com.example.model", restored["com.example.model"]!!.label)
    }
}
