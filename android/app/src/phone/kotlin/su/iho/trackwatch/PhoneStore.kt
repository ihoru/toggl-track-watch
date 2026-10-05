package su.iho.trackwatch

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.gms.wearable.PutDataRequest
import com.google.android.gms.wearable.Wearable
import su.iho.trackwatch.shared.Command
import su.iho.trackwatch.shared.Favorite
import su.iho.trackwatch.shared.Frequent
import su.iho.trackwatch.shared.Paths
import su.iho.trackwatch.shared.Project
import su.iho.trackwatch.shared.QueueLogic
import su.iho.trackwatch.shared.Reducer
import su.iho.trackwatch.shared.TimeEntry
import su.iho.trackwatch.shared.ViewState
import su.iho.trackwatch.shared.objects
import su.iho.trackwatch.shared.strings
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Everything the phone persists: account, favorites, the Toggl snapshot, the
 * command queue and sync status. Every mutation publishes the new view state to
 * the watch and to the Flutter UI.
 */
class PhoneStore private constructor(private val context: Context) {
    private val prefs = context.getSharedPreferences("store", Context.MODE_PRIVATE)
    private val tokens = TokenStore(context)
    private val listeners = CopyOnWriteArrayList<(ViewState) -> Unit>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var lastPublished: ViewState? = null

    /** Until when the watch is open and wants every change, sync status included (see [watchActive]). */
    @Volatile
    private var watchActiveUntil = 0L

    val token: String? get() = tokens.get()

    @get:Synchronized
    val account: Account?
        get() = prefs.getString(K_ACCOUNT, null)?.let {
            val o = JSONObject(it)
            Account(o.optString("name"), o.optString("email"), o.getLong("workspaceId"), o.optString("workspaceName"))
        }

    @get:Synchronized
    val queue: List<Command> get() = readArray(K_QUEUE).map(Command::fromJson)

    @get:Synchronized
    val snapshot: List<TimeEntry> get() = readArray(K_ENTRIES).map(TimeEntry::fromJson)

    @get:Synchronized
    val favorites: List<Favorite> get() = readArray(K_FAVORITES).map(Favorite::fromJson)

    @get:Synchronized
    val projects: List<Project> get() = readArray(K_PROJECTS).map(Project::fromJson)

    @get:Synchronized
    val idMap: Map<String, String>
        get() = prefs.getString(K_IDS, null)?.let { s -> JSONObject(s).let { o -> o.keys().asSequence().associateWith { o.getString(it) } } }
            ?: emptyMap()

    val projectsFetchedAt get() = prefs.getLong(K_PROJECTS_AT, 0)
    val lastRefresh get() = prefs.getLong(K_LAST_REFRESH, 0)
    val refreshRequested get() = prefs.getBoolean(K_REFRESH_REQUESTED, false)
    val rateLimitedUntil get() = prefs.getLong(K_RATE_LIMITED_UNTIL, 0)
    val refreshForced get() = prefs.getBoolean(K_REFRESH_FORCED, false)

    /** Local date (yyyy-MM-dd) when [frequent] was last ranked. */
    val frequentDay: String? get() = prefs.getString(K_FREQUENT_DAY, null)

    @get:Synchronized
    val frequent: List<Frequent> get() = readArray(K_FREQUENT).map(Frequent::fromJson)

    @Synchronized
    fun setFrequent(list: List<Frequent>, day: String) {
        prefs.edit().putString(K_FREQUENT, JSONArray(list.map { it.toJson() }).toString()).putString(K_FREQUENT_DAY, day).apply()
    }

    @Synchronized
    fun signIn(token: String, account: Account) {
        clearData()
        tokens.set(token)
        prefs.edit()
            .putString(K_ACCOUNT, JSONObject().put("name", account.name).put("email", account.email)
                .put("workspaceId", account.workspaceId).put("workspaceName", account.workspaceName).toString())
            .putBoolean(K_REFRESH_REQUESTED, true)
            .apply()
        changed()
    }

    @Synchronized
    fun signOut() {
        tokens.set(null)
        clearData()
        changed()
    }

