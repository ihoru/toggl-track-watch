package su.iho.trackwatch

import android.content.Context
import android.os.Build
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.tasks.await
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import su.iho.trackwatch.shared.LOCAL_ID_PREFIX
import su.iho.trackwatch.shared.PushAction
import su.iho.trackwatch.shared.PushLogic
import java.io.IOException
import java.time.LocalDate
import java.time.ZoneId
import java.util.concurrent.TimeUnit

/**
 * Live updates: a server (by default the one built into the app, see server/README.md) forwards
 * Toggl webhook events as Firebase Cloud Messaging data messages. While they work, the phone stops
 * polling Toggl every 15 minutes and only refreshes once a day, when the watch asks for it by hand,
 * or when a change made elsewhere arrives.
 *
 * Turning them on needs nothing but the switch: the phone registers with the server, which answers
 * a webhook URL and secret, and then creates the Toggl webhook subscription itself with the user's
 * API token (the server never sees the token). A daily check re-enables the subscription when Toggl
 * turned it off after failed deliveries.
 *
 * Builds without a Firebase configuration (no google-services.json) have no Firebase app; live
 * updates are then unavailable and the phone polls as before.
 */
object Push {
    private const val PREFS = "push"
    private const val K_ENABLED = "enabled"
    private const val K_URL = "url" // A server the user entered; null means the built-in one.
    private const val K_REG_SERVER = "regServer"
    private const val K_REG_ID = "regId"
    private const val K_REG_SECRET = "regSecret"
    private const val K_REG_PATH = "regPath"
    private const val K_SUB_WORKSPACE = "subWorkspace"
    private const val K_SUB_ID = "subId"
    private const val K_SUB_CALLBACK = "subCallback"
    private const val K_TOKEN = "fcmToken"
    private const val K_REGISTERED = "registeredToken"
    private const val K_REGISTERED_AT = "registeredAt"
    private const val K_ERROR = "error"
    private const val K_STOPPED = "stopped" // Another phone took the subscription over: no automatic retries.
    private const val K_LAST_MESSAGE = "lastMessageAt"
    // Register and unregister calls share one queue, so a late unregister can't undo a newer registration.
    private const val SERVER_CALLS = "push-server"
    private const val CHECK_AFTER = 20 * 60 * 60_000L
    // Toggl wants descriptions unique per workspace, and admins see members' subscriptions: one per user.
    internal const val DESCRIPTION = "Track Watch live updates"
    internal fun description(userId: Long) = "$DESCRIPTION ($userId)"
    internal val EVENT_FILTERS: JSONArray
        get() = JSONArray(
            listOf("created", "updated", "deleted").map { JSONObject().put("entity", "time_entry").put("action", it) }
        )

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Whether this build has a Firebase configuration. */
    fun available(context: Context): Boolean = FirebaseApp.getApps(context.applicationContext).isNotEmpty()

    fun enabled(context: Context): Boolean = prefs(context).getBoolean(K_ENABLED, false)

    /** The server built into this build (empty in forks that set LIVE_UPDATES_URL to nothing). */
    fun defaultUrl(context: Context): String {
        val id = context.resources.getIdentifier("live_updates_default_url", "string", context.packageName)
        return if (id == 0) "" else context.getString(id).trim().trimEnd('/')
    }

    /** The server the user entered instead of the built-in one, or null. */
    fun customUrl(context: Context): String? = prefs(context).getString(K_URL, null)

    fun serverUrl(context: Context): String? = customUrl(context) ?: defaultUrl(context).ifEmpty { null }

    /** Live updates are on: the server registered this phone's current FCM token and Toggl validated the webhook. */
    fun active(context: Context): Boolean {
        val p = prefs(context)
        val token = p.getString(K_TOKEN, null)
        return available(context) && enabled(context) && serverUrl(context) != null &&
            token != null && token == p.getString(K_REGISTERED, null) && PhoneStore.get(context).account != null
    }

    fun statusJson(context: Context): JSONObject {
        val p = prefs(context)
        return JSONObject()
            .put("available", available(context))
            .put("enabled", enabled(context))
            .put("url", serverUrl(context) ?: "")
            .put("defaultUrl", defaultUrl(context))
            .put("active", active(context))
            .put("error", p.getString(K_ERROR, null) ?: JSONObject.NULL)
            .put("lastMessageAt", p.getLong(K_LAST_MESSAGE, 0).takeIf { it > 0 } ?: JSONObject.NULL)
    }

