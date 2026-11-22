package com.rouddy.bluetooth_communicator.bluetooth_communicator

import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Cancellable
import com.rouddy.bluetooth_communicator.bluetooth_communicator.protocol.Scheduler

/**
 * Runs the GATT operations of one link strictly one at a time.
 *
 * Android allows a single outstanding operation per connection (client
 * characteristic/descriptor writes, server notifications). Starting another one
 * before the previous operation's callback fails, which used to drop messages
 * silently. Each [Operation] is started only after the previous one was
 * [complete]d from its GATT callback.
 *
 * An operation whose callback hasn't come after [timeoutMs] fails, and so does
 * everything queued behind it: the stack still counts it as outstanding, so the
 * connection can't run another one. [onTimeout] then tells the owner to drop the
 * link. Without this, one lost callback stalled the link until it disconnected.
 */
class GattOperationQueue(
    private val scheduler: Scheduler,
    private val timeoutMs: Long = OPERATION_TIMEOUT_MS,
    private val onTimeout: () -> Unit
) {
    class Operation(
        /** Starts the operation; returns false if the stack refused it right away. */
        val start: () -> Boolean,
        /** Called exactly once with the outcome. */
        val onComplete: (success: Boolean, error: String?) -> Unit
    )

    private val pending = ArrayDeque<Operation>()
    private var inFlight: Operation? = null
    private var timer: Cancellable? = null

    @Synchronized
    fun enqueue(operation: Operation) {
        pending.addLast(operation)
        startNext()
    }

    /** Finishes the in-flight operation; call it from the operation's GATT callback. */
    @Synchronized
    fun complete(success: Boolean, error: String? = null) {
        val operation = inFlight ?: return
        inFlight = null
        cancelTimer()
        operation.onComplete(success, error)
        startNext()
    }

    /** Fails the in-flight and all queued operations, e.g. when the link goes away. */
    @Synchronized
    fun failAll(error: String) {
        val operations = listOfNotNull(inFlight) + pending
        inFlight = null
        cancelTimer()
        pending.clear()
        operations.forEach { it.onComplete(false, error) }
    }

    private fun startNext() {
        while (inFlight == null) {
            val operation = pending.removeFirstOrNull() ?: return
            inFlight = operation
            // Armed before start(), which may complete the operation synchronously.
            timer = scheduler.schedule(timeoutMs) { timedOut(operation) }
            val started = runCatching(operation.start).getOrDefault(false)
            if (!started && inFlight === operation) {
                inFlight = null
                cancelTimer()
                operation.onComplete(false, "GATT operation could not be started")
            }
        }
    }

    private fun timedOut(operation: Operation) {
        synchronized(this) {
            if (inFlight !== operation) {
                return
            }
            timer = null
            failAll(TIMEOUT_ERROR)
        }
        onTimeout()
    }

    private fun cancelTimer() {
        timer?.cancel()
        timer = null
    }

    companion object {
        /** A GATT operation normally completes within a few connection intervals. */
        const val OPERATION_TIMEOUT_MS = 10_000L
        const val TIMEOUT_ERROR = "GATT operation timed out"
    }
}
