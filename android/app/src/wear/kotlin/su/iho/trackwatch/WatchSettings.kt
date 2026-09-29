package su.iho.trackwatch

import android.content.Context

/** Watch-side settings, edited on the watch's Settings screen. */
object WatchSettings {
    /** Show the running-timer notification and Ongoing Activity icon. */
    const val ONGOING = "ongoing"

    /** Minutes per crown step in the start-time editor (1 or 5). */
    const val CROWN_STEP = "crownStep"

    /** Vibrate on actions (start, stop, save). */
    const val HAPTICS = "haptics"

    private val defaults = mapOf<String, Any>(ONGOING to true, CROWN_STEP to 1, HAPTICS to true)

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
        val edit = prefs(context).edit()
        when (value) {
            is Boolean -> edit.putBoolean(key, value)
            is Number -> edit.putInt(key, value.toInt())
            else -> return
        }
        edit.apply()
    }

    fun showOngoing(context: Context) = prefs(context).getBoolean(ONGOING, true)
}