    private fun clearData() {
        val favorites = prefs.getString(K_FAVORITES, null)
        prefs.edit().clear().putString(K_FAVORITES, favorites).apply()
    }

    @Synchronized
    fun setFavorites(list: List<Favorite>) {
        writeArray(K_FAVORITES, list.map { it.toJson() })
        changed()
    }

    /** Adds commands received from the watch and remembers their ids as acknowledged. */
    @Synchronized
    fun enqueue(commands: List<Command>) {
        val acks = readStrings(K_ACKS)
        var queue = queue
        for (cmd in commands) {
            if (cmd.id in acks) continue
            queue = QueueLogic.enqueue(queue, cmd)
            acks.add(cmd.id)
        }
        writeArray(K_QUEUE, queue.map { it.toJson() })
        prefs.edit().putString(K_ACKS, JSONArray(acks.takeLast(MAX_ACKS)).toString()).apply()
        changed()
    }

    @Synchronized
    fun removeCommand(id: String) {
        writeArray(K_QUEUE, queue.filterNot { it.id == id }.map { it.toJson() })
        changed()
    }

    @Synchronized
    fun mapId(localId: String, remoteId: String) {
        val map = LinkedHashMap(idMap)
        map[localId] = remoteId
        val trimmed = map.entries.toList().takeLast(MAX_IDS).associate { it.key to it.value }
        prefs.edit().putString(K_IDS, JSONObject(trimmed).toString()).apply()
    }

    @Synchronized
    fun upsertEntry(entry: TimeEntry) {
        val list = snapshot.filterNot { it.id == entry.id }.toMutableList()
        // Toggl stops the running entry when a new one starts.
        if (entry.isRunning) list.replaceAll { if (it.isRunning) it.copy(stop = entry.start) else it }
        list.add(entry)
        setSnapshot(list)
    }

    @Synchronized
    fun removeEntry(id: String) = setSnapshot(snapshot.filterNot { it.id == id })

    @Synchronized
    fun setSnapshot(entries: List<TimeEntry>) {
        writeArray(K_ENTRIES, entries.sortedByDescending { it.start }.map { it.toJson() })
        changed()
    }

    @Synchronized
    fun setRefreshed(entries: List<TimeEntry>, projects: List<Project>?) {
        val edit = prefs.edit()
            .putLong(K_LAST_REFRESH, System.currentTimeMillis())
            .putBoolean(K_REFRESH_REQUESTED, false)
            .putBoolean(K_REFRESH_FORCED, false)
        if (projects != null) {
            edit.putString(K_PROJECTS, JSONArray(projects.map { it.toJson() }).toString())
            edit.putLong(K_PROJECTS_AT, System.currentTimeMillis())
        }
        edit.apply()
        setSnapshot(entries)
    }

    /** [force] skips the 30-second refresh throttle, e.g. right after the Toggl app started a timer. */
    @Synchronized
    fun requestRefresh(force: Boolean = false) {
        val edit = prefs.edit().putBoolean(K_REFRESH_REQUESTED, true)
        if (force) edit.putBoolean(K_REFRESH_FORCED, true)
        edit.apply()
    }

    /** Saves the latest quota headers; published with the next state change. */
    @Synchronized
    fun setQuota(remaining: Int, resetsAt: Long) {
        prefs.edit().putInt(K_QUOTA_REMAINING, remaining).putLong(K_QUOTA_RESETS_AT, resetsAt).apply()
    }

    @Synchronized
    fun setStatus(error: String?, rateLimitedUntil: Long = 0, synced: Boolean = false) {
        val edit = prefs.edit().putString(K_ERROR, error).putLong(K_RATE_LIMITED_UNTIL, rateLimitedUntil)
        if (synced) edit.putLong(K_LAST_SYNC, System.currentTimeMillis())
        edit.apply()
        changed()
    }

