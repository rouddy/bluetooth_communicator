package com.rouddy.bluetooth_communicator.bluetooth_communicator

import org.junit.Assert.assertEquals
import org.junit.Test

class GattOperationQueueTest {
    private val queue = GattOperationQueue()
    private val events = mutableListOf<String>()

    private fun operation(name: String, startResult: Boolean = true) =
        GattOperationQueue.Operation(
            start = {
                events += "start $name"
                startResult
            },
            onComplete = { success, error ->
                events += if (success) "done $name" else "fail $name: $error"
            }
        )

    @Test
    fun startsOnlyOneOperationUntilTheCallbackCompletesIt() {
        queue.enqueue(operation("a"))
        queue.enqueue(operation("b"))
        queue.enqueue(operation("c"))
        assertEquals(listOf("start a"), events)

        queue.complete(true)
        assertEquals(listOf("start a", "done a", "start b"), events)

        queue.complete(false, "status 133")
        queue.complete(true)
        assertEquals(
            listOf("start a", "done a", "start b", "fail b: status 133", "start c", "done c"),
            events
        )
    }

    @Test
    fun anOperationTheStackRefusesFailsAndTheNextOneStarts() {
        queue.enqueue(operation("busy", startResult = false))
        queue.enqueue(operation("next"))

        assertEquals(
            listOf(
                "start busy",
                "fail busy: GATT operation could not be started",
                "start next"
            ),
            events
        )
    }

    @Test
    fun failAllFailsTheInFlightAndQueuedOperationsInOrder() {
        queue.enqueue(operation("a"))
        queue.enqueue(operation("b"))

        queue.failAll("Disconnected")
        // A late callback for the dropped operation is ignored.
        queue.complete(true)

        assertEquals(
            listOf("start a", "fail a: Disconnected", "fail b: Disconnected"),
            events
        )
    }

    @Test
    fun operationsEnqueuedFromACompletionCallbackRunAfterIt() {
        queue.enqueue(
            GattOperationQueue.Operation(
                start = { events += "start a"; true },
                onComplete = { _, _ ->
                    events += "done a"
                    queue.enqueue(operation("b"))
                }
            )
        )

        queue.complete(true)

        assertEquals(listOf("start a", "done a", "start b"), events)
    }
}
