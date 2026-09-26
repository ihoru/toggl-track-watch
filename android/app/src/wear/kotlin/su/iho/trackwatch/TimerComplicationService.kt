package su.iho.trackwatch

import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.CountUpTimeReference
import androidx.wear.watchface.complications.data.MonochromaticImage
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.ShortTextComplicationData
import androidx.wear.watchface.complications.data.TimeDifferenceComplicationText
import androidx.wear.watchface.complications.data.TimeDifferenceStyle
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import androidx.wear.watchface.complications.datasource.SuspendingComplicationDataSourceService
import su.iho.trackwatch.shared.TimeEntry
import java.time.Instant
import java.util.concurrent.TimeUnit

/** Short-text complication: elapsed time of the running entry, "—" when idle. */
class TimerComplicationService : SuspendingComplicationDataSourceService() {
    override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? {
        if (request.complicationType != ComplicationType.SHORT_TEXT) return null
        return build(WatchStore.get(this).view().running)
    }

    override fun getPreviewData(type: ComplicationType): ComplicationData? {
        if (type != ComplicationType.SHORT_TEXT) return null
        return build(TimeEntry("preview", "Work", null, System.currentTimeMillis() - 84 * 60_000, null), tap = false)
    }

    private fun build(running: TimeEntry?, tap: Boolean = true): ComplicationData {
        val icon = MonochromaticImage.Builder(Icon.createWithResource(this, R.drawable.ic_timer)).build()
        val builder = if (running != null) {
            val text = TimeDifferenceComplicationText.Builder(
                TimeDifferenceStyle.STOPWATCH,
                CountUpTimeReference(Instant.ofEpochMilli(running.start)),
            ).setMinimumTimeUnit(TimeUnit.MINUTES).build()
            val description = running.description.ifBlank { "Timer" }
            ShortTextComplicationData.Builder(text, PlainComplicationText.Builder("$description running").build())
                .setTitle(PlainComplicationText.Builder(description.take(7)).build())
        } else {
            ShortTextComplicationData.Builder(
                PlainComplicationText.Builder("—").build(),
                PlainComplicationText.Builder("No timer running").build(),
            )
        }
        builder.setMonochromaticImage(icon)
        if (tap) {
            val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            builder.setTapAction(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        }
        return builder.build()
    }
}
