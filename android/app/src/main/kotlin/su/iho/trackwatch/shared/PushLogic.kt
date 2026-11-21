package su.iho.trackwatch.shared

/** What the phone does with a live update (a Toggl webhook event forwarded by the push server). */
enum class PushAction {
    /** The phone already has this version of the entry (usually its own change coming back), or doesn't show it. */
    IGNORE,

    /** The entry was deleted elsewhere: drop it from the snapshot, no API call needed. */
    REMOVE,

    /** Something changed elsewhere: refresh from Toggl. */
    REFRESH,
}

object PushLogic {
    /**
     * Decides how to apply a time-entry event. [entry] is null when the event could not be parsed,
     * which always refreshes. [pendingIds] are the Toggl ids that queued commands still change: the
     * response to those commands brings the entry up to date anyway. Entries that ended before
     * [historyStart] are outside what the phone keeps.
     */
    fun decide(
        action: String,
        entry: TimeEntry?,
        entryWorkspaceId: Long?,
        workspaceId: Long,
        snapshot: List<TimeEntry>,
        pendingIds: Set<String>,
        historyStart: Long,
    ): PushAction {
        if (entry == null) return PushAction.REFRESH
        if (entryWorkspaceId != null && entryWorkspaceId != workspaceId) return PushAction.IGNORE
        val known = snapshot.firstOrNull { it.id == entry.id }
        if (action == "deleted") return if (known != null) PushAction.REMOVE else PushAction.IGNORE
        if (entry.id in pendingIds) return PushAction.IGNORE
        if (known != null && known.copy(pending = false) == entry.copy(pending = false)) return PushAction.IGNORE
        if (known == null && !entry.isRunning && (entry.stop ?: entry.start) < historyStart) return PushAction.IGNORE
        return PushAction.REFRESH
    }
}
