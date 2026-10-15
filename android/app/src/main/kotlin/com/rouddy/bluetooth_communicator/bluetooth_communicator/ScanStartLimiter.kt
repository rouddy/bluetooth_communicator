package com.rouddy.bluetooth_communicator.bluetooth_communicator

/**
 * Keeps scan starts under Android's limit of [maxStarts] per app in any [windowMs].
 *
 * Above the limit Android refuses the registration and only logs "scanning too
 * frequently" (no onScanFailed), so the app would believe it's scanning. Instead of
 * starting, callers wait for [delayBeforeStart].
 */
class ScanStartLimiter(
    private val maxStarts: Int = 5,
    private val windowMs: Long = 30_000L,
    private val marginMs: Long = 1_000L
) {
    private val starts = ArrayDeque<Long>()

    /**
     * Returns 0 and records a start at [now] if a scan may start now; otherwise how long
     * to wait (nothing is recorded).
     */
    fun delayBeforeStart(now: Long): Long {
        while (starts.isNotEmpty() && now - starts.first() >= windowMs) {
            starts.removeFirst()
        }
        if (starts.size >= maxStarts) {
            return starts.first() + windowMs - now + marginMs
        }
        starts.addLast(now)
        return 0
    }
}
