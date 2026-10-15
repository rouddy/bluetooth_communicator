package com.rouddy.bluetooth_communicator.bluetooth_communicator

/**
 * Runs the GATT operations of one link strictly one at a time.
 *
 * Android allows a single outstanding operation per connection (client
 * characteristic/descriptor writes, server notifications). Starting another one
 * before the previous operation's callback fails, which used to drop messages
 * silently. Each [Operation] is started only after the previous one was
 * [complete]d from its GATT callback.
 */
class GattOperationQueue {
    class Operation(
        /** Starts the operation; returns false if the stack refused it right away. */
        val start: () -> Boolean,
        /** Called exactly once with the outcome. */
        val onComplete: (success: Boolean, error: String?) -> Unit
    )

    private val pending = ArrayDeque<Operation>()
    private var inFlight: Operation? = null

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
        operation.onComplete(success, error)
        startNext()
    }

    /** Fails the in-flight and all queued operations, e.g. when the link goes away. */
    @Synchronized
    fun failAll(error: String) {
        val operations = listOfNotNull(inFlight) + pending
        inFlight = null
        pending.clear()
        operations.forEach { it.onComplete(false, error) }
    }

    private fun startNext() {
        while (inFlight == null) {
            val operation = pending.removeFirstOrNull() ?: return
            inFlight = operation
            val started = runCatching(operation.start).getOrDefault(false)
            if (!started) {
                inFlight = null
                operation.onComplete(false, "GATT operation could not be started")
            }
        }
    }
}
