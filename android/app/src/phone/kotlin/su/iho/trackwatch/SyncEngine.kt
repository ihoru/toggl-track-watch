package su.iho.trackwatch

import android.content.Context
import android.net.Uri
import com.google.android.gms.wearable.DataItem
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.PutDataRequest
import com.google.android.gms.wearable.Wearable
import su.iho.trackwatch.shared.Command
import su.iho.trackwatch.shared.CommandType
import su.iho.trackwatch.shared.LOCAL_ID_PREFIX
import su.iho.trackwatch.shared.Paths
import kotlinx.coroutines.tasks.await
import org.json.JSONObject
import java.io.IOException
import java.time.LocalDate
import java.time.ZoneId

/** Outcome of one sync run, mapped to a WorkManager result by [SyncWorker]. */
sealed interface SyncOutcome {
    data object Done : SyncOutcome
    data object Retry : SyncOutcome
    data class RetryAt(val atMillis: Long) : SyncOutcome
}

/** Sends queued commands to Toggl and refreshes the snapshot. */
class SyncEngine(private val context: Context) {
    private val store = PhoneStore.get(context)

    suspend fun run(): SyncOutcome {
        ingestPendingDataItems()
        val token = store.token ?: return SyncOutcome.Done
        val account = store.account ?: return SyncOutcome.Done
        val now = System.currentTimeMillis()
        if (store.rateLimitedUntil > now) return SyncOutcome.RetryAt(store.rateLimitedUntil)

        val api = TogglApi(token)
        var dropped: String? = null
        try {
            while (true) {
                val cmd = store.queue.firstOrNull() ?: break
                try {
                    execute(api, account.workspaceId, cmd)
                } catch (e: TogglException) {
                    if (e.code !in 400..499 || e.code in RETRYABLE) throw e
                    // The entry was changed or deleted elsewhere, or the request is invalid: drop it.
                    store.requestRefresh()
                    val benign = (cmd.type == CommandType.STOP && e.code in setOf(400, 409)) || e.code == 404
                    if (!benign) dropped = "Dropped ${cmd.type.name.lowercase()}: ${e.message}"
                }
                store.removeCommand(cmd.id)
            }
            val stale = System.currentTimeMillis() - store.lastRefresh > MIN_REFRESH_INTERVAL
            if ((store.refreshRequested && stale) || store.lastRefresh == 0L) refresh(api, account.workspaceId)
            store.setStatus(error = dropped, synced = true)
            return SyncOutcome.Done
        } catch (e: TogglException) {
            return when (e.code) {
                401, 403 -> {
                    store.setStatus("Toggl rejected the API token. Update it in settings.")
                    SyncOutcome.Done
                }
                402, 429 -> {
                    val until = System.currentTimeMillis() + (e.retryAfterSeconds ?: 60) * 1000
                    store.setStatus("Toggl API limit reached, will retry", rateLimitedUntil = until)
                    SyncOutcome.RetryAt(until)
                }
                else -> {
                    store.setStatus("Toggl error ${e.code}, will retry")
                    SyncOutcome.Retry
                }
            }
        } catch (e: IOException) {
            store.setStatus("No connection to Toggl, will retry")
            return SyncOutcome.Retry
        }
    }

    private fun execute(api: TogglApi, wid: Long, cmd: Command) {
        if (cmd.type == CommandType.START) {
            val created = api.create(wid, cmd.description.orEmpty(), cmd.projectId, cmd.at)
            store.mapId(cmd.entryId, created.id)
            store.upsertEntry(created)
            return
        }
        val id = resolve(cmd.entryId) ?: return // Its start was dropped, nothing to do.
        when (cmd.type) {
            CommandType.STOP -> {
                val entry = store.snapshot.firstOrNull { it.id == id.toString() }
                val fresh = System.currentTimeMillis() - cmd.at < FRESH_STOP_WINDOW
                val stopped = if (fresh || entry == null || cmd.at <= entry.start) {
                    api.stopNow(wid, id)
                } else {
                    api.update(wid, id, JSONObject().put("stop", TogglApi.iso(cmd.at)).put("duration", (cmd.at - entry.start) / 1000))
                }
                store.upsertEntry(stopped)
            }
            CommandType.UPDATE -> {
                val fields = JSONObject()
                    .put("description", cmd.description.orEmpty())
                    .put("project_id", cmd.projectId ?: JSONObject.NULL)
                store.upsertEntry(api.update(wid, id, fields))
            }
            CommandType.DELETE -> {
                api.delete(wid, id)
                store.removeEntry(id.toString())
            }
            CommandType.START -> Unit
        }
    }

    private fun resolve(entryId: String): Long? =
        if (entryId.startsWith(LOCAL_ID_PREFIX)) store.idMap[entryId]?.toLongOrNull() else entryId.toLongOrNull()

    private fun refresh(api: TogglApi, wid: Long) {
        val zone = ZoneId.systemDefault()
        val today = LocalDate.now(zone)
        val from = today.minusDays(HISTORY_DAYS - 1).atStartOfDay(zone).toInstant()
        val to = today.plusDays(1).atStartOfDay(zone).toInstant()
        val projectsStale = System.currentTimeMillis() - store.projectsFetchedAt > PROJECTS_TTL
        val projects = if (projectsStale) api.projects(wid) else null
        store.setRefreshed(api.entries(wid, from, to), projects)
    }

    /** Picks up commands whose DATA_CHANGED event was missed (e.g. app was updated). */
    private suspend fun ingestPendingDataItems() {
        try {
            val client = Wearable.getDataClient(context)
            val uri = Uri.Builder().scheme(PutDataRequest.WEAR_URI_SCHEME).path(Paths.COMMAND_PREFIX).build()
            val buffer = client.getDataItems(uri, com.google.android.gms.wearable.DataClient.FILTER_PREFIX).await()
            val items = buffer.map { it.freeze() }
            buffer.release()
            ingest(context, items)
        } catch (e: Exception) {
            // Wearable API unavailable (no watch paired); nothing to ingest.
        }
    }

    companion object {
        const val HISTORY_DAYS = 7L
        private const val FRESH_STOP_WINDOW = 2 * 60_000L
        private const val MIN_REFRESH_INTERVAL = 30_000L
        private const val PROJECTS_TTL = 60 * 60_000L
        private val RETRYABLE = setOf(401, 402, 403, 408, 429)

        /** Moves command DataItems into the queue and deletes them from the Data Layer. */
        fun ingest(context: Context, items: List<DataItem>) {
            val commandItems = items.filter { it.uri.path?.startsWith(Paths.COMMAND_PREFIX) == true }
            if (commandItems.isEmpty()) return
            val commands = commandItems.mapNotNull { item ->
                runCatching {
                    Command.fromJson(JSONObject(DataMapItem.fromDataItem(item).dataMap.getString(Paths.KEY_PAYLOAD)!!))
                }.getOrNull()
            }
            // Watch commands are ordered by the time they were made.
            if (commands.isNotEmpty()) PhoneStore.get(context).enqueue(commands.sortedBy { it.at })
            val client = Wearable.getDataClient(context)
            commandItems.forEach { client.deleteDataItems(it.uri) }
        }
    }
}
