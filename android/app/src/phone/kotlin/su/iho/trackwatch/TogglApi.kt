package su.iho.trackwatch

import su.iho.trackwatch.shared.Project
import su.iho.trackwatch.shared.TimeEntry
import su.iho.trackwatch.shared.objects
import su.iho.trackwatch.shared.optLongOrNull
import okhttp3.Credentials
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.OffsetDateTime
import java.util.concurrent.TimeUnit

/** An HTTP error from Toggl. [retryAfterSeconds] is set for quota / rate-limit responses. */
class TogglException(val code: Int, message: String, val retryAfterSeconds: Long? = null) : Exception(message)

data class Account(val name: String, val email: String, val workspaceId: Long, val workspaceName: String)

/**
 * Minimal Toggl Track API v9 client. All calls are blocking; call them off the main thread.
 * [onQuota] receives the quota headers of every response: requests left and when the window resets (epoch ms).
 */
class TogglApi(private val token: String, private val onQuota: (remaining: Int, resetsAt: Long) -> Unit = { _, _ -> }) {
    private val base = "https://api.track.toggl.com/api/v9"

    fun account(): Account {
        val me = JSONObject(call("GET", "/me"))
        val wid = me.getLong("default_workspace_id")
        val ws = JSONObject(call("GET", "/workspaces/$wid"))
        return Account(me.optString("fullname"), me.optString("email"), wid, ws.optString("name"))
    }

    fun projects(wid: Long): List<Project> {
        val result = mutableListOf<Project>()
        var page = 1
        while (true) {
            val batch = JSONArray(call("GET", "/workspaces/$wid/projects?active=true&per_page=200&page=$page")).objects()
            batch.mapTo(result) { Project(it.getLong("id"), it.optString("name"), it.optString("color", "#9e9e9e")) }
            if (batch.size < 200) return result
            page++
        }
    }

    fun entries(wid: Long, from: Instant, to: Instant): List<TimeEntry> {
        val body = call("GET", "/me/time_entries?start_date=$from&end_date=$to")
        return JSONArray(body).objects()
            .filter { it.optLong("workspace_id") == wid && it.isNull("server_deleted_at") }
            .map(::parseEntry)
    }

    /** The running entry, or null. */
    fun current(): TimeEntry? {
        val body = call("GET", "/me/time_entries/current").trim()
        if (body.isEmpty() || body == "null") return null
        val o = JSONObject(body)
        return if (o.isNull("server_deleted_at")) parseEntry(o) else null
    }

    /** One entry by id, also outside the synced date range. */
    fun entry(id: Long): TimeEntry = parseEntry(JSONObject(call("GET", "/me/time_entries/$id")))

    fun create(wid: Long, description: String, projectId: Long?, start: Long): TimeEntry {
        val body = JSONObject()
            .put("created_with", "TrackWatch")
            .put("workspace_id", wid)
            .put("description", description)
            .put("project_id", projectId ?: JSONObject.NULL)
            .put("start", iso(start))
            .put("duration", -1)
        return parseEntry(JSONObject(call("POST", "/workspaces/$wid/time_entries", body)))
    }

    fun update(wid: Long, id: Long, fields: JSONObject): TimeEntry =
        parseEntry(JSONObject(call("PUT", "/workspaces/$wid/time_entries/$id", fields)))

    fun stopNow(wid: Long, id: Long): TimeEntry =
        parseEntry(JSONObject(call("PATCH", "/workspaces/$wid/time_entries/$id/stop")))

    fun delete(wid: Long, id: Long) {
        call("DELETE", "/workspaces/$wid/time_entries/$id")
    }

    private fun call(method: String, path: String, body: JSONObject? = null): String {
        val requestBody = when {
            body != null -> body.toString().toRequestBody(JSON)
            method == "PATCH" || method == "POST" || method == "PUT" -> "".toRequestBody(JSON)
            else -> null
        }
        val request = Request.Builder()
            .url(base + path)
            .header("Authorization", Credentials.basic(token, "api_token"))
            .method(method, requestBody)
            .build()
        client.newCall(request).execute().use { response ->
            response.header("X-Toggl-Quota-Remaining")?.toIntOrNull()?.let { remaining ->
                val resetsIn = response.header("X-Toggl-Quota-Resets-In")?.toLongOrNull() ?: 0
                onQuota(remaining, System.currentTimeMillis() + resetsIn * 1000)
            }
            val text = response.body?.string().orEmpty()
            if (response.isSuccessful) return text
            val retryAfter = when (response.code) {
                402 -> response.header("X-Toggl-Quota-Resets-In")?.toLongOrNull() ?: DEFAULT_QUOTA_WAIT_SECONDS
                429 -> response.header("Retry-After")?.toLongOrNull() ?: 5
                else -> null
            }
            throw TogglException(response.code, text.take(200).ifBlank { "HTTP ${response.code}" }, retryAfter)
        }
    }

    companion object {
        const val DEFAULT_QUOTA_WAIT_SECONDS = 15 * 60L
        private val JSON = "application/json; charset=utf-8".toMediaType()
        private val client = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .build()

        fun iso(millis: Long): String = Instant.ofEpochMilli(millis / 1000 * 1000).toString()

        fun parseEntry(o: JSONObject): TimeEntry {
            val start = OffsetDateTime.parse(o.getString("start")).toInstant().toEpochMilli()
            val running = o.optLong("duration", 0) < 0
            val stop = if (running || o.isNull("stop")) null else OffsetDateTime.parse(o.getString("stop")).toInstant().toEpochMilli()
            return TimeEntry(
                id = o.getLong("id").toString(),
                description = if (o.isNull("description")) "" else o.optString("description"),
                projectId = o.optLongOrNull("project_id"),
                start = start,
                stop = stop,
            )
        }
    }
}
