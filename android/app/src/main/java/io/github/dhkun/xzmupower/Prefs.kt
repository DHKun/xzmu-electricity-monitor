package io.github.dhkun.xzmupower

import android.content.Context

/** 绑定配置与状态, 存 SharedPreferences */
object Prefs {
    private const val FILE = "config"
    private const val MAX_SAMPLES = 120

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun configured(ctx: Context) = sp(ctx).getBoolean("configured", false)
    fun setConfigured(ctx: Context, v: Boolean) = sp(ctx).edit().putBoolean("configured", v).apply()

    fun payProId(ctx: Context) = sp(ctx).getString("payProId", "") ?: ""
    fun roomVerify(ctx: Context) = sp(ctx).getString("roomVerify", "") ?: ""
    fun roomLabel(ctx: Context) = sp(ctx).getString("roomLabel", "") ?: ""
    fun threshold(ctx: Context) = sp(ctx).getFloat("threshold", 20f)
    fun cookieSnapshot(ctx: Context) = sp(ctx).getString("cookieSnapshot", null)

    /** 绑定新房间: 读数历史与告警状态一并重置 */
    fun saveBinding(ctx: Context, payProId: String, roomVerify: String, roomLabel: String) {
        sp(ctx).edit()
            .putString("payProId", payProId)
            .putString("roomVerify", roomVerify)
            .putString("roomLabel", roomLabel)
            .putString("samples", "")
            .putFloat("peakQty", -1f)
            .putFloat("lastQty", -1f)
            .putBoolean("sessionDead", false)
            .putBoolean("alerted", false)
            .putBoolean("configured", true)
            .apply()
    }

    fun setThreshold(ctx: Context, v: Float) = sp(ctx).edit().putFloat("threshold", v).apply()
    fun setCookieSnapshot(ctx: Context, cookie: String?) {
        if (!cookie.isNullOrBlank()) sp(ctx).edit().putString("cookieSnapshot", cookie).apply()
    }

    fun alerted(ctx: Context) = sp(ctx).getBoolean("alerted", false)
    fun setAlerted(ctx: Context, v: Boolean) = sp(ctx).edit().putBoolean("alerted", v).apply()

    fun sessionDead(ctx: Context) = sp(ctx).getBoolean("sessionDead", false)
    fun setSessionDead(ctx: Context, v: Boolean) = sp(ctx).edit().putBoolean("sessionDead", v).apply()

    /** 最近一次成功查询的时间戳(ms), 0 表示从未成功 */
    fun lastCheck(ctx: Context): Long = sp(ctx).getLong("lastCheck", 0L)

    fun lastQty(ctx: Context): Float = sp(ctx).getFloat("lastQty", -1f)

    /** 上次充值后的最高读数, 作为进度环满格 */
    fun peakQty(ctx: Context): Float = sp(ctx).getFloat("peakQty", -1f)

    /** 读数历史 (时间戳 ms, 度), 只用于估算日均 */
    fun samples(ctx: Context): List<Pair<Long, Float>> =
        (sp(ctx).getString("samples", "") ?: "").split(',').mapNotNull { item ->
            val kv = item.split(':')
            val t = kv.getOrNull(0)?.toLongOrNull()
            val q = kv.getOrNull(1)?.toFloatOrNull()
            if (kv.size == 2 && t != null && q != null) t to q else null
        }

    /** 记录一次成功读数: 更新最新值、满格基准、历史采样 */
    fun recordReading(ctx: Context, qty: Float) {
        val now = System.currentTimeMillis()
        val peak = peakQty(ctx)
        val last = lastQty(ctx)
        val samples = samples(ctx).toMutableList()
        val prev = samples.lastOrNull()
        // 同一读数半小时内只记一次
        if (prev == null || prev.second != qty || now - prev.first > 30 * 60 * 1000L) {
            samples.add(now to qty)
        }
        sp(ctx).edit().apply {
            // 读数上涨视为充值, 满格基准跟着重置
            if (peak <= 0f || qty > peak || (last >= 0f && qty > last + 0.5f)) putFloat("peakQty", qty)
            putFloat("lastQty", qty)
            putLong("lastCheck", now)
            putBoolean("sessionDead", false)
            putString("samples", samples.takeLast(MAX_SAMPLES).joinToString(",") { "${it.first}:${it.second}" })
        }.apply()
    }
}
