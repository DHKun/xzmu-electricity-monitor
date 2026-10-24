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

    /** 跟随壁纸取色(Material You), 默认关闭用固定色板 */
    fun dynamicColor(ctx: Context) = sp(ctx).getBoolean("dynamicColor", false)
    fun setDynamicColor(ctx: Context, v: Boolean) = sp(ctx).edit().putBoolean("dynamicColor", v).apply()

    /** 调试构建专用: 写入一套示例数据, 便于在模拟器上不登录就查看已绑定界面 */
    fun seedDemo(ctx: Context) {
        val now = System.currentTimeMillis()
        // 近 7 天每 6 小时一个读数, 中间有一次充值
        val qtys = floatArrayOf(62f, 59f, 55f, 52f, 49f, 46f, 42f, 38f, 300f, 297f, 293f, 289f, 286f, 282f,
            277f, 273f, 270f, 266f, 262f, 259f, 256f, 252f, 248f, 244f)
        val samples = qtys.indices.joinToString(",") { i ->
            "${now - (qtys.size - 1 - i) * 6 * 3_600_000L}:${qtys[i]}"
        }
        sp(ctx).edit()
            .putBoolean("configured", true)
            .putString("payProId", "3148")
            .putString("roomVerify", "101-1--9-902")
            .putString("roomLabel", "902房间")
            .putString("cookieSnapshot", "SESSION=demo")
            .putFloat("threshold", 20f)
            .putFloat("lastQty", 244f)
            .putFloat("peakQty", 300f)
            .putLong("lastCheck", now)
            .putBoolean("sessionDead", false)
            .putString("samples", samples)
            .apply()
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
