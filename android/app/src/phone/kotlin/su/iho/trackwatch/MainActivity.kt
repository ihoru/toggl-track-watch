package su.iho.trackwatch

import com.google.android.gms.wearable.Wearable
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
                            val account = withContext(Dispatchers.IO) { TogglApi(token).account() }
                            store.signIn(token, account)
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
