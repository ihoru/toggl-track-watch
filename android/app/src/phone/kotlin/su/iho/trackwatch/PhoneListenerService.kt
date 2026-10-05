package su.iho.trackwatch

import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import su.iho.trackwatch.shared.Paths

/** Receives commands and refresh requests from the watch, even when the app is closed. */
class PhoneListenerService : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) {
        val items = events.filter { it.type == DataEvent.TYPE_CHANGED }.map { it.dataItem.freeze() }
        if (items.isEmpty()) return
        SyncEngine.ingest(this, items)
        Sync.now(this)
    }

    override fun onMessageReceived(event: MessageEvent) {
        if (event.path == Paths.REFRESH) {
            // Re-publish right away so a freshly opened watch app has data, then refresh from Toggl.
            val store = PhoneStore.get(this)
            store.watchActive()
            store.changed()
            Sync.now(this, refresh = true)
        }
    }
}
