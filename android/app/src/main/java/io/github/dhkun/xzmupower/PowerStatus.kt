package io.github.dhkun.xzmupower

import android.content.Context
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

enum class PowerLevel(val text: String) {
    UNKNOWN("暂无数据"), OK("电量充足"), WARN("电量偏低"), LOW("电量不足")
}

/** 由存储推算出的展示状态 */
data class PowerView(
    val configured: Boolean,
    val qty: Float,
    val room: String,
    val level: PowerLevel,
    /** 相对上次充值后最高读数的百分比 0-100 */
    val percent: Int,
    /** 日均用电(度), <0 表示样本不足 */
    val dailyUse: Float,
    /** 预计可用天数, <0 表示无法估算 */
    val daysLeft: Int,
    val lastAt: Long,
    val sessionDead: Boolean,
    val threshold: Float,
)

object PowerStatus {

    fun load(ctx: Context): PowerView {
        val qty = Prefs.lastQty(ctx)
        val threshold = Prefs.threshold(ctx)
        val peak = max(max(Prefs.peakQty(ctx), qty), 1f)
        val daily = estimateDaily(Prefs.samples(ctx))
        return PowerView(
            configured = Prefs.configured(ctx),
            qty = qty,
            room = Prefs.roomLabel(ctx),
            level = levelOf(qty, threshold),
            percent = if (qty < 0) 0 else min(100f, qty / peak * 100f).roundToInt(),
            dailyUse = daily,
            daysLeft = if (qty >= 0 && daily > 0.05f) floor(qty / daily).toInt() else -1,
            lastAt = Prefs.lastCheck(ctx),
            sessionDead = Prefs.sessionDead(ctx),
            threshold = threshold,
        )
    }

    fun levelOf(qty: Float, threshold: Float) = when {
        qty < 0 -> PowerLevel.UNKNOWN
        qty < threshold -> PowerLevel.LOW
        qty < threshold * 2 -> PowerLevel.WARN
        else -> PowerLevel.OK
    }

    /** 只用最近一次充值之后的样本, 跨度不足 6 小时不估算 */
    fun estimateDaily(samples: List<Pair<Long, Float>>): Float {
        if (samples.size < 2) return -1f
        var start = 0
        for (i in 1 until samples.size) {
            if (samples[i].second > samples[i - 1].second + 0.5f) start = i
        }
        val first = samples[start]
        val last = samples.last()
        val hours = (last.first - first.first) / 3_600_000f
        val used = first.second - last.second
        if (hours < 6f || used <= 0f) return -1f
        return used / hours * 24f
    }

    fun fmtQty(v: Float): String = when {
        v < 0 -> "--"
        v == v.toLong().toFloat() -> v.toLong().toString()
        else -> String.format(Locale.CHINA, "%.1f", v)
    }

    /** "刚刚 / 12 分钟前 / 今天 08:30 / 10月24日 21:00" */
    fun fmtTime(at: Long): String {
        if (at <= 0) return "尚未查询"
        val diff = System.currentTimeMillis() - at
        if (diff < 60_000) return "刚刚更新"
        if (diff < 3_600_000) return "${diff / 60_000} 分钟前更新"
        val then = Calendar.getInstance().apply { timeInMillis = at }
        val now = Calendar.getInstance()
        val sameDay = then.get(Calendar.YEAR) == now.get(Calendar.YEAR) &&
                then.get(Calendar.DAY_OF_YEAR) == now.get(Calendar.DAY_OF_YEAR)
        val pattern = if (sameDay) "今天 HH:mm 更新" else "M月d日 HH:mm 更新"
        return SimpleDateFormat(pattern, Locale.CHINA).format(Date(at))
    }
}
