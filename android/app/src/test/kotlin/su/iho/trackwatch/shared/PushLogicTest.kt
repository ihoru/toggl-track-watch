package su.iho.trackwatch.shared

import org.junit.Assert.assertEquals
import org.junit.Test

class PushLogicTest {
    private val wid = 42L
    private val running = TimeEntry("1", "Writing", 5L, 10_000, null)
    private val snapshot = listOf(running, TimeEntry("2", "Reading", null, 1_000, 2_000))

    private fun decide(action: String, entry: TimeEntry?, workspace: Long? = wid, pending: Set<String> = emptySet()) =
        PushLogic.decide(action, entry, workspace, wid, snapshot, pending, historyStart = 500)

    @Test
    fun stopFromElsewhereRefreshes() {
        assertEquals(PushAction.REFRESH, decide("updated", running.copy(stop = 20_000)))
    }

    @Test
    fun ownChangeComingBackIsIgnored() {
        assertEquals(PushAction.IGNORE, decide("updated", running))
        assertEquals(PushAction.IGNORE, decide("updated", running.copy(stop = 20_000), pending = setOf("1")))
    }

    @Test
    fun newEntryRefreshes() {
        assertEquals(PushAction.REFRESH, decide("created", TimeEntry("3", "", null, 30_000, null)))
    }

    @Test
    fun deleteRemovesKnownEntriesWithoutAnApiCall() {
        assertEquals(PushAction.REMOVE, decide("deleted", snapshot[1]))
        assertEquals(PushAction.IGNORE, decide("deleted", TimeEntry("9", "", null, 1_000, 2_000)))
    }

    @Test
    fun otherWorkspacesAndOldEntriesAreIgnored() {
        assertEquals(PushAction.IGNORE, decide("updated", running.copy(stop = 20_000), workspace = 7))
        assertEquals(PushAction.IGNORE, decide("updated", TimeEntry("8", "old", null, 100, 200)))
        // A running entry is shown however old its start.
        assertEquals(PushAction.REFRESH, decide("updated", TimeEntry("8", "old", null, 100, null)))
    }

    @Test
    fun unreadableEventRefreshes() {
        assertEquals(PushAction.REFRESH, decide("updated", null))
    }
}
