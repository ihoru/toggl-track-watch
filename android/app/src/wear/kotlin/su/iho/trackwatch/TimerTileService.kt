package su.iho.trackwatch

import android.content.Context
import androidx.core.graphics.ColorUtils
import androidx.wear.protolayout.ActionBuilders
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DeviceParametersBuilders.DeviceParameters
import androidx.wear.protolayout.DimensionBuilders.dp
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ModifiersBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.protolayout.material.ChipColors
import androidx.wear.protolayout.material.Colors
import androidx.wear.protolayout.material.CompactChip
import androidx.wear.protolayout.material.Text
import androidx.wear.protolayout.material.Typography
import androidx.wear.protolayout.material.layouts.PrimaryLayout
import androidx.wear.tiles.EventBuilders
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import su.iho.trackwatch.shared.ViewState
import java.text.DateFormat
import java.util.Date

/** Tile: the running timer with a Stop button, and favorites as one-tap start buttons. */
class TimerTileService : TileService() {
    override fun onTileRequest(requestParams: RequestBuilders.TileRequest): ListenableFuture<TileBuilders.Tile> {
        val store = WatchStore.get(this)
        val clicked = requestParams.currentState.lastClickableId
        when {
            clicked == ID_STOP -> store.stopRunning()
            clicked.startsWith(ID_FAVORITE) -> clicked.removePrefix(ID_FAVORITE).toIntOrNull()?.let(store::startFavorite)
            clicked.startsWith(ID_FREQUENT) -> clicked.removePrefix(ID_FREQUENT).toIntOrNull()?.let(store::startFrequent)
        }
        val tile = TileBuilders.Tile.Builder()
            .setResourcesVersion(RESOURCES_VERSION)
            .setFreshnessIntervalMillis(60_000)
            .setTileTimeline(
                TimelineBuilders.Timeline.fromLayoutElement(TileLayout(this, requestParams.deviceConfiguration).build(store.view()))
            )
            .build()
        return Futures.immediateFuture(tile)
    }

    override fun onTileResourcesRequest(requestParams: RequestBuilders.ResourcesRequest): ListenableFuture<ResourceBuilders.Resources> =
        Futures.immediateFuture(ResourceBuilders.Resources.Builder().setVersion(RESOURCES_VERSION).build())

    override fun onTileEnterEvent(requestParams: EventBuilders.TileEnterEvent) {
        WatchStore.get(this).requestRefresh()
    }

    companion object {
        const val ID_STOP = "stop"
        const val ID_FAVORITE = "fav:"
        const val ID_FREQUENT = "freq:"
        private const val RESOURCES_VERSION = "1"
    }
}

private class TileLayout(private val context: Context, private val device: DeviceParameters) {
    fun build(state: ViewState): LayoutElementBuilders.LayoutElement {
        val running = state.running
        val column = LayoutElementBuilders.Column.Builder()
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)

        if (!state.configured) {
            column.addContent(text("Set up Track Watch on your phone", Typography.TYPOGRAPHY_CAPTION1, GREY, 3))
            return PrimaryLayout.Builder(device).setContent(column.build()).setPrimaryChipContent(openChip()).build()
        }

