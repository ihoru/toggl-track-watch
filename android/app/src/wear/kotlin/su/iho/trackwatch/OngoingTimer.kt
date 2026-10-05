package su.iho.trackwatch

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.wear.ongoing.OngoingActivity
import androidx.wear.ongoing.Status
import su.iho.trackwatch.shared.ViewState
import java.text.DateFormat
import java.util.Date

/** Shows an Ongoing Activity (watch-face icon + notification with Stop) while a timer runs. */
object OngoingTimer {
    private const val CHANNEL = "timer"
    private const val NOTIFICATION_ID = 1
    private const val EXTRA_KEY = "su.iho.trackwatch.key"
    private var shownKey: String? = null

    /** Re-applies the notification after the setting changed. */
    @Synchronized
    fun refresh(context: Context, state: ViewState) {
        shownKey = null
        update(context, state)
    }

    @Synchronized
    fun update(context: Context, state: ViewState) {
        val manager = NotificationManagerCompat.from(context)
        val running = state.running
        if (running == null || !WatchSettings.showOngoing(context)) {
            manager.cancel(NOTIFICATION_ID)
            shownKey = null
            return
        }
        val granted = Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (!granted) return
        val title = running.description.ifBlank { "(no description)" }
        val key = "$title|${running.start}|${running.projectId}|${state.project(running.projectId)?.name}"
        if (shownKey == key) return
        // After the process restarts (e.g. woken by a phone update), keep a notification that is already right:
        // re-posting it makes the watch face indicator flash.
        val shown = context.getSystemService(NotificationManager::class.java).activeNotifications
            .firstOrNull { it.id == NOTIFICATION_ID }?.notification?.extras?.getString(EXTRA_KEY)
        shownKey = key
        if (shown == key) return

        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Running timer", NotificationManager.IMPORTANCE_LOW)
        )
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getBroadcast(
            context, 1, Intent(context, StopTimerReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val project = state.project(running.projectId)?.name
        val builder = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_timer)
            .setContentTitle(title)
            .setContentText(project ?: "No project")
            .setCategory(NotificationCompat.CATEGORY_STOPWATCH)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setUsesChronometer(true)
            .setWhen(running.start)
            .setContentIntent(open)
            .addAction(R.drawable.ic_stop, "Stop", stop)
            .addExtras(Bundle().apply { putString(EXTRA_KEY, key) })

        // A static status: a running stopwatch here is redrawn every second wherever the system
        // shows the ongoing activity, which flickers and keeps the screen busy.
        val since = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(running.start))
        val status = Status.Builder()
            .addTemplate("#title# · #since#")
            .addPart("title", Status.TextPart(title))
            .addPart("since", Status.TextPart("since $since"))
            .build()
        OngoingActivity.Builder(context, NOTIFICATION_ID, builder)
            .setStaticIcon(R.drawable.ic_timer)
            .setTouchIntent(open)
            .setStatus(status)
            .build()
            .apply(context)
        manager.notify(NOTIFICATION_ID, builder.build())
    }
}

/** Handles the notification's Stop action. */
class StopTimerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        WatchStore.get(context).stopRunning()
    }
}
