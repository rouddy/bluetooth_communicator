package com.rouddy.bluetooth_communicator.bluetooth_communicator

import org.junit.Assert.assertEquals
import org.junit.Test

class PendingMessageStoreTest {
    private var stored: String? = null
    private fun store(capacity: Int = 500) =
        PendingMessageStore(load = { stored }, save = { stored = it }, capacity = capacity)

    @Test
    fun drainReturnsMessagesInOrderAndClearsTheStore() {
        val store = store()
        store.add(PendingMessage("AA:AA", "first", 1))
        store.add(PendingMessage("BB:BB", "second", 2))

        assertEquals(
            listOf(PendingMessage("AA:AA", "first", 1), PendingMessage("BB:BB", "second", 2)),
            store.drain()
        )
        assertEquals(emptyList<PendingMessage>(), store.drain())
    }

    @Test
    fun survivesAReloadAndKeepsArbitraryText() {
        // Separators, newlines, and Korean text must round-trip through storage.
        val text = "안녕: line1\nline2 : ::"
        store().add(PendingMessage("AA:BB:CC:DD:EE:FF", text, 1_700_000_000_000))

        // A new instance reading the same storage, e.g. after the process restarted.
        assertEquals(
            listOf(PendingMessage("AA:BB:CC:DD:EE:FF", text, 1_700_000_000_000)),
            store().drain()
        )
    }

    @Test
    fun keepsOnlyTheNewestMessagesBeyondCapacity() {
        val store = store(capacity = 2)
        (1..4).forEach { store.add(PendingMessage("AA:AA", "m$it", it.toLong())) }

        assertEquals(listOf("m3", "m4"), store.drain().map { it.message })
    }
}
