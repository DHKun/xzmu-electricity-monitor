package io.github.dhkun.xzmupower

import android.content.Context

/** 阈值评估: 手动查询、修改阈值、后台定时三条路径共用, 保证告警行为一致 */
object AlertEval {

    /**
     * 用一次查询结果做阈值判断(仅在 ok 且 quantity 有效时调用); 读数由 Prefs.recordReading 落盘。
     * 返回 true 表示低电量告警没能发出: 告警状态保持未发, 下次评估会再发。
     */
    fun evaluate(ctx: Context, quantity: Double, unit: String): Boolean {
        val threshold = Prefs.threshold(ctx)
        if (quantity < threshold) {
            if (Prefs.alerted(ctx)) return false
            val posted = AlertNotify.alert(ctx,
                "⚠️ 电费不足! ${Prefs.roomLabel(ctx)} 剩余 $quantity$unit",
                "低于阈值 $threshold$unit, 请尽快充值")
            if (posted) Prefs.setAlerted(ctx, true)
            return !posted
        }
        if (Prefs.alerted(ctx)) {
            AlertNotify.info(ctx, "电费已恢复: $quantity$unit", "回到阈值以上")
        }
        Prefs.setAlerted(ctx, false)
        return false
    }

    /** 阈值被修改后, 立即用最近一次电量重新评估(不发网络请求) */
    fun reevaluateWithLast(ctx: Context) {
        Prefs.lastQty(ctx).takeIf { it >= 0 }
            ?.let { evaluate(ctx, it.toDouble(), "度") }
    }
}
