package su.iho.trackwatch

import android.Manifest
import android.app.RemoteInput
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.MotionEvent
import android.view.ViewConfiguration
import androidx.core.view.InputDeviceCompat
import androidx.core.view.ViewConfigurationCompat
import androidx.wear.input.RemoteInputIntentHelper
import su.iho.trackwatch.shared.ViewState
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Watch UI host. Channel protocol is mirrored in lib/wear/watch_bridge.dart. */
class MainActivity : FlutterActivity() {
    private val store by lazy { WatchStore.get(this) }
    private var stateListener: ((ViewState) -> Unit)? = null
    private var rotarySink: EventChannel.EventSink? = null
    private var pendingTextResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun onResume() {
        super.onResume()
        store.requestRefresh()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "trackwatch/watch").setMethodCallHandler { call, result ->
            fun entryId() = call.argument<String>("entryId")!!
            fun projectId() = call.argument<Number>("projectId")?.toLong()
            when (call.method) {
                "getState" -> result.success(store.view().toJson().toString())
                "start" -> {
                    store.start(call.argument<String>("description").orEmpty(), projectId())
                    result.success(null)
                }
                "stop" -> {
                    store.stop(entryId())
                    result.success(null)
                }
                "update" -> {
                    store.update(entryId(), call.argument<String>("description").orEmpty(), projectId())
                    result.success(null)
                }
                "delete" -> {
                    store.delete(entryId())
                    result.success(null)
                }
                "refresh" -> {
                    store.requestRefresh()
                    result.success(null)
                }
                "textInput" -> {
                    pendingTextResult?.success(null)
                    pendingTextResult = result
                    val remoteInput = RemoteInput.Builder(TEXT_KEY).setLabel(call.argument<String>("label") ?: "Description").build()
                    val intent = RemoteInputIntentHelper.createActionRemoteInputIntent()
                    RemoteInputIntentHelper.putRemoteInputsExtra(intent, listOf(remoteInput))
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, TEXT_REQUEST)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "trackwatch/watch/state").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val listener: (ViewState) -> Unit = { events.success(it.toJson().toString()) }
                stateListener = listener
                store.addListener(listener)
            }

            override fun onCancel(arguments: Any?) {
                stateListener?.let { store.removeListener(it) }
                stateListener = null
            }
        })

        EventChannel(messenger, "trackwatch/watch/rotary").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                rotarySink = events
            }

            override fun onCancel(arguments: Any?) {
                rotarySink = null
            }
        })
    }

    /** Forwards rotary crown / bezel scrolling to Flutter as pixel deltas. */
    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        val sink = rotarySink
        if (sink != null && event.action == MotionEvent.ACTION_SCROLL &&
            event.isFromSource(InputDeviceCompat.SOURCE_ROTARY_ENCODER)
        ) {
            val delta = -event.getAxisValue(MotionEvent.AXIS_SCROLL) *
                ViewConfigurationCompat.getScaledVerticalScrollFactor(ViewConfiguration.get(this), this)
            sink.success(delta.toDouble() / resources.displayMetrics.density)
            return true
        }
        return super.dispatchGenericMotionEvent(event)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != TEXT_REQUEST) return
        val text = data?.let { RemoteInput.getResultsFromIntent(it)?.getCharSequence(TEXT_KEY)?.toString() }
        pendingTextResult?.success(text)
        pendingTextResult = null
    }

    override fun onDestroy() {
        stateListener?.let { store.removeListener(it) }
        super.onDestroy()
    }

    private companion object {
        const val TEXT_KEY = "text"
        const val TEXT_REQUEST = 42
    }
}
