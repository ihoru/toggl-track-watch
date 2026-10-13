package su.iho.trackwatch

import android.content.Context
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import org.json.JSONObject
import su.iho.trackwatch.shared.Paths

/**
 * Watch-side settings, edited on the watch's Settings screen. The phone keeps a copy (and backs it
 * up with its own settings), so they come back after reinstalling the watch app.
 */
object WatchSettings {
    /** Show the running-timer notification and Ongoing Activity icon. */
    const val ONGOING = "ongoing"

    /** Minutes per crown step in the start-time editor (1 or 5). */
    const val CROWN_STEP = "crownStep"

    /** Vibrate on actions (start, stop, save). */
    const val HAPTICS = "haptics"

    /** Show favorites as small two-per-row buttons, like on the tile. */
    const val COMPACT_FAVORITES = "compactFavorites"

    private val defaults = mapOf<String, Any>(ONGOING to true, CROWN_STEP to 1, HAPTICS to true, COMPACT_FAVORITES to false)

    private fun prefs(context: Context) = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    fun all(context: Context): Map<String, Any> {
        val prefs = prefs(context)
        return defaults.mapValues { (key, default) ->
            when (default) {
                is Boolean -> prefs.getBoolean(key, default)
                is Int -> prefs.getInt(key, default)
                else -> default
            }
        }
    }

    fun set(context: Context, key: String, value: Any) {
        write(context, mapOf(key to value))
        sendToPhone(context)
    }

    private fun write(context: Context, values: Map<String, Any>) {
        val edit = prefs(context).edit()
        for ((key, value) in values) {
            val default = defaults[key]
            when {
                default is Boolean && value is Boolean -> edit.putBoolean(key, value)
                default is Int && value is Number -> edit.putInt(key, value.toInt())
            }
        }
        edit.apply()
    }

    /** Whether no setting was ever saved here, i.e. the app is freshly installed. */
    private fun isUnset(context: Context) = prefs(context).all.keys.none { it in defaults }

    /** Sends the settings to the phone. The Data Layer skips the update when nothing changed. */
    private fun sendToPhone(context: Context) {
        val request = PutDataMapRequest.create(Paths.WATCH_SETTINGS).apply {
            dataMap.putString(Paths.KEY_PAYLOAD, JSONObject(all(context)).toString())
        }.asPutDataRequest()
        Wearable.getDataClient(context).putDataItem(request)
    }

    /**
     * Called with the phone's copy of the settings: restores it when nothing was set here yet (a
     * fresh install), otherwise sends the watch's settings when the copy is missing or differs
     * (they were set before this existed, or the phone app was reinstalled).
     */
    fun reconcile(context: Context, phoneCopy: Map<String, Any>?) {
        if (isUnset(context)) {
            if (phoneCopy != null) write(context, phoneCopy)
        } else if (phoneCopy != all(context)) {
            sendToPhone(context)
        }
    }

    fun showOngoing(context: Context) = prefs(context).getBoolean(ONGOING, true)
}
