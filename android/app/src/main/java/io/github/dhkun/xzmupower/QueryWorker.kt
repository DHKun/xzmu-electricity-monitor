package io.github.dhkun.xzmupower

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters

/** 后台定时查询电量, 低于阈值时告警 */
class QueryWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {

    override suspend fun doWork(): Result {
        val ctx = applicationContext
        if (!Prefs.configured(ctx)) return Result.success()
        // 网络错误等静默, 下个周期再试
        PowerSync.sync(ctx)
        return Result.success()
    }

    companion object {
        const val PERIODIC = "periodic_query"
        const val HOURS = 6L
    }
}
