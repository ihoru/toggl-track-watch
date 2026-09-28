package su.iho.trackwatch

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import java.util.concurrent.TimeUnit

class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        if (inputData.getBoolean(KEY_REFRESH, false)) {
            PhoneStore.get(applicationContext).requestRefresh(force = inputData.getBoolean(KEY_FORCE, false))
        }
        return when (val outcome = SyncEngine(applicationContext).run()) {
            SyncOutcome.Done -> Result.success()
            SyncOutcome.Retry -> Result.retry()
            is SyncOutcome.RetryAt -> {
                Sync.later(applicationContext, outcome.atMillis - System.currentTimeMillis())
                Result.success()
            }
        }
    }

    companion object {
        const val KEY_REFRESH = "refresh"
        const val KEY_FORCE = "force"
    }
}

object Sync {
    private const val NOW = "sync"
    private const val LATER = "sync-later"
    private const val SOON = "sync-soon"
    private const val PERIODIC = "sync-periodic"

    private val network = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

    /** Runs a sync as soon as there is network. Queued behind a sync already running. */
    fun now(context: Context, refresh: Boolean = false) {
        val request = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(network)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .setInputData(workDataOf(SyncWorker.KEY_REFRESH to refresh))
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(NOW, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
    }

    /** Runs a sync after [delayMillis], e.g. once the Toggl API quota resets. */
    fun later(context: Context, delayMillis: Long) {
        val request = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(network)
            .setInitialDelay(delayMillis.coerceAtLeast(1_000), TimeUnit.MILLISECONDS)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(LATER, ExistingWorkPolicy.REPLACE, request)
    }

    /** Refreshes from Toggl after [delayMillis], skipping the refresh throttle (e.g. after the Toggl app started a timer). */
    fun refreshSoon(context: Context, delayMillis: Long) {
        val request = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(network)
            .setInitialDelay(delayMillis, TimeUnit.MILLISECONDS)
            .setInputData(workDataOf(SyncWorker.KEY_REFRESH to true, SyncWorker.KEY_FORCE to true))
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(SOON, ExistingWorkPolicy.REPLACE, request)
    }

    /** Refreshes from Toggl every 15 minutes (the Android minimum). */
    fun schedulePeriodic(context: Context) {
        val request = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
            .setConstraints(network)
            .setInputData(workDataOf(SyncWorker.KEY_REFRESH to true))
            .build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    fun cancelAll(context: Context) {
        WorkManager.getInstance(context).apply {
            cancelUniqueWork(NOW)
            cancelUniqueWork(LATER)
            cancelUniqueWork(SOON)
            cancelUniqueWork(PERIODIC)
        }
    }
}
