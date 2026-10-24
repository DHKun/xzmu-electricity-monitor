package io.github.dhkun.xzmupower

import android.content.Context

/** 绑定配置与状态, 存 SharedPreferences */
object Prefs {
    private const val FILE = "config"

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun configured(ctx: Context) = sp(ctx).getBoolean("configured", false)
    fun setConfigured(ctx: Context, v: Boolean) = sp(ctx).edit().putBoolean("configured", v).apply()

    fun payProId(ctx: Context) = sp(ctx).getString("payProId", "") ?: ""
    fun roomVerify(ctx: Context) = sp(ctx).getString("roomVerify", "") ?: ""
    fun roomLabel(ctx: Context) = sp(ctx).getString("roomLabel", "") ?: ""
    fun threshold(ctx: Context) = sp(ctx).getFloat("threshold", 20f)
    fun cookieSnapshot(ctx: Context) = sp(ctx).getString("cookieSnapshot", null)

    fun saveBinding(ctx: Context, payProId: String, roomVerify: String, roomLabel: String) {
        sp(ctx).edit()
            .putString("payProId", payProId)
            .putString("roomVerify", roomVerify)
            .putString("roomLabel", roomLabel)
            .putBoolean("configured", true)
            .apply()
    }

    fun setThreshold(ctx: Context, v: Float) = sp(ctx).edit().putFloat("threshold", v).apply()
    fun setCookieSnapshot(ctx: Context, cookie: String?) {
        if (!cookie.isNullOrBlank()) sp(ctx).edit().putString("cookieSnapshot", cookie).apply()
    }

    fun alerted(ctx: Context) = sp(ctx).getBoolean("alerted", false)
    fun setAlerted(ctx: Context, v: Boolean) = sp(ctx).edit().putBoolean("alerted", v).apply()

    fun lastCheck(ctx: Context): Long = sp(ctx).getLong("lastCheck", 0L)
    fun setLastCheck(ctx: Context, t: Long) = sp(ctx).edit().putLong("lastCheck", t).apply()

    fun lastQty(ctx: Context): Float = sp(ctx).getFloat("lastQty", -1f)
    fun setLastQty(ctx: Context, v: Float) = sp(ctx).edit().putFloat("lastQty", v).apply()

    fun clearBinding(ctx: Context) = sp(ctx).edit().clear().apply()
}
