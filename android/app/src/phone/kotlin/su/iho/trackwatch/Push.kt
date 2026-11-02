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
import org.json.JSONObject
import su.iho.trackwatch.shared.LOCAL_ID_PREFIX
import su.iho.trackwatch.shared.PushAction
import su.iho.trackwatch.shared.PushLogic
import java.io.IOException
import java.time.LocalDate
import java.time.ZoneId
import java.util.concurrent.TimeUnit

/**
 * Live updates: the user's own server forwards Toggl webhook events as Firebase Cloud Messaging
 * data messages (see server/README.md). While they work, the phone stops polling Toggl every
 * 15 minutes and only refreshes once a day, when the watch asks for it by hand, or when a change
 * made elsewhere arrives.
 *
 * Builds without a Firebase configuration (no google-services.json) have no Firebase app; live
 * updates are then unavailable and the phone polls as before.
 */
object Push {
    private const val PREFS = "push"
    private const val K_URL = "url"
    private const val K_SECRET = "secret"
    private const val K_TOKEN = "fcmToken"
    private const val K_REGISTERED = "registeredToken"
    private const val K_REGISTERED_AT = "registeredAt"
    private const val K_ERROR = "error"
    private const val K_LAST_MESSAGE = "lastMessageAt"
    private const val REGISTER = "push-register"
    private const val REREGISTER_AFTER = 7 * 24 * 60 * 60_000L

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Whether this build has a Firebase configuration. */
    fun available(context: Context): Boolean = FirebaseApp.getApps(context.applicationContext).isNotEmpty()

    fun url(context: Context): String? = prefs(context).getString(K_URL, null)
    fun secret(context: Context): String? = prefs(context).getString(K_SECRET, null)

    /** Live updates are on: configured, and the server accepted this phone's current FCM token. */
    fun active(context: Context): Boolean {
        val p = prefs(context)
        val token = p.getString(K_TOKEN, null)
        return available(context) && url(context) != null && secret(context) != null &&
            token != null && token == p.getString(K_REGISTERED, null) && PhoneStore.get(context).account != null
    }

    fun statusJson(context: Context): JSONObject {
        val p = prefs(context)
        return JSONObject()
            .put("available", available(context))
            .put("url", url(context) ?: "")
            .put("hasSecret", secret(context) != null)
            .put("active", active(context))
            .put("error", p.getString(K_ERROR, null) ?: JSONObject.NULL)
            .put("lastMessageAt", p.getLong(K_LAST_MESSAGE, 0).takeIf { it > 0 } ?: JSONObject.NULL)
    }

    /** Saves the server settings and registers with it; a blank URL turns live updates off. */
    fun configure(context: Context, url: String, secret: String) {
        val oldUrl = url(context)
        val oldSecret = secret(context)
        val oldToken = prefs(context).getString(K_REGISTERED, null)
        val cleanUrl = url.trim().trimEnd('/').ifEmpty { null }
        val cleanSecret = secret.trim().ifEmpty { oldSecret.takeIf { cleanUrl != null } }
        if (oldUrl != null && oldSecret != null && oldToken != null && oldUrl != cleanUrl) {
            unregister(context, oldUrl, oldSecret, oldToken)
        }
        prefs(context).edit()
            .putString(K_URL, cleanUrl)
            .putString(K_SECRET, cleanSecret)
            .remove(K_REGISTERED)
            .remove(K_ERROR)
            .apply()
        changed(context)
        if (cleanUrl != null) {
            register(context)
        } else if (available(context)) {
            // Turned off: drop the FCM token too; a new one is made if live updates are set up again.
            prefs(context).edit().remove(K_TOKEN).apply()
            FirebaseMessaging.getInstance().deleteToken()
        }
    }

    /** Restores the server settings from the cloud backup. */
    fun restore(context: Context, url: String?, secret: String?) {
        if (url == null || secret == null || url(context) != null) return
        prefs(context).edit().putString(K_URL, url).putString(K_SECRET, secret).apply()
    }

    /** Registers this phone with the server (again) in the background, when live updates are set up. */
    fun register(context: Context) {
        if (!available(context) || url(context) == null) return
        val request = OneTimeWorkRequestBuilder<PushRegisterWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(REGISTER, ExistingWorkPolicy.REPLACE, request)
    }

