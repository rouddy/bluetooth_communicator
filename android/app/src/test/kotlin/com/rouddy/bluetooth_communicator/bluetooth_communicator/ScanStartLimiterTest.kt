package com.rouddy.bluetooth_communicator.bluetooth_communicator

import org.junit.Assert.assertEquals
import org.junit.Test

class ScanStartLimiterTest {
    private val limiter = ScanStartLimiter(maxStarts = 5, windowMs = 30_000, marginMs = 1_000)

    @Test
    fun allowsFiveStartsThenDefersTheSixthUntilTheOldestLeavesTheWindow() {
        (0..4).forEach { assertEquals(0L, limiter.delayBeforeStart(it * 1_000L)) }

        // Oldest start at 0 leaves the window at 30 000; plus the margin.
        assertEquals(26_000L, limiter.delayBeforeStart(5_000))
    }

    @Test
    fun aDeferredStartIsNotCountedAndTheRetryIsAllowed() {
        (0..4).forEach { limiter.delayBeforeStart(it * 100L) }
        limiter.delayBeforeStart(1_000)

        assertEquals(0L, limiter.delayBeforeStart(31_000))
    }

    @Test
    fun startsSpreadOverMoreThanTheWindowAreNeverDeferred() {
        (0 until 20).forEach { assertEquals(0L, limiter.delayBeforeStart(it * 7_000L)) }
    }
}
