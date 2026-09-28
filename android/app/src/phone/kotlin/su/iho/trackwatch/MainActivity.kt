package su.iho.trackwatch

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import com.google.android.gms.wearable.Wearable
import su.iho.trackwatch.shared.CommandFactory
import su.iho.trackwatch.shared.Favorite
import su.iho.trackwatch.shared.ViewState
import su.iho.trackwatch.shared.objects
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject

/** Phone settings UI host. Channel protocol is mirrored in lib/phone/phone_bridge.dart. */
class MainActivity : FlutterActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val store by lazy { PhoneStore.get(this) }
    private val uiPrefs by lazy { getSharedPreferences("ui", MODE_PRIVATE) }
    private var stateListener: ((ViewState) -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "trackwatch/phone").setMethodCallHandler { call, result ->
            when (call.method) {
                "getState" -> result.success(stateJson(store.viewState()))
                "setToken" -> {
                    val token = call.argument<String>("token")?.trim().orEmpty()
                    scope.launch {
                        try {
                            var quota: Pair<Int, Long>? = null
                            val api = TogglApi(token) { remaining, resetsAt -> quota = remaining to resetsAt }
                            val account = withContext(Dispatchers.IO) { api.account() }
                            store.signIn(token, account)
                            quota?.let { (remaining, resetsAt) -> store.setQuota(remaining, resetsAt) }
                            Sync.schedulePeriodic(this@MainActivity)
                            Sync.now(this@MainActivity, refresh = true)
                            result.success(stateJson(store.viewState()))
                        } catch (e: TogglException) {
                            result.error("toggl", if (e.code == 401 || e.code == 403) "Invalid API token" else "Toggl error ${e.code}", null)
                        } catch (e: Exception) {
                            result.error("network", "Could not reach Toggl: ${e.message}", null)
                        }
                    }
                }
                "signOut" -> {
                    Sync.cancelAll(this)
                    store.signOut()
                    result.success(null)
                }
                "setFavorites" -> {
                    val json = call.argument<String>("favorites") ?: "[]"
                    store.setFavorites(JSONArray(json).objects().map(Favorite::fromJson))
                    result.success(null)
                }
                "syncNow" -> {
                    Sync.now(this, refresh = true)
                    result.success(null)
                }
                "startTimer" -> {
                    val description = call.argument<String>("description").orEmpty()
                    val projectId = call.argument<Number>("projectId")?.toLong()
                    result.success(startTimer(description, projectId))
                }
                "getCompact" -> result.success(uiPrefs.getBoolean("compact", false))
                "setCompact" -> {
                    uiPrefs.edit().putBoolean("compact", call.argument<Boolean>("compact") == true).apply()
                    result.success(null)
                }
                "watchConnected" -> scope.launch {
                    val nodes = withTimeoutOrNull(3_000) {
                        runCatching { Wearable.getNodeClient(this@MainActivity).connectedNodes.await() }.getOrNull()
                    }
                    result.success(nodes?.isNotEmpty() == true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "trackwatch/phone/state").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val listener: (ViewState) -> Unit = { events.success(stateJson(it)) }
                stateListener = listener
                store.addListener(listener)
            }

            override fun onCancel(arguments: Any?) {
                stateListener?.let { store.removeListener(it) }
                stateListener = null
            }
        })

        if (store.token != null) {
            Sync.schedulePeriodic(this)
            Sync.now(this, refresh = true)
        }
    }

    /**
     * Starts a timer in the official Toggl app via its start link. When no installed app handles the
     * link, starts it through our own queue instead (same path as the watch). Returns "toggl" or "api".
     */
    private fun startTimer(description: String, projectId: Long?): String {
        val workspaceId = store.account?.workspaceId
        if (workspaceId != null) {
            val uri = Uri.Builder()
                .scheme("toggl")
                .authority("tracker")
                .path("/timeEntry/start")
                .appendQueryParameter("workspaceId", workspaceId.toString())
                .appendQueryParameter("description", description)
                .apply { if (projectId != null) appendQueryParameter("projectId", projectId.toString()) }
                .build()
            val intent = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (packageManager.resolveActivity(intent, 0) != null) {
                try {
                    startActivity(intent)
                    return "toggl"
                } catch (e: ActivityNotFoundException) {
                    // Fall through to our own API.
                }
            }
        }
        store.enqueue(CommandFactory.start(store.viewState().entries, description, projectId, System.currentTimeMillis()))
        Sync.now(this)
        return "api"
    }

    private fun stateJson(state: ViewState): String {
        val account = store.account
        return JSONObject()
            .put("state", state.toJson())
            .put("account", account?.let {
                JSONObject().put("name", it.name).put("email", it.email).put("workspace", it.workspaceName)
            } ?: JSONObject.NULL)
            .toString()
    }

    override fun onDestroy() {
        stateListener?.let { store.removeListener(it) }
        scope.cancel()
        super.onDestroy()
    }
}
