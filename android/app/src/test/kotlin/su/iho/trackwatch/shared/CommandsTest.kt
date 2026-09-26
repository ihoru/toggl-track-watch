package su.iho.trackwatch.shared

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CommandsTest {
    private val done = TimeEntry("1", "done", 10L, 1_000, 2_000)
    private val running = TimeEntry("2", "running", null, 3_000, null)

    @Test
    fun startStopsRunningEntryAndAddsNewOne() {
        val cmds = CommandFactory.start(listOf(running, done), "new", 10L, 5_000)
        assertEquals(listOf(CommandType.STOP, CommandType.START), cmds.map { it.type })

        val view = Reducer.apply(listOf(running, done), cmds)
        assertEquals(3, view.size)
        val new = view.first()
        assertEquals("new", new.description)
        assertTrue(new.isRunning && new.pending)
        assertTrue(new.id.startsWith(LOCAL_ID_PREFIX))
        assertEquals(5_000L, view.first { it.id == "2" }.stop)
    }

    @Test
    fun updateAndDelete() {
        val update = CommandFactory.update("1", "renamed", null, 6_000)
        val view = Reducer.apply(listOf(done), listOf(update))
        assertEquals("renamed", view.single().description)
        assertNull(view.single().projectId)

        assertTrue(Reducer.apply(listOf(done), listOf(CommandFactory.delete("1", 7_000))).isEmpty())
    }

    @Test
    fun queueCoalescesLocalEntries() {
        val start = CommandFactory.start(emptyList(), "x", null, 1_000).single()
        var queue = QueueLogic.enqueue(emptyList(), start)
        queue = QueueLogic.enqueue(queue, CommandFactory.update(start.entryId, "y", 5L, 2_000))
        assertEquals(1, queue.size)
        assertEquals("y", queue.single().description)
        assertEquals(5L, queue.single().projectId)

        queue = QueueLogic.enqueue(queue, CommandFactory.stop(start.entryId, 3_000))
        assertEquals(2, queue.size)
        queue = QueueLogic.enqueue(queue, CommandFactory.delete(start.entryId, 4_000))
        assertTrue(queue.isEmpty())
    }

    @Test
    fun queueIgnoresDuplicates() {
        val stop = CommandFactory.stop("1", 1_000)
        assertEquals(1, QueueLogic.enqueue(QueueLogic.enqueue(emptyList(), stop), stop).size)
    }

    @Test
    fun viewStateRoundTrip() {
        val state = ViewState(
            configured = true,
            entries = listOf(done, running),
            projects = listOf(Project(10, "P", "#ff0000")),
            favorites = listOf(Favorite("fav", 10), Favorite("nofav", null)),
            acks = listOf("a"),
            pendingCount = 2,
            lastSync = 42,
            error = "boom",
        )
        assertEquals(state, ViewState.fromBytes(state.toBytes()))
    }
}