    /** On app start and daily: registers when not registered yet, or re-registers weekly in case the server lost it. */
    fun ensureRegistered(context: Context) {
        val stale = System.currentTimeMillis() - prefs(context).getLong(K_REGISTERED_AT, 0) > REREGISTER_AFTER
        if (url(context) != null && (!active(context) || stale)) register(context)
    }

    /** Sign-out: tells the server to forget this phone. Keeps the server settings for the next sign-in. */
    fun signedOut(context: Context) {
        val url = url(context)
        val secret = secret(context)
        val token = prefs(context).getString(K_REGISTERED, null)
        if (url != null && secret != null && token != null) unregister(context, url, secret, token)
        prefs(context).edit().remove(K_REGISTERED).remove(K_ERROR).apply()
    }

    private fun unregister(context: Context, url: String, secret: String, token: String) {
        val request = OneTimeWorkRequestBuilder<PushUnregisterWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setInputData(workDataOf("url" to url, "secret" to secret, "token" to token))
            .build()
        WorkManager.getInstance(context).enqueue(request)
    }

    internal fun newToken(context: Context, token: String) {
        if (url(context) == null) return
        prefs(context).edit().putString(K_TOKEN, token).apply()
        register(context)
    }

    internal fun registered(context: Context, token: String) {
        prefs(context).edit()
            .putString(K_TOKEN, token)
            .putString(K_REGISTERED, token)
            .putLong(K_REGISTERED_AT, System.currentTimeMillis())
            .remove(K_ERROR)
            .apply()
        changed(context)
    }

    internal fun failed(context: Context, error: String) {
        prefs(context).edit().putString(K_ERROR, error).remove(K_REGISTERED).apply()
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

/** Sends this phone's FCM token and Toggl user id to the server. */
class PushRegisterWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val context = applicationContext
        val url = Push.url(context) ?: return Result.success()
        val secret = Push.secret(context) ?: return Result.success()
        val store = PhoneStore.get(context)
        val apiToken = store.token ?: return Result.success() // Registers again on sign-in.
        var account = store.account ?: return Result.success()
        return try {
            if (account.userId == 0L) {
                store.setUserId(TogglApi(apiToken, store::setQuota).userId())
                account = store.account ?: return Result.success()
            }
            val token = FirebaseMessaging.getInstance().token.await()
            val body = JSONObject()
                .put("token", token)
                .put("user_id", account.userId)
                .put("workspace_id", account.workspaceId)
                .put("name", "${Build.MANUFACTURER} ${Build.MODEL}")
            val request = Request.Builder()
                .url("$url/devices")
                .header("Authorization", "Bearer $secret")
                .post(body.toString().toRequestBody(Push.JSON))
                .build()
            Push.http.newCall(request).execute().use { response ->
                when {
                    response.isSuccessful -> {
                        Push.registered(context, token)
                        Result.success()
                    }
                    response.code == 401 -> {
                        Push.failed(context, "The server rejected the app secret")
                        Result.success()
                    }
                    response.code in 400..499 -> {
                        Push.failed(context, "The server answered ${response.code}; check the URL")
                        Result.success()
                    }
                    else -> {
                        Push.failed(context, "Server error ${response.code}, will retry")
                        Result.retry()
                    }
                }
            }
        } catch (e: IllegalArgumentException) {
            Push.failed(context, "Invalid server URL")
            Result.success()
        } catch (e: TogglException) {
            Push.failed(context, "Toggl error ${e.code}, will retry")
            Result.retry()
        } catch (e: IOException) {
            Push.failed(context, "Can't reach the server, will retry")
            Result.retry()
        } catch (e: Exception) {
            // Play services missing or Firebase not reachable.
            Push.failed(context, "Couldn't get a push token: ${e.message ?: e.javaClass.simpleName}")
            Result.retry()
        }
    }
}

/** Best effort: tells a server to forget a token (sign-out, URL changed). */
class PushUnregisterWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val url = inputData.getString("url") ?: return Result.success()
        val secret = inputData.getString("secret") ?: return Result.success()
        val token = inputData.getString("token") ?: return Result.success()
        return try {
            val request = Request.Builder()
                .url("$url/devices")
                .header("Authorization", "Bearer $secret")
                .delete(JSONObject().put("token", token).toString().toRequestBody(Push.JSON))
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