    /**
     * Turns live updates on with [url] (blank or the built-in server: the built-in one), or off.
     * Turning them on (again) takes over the Toggl subscription even if another phone had it.
     */
    fun configure(context: Context, enabled: Boolean, url: String) {
        val cleanUrl = url.trim().trimEnd('/').ifEmpty { null }?.takeIf { it != defaultUrl(context) }
        val p = prefs(context)
        val oldServer = p.getString(K_REG_SERVER, null)
        val newServer = if (enabled) cleanUrl ?: defaultUrl(context).ifEmpty { null } else null
        if (oldServer != null && oldServer != newServer) unregister(context, removeSubscription = !enabled)
        p.edit()
            .putBoolean(K_ENABLED, enabled)
            .putString(K_URL, if (enabled) cleanUrl else customUrl(context))
            .remove(K_REGISTERED)
            .remove(K_ERROR)
            .remove(K_STOPPED)
            .apply()
        changed(context)
        if (enabled) {
            register(context, takeOver = true)
        } else if (available(context)) {
            // Turned off: drop the FCM token too; a new one is made if live updates are turned on again.
            p.edit().remove(K_TOKEN).apply()
            FirebaseMessaging.getInstance().deleteToken()
        }
    }

    /** Restores the setting from the cloud backup. */
    fun restore(context: Context, enabled: Boolean, url: String?) {
        if (!enabled || enabled(context)) return
        prefs(context).edit().putBoolean(K_ENABLED, true).putString(K_URL, url).apply()
    }

