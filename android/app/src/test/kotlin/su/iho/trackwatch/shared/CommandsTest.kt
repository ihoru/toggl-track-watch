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
    fun setStartMovesStartAndNeverIntoTheFuture() {
        val cmd = CommandFactory.setStart("2", 2_000, 5_000)
        assertEquals(2_000L, Reducer.apply(listOf(running), listOf(cmd)).single().start)
        assertTrue(Reducer.apply(listOf(running), listOf(cmd)).single().pending)
        assertEquals(5_000L, CommandFactory.setStart("2", 9_000, 5_000).start)
        assertEquals(cmd, Command.fromJson(cmd.toJson()))
    }

    @Test
    fun setStartOnQueuedLocalEntryChangesItsStart() {
        val start = CommandFactory.start(emptyList(), "x", null, 10_000).single()
        val queue = QueueLogic.enqueue(listOf(start), CommandFactory.setStart(start.entryId, 4_000, 11_000))
        assertEquals(1, queue.size)
        assertEquals(4_000L, queue.single().at)
    }

    @Test
    fun setStopMovesEndOfStoppedEntryWithinStartAndNow() {
        val cmd = CommandFactory.setStop("1", 1_000, 1_500, 5_000)
        assertEquals(CommandType.SET_START, cmd.type)
        val moved = Reducer.apply(listOf(done), listOf(cmd)).single()
        assertEquals(1_000L, moved.start)
        assertEquals(1_500L, moved.stop)
        assertTrue(moved.pending)
        assertEquals(5_000L, CommandFactory.setStop("1", 1_000, 9_000, 5_000).stop)
        // Never before the start, and a running entry keeps running.
        assertEquals(1_000L, Reducer.apply(listOf(done), listOf(CommandFactory.setStop("1", 1_000, 500, 5_000))).single().stop)
        assertNull(Reducer.apply(listOf(running), listOf(CommandFactory.setStop("2", 3_000, 4_000, 5_000))).single().stop)
        assertEquals(cmd, Command.fromJson(cmd.toJson()))
    }

    @Test
    fun timeEditsOnStoppedLocalEntryRunAfterTheStop() {
        val start = CommandFactory.start(emptyList(), "x", null, 10_000).single()
        val stop = CommandFactory.stop(start.entryId, 20_000)
        val queue = listOf(start, stop)
        val setStart = CommandFactory.setStart(start.entryId, 20_000, 30_000)
        assertEquals(queue + setStart, QueueLogic.enqueue(queue, setStart))
        val setStop = CommandFactory.setStop(start.entryId, 10_000, 15_000, 30_000)
        assertEquals(queue + setStop, QueueLogic.enqueue(queue, setStop))
    }

    @Test
    fun delayedStopRunsBeforeALaterEndEdit() {
        val setStop = CommandFactory.setStop("2", 3_000, 4_000, 6_000)
        val stop = CommandFactory.stop("2", 5_000)
        assertEquals(listOf(stop, setStop), QueueLogic.enqueue(listOf(setStop), stop))
        // Never before the entry's own START.
        val created = CommandFactory.start(emptyList(), "x", null, 1_000).single()
        val localEdit = CommandFactory.setStop(created.entryId, 1_000, 1_500, 6_000)
        val localStop = CommandFactory.stop(created.entryId, 2_000)
        var queue = QueueLogic.enqueue(listOf(localEdit), created)
        assertEquals(listOf(created, localEdit), queue)
        queue = QueueLogic.enqueue(queue, localStop)
        assertEquals(listOf(created, localStop, localEdit), queue)
        // A start-only edit doesn't reorder.
        val setStart = CommandFactory.setStart("2", 2_000, 6_000)
        assertEquals(listOf(setStart, stop), QueueLogic.enqueue(listOf(setStart), stop))
    }

    @Test
    fun queueIgnoresDuplicates() {
        val stop = CommandFactory.stop("1", 1_000)
        assertEquals(1, QueueLogic.enqueue(QueueLogic.enqueue(emptyList(), stop), stop).size)
    }

    @Test
    fun frequencyRanksByCountThenRecency() {
        fun e(id: Int, d: String, p: Long?, start: Long) = TimeEntry(id.toString(), d, p, start, start + 1)
        val entries = listOf(
            e(1, "Email", null, 100),
            e(2, "Coding", 1, 200),
            e(3, "Coding ", 1, 300),
            e(4, "Email", null, 400),
            e(5, "Review", 2, 500),
            e(6, "", null, 600),
            e(7, "Coding", 2, 700),
        )
        assertEquals(
            listOf(Frequent("Email", null, 2), Frequent("Coding", 1, 2), Frequent("Coding", 2, 1), Frequent("Review", 2, 1)),
            Frequency.rank(entries),
        )
        assertEquals(1, Frequency.rank(entries, limit = 1).size)
    }

    @Test
    fun withoutFavoritesFiltersBeforeTheLimit() {
        val ranking = listOf(Frequent("A", 1, 9), Frequent("B", 1, 8), Frequent("C", null, 7), Frequent("D", 2, 6))
        val favorites = listOf(Favorite(" A ", 1), Favorite("B", 1))
        assertEquals(listOf(Frequent("C", null, 7), Frequent("D", 2, 6)), Frequency.withoutFavorites(ranking, favorites, limit = 2))
    }

    @Test
    fun recentIsDistinctAndNewestFirst() {
        fun e(id: Int, d: String, p: Long?, start: Long) = TimeEntry(id.toString(), d, p, start, start + 1)
        val entries = listOf(
            e(1, "Email", null, 100),
            e(2, "Coding", 1, 400),
            e(3, "Coding ", 1, 200),
            e(4, "", null, 600),
            e(5, "Review", 2, 300),
        )
        assertEquals(
            listOf(Favorite("Coding", 1), Favorite("Review", 2), Favorite("Email", null)),
            Frequency.recent(entries),
        )
        assertEquals(1, Frequency.recent(entries, limit = 1).size)
    }

    @Test
    fun viewStateRoundTrip() {
        val state = ViewState(
            configured = true,
            entries = listOf(done, running),
            projects = listOf(Project(10, "P", "#ff0000")),
            favorites = listOf(Favorite("fav", 10), Favorite("nofav", null)),
            frequent = listOf(Frequent("fav", 10, 3)),
            recent = listOf(Favorite("fav", 10)),
            acks = listOf("a"),
            pendingCount = 2,
            lastSync = 42,
            error = "boom",
            quotaRemaining = 27,
            quotaResetsAt = 99,
        )
        assertEquals(state, ViewState.fromBytes(state.toBytes()))
    }

    @Test
    fun watchContentIgnoresSyncTimeAndQuota() {
        val state = ViewState(configured = true, entries = listOf(running), lastSync = 1, quotaRemaining = 30, quotaResetsAt = 5)
        val synced = state.copy(lastSync = 2, quotaRemaining = 29, quotaResetsAt = 6)
        assertEquals(state.watchContentHash(), synced.watchContentHash())
        assertTrue(state.watchContentHash() != state.copy(entries = listOf(done)).watchContentHash())
        assertTrue(state.watchContentHash() != state.copy(error = "boom").watchContentHash())
    }
}