        if (running != null) {
            val color = projectColor(state, running.projectId)
            column.addContent(text(running.description.ifBlank { "(no description)" }, Typography.TYPOGRAPHY_TITLE3, color, 1))
            val project = state.project(running.projectId)?.name
            val since = "since " + DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(running.start))
            column.addContent(text(listOfNotNull(project, since).joinToString(" · "), Typography.TYPOGRAPHY_CAPTION2, GREY, 1))
        }

        val slots = slots(state, if (running != null) 4 else 6)
        if (slots.isEmpty() && running == null) {
            column.addContent(text("No favorites yet", Typography.TYPOGRAPHY_CAPTION1, GREY, 2))
        }
        slots.chunked(2).forEach { pair ->
            column.addContent(LayoutElementBuilders.Spacer.Builder().setHeight(dp(4f)).build())
            val row = LayoutElementBuilders.Row.Builder()
            pair.forEachIndexed { i, slot ->
                if (i > 0) row.addContent(LayoutElementBuilders.Spacer.Builder().setWidth(dp(4f)).build())
                row.addContent(slotButton(state, slot))
            }
            column.addContent(row.build())
        }

        val primary = if (running != null) {
            CompactChip.Builder(context, "Stop", loadClickable(TimerTileService.ID_STOP), device)
                .setChipColors(ChipColors(RED, WHITE))
                .build()
        } else {
            openChip()
        }
        return PrimaryLayout.Builder(device).setContent(column.build()).setPrimaryChipContent(primary).build()
    }

    /** A timer on the tile: favorites first, then frequent timers that are not favorites. */
    private data class Slot(val label: String, val projectId: Long?, val clickId: String)

    private fun slots(state: ViewState, count: Int): List<Slot> {
        fun label(description: String, projectId: Long?) =
            description.ifBlank { state.project(projectId)?.name ?: "(none)" }
        val favorites = state.favorites.mapIndexed { i, f ->
            Slot(label(f.description, f.projectId), f.projectId, TimerTileService.ID_FAVORITE + i)
        }
        val frequent = state.frequent.mapIndexedNotNull { i, f ->
            if (state.favorites.any { it.description == f.description && it.projectId == f.projectId }) null
            else Slot(label(f.description, f.projectId), f.projectId, TimerTileService.ID_FREQUENT + i)
        }
        return (favorites + frequent).take(count)
    }

    /** A small rounded button in the project's color; two fit side by side. */
    private fun slotButton(state: ViewState, slot: Slot): LayoutElementBuilders.LayoutElement {
        val background = projectColor(state, slot.projectId)
        val content = if (ColorUtils.calculateLuminance(background) > 0.5) BLACK else WHITE
        val width = (device.screenWidthDp * 0.36f).coerceIn(64f, 96f)
        val maxChars = (width / 8.5f).toInt()
        val label = if (slot.label.length > maxChars) slot.label.take(maxChars - 1).trimEnd() + "…" else slot.label
        return LayoutElementBuilders.Box.Builder()
            .setWidth(dp(width))
            .setHeight(dp(30f))
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
            .setModifiers(
                ModifiersBuilders.Modifiers.Builder()
                    .setClickable(loadClickable(slot.clickId))
                    .setBackground(
                        ModifiersBuilders.Background.Builder()
                            .setColor(argb(background))
                            .setCorner(ModifiersBuilders.Corner.Builder().setRadius(dp(15f)).build())
                            .build()
                    )
                    .build()
            )
            .addContent(text(label, Typography.TYPOGRAPHY_CAPTION2, content, 1))
            .build()
    }

    private fun openChip() = CompactChip.Builder(context, "Open", launchClickable(), device)
        .setChipColors(ChipColors.primaryChipColors(Colors.DEFAULT))
        .build()

    private fun text(value: String, typography: Int, color: Int, maxLines: Int) = Text.Builder(context, value)
        .setTypography(typography)
        .setColor(argb(color))
        .setMaxLines(maxLines)
        .setOverflow(LayoutElementBuilders.TEXT_OVERFLOW_ELLIPSIZE_END)
        .build()

    private fun loadClickable(id: String) = ModifiersBuilders.Clickable.Builder()
        .setId(id)
        .setOnClick(ActionBuilders.LoadAction.Builder().build())
        .build()

    private fun launchClickable() = ModifiersBuilders.Clickable.Builder()
        .setId("open")
        .setOnClick(
            ActionBuilders.LaunchAction.Builder()
                .setAndroidActivity(
                    ActionBuilders.AndroidActivity.Builder()
                        .setPackageName(context.packageName)
                        .setClassName(MainActivity::class.java.name)
                        .build()
                )
                .build()
        )
        .build()

    private fun projectColor(state: ViewState, projectId: Long?): Int = parseColor(state.project(projectId)?.color)

    companion object {
        const val GREY = 0xFFBDBDBD.toInt()
        const val RED = 0xFFE57373.toInt()
        const val WHITE = 0xFFFFFFFF.toInt()
        const val BLACK = 0xFF000000.toInt()
        const val NO_PROJECT = 0xFF9E9E9E.toInt()

        fun parseColor(hex: String?): Int =
            hex?.let { runCatching { android.graphics.Color.parseColor(it) }.getOrNull() } ?: NO_PROJECT
    }
}
