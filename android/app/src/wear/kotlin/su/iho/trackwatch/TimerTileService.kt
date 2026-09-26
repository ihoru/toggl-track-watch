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
import su.iho.trackwatch.shared.Favorite
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

        val favorites = state.favorites.take(if (running != null) 2 else 3)
        if (favorites.isEmpty() && running == null) {
            column.addContent(text("No favorites yet", Typography.TYPOGRAPHY_CAPTION1, GREY, 2))
        }
        favorites.forEachIndexed { index, favorite ->
            column.addContent(LayoutElementBuilders.Spacer.Builder().setHeight(dp(4f)).build())
            column.addContent(favoriteChip(state, index, favorite))
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

    private fun favoriteChip(state: ViewState, index: Int, favorite: Favorite): LayoutElementBuilders.LayoutElement {
        val background = projectColor(state, favorite.projectId)
        val content = if (ColorUtils.calculateLuminance(background) > 0.5) BLACK else WHITE
        val label = favorite.description.ifBlank { state.project(favorite.projectId)?.name ?: "(no description)" }
        return CompactChip.Builder(context, label.take(18), loadClickable(TimerTileService.ID_FAVORITE + index), device)
            .setChipColors(ChipColors(background, content))
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
