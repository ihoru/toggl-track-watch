package su.iho.trackwatch.shared

import java.util.UUID

/** Applies not-yet-synced commands on top of a list of entries (optimistic UI). */
object Reducer {
    fun apply(entries: List<TimeEntry>, commands: List<Command>): List<TimeEntry> {
        val result = entries.toMutableList()
        for (cmd in commands) {
            when (cmd.type) {
                CommandType.START -> {
                    result.replaceAll { if (it.isRunning) it.copy(stop = maxOf(cmd.at, it.start), pending = true) else it }
                    result.removeAll { it.id == cmd.entryId }
                    result.add(TimeEntry(cmd.entryId, cmd.description ?: "", cmd.projectId, cmd.at, null, pending = true))
                }
                CommandType.STOP -> result.replaceAll {
                    if (it.id == cmd.entryId && it.isRunning) it.copy(stop = maxOf(cmd.at, it.start), pending = true) else it
                }
                CommandType.UPDATE -> result.replaceAll {
                    if (it.id == cmd.entryId) it.copy(description = cmd.description ?: it.description, projectId = cmd.projectId, pending = true) else it
                }
                CommandType.DELETE -> result.removeAll { it.id == cmd.entryId }
            }
        }
        return result.sortedByDescending { it.start }
    }
}

/** Builds the commands for a user action, given what the user currently sees. */
object CommandFactory {
    private fun newId() = UUID.randomUUID().toString()

    fun start(view: List<TimeEntry>, description: String, projectId: Long?, now: Long): List<Command> {
        val stop = view.firstOrNull { it.isRunning }?.let { stop(it.id, now) }
        val start = Command(newId(), CommandType.START, LOCAL_ID_PREFIX + newId(), now, description, projectId)
        return listOfNotNull(stop, start)
    }

    fun stop(entryId: String, now: Long) = Command(newId(), CommandType.STOP, entryId, now)

    fun update(entryId: String, description: String, projectId: Long?, now: Long) =
        Command(newId(), CommandType.UPDATE, entryId, now, description, projectId)

    fun delete(entryId: String, now: Long) = Command(newId(), CommandType.DELETE, entryId, now)
}

/**
 * The phone-side queue logic: coalesces commands that target entries which were
 * not yet created in Toggl, so that e.g. start+delete never reaches the API.
 */
object QueueLogic {
    fun enqueue(queue: List<Command>, cmd: Command): List<Command> {
        if (queue.any { it.id == cmd.id }) return queue
        val local = cmd.entryId.startsWith(LOCAL_ID_PREFIX)
        val startIndex = queue.indexOfFirst { it.type == CommandType.START && it.entryId == cmd.entryId }
        if (local && startIndex >= 0) {
            when (cmd.type) {
                CommandType.DELETE -> return queue.filterNot { it.entryId == cmd.entryId }
                CommandType.UPDATE -> return queue.toMutableList().also {
                    it[startIndex] = it[startIndex].copy(description = cmd.description, projectId = cmd.projectId)
                }
                else -> {}
            }
        }
        return queue + cmd
    }
}