    @Synchronized
    fun viewState(): ViewState {
        val ids = idMap
        val pending = queue.map { it.copy(entryId = ids[it.entryId] ?: it.entryId) }
        return ViewState(
            configured = token != null && account != null,
            entries = Reducer.apply(snapshot, pending),
            projects = projects.sortedBy { it.name.lowercase() },
            favorites = favorites,
            frequent = frequent,
            acks = readStrings(K_ACKS).takeLast(MAX_ACKS),
            idMap = ids,
            pendingCount = pending.size,
            lastSync = prefs.getLong(K_LAST_SYNC, 0).takeIf { it > 0 },
            error = prefs.getString(K_ERROR, null),
            rateLimitedUntil = rateLimitedUntil.takeIf { it > System.currentTimeMillis() },
            quotaRemaining = prefs.getInt(K_QUOTA_REMAINING, -1).takeIf { it >= 0 },
            quotaResetsAt = prefs.getLong(K_QUOTA_RESETS_AT, 0).takeIf { it > 0 },
        )
    }

    fun addListener(listener: (ViewState) -> Unit) = listeners.add(listener)
    fun removeListener(listener: (ViewState) -> Unit) = listeners.remove(listener)

    /** The watch app, tile or Refresh button asked for fresh data: publish everything for a few minutes. */
    fun watchActive() {
        watchActiveUntil = System.currentTimeMillis() + WATCH_ACTIVE_MILLIS
    }

    /**
     * Publishes the current view state to the watch (Data Layer) and the Flutter UI.
     *
     * Every publish wakes the watch, so background syncs that only move the sync time or the
     * API quota are not sent; the watch gets them with the next real change or when it asks.
     */
    @Synchronized
    fun changed() {
        val state = viewState()
        if (state != lastPublished) {
            val content = state.watchContentHash()
            val watching = System.currentTimeMillis() < watchActiveUntil
            if (watching || content != prefs.getString(K_PUBLISHED, null)) {
                lastPublished = state
                prefs.edit().putString(K_PUBLISHED, content).apply()
                val request = PutDataRequest.create(Paths.STATE).setData(state.toBytes()).setUrgent()
                Wearable.getDataClient(context).putDataItem(request)
            }
        }
        mainHandler.post { listeners.forEach { it(state) } }
    }

    private fun readArray(key: String): List<JSONObject> = prefs.getString(key, null)?.let { JSONArray(it).objects() } ?: emptyList()

    private fun readStrings(key: String): MutableList<String> =
        prefs.getString(key, null)?.let { JSONArray(it).strings().toMutableList() } ?: mutableListOf()

    private fun writeArray(key: String, items: List<JSONObject>) {
        prefs.edit().putString(key, JSONArray(items).toString()).apply()
    }

    companion object {
        private const val K_ACCOUNT = "account"
        private const val K_QUEUE = "queue"
        private const val K_ENTRIES = "entries"
        private const val K_FAVORITES = "favorites"
        private const val K_PROJECTS = "projects"
        private const val K_PROJECTS_AT = "projectsAt"
        private const val K_IDS = "ids"
        private const val K_ACKS = "acks"
        private const val K_LAST_SYNC = "lastSync"
        private const val K_LAST_REFRESH = "lastRefresh"
        private const val K_REFRESH_REQUESTED = "refreshRequested"
        private const val K_ERROR = "error"
        private const val K_RATE_LIMITED_UNTIL = "rateLimitedUntil"
        private const val K_REFRESH_FORCED = "refreshForced"
        private const val K_FREQUENT = "frequent"
        private const val K_FREQUENT_DAY = "frequentDay"
        private const val K_QUOTA_REMAINING = "quotaRemaining"
        private const val K_QUOTA_RESETS_AT = "quotaResetsAt"
        private const val K_PUBLISHED = "published"
        private const val WATCH_ACTIVE_MILLIS = 5 * 60_000L
        private const val MAX_ACKS = 200
        private const val MAX_IDS = 100

        @Volatile
        private var instance: PhoneStore? = null

        fun get(context: Context): PhoneStore =
            instance ?: synchronized(this) { instance ?: PhoneStore(context.applicationContext).also { instance = it } }
    }
}