    /**
     * Registers this phone with the server (again) and sets up the Toggl subscription in the
     * background. [takeOver]: also when the subscription now points elsewhere (another phone of
     * this account, an earlier install); the daily check doesn't, so two phones don't take turns.
     */
    fun register(context: Context, takeOver: Boolean = true) {
        if (!available(context) || !enabled(context) || serverUrl(context) == null) return
        val request = OneTimeWorkRequestBuilder<PushRegisterWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .setInputData(workDataOf(PushRegisterWorker.TAKE_OVER to takeOver))
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(SERVER_CALLS, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
    }

    /** On app start and daily: sets up when not set up yet, or checks the server and Toggl subscription. */
    fun ensureRegistered(context: Context) {
        val stale = System.currentTimeMillis() - prefs(context).getLong(K_REGISTERED_AT, 0) > CHECK_AFTER
        // A phone that lost the subscription to another one stays off until the user turns it on again.
        val stopped = prefs(context).getBoolean(K_STOPPED, false)
        if (enabled(context) && !stopped && (!active(context) || stale)) register(context, takeOver = false)
    }

    /**
     * Sign-out: tells the server to forget this phone and deletes the Toggl subscription, with the
     * API token that is about to be forgotten. Keeps the setting for the next sign-in.
     */
    fun signedOut(context: Context, apiToken: String?) {
        val p = prefs(context)
        val wid = p.getLong(K_SUB_WORKSPACE, 0)
        val subId = p.getLong(K_SUB_ID, 0)
        val callback = p.getString(K_SUB_CALLBACK, null)
        if (apiToken != null && wid > 0 && subId > 0 && callback != null) {
            Thread { runCatching { deleteOwnWebhook(TogglApi(apiToken), wid, subId, callback) } }.start()
        }
        unregister(context, removeSubscription = false)
        p.edit().remove(K_REGISTERED).remove(K_ERROR).remove(K_STOPPED).apply()
        forgetSubscription(context)
    }

    /** Forgets the server registration, and also the Toggl subscription when [removeSubscription] (turned off). */
    private fun unregister(context: Context, removeSubscription: Boolean) {
        val p = prefs(context)
        val server = p.getString(K_REG_SERVER, null)
        val id = p.getString(K_REG_ID, null)
        val secret = p.getString(K_REG_SECRET, null)
        val wid = if (removeSubscription) p.getLong(K_SUB_WORKSPACE, 0) else 0
        val subId = if (removeSubscription) p.getLong(K_SUB_ID, 0) else 0
        val callback = if (removeSubscription) p.getString(K_SUB_CALLBACK, null) else null
        p.edit().remove(K_REG_SERVER).remove(K_REG_ID).remove(K_REG_SECRET).remove(K_REG_PATH).apply()
        if (removeSubscription) forgetSubscription(context)
        if (server == null || id == null || secret == null) return
        val request = OneTimeWorkRequestBuilder<PushUnregisterWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setInputData(
                workDataOf("url" to server, "id" to id, "secret" to secret, "wid" to wid, "subId" to subId, "callback" to callback)
            )
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(SERVER_CALLS, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
    }

    internal fun newToken(context: Context, token: String) {
        if (!enabled(context)) return
        prefs(context).edit().putString(K_TOKEN, token).apply()
        register(context, takeOver = false)
    }

    internal data class Registration(val server: String, val id: String, val secret: String, val path: String)

    internal fun registration(context: Context): Registration? {
        val p = prefs(context)
        return Registration(
            server = p.getString(K_REG_SERVER, null) ?: return null,
            id = p.getString(K_REG_ID, null) ?: return null,
            secret = p.getString(K_REG_SECRET, null) ?: return null,
            path = p.getString(K_REG_PATH, null) ?: return null,
        )
    }

    internal fun saveRegistration(context: Context, reg: Registration?) {
        val edit = prefs(context).edit()
        if (reg == null) {
            edit.remove(K_REG_SERVER).remove(K_REG_ID).remove(K_REG_SECRET).remove(K_REG_PATH)
        } else {
            edit.putString(K_REG_SERVER, reg.server).putString(K_REG_ID, reg.id)
                .putString(K_REG_SECRET, reg.secret).putString(K_REG_PATH, reg.path)
        }
        edit.apply()
    }

    internal fun saveSubscription(context: Context, workspaceId: Long, id: Long, callback: String) {
        prefs(context).edit().putLong(K_SUB_WORKSPACE, workspaceId).putLong(K_SUB_ID, id).putString(K_SUB_CALLBACK, callback).apply()
    }

    internal fun subscriptionCallback(context: Context): String? = prefs(context).getString(K_SUB_CALLBACK, null)

    private fun forgetSubscription(context: Context) {
        prefs(context).edit().remove(K_SUB_WORKSPACE).remove(K_SUB_ID).remove(K_SUB_CALLBACK).apply()
    }

    /**
     * Deletes the Toggl subscription only while it still points at this phone's registration:
     * another phone may have taken it over (same subscription id, new callback).
     */
    internal fun deleteOwnWebhook(api: TogglApi, wid: Long, id: Long, callback: String) {
        val current = api.webhookSubscriptions(wid).firstOrNull { it.optLong("subscription_id") == id } ?: return
        if (current.optString("url_callback") == callback) api.deleteWebhook(wid, id)
    }

    internal fun registered(context: Context, token: String) {
        prefs(context).edit()
            .putString(K_TOKEN, token)
            .putString(K_REGISTERED, token)
            .putLong(K_REGISTERED_AT, System.currentTimeMillis())
            .remove(K_ERROR)
            .remove(K_STOPPED)
            .apply()
        changed(context)
    }

    internal fun failed(context: Context, error: String, stop: Boolean = false) {
        prefs(context).edit().putString(K_ERROR, error).putBoolean(K_STOPPED, stop).remove(K_REGISTERED).apply()
        // The subscription now belongs to another phone: this one must not delete it later.
        if (stop) forgetSubscription(context)
        changed(context)
    }

    internal fun messageReceived(context: Context) {
        prefs(context).edit().putLong(K_LAST_MESSAGE, System.currentTimeMillis()).apply()
    }

    /** Polling depends on whether live updates work; the phone UI shows their status. */
    private fun changed(context: Context) {
        Sync.schedulePeriodic(context)
        PhoneStore.get(context).changed()
    }

    internal val http: OkHttpClient by lazy {
        OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS).build()
    }
    internal val JSON = "application/json; charset=utf-8".toMediaType()
}

/** A setup step failed; [retry] when it may work later by itself. */
private class PushSetupException(message: String, val retry: Boolean, val stop: Boolean = false) : Exception(message)

/**
 * Registers with the server, then creates, repairs or checks the Toggl webhook subscription that
 * points at this registration, and has Toggl validate it.
 */
class PushRegisterWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val context = applicationContext
        if (!Push.enabled(context)) return Result.success()
        val server = Push.serverUrl(context) ?: return Result.success()
        val store = PhoneStore.get(context)
        val apiToken = store.token ?: return Result.success() // Registers again on sign-in.
        var account = store.account ?: return Result.success()
        val takeOver = inputData.getBoolean(TAKE_OVER, true)
        return try {
            val api = TogglApi(apiToken, store::setQuota)
            if (account.userId == 0L) {
                store.setUserId(api.userId())
                account = store.account ?: return Result.success()
            }
            val fcmToken = FirebaseMessaging.getInstance().token.await()
            val phone = JSONObject()
                .put("token", fcmToken)
                .put("user_id", account.userId)
                .put("workspace_id", account.workspaceId)
                .put("name", "${Build.MANUFACTURER} ${Build.MODEL}")

            var reg = Push.registration(context)?.takeIf { it.server == server }
            // The subscription this phone last set up is still its own, even if the server lost that
            // registration (saved only once a setup succeeded, so it survives failed retries).
            val previousCallback = Push.subscriptionCallback(context) ?: reg?.let { it.server + it.path }
            var validated = false
            if (reg != null) {
                val status = serverCall("PUT", "$server/registrations/${reg.id}", phone, reg.secret)
                if (status == null) reg = null else validated = status.optBoolean("validated")
            }
            if (reg == null) {
                val created = serverCall("POST", "$server/registrations", phone, null)
                    ?: throw PushSetupException("The server answered 404; check the URL", retry = false)
                reg = Push.Registration(server, created.getString("id"), created.getString("secret"), created.getString("webhook_path"))
                if (obsolete(server, apiToken)) {
                    // Turned off, another server chosen or signed out while registering: don't leave this one behind.
                    runCatching { serverCall("DELETE", "$server/registrations/${reg.id}", null, reg.secret) }
                    return Result.success()
                }
                Push.saveRegistration(context, reg)
            }

            val subscription = subscribe(api, account.workspaceId, account.userId, reg, takeOver, previousCallback)
            val subId = subscription.getLong("subscription_id")
            if (obsolete(server, apiToken)) {
                runCatching { Push.deleteOwnWebhook(api, account.workspaceId, subId, reg.server + reg.path) }
                runCatching { serverCall("DELETE", "$server/registrations/${reg.id}", null, reg.secret) }
                if (Push.registration(context)?.id == reg.id) Push.saveRegistration(context, null)
                return Result.success()
            }
            Push.saveSubscription(context, account.workspaceId, subId, reg.server + reg.path)
            if (!validated || subscription.isNull("validated_at")) {
                api.pingWebhook(account.workspaceId, subId)
                validated = serverCall("GET", "$server/registrations/${reg.id}", null, reg.secret)?.optBoolean("validated") == true
                if (!validated) throw PushSetupException("Toggl couldn't reach the server yet, will retry", retry = true)
            }
            Push.registered(context, fcmToken)
            Result.success()
        } catch (e: PushSetupException) {
            Push.failed(context, e.message.orEmpty(), e.stop)
            if (e.retry) Result.retry() else Result.success()
        } catch (e: IllegalArgumentException) {
            Push.failed(context, "Invalid server URL")
            Result.success()
        } catch (e: TogglException) {
            when (e.code) {
                402, 429 -> {
                    Push.failed(context, "Toggl is busy, will retry")
                    Result.retry()
                }
                in 400..499 -> {
                    // E.g. the workspace's webhook limit is reached (1 on the Free plan).
                    Push.failed(context, "Toggl refused the webhook: ${e.message.orEmpty().take(120)}")
                    Result.success()
                }
                else -> {
                    Push.failed(context, "Toggl error ${e.code}, will retry")
                    Result.retry()
                }
            }
        } catch (e: IOException) {
            Push.failed(context, "Can't reach the server, will retry")
            Result.retry()
        } catch (e: Exception) {
            // Play services missing or Firebase not reachable.
            Push.failed(context, "Couldn't get a push token: ${e.message ?: e.javaClass.simpleName}")
            Result.retry()
        }
    }

    /**
     * The Toggl subscription for [reg]: ours if it exists, otherwise one Track Watch made before
     * (by description) is pointed here when [takeOver], otherwise a new one is created.
     */
    /** Things changed while this ran: live updates turned off or moved to another server, or signed out. */
    private fun obsolete(server: String, apiToken: String): Boolean =
        !Push.enabled(applicationContext) || Push.serverUrl(applicationContext) != server ||
            PhoneStore.get(applicationContext).token != apiToken

    private fun subscribe(
        api: TogglApi,
        wid: Long,
        userId: Long,
        reg: Push.Registration,
        takeOver: Boolean,
        previousCallback: String?,
    ): JSONObject {
        val callback = reg.server + reg.path
        val body = JSONObject()
            .put("url_callback", callback)
            .put("event_filters", Push.EVENT_FILTERS)
            .put("enabled", true)
            .put("description", Push.description(userId))
            .put("secret", reg.secret)
        val subscriptions = api.webhookSubscriptions(wid)
        val ours = subscriptions.firstOrNull { it.optString("url_callback") == callback }
        if (ours != null) {
            // Toggl turns a subscription off after repeated delivery failures (e.g. the server was down).
            return if (ours.optBoolean("enabled", true)) ours else api.enableWebhook(wid, ours.getLong("subscription_id"))
        }
        // Only this user's own: a workspace admin also sees, and could overwrite, other members' subscriptions.
        val earlier = subscriptions.firstOrNull {
            it.optString("description").startsWith(Push.DESCRIPTION) && it.optLong("user_id", userId) == userId
        }
        return when {
            earlier == null -> api.createWebhook(wid, body)
            takeOver || earlier.optString("url_callback") == previousCallback ->
                api.updateWebhook(wid, earlier.getLong("subscription_id"), body)
            else -> throw PushSetupException("moved to another phone; Settings → Save brings them back", retry = false, stop = true)
        }
    }

    /** Calls the server; null when it doesn't know the registration (404, or 401/403 for a wrong secret). */
    private fun serverCall(method: String, url: String, body: JSONObject?, secret: String?): JSONObject? {
        val builder = Request.Builder().url(url).method(method, body?.toString()?.toRequestBody(Push.JSON))
        if (secret != null) builder.header("Authorization", "Bearer $secret")
        Push.http.newCall(builder.build()).execute().use { response ->
            val text = response.body?.string().orEmpty()
            return when {
                response.isSuccessful -> runCatching { JSONObject(text) }.getOrElse { JSONObject() }
                response.code == 404 || response.code == 401 || response.code == 403 -> null
                response.code == 429 -> throw PushSetupException("Too many attempts, will retry later", retry = true)
                response.code in 400..499 -> throw PushSetupException("The server answered ${response.code}; check the URL", retry = false)
                else -> throw PushSetupException("Server error ${response.code}, will retry", retry = true)
            }
        }
    }

    companion object {
        const val TAKE_OVER = "takeOver"
    }
}

