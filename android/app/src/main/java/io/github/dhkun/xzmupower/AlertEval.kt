package io.github.dhkun.xzmupower

import android.content.Context

/** 阈值评估: 手动查询、修改阈值、后台定时三条路径共用, 保证告警行为一致 */
object AlertEval {

    /** 用一次查询结果做阈值判断(仅在 ok 且 quantity 有效时调用); 读数由 Prefs.recordReading 落盘 */
    fun evaluate(ctx: Context, quantity: Double, unit: String) {
        val threshold = Prefs.threshold(ctx)
        if (quantity < threshold) {
            if (!Prefs.alerted(ctx)) {
                AlertNotify.alert(ctx,
                    "⚠️ 电费不足! ${Prefs.roomLabel(ctx)} 剩余 $quantity$unit",
                    "低于阈值 $threshold$unit, 请尽快充值")
                Prefs.setAlerted(ctx, true)
            }
        } else {
            if (Prefs.alerted(ctx)) {
                AlertNotify.info(ctx, "电费已恢复: $quantity$unit", "回到阈值以上")
            }
            Prefs.setAlerted(ctx, false)
        }
    }

    /** 阈值被修改后, 立即用最近一次电量重新评估(不发网络请求) */
    fun reevaluateWithLast(ctx: Context) {
        Prefs.lastQty(ctx).takeIf { it >= 0 }
            ?.let { evaluate(ctx, it.toDouble(), "度") }
    }
}
