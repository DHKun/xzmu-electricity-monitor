package io.github.dhkun.xzmupower

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters

/** 后台定时查询电量, 低于阈值时告警 */
class QueryWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {

    override suspend fun doWork(): Result {
        val ctx = applicationContext
        if (!Prefs.configured(ctx)) return Result.success()

        val r = PowerApi.queryRoomState(ctx, Prefs.payProId(ctx), Prefs.roomVerify(ctx))
        Prefs.setLastCheck(ctx, System.currentTimeMillis())

        // 会话刷新(服务端可能通过 Set-Cookie 续期)
        r.setCookie?.let { Prefs.setCookieSnapshot(ctx, it) }

        when {
            r.sessionDead -> {
                Prefs.setAlerted(ctx, false)
                AlertNotify.info(ctx, "电费监控: 登录已过期",
                    "点击重新登录, 登录后选择房间即可恢复监控", openSetup = true)
            }
            r.ok && r.quantity != null -> {
                AlertEval.evaluate(ctx, r.quantity!!, r.unit)
            }
            else -> {
                // 网络错误等: 静默, 下个周期再试
            }
        }
        return Result.success()
    }

    companion object {
        const val PERIODIC = "periodic_query"
        const val HOURS = 6L
    }
}