/** Best effort: tells a server to forget this phone, and deletes the Toggl subscription when turned off. */
class PushUnregisterWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val url = inputData.getString("url") ?: return Result.success()
        val id = inputData.getString("id") ?: return Result.success()
        val secret = inputData.getString("secret") ?: return Result.success()
        val wid = inputData.getLong("wid", 0)
        val subId = inputData.getLong("subId", 0)
        val callback = inputData.getString("callback")
        return try {
            val apiToken = PhoneStore.get(applicationContext).token
            if (apiToken != null && wid > 0 && subId > 0 && callback != null) {
                runCatching { Push.deleteOwnWebhook(TogglApi(apiToken), wid, subId, callback) }
            }
            val request = Request.Builder()
                .url("$url/registrations/$id")
                .header("Authorization", "Bearer $secret")
                .delete()
                .build()
            Push.http.newCall(request).execute().close()
            Result.success()
        } catch (e: IOException) {
            if (runAttemptCount < 3) Result.retry() else Result.success()
        } catch (e: IllegalArgumentException) {
            Result.success()
        }
    }
}

/** Receives live updates and FCM token changes. */
class PushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        Push.newToken(this, token)
    }

    /** FCM dropped messages it held too long or too many of (phone offline): catch up from Toggl. */
    override fun onDeletedMessages() {
        if (PhoneStore.get(this).token != null) Sync.refreshSoon(this, 2_000)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        if (data["kind"] != "time_entry") return
        Push.messageReceived(this)
        val store = PhoneStore.get(this)
        val account = store.account ?: return
        if (store.token == null) return

        val json = runCatching { JSONObject(data["entry"].orEmpty()) }.getOrNull()
        val entry = json?.let { runCatching { TogglApi.parseEntry(it) }.getOrNull() }
        val ids = store.idMap
        val pendingIds = store.queue.mapNotNull { cmd ->
            if (cmd.entryId.startsWith(LOCAL_ID_PREFIX)) ids[cmd.entryId] else cmd.entryId
        }.toSet()
        val zone = ZoneId.systemDefault()
        val historyStart = LocalDate.now(zone).minusDays(SyncEngine.HISTORY_DAYS - 1).atStartOfDay(zone).toInstant().toEpochMilli()
        val action = PushLogic.decide(
            action = data["action"].orEmpty(),
            entry = entry,
            entryWorkspaceId = json?.optLong("workspace_id")?.takeIf { it > 0 },
            workspaceId = account.workspaceId,
            snapshot = store.snapshot,
            pendingIds = pendingIds,
            historyStart = historyStart,
        )
        when (action) {
            PushAction.IGNORE -> Unit
            PushAction.REMOVE -> store.removeEntry(entry!!.id)
            // A short delay merges a burst of events (e.g. stop + start) into one refresh.
            PushAction.REFRESH -> Sync.refreshSoon(this, 2_000)
        }
    }
}
