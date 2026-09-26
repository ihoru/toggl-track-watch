package com.ihoru.trackwatch

import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.wear.tiles.TileService
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import com.ihoru.trackwatch.shared.Command
import com.ihoru.trackwatch.shared.CommandFactory
import com.ihoru.trackwatch.shared.Paths
import com.ihoru.trackwatch.shared.Reducer
import com.ihoru.trackwatch.shared.ViewState
import com.ihoru.trackwatch.shared.objects
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The watch's local state: the last state published by the phone plus commands
 * the phone has not acknowledged yet. Commands are sent as DataItems, which the
 * Data Layer delivers whenever the phone becomes reachable.
 */
class WatchStore private constructor(private val context: Context) {
    private val stateFile = File(context.filesDir, "phone_state.json")
    private val pendingFile = File(context.filesDir, "pending.json")
    private val listeners = CopyOnWriteArrayList<(ViewState) -> Unit>()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var phoneState: ViewState = runCatching { ViewState.fromJson(JSONObject(stateFile.readText())) }.getOrDefault(ViewState())
    private var pending: List<Command> = runCatching { JSONArray(pendingFile.readText()).objects().map(Command::fromJson) }.getOrDefault(emptyList())

    @Volatile
    var phoneReachable: Boolean = true
        private set

    @Synchronized
    fun view(): ViewState {
        val ids = phoneState.idMap
        val mapped = pending.map { it.copy(entryId = ids[it.entryId] ?: it.entryId) }
        return phoneState.copy(
            entries = Reducer.apply(phoneState.entries, mapped),
            pendingCount = phoneState.pendingCount + pending.size,
            phoneReachable = phoneReachable,
        )
    }

    @Synchronized
    fun onPhoneState(state: ViewState) {
        phoneState = state
        stateFile.writeText(state.toJson().toString())
        val acked = state.acks.toSet()
        if (pending.any { it.id in acked }) setPending(pending.filterNot { it.id in acked })
        changed()
    }

    fun setPhoneReachable(reachable: Boolean) {
        if (phoneReachable == reachable) return
        phoneReachable = reachable
        changed()
    }

    private fun resolve(entryId: String) = phoneState.idMap[entryId] ?: entryId

    fun start(description: String, projectId: Long?) =
        dispatch(CommandFactory.start(view().entries, description, projectId, System.currentTimeMillis()))

    fun startFavorite(index: Int) {
        val favorite = view().favorites.getOrNull(index) ?: return
        start(favorite.description, favorite.projectId)
    }

    fun stop(entryId: String) = dispatch(listOf(CommandFactory.stop(resolve(entryId), System.currentTimeMillis())))

    fun stopRunning() {
        view().running?.let { stop(it.id) }
    }

    fun update(entryId: String, description: String, projectId: Long?) =
        dispatch(listOf(CommandFactory.update(resolve(entryId), description, projectId, System.currentTimeMillis())))

    fun delete(entryId: String) = dispatch(listOf(CommandFactory.delete(resolve(entryId), System.currentTimeMillis())))

    private fun dispatch(commands: List<Command>) {
        synchronized(this) { setPending(pending + commands) }
        val client = Wearable.getDataClient(context)
        for (cmd in commands) {
            val request = PutDataMapRequest.create(Paths.COMMAND_PREFIX + cmd.id).apply {
                dataMap.putString(Paths.KEY_PAYLOAD, cmd.toJson().toString())
            }.asPutDataRequest().setUrgent()
            client.putDataItem(request)
        }
        changed()
    }

    private fun setPending(list: List<Command>) {
        pending = list
        pendingFile.writeText(JSONArray(list.map { it.toJson() }).toString())
    }

    /** Asks the phone to refresh from Toggl. Also updates [phoneReachable]. */
    fun requestRefresh() {
        Wearable.getNodeClient(context).connectedNodes.addOnCompleteListener { task ->
            val nodes = if (task.isSuccessful) task.result.orEmpty() else emptyList()
            setPhoneReachable(nodes.isNotEmpty())
            val messages = Wearable.getMessageClient(context)
            nodes.forEach { messages.sendMessage(it.id, Paths.REFRESH, ByteArray(0)) }
        }
    }

    fun addListener(listener: (ViewState) -> Unit) = listeners.add(listener)
    fun removeListener(listener: (ViewState) -> Unit) = listeners.remove(listener)

    private fun changed() {
        val state = view()
        mainHandler.post { listeners.forEach { it(state) } }
        OngoingTimer.update(context, state)
        TileService.getUpdater(context).requestUpdate(TimerTileService::class.java)
        ComplicationDataSourceUpdateRequester
            .create(context, ComponentName(context, TimerComplicationService::class.java))
            .requestUpdateAll()
    }

    companion object {
        @Volatile
        private var instance: WatchStore? = null

        fun get(context: Context): WatchStore =
            instance ?: synchronized(this) { instance ?: WatchStore(context.applicationContext).also { instance = it } }
    }
}
