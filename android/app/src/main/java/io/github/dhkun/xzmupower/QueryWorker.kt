package io.github.dhkun.xzmupower

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

/** 后台定时查询电量; 会话过期时自行恢复, 不依赖页面 */
class QueryWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val widget = inputData.getBoolean(KEY_WIDGET, false)
        val trigger = if (widget) Trigger.WIDGET else Trigger.PERIODIC
        val report = PowerSync.sync(applicationContext, trigger, cancelled = { isStopped })
        // 临时故障让系统稍后再试几次, 用完次数就等下个周期; 实际间隔以持久退避为下限
        if (!widget && report.retry && runAttemptCount < MAX_RETRIES) Result.retry() else Result.success()
    }

    companion object {
        const val PERIODIC = "periodic_query"
        const val HOURS = 6L
        private const val KEY_WIDGET = "widget"
        private const val MAX_RETRIES = 3

        fun widgetInput() = workDataOf(KEY_WIDGET to true)

        /** UPDATE 不重置周期, 重复调用不会产生重复任务, 升级后也能换上新约束 */
        fun schedule(ctx: Context) {
            val request = PeriodicWorkRequestBuilder<QueryWorker>(HOURS, TimeUnit.HOURS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
                .build()
            WorkManager.getInstance(ctx)
                .enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.UPDATE, request)
        }
    }
}
