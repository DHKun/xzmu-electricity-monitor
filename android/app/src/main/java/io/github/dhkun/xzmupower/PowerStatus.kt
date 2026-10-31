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

/** 某一天的用电量, used < 0 表示当天没有读数 */
data class DayUse(val label: String, val used: Float)

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
    /** 近 7 天每日用电, 最后一项是今天 */
    val week: List<DayUse>,
    val lastAt: Long,
    val needsLogin: Boolean,
    val threshold: Float,
)

object PowerStatus {

    fun load(ctx: Context): PowerView {
        val qty = Prefs.lastQty(ctx)
        val threshold = Prefs.threshold(ctx)
        val peak = max(max(Prefs.peakQty(ctx), qty), 1f)
        val samples = Prefs.samples(ctx)
        val daily = estimateDaily(samples)
        return PowerView(
            configured = Prefs.configured(ctx),
            qty = qty,
            room = Prefs.roomLabel(ctx),
            level = levelOf(qty, threshold),
            percent = if (qty < 0) 0 else min(100f, qty / peak * 100f).roundToInt(),
            dailyUse = daily,
            daysLeft = if (qty >= 0 && daily > 0.05f) floor(qty / daily).toInt() else -1,
            week = lastWeek(samples),
            lastAt = Prefs.lastCheck(ctx),
            needsLogin = Prefs.needsLogin(ctx),
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

    /** 近 7 天每日用电: 相邻读数的下降量归到后一读数所在的那天, 读数上涨(充值)不计 */
    fun lastWeek(samples: List<Pair<Long, Float>>): List<DayUse> {
        val names = arrayOf("周日", "周一", "周二", "周三", "周四", "周五", "周六")
        val today = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        return (6 downTo 0).map { k ->
            val day = (today.clone() as Calendar).apply { add(Calendar.DAY_OF_YEAR, -k) }
            val start = day.timeInMillis
            val end = (day.clone() as Calendar).apply { add(Calendar.DAY_OF_YEAR, 1) }.timeInMillis
            var used = 0f
            var seen = false
            for (i in 1 until samples.size) {
                if (samples[i].first in start until end) {
                    seen = true
                    used += max(0f, samples[i - 1].second - samples[i].second)
                }
            }
            DayUse(if (k == 0) "今天" else names[day.get(Calendar.DAY_OF_WEEK) - 1], if (seen) used else -1f)
        }
    }

    /** 预计用完的日期, 如 "11月10日" */
    fun runOutDate(daysLeft: Int): String =
        if (daysLeft < 0) "" else SimpleDateFormat("M月d日", Locale.CHINA)
            .format(Date(System.currentTimeMillis() + daysLeft * 86_400_000L))

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
