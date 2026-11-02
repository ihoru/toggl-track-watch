package su.iho.trackwatch.shared

import org.junit.Assert.assertEquals
import org.junit.Test

class DurationsTest {
    @Test
    fun formatsWholeMinutesAndHours() {
        assertEquals("0m", shortDuration(59_999))
        assertEquals("1m", shortDuration(60_000))
        assertEquals("15m", shortDuration(15 * 60_000L + 30_000))
        assertEquals("59m", shortDuration(59 * 60_000L))
        assertEquals("1h", shortDuration(60 * 60_000L))
        assertEquals("1h 5m", shortDuration(65 * 60_000L))
        assertEquals("26h 3m", shortDuration((26 * 60 + 3) * 60_000L))
    }

    @Test
    fun clockSkewShowsZero() {
        assertEquals("0m", shortDuration(-5_000))
    }
}
