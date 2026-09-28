package su.iho.trackwatch.shared

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

/** Data Layer paths shared by the phone and the watch. */
object Paths {
    const val STATE = "/state"
    const val COMMAND_PREFIX = "/cmd/"
    const val REFRESH = "/refresh"
    const val KEY_PAYLOAD = "payload"
}

const val LOCAL_ID_PREFIX = "local-"

data class Project(val id: Long, val name: String, val color: String) {
    fun toJson(): JSONObject = JSONObject().put("id", id).put("name", name).put("color", color)

    companion object {
        fun fromJson(o: JSONObject) = Project(o.getLong("id"), o.getString("name"), o.optString("color", "#9e9e9e"))
    }
}

data class Favorite(val description: String, val projectId: Long?) {
    fun toJson(): JSONObject = JSONObject().put("description", description).put("projectId", projectId ?: JSONObject.NULL)

    companion object {
        fun fromJson(o: JSONObject) = Favorite(o.optString("description", ""), o.optLongOrNull("projectId"))
    }
}

/** A (description, project) pair and how many times it was tracked in the last 30 days. */
data class Frequent(val description: String, val projectId: Long?, val count: Int) {
    fun toJson(): JSONObject = JSONObject()
        .put("description", description)
        .put("projectId", projectId ?: JSONObject.NULL)
        .put("count", count)

    companion object {
        fun fromJson(o: JSONObject) = Frequent(o.optString("description", ""), o.optLongOrNull("projectId"), o.optInt("count", 0))
    }
}

/** Times are epoch milliseconds. [stop] is null while the entry is running. */
data class TimeEntry(
    val id: String,
    val description: String,
    val projectId: Long?,
    val start: Long,
    val stop: Long?,
    val pending: Boolean = false,
) {
    val isRunning get() = stop == null

    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("description", description)
        .put("projectId", projectId ?: JSONObject.NULL)
        .put("start", start)
        .put("stop", stop ?: JSONObject.NULL)
        .put("pending", pending)

    companion object {
        fun fromJson(o: JSONObject) = TimeEntry(
            id = o.getString("id"),
            description = o.optString("description", ""),
            projectId = o.optLongOrNull("projectId"),
            start = o.getLong("start"),
            stop = o.optLongOrNull("stop"),
            pending = o.optBoolean("pending", false),
        )
    }
}

enum class CommandType { START, STOP, UPDATE, DELETE }

/**
 * A user action. [at] is when the user tapped it; it is used as start/stop time
 * so that queued commands keep exact times.
 */
data class Command(
    val id: String,
    val type: CommandType,
    val entryId: String,
    val at: Long,
    val description: String? = null,
    val projectId: Long? = null,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("type", type.name)
        .put("entryId", entryId)
        .put("at", at)
        .put("description", description ?: JSONObject.NULL)
        .put("projectId", projectId ?: JSONObject.NULL)

    companion object {
        fun fromJson(o: JSONObject) = Command(
            id = o.getString("id"),
            type = CommandType.valueOf(o.getString("type")),
            entryId = o.getString("entryId"),
            at = o.getLong("at"),
            description = if (o.isNull("description")) null else o.optString("description"),
            projectId = o.optLongOrNull("projectId"),
        )
    }
}

/** The state the phone publishes to the watch and both Flutter UIs render. */
data class ViewState(
    val configured: Boolean = false,
    val entries: List<TimeEntry> = emptyList(),
    val projects: List<Project> = emptyList(),
    val favorites: List<Favorite> = emptyList(),
    /** Most-tracked (description, project) pairs of the last 30 days, recalculated once a day. */
    val frequent: List<Frequent> = emptyList(),
    val acks: List<String> = emptyList(),
    /** Local ids of entries created offline mapped to their Toggl ids. */
    val idMap: Map<String, String> = emptyMap(),
    val pendingCount: Int = 0,
    val lastSync: Long? = null,
    val error: String? = null,
    val rateLimitedUntil: Long? = null,
    /** Toggl API requests left in the current quota window, as last reported by Toggl. */
    val quotaRemaining: Int? = null,
    /** When the current quota window resets (epoch ms). */
    val quotaResetsAt: Long? = null,
    val phoneReachable: Boolean = true,
) {
    val running: TimeEntry? get() = entries.firstOrNull { it.isRunning }

    fun project(id: Long?): Project? = id?.let { pid -> projects.firstOrNull { it.id == pid } }

    fun toJson(): JSONObject = JSONObject()
        .put("configured", configured)
        .put("entries", JSONArray(entries.map { it.toJson() }))
        .put("projects", JSONArray(projects.map { it.toJson() }))
        .put("favorites", JSONArray(favorites.map { it.toJson() }))
        .put("frequent", JSONArray(frequent.map { it.toJson() }))
        .put("acks", JSONArray(acks))
        .put("idMap", JSONObject(idMap))
        .put("pendingCount", pendingCount)
        .put("lastSync", lastSync ?: JSONObject.NULL)
        .put("error", error ?: JSONObject.NULL)
        .put("rateLimitedUntil", rateLimitedUntil ?: JSONObject.NULL)
        .put("quotaRemaining", quotaRemaining ?: JSONObject.NULL)
        .put("quotaResetsAt", quotaResetsAt ?: JSONObject.NULL)
        .put("phoneReachable", phoneReachable)

    fun toBytes(): ByteArray = gzip(toJson().toString())

    companion object {
        fun fromJson(o: JSONObject) = ViewState(
            configured = o.optBoolean("configured", false),
            entries = o.optJSONArray("entries").objects().map(TimeEntry::fromJson),
            projects = o.optJSONArray("projects").objects().map(Project::fromJson),
            favorites = o.optJSONArray("favorites").objects().map(Favorite::fromJson),
            frequent = o.optJSONArray("frequent").objects().map(Frequent::fromJson),
            acks = o.optJSONArray("acks").strings(),
            idMap = o.optJSONObject("idMap")?.let { m -> m.keys().asSequence().associateWith { m.getString(it) } } ?: emptyMap(),
            pendingCount = o.optInt("pendingCount", 0),
            lastSync = o.optLongOrNull("lastSync"),
            error = if (o.isNull("error")) null else o.optString("error"),
            rateLimitedUntil = o.optLongOrNull("rateLimitedUntil"),
            quotaRemaining = o.optLongOrNull("quotaRemaining")?.toInt(),
            quotaResetsAt = o.optLongOrNull("quotaResetsAt"),
            phoneReachable = o.optBoolean("phoneReachable", true),
        )

        fun fromBytes(bytes: ByteArray) = fromJson(JSONObject(gunzip(bytes)))
    }
}

fun JSONObject.optLongOrNull(key: String): Long? = if (!has(key) || isNull(key)) null else getLong(key)

fun JSONArray?.objects(): List<JSONObject> =
    if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }

fun JSONArray?.strings(): List<String> =
    if (this == null) emptyList() else (0 until length()).map { getString(it) }

fun gzip(text: String): ByteArray {
    val out = ByteArrayOutputStream()
    GZIPOutputStream(out).use { it.write(text.toByteArray(Charsets.UTF_8)) }
    return out.toByteArray()
}

fun gunzip(bytes: ByteArray): String =
    GZIPInputStream(ByteArrayInputStream(bytes)).use { it.readBytes().toString(Charsets.UTF_8) }
