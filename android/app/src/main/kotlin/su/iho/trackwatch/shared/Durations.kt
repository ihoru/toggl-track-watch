package su.iho.trackwatch.shared

/** Coarse elapsed time for the watch-face chip: "0m", "15m", "1h", "1h 5m". Whole minutes, rounded down. */
fun shortDuration(ms: Long): String {
    val minutes = (ms.coerceAtLeast(0) / 60_000)
    val h = minutes / 60
    val m = minutes % 60
    return when {
        h == 0L -> "${m}m"
        m == 0L -> "${h}h"
        else -> "${h}h ${m}m"
    }
}
