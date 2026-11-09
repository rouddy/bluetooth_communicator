package com.rouddy.bluetooth_communicator.bluetooth_communicator

import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.FakeScheduler
import org.junit.Assert.assertEquals
import org.junit.Test

class GattOperationQueueTest {
    private val scheduler = FakeScheduler()
    private val events = mutableListOf<String>()
    private val queue = GattOperationQueue(scheduler, TIMEOUT_MS) { events += "timeout" }

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

    @Test
    fun anOperationWithoutACallbackTimesOutWithEverythingQueuedBehindIt() {
        queue.enqueue(operation("a"))
        queue.enqueue(operation("b"))

        scheduler.advance(TIMEOUT_MS - 1)
        assertEquals(listOf("start a"), events)

        scheduler.advance(1)
        assertEquals(
            listOf(
                "start a",
                "fail a: ${GattOperationQueue.TIMEOUT_ERROR}",
                "fail b: ${GattOperationQueue.TIMEOUT_ERROR}",
                "timeout"
            ),
            events
        )

        // A callback that comes after all is ignored.
        queue.complete(true)
        assertEquals(4, events.size)
    }

    @Test
    fun eachOperationGetsItsOwnTimeLimit() {
        queue.enqueue(operation("a"))
        queue.enqueue(operation("b"))

        scheduler.advance(TIMEOUT_MS - 1)
        queue.complete(true)
        // b started just now; a's timer must not fire for it.
        scheduler.advance(TIMEOUT_MS - 1)
        assertEquals(listOf("start a", "done a", "start b"), events)

        scheduler.advance(1)
        assertEquals(
            listOf("start a", "done a", "start b", "fail b: ${GattOperationQueue.TIMEOUT_ERROR}", "timeout"),
            events
        )
    }

    @Test
    fun finishedOrFailedOperationsDoNotTimeOut() {
        queue.enqueue(operation("a"))
        queue.complete(true)
        queue.enqueue(operation("refused", startResult = false))
        queue.enqueue(operation("dropped"))
        queue.failAll("Disconnected")

        scheduler.advance(TIMEOUT_MS * 2)

        assertEquals(
            listOf(
                "start a",
                "done a",
                "start refused",
                "fail refused: GATT operation could not be started",
                "start dropped",
                "fail dropped: Disconnected"
            ),
            events
        )
    }

    private companion object {
        const val TIMEOUT_MS = 10_000L
    }
}
