package io.github.dhkun.xzmupower

import android.content.Context

/** 查询并把结果落到所有地方: 读数历史、Cookie 快照、低电量告警. 手动查询与后台任务共用 */
object PowerSync {

    /** 阻塞, 需在工作线程调用 */
    fun sync(ctx: Context): PowerApi.Result {
        val cookie = PowerApi.sessionCookie(ctx)
        val r = PowerApi.queryRoomState(ctx, Prefs.payProId(ctx), Prefs.roomVerify(ctx))
        when {
            r.ok && r.quantity != null -> {
                Prefs.setCookieSnapshot(ctx, mergeSession(cookie ?: "", r.setCookie))
                Prefs.recordReading(ctx, r.quantity.toFloat())
                AlertEval.evaluate(ctx, r.quantity, r.unit)
            }
            r.sessionDead -> {
                // 只在刚失效时提醒一次, 不每个周期重复打扰
                if (!Prefs.sessionDead(ctx)) {
                    AlertNotify.info(ctx, "电费监控: 登录已过期",
                        "点击重新登录, 登录后选择房间即可恢复监控", openSetup = true)
                }
                Prefs.setSessionDead(ctx, true)
            }
        }
        return r
    }

    /** 服务端轮换 SESSION 时, 把新值合并进原 Cookie 串 */
    fun mergeSession(cookie: String, setCookie: String?): String {
        val fresh = setCookie?.let { Regex("SESSION=([^;,\\s]+)").find(it) }?.let { "SESSION=${it.groupValues[1]}" }
            ?: return cookie
        return when {
            cookie.isBlank() -> fresh
            "SESSION=" in cookie -> cookie.replace(Regex("SESSION=[^;]*"), fresh)
            else -> "$cookie; $fresh"
        }
    }
}
