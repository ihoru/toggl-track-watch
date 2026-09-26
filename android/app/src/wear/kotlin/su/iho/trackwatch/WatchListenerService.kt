package su.iho.trackwatch

import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.WearableListenerService
import su.iho.trackwatch.shared.Paths
import su.iho.trackwatch.shared.ViewState

/** Receives the state published by the phone, even when the watch app is closed. */
class WatchListenerService : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) {
        val state = events
            .filter { it.type == DataEvent.TYPE_CHANGED && it.dataItem.uri.path == Paths.STATE }
            .mapNotNull { event -> event.dataItem.data?.let { runCatching { ViewState.fromBytes(it) }.getOrNull() } }
            .lastOrNull() ?: return
        val store = WatchStore.get(this)
        store.setPhoneReachable(true)
        store.onPhoneState(state)
    }
}
