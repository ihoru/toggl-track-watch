package su.iho.trackwatch

import android.content.Context
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.DeleteBytesRequest
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import kotlinx.coroutines.tasks.await
import org.json.JSONArray
import org.json.JSONObject
import su.iho.trackwatch.shared.Favorite
import su.iho.trackwatch.shared.gunzip
import su.iho.trackwatch.shared.gzip
import su.iho.trackwatch.shared.objects

/**
 * Keeps the Toggl token, favorites and compact-view setting in Google Play services Block Store,
 * so they come back after reinstalling the app (and on a new phone when Google backup is on).
 * Stored end-to-end encrypted in the cloud when the device supports it (screen lock set),
 * otherwise only on this device. Readable only by an app with the same package and signing key.
 */
object CloudBackup {
    private const val KEY_PREFIX = "settings."
    private const val MAX_CHUNKS = 8
    private const val CHUNK_SIZE = 3800 // Block Store allows 4 KB per entry.

    data class Backup(val token: String?, val favorites: List<Favorite>, val compact: Boolean)

    /** Saves the current settings. Fire-and-forget; failures only mean there is no backup. */
    fun save(context: Context) {
        val app = context.applicationContext
        val store = PhoneStore.get(app)
        val json = JSONObject()
            .put("token", store.token ?: JSONObject.NULL)
            .put("favorites", JSONArray(store.favorites.map { it.toJson() }))
            .put("compact", app.getSharedPreferences("ui", Context.MODE_PRIVATE).getBoolean("compact", false))
        val chunks = gzip(json.toString()).toList().chunked(CHUNK_SIZE).map { it.toByteArray() }
        if (chunks.size > MAX_CHUNKS) return

        val client = Blockstore.getClient(app)
        client.isEndToEndEncryptionAvailable().addOnCompleteListener { e2ee ->
            val toCloud = e2ee.isSuccessful && e2ee.result == true
            chunks.forEachIndexed { i, bytes ->
                client.storeBytes(
                    StoreBytesData.Builder().setKey(KEY_PREFIX + i).setBytes(bytes).setShouldBackupToCloud(toCloud).build()
                )
            }
            val stale = (chunks.size until MAX_CHUNKS).map { KEY_PREFIX + it }
            if (stale.isNotEmpty()) client.deleteBytes(DeleteBytesRequest.Builder().setKeys(stale).build())
        }
    }

    /** Reads the saved settings, or null when there is no backup. */
    suspend fun load(context: Context): Backup? {
        val request = RetrieveBytesRequest.Builder().setRetrieveAll(true).build()
        val data = Blockstore.getClient(context).retrieveBytes(request).await().blockstoreDataMap
        val chunks = (0 until MAX_CHUNKS).map { data[KEY_PREFIX + it]?.bytes }.takeWhile { it != null }.filterNotNull()
        if (chunks.isEmpty()) return null
        val json = JSONObject(gunzip(chunks.reduce { a, b -> a + b }))
        return Backup(
            token = if (json.isNull("token")) null else json.getString("token"),
            favorites = json.optJSONArray("favorites").objects().map(Favorite::fromJson),
            compact = json.optBoolean("compact", false),
        )
    }
}
