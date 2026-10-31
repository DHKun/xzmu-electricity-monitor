package io.github.dhkun.xzmupower

import android.content.Context
import android.content.SharedPreferences
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 绑定配置与状态, 存 SharedPreferences */
object Prefs {
    private const val FILE = "config"
    private const val MAX_SAMPLES = 120
    private const val MAX_RUNS = 30

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun configured(ctx: Context) = sp(ctx).getBoolean("configured", false)
    fun setConfigured(ctx: Context, v: Boolean) = sp(ctx).edit().putBoolean("configured", v).apply()

    fun payProId(ctx: Context) = sp(ctx).getString("payProId", "") ?: ""
    fun roomVerify(ctx: Context) = sp(ctx).getString("roomVerify", "") ?: ""
    fun roomLabel(ctx: Context) = sp(ctx).getString("roomLabel", "") ?: ""
    fun threshold(ctx: Context) = sp(ctx).getFloat("threshold", 20f)
    /** 旧版的 Cookie 快照, 现在只用于升级时迁移 */
    fun cookieSnapshot(ctx: Context) = sp(ctx).getString("cookieSnapshot", null)

    /** 绑定新房间: 读数历史、告警与恢复状态一并重置 */
    @Synchronized
    fun saveBinding(ctx: Context, payProId: String, roomVerify: String, roomLabel: String) {
        sp(ctx).edit()
            .putString("payProId", payProId)
            .putString("roomVerify", roomVerify)
            .putString("roomLabel", roomLabel)
            .putString("samples", "")
            .putFloat("peakQty", -1f)
            .putFloat("lastQty", -1f)
            .putBoolean("alerted", false)
            .putBoolean("configured", true)
            .putInt("bindingGen", bindingGen(ctx) + 1)
            .apply { putRecovery(this, RecoveryState()) }
            .putBoolean("manualAlerted", false)
            .apply()
    }

    fun setThreshold(ctx: Context, v: Float) = sp(ctx).edit().putFloat("threshold", v).apply()

    fun alerted(ctx: Context) = sp(ctx).getBoolean("alerted", false)
    fun setAlerted(ctx: Context, v: Boolean) = sp(ctx).edit().putBoolean("alerted", v).apply()

    /** 自动恢复已无能为力, 需要用户手动登录 */
    fun needsLogin(ctx: Context) = sp(ctx).getBoolean("needsLogin", false)
    fun manualAlerted(ctx: Context) = sp(ctx).getBoolean("manualAlerted", false)
    fun setManualAlerted(ctx: Context, v: Boolean) = sp(ctx).edit().putBoolean("manualAlerted", v).apply()

    private fun bindingGen(ctx: Context) = sp(ctx).getInt("bindingGen", 0)
    private fun sessionGen(ctx: Context) = sp(ctx).getInt("sessionGen", 0)

    /** 持久 Cookie, null 表示尚未从旧版迁移 */
    fun cookieJar(ctx: Context): String? = sp(ctx).getString("cookieJar", null)

    @Synchronized
    fun seedCookieJar(ctx: Context, cookies: String) {
        if (cookieJar(ctx) == null) sp(ctx).edit().putString("cookieJar", cookies).apply()
    }

    /** 新的交互登录生效: 更新会话代次, 让进行中的同步作废, 并解除认证退避 */
    @Synchronized
    fun replaceSession(ctx: Context, cookies: String) {
        val e = sp(ctx).edit().putString("cookieJar", cookies).putInt("sessionGen", sessionGen(ctx) + 1)
        putRecovery(e, recovery(ctx).copy(failCount = 0, nextAttemptAt = 0L, authBackoff = false))
        e.apply()
    }

    /** 登录凭据变了: 进行中的认证结果不得再写回 */
    @Synchronized
    fun bumpSessionGen(ctx: Context) {
        sp(ctx).edit().putInt("sessionGen", sessionGen(ctx) + 1).apply()
    }

    private fun recovery(ctx: Context): RecoveryState {
        val s = sp(ctx)
        return RecoveryState(
            failCount = s.getInt("failCount", 0),
            nextAttemptAt = s.getLong("nextAttemptAt", 0L),
            authBackoff = s.getBoolean("authBackoff", false),
            needsLogin = s.getBoolean("needsLogin", false),
            lastOutcome = s.getString("lastOutcome", null)
                ?.let { name -> Outcome.entries.firstOrNull { it.name == name } },
        )
    }

    private fun putRecovery(e: SharedPreferences.Editor, r: RecoveryState) {
        e.putInt("failCount", r.failCount)
            .putLong("nextAttemptAt", r.nextAttemptAt)
            .putBoolean("authBackoff", r.authBackoff)
            .putBoolean("needsLogin", r.needsLogin)
            .putString("lastOutcome", r.lastOutcome?.name)
    }

    fun syncSnapshot(ctx: Context) = SyncSnapshot(
        bindingGen(ctx), sessionGen(ctx), payProId(ctx), roomVerify(ctx), cookieJar(ctx).orEmpty(), recovery(ctx))

    /** 一轮同步的结果一次性原子落盘; 期间绑定或会话变过就整体放弃 */
    @Synchronized
    fun commitSync(ctx: Context, base: SyncSnapshot, c: SyncCommit): Boolean {
        if (!configured(ctx) || bindingGen(ctx) != base.bindingGen || sessionGen(ctx) != base.sessionGen) return false
        val e = sp(ctx).edit()
        putRecovery(e, c.state)
        if (!c.state.needsLogin) e.putBoolean("manualAlerted", false)
        c.cookies?.let { e.putString("cookieJar", it) }
        c.quantity?.let { applyReading(ctx, e, it.toFloat()) }
        return e.commit()
    }

    /** 最近的执行记录, 用于判断是没被调度、网络失败还是恢复失败; 不含账号、房间与 Cookie */
    fun runLog(ctx: Context): List<String> =
        sp(ctx).getString("runLog", "").orEmpty().lines().filter { it.isNotEmpty() }

    @Synchronized
    fun appendRun(ctx: Context, startedAt: Long, trigger: Trigger, r: SyncReport, notifyBlocked: Boolean) {
        val time = SimpleDateFormat("MM-dd HH:mm:ss", Locale.CHINA).format(Date(startedAt))
        val ms = System.currentTimeMillis() - startedAt
        val note = if (notifyBlocked) " 通知受限" else ""
        // 认证阶段的失败原因是固定文案; 查询阶段的 message 可能带响应原文, 不记录
        val failed = r.stage != Stage.QUERY && (r.outcome == Outcome.UNKNOWN || r.outcome == Outcome.TRANSIENT)
        val why = if (failed) " ${r.message.take(60)}" else ""
        val lines = runLog(ctx) + "$time ${trigger.name} ${r.stage.name} ${r.outcome.name} ${ms}ms$why$note"
        sp(ctx).edit().putString("runLog", lines.takeLast(MAX_RUNS).joinToString("\n")).apply()
    }

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
            .remove("cookieJar")
            .putFloat("threshold", 20f)
            .putFloat("lastQty", 244f)
            .putFloat("peakQty", 300f)
            .putLong("lastCheck", now)
            .putBoolean("needsLogin", false)
            .putString("samples", samples)
            .apply()
    }

    /** 记录一次成功读数 */
    fun recordReading(ctx: Context, qty: Float) {
        val e = sp(ctx).edit()
        applyReading(ctx, e, qty)
        e.apply()
    }

    /** 更新最新值、满格基准、历史采样 */
    private fun applyReading(ctx: Context, e: SharedPreferences.Editor, qty: Float) {
        val now = System.currentTimeMillis()
        val peak = peakQty(ctx)
        val last = lastQty(ctx)
        val samples = samples(ctx).toMutableList()
        val prev = samples.lastOrNull()
        // 同一读数半小时内只记一次
        if (prev == null || prev.second != qty || now - prev.first > 30 * 60 * 1000L) {
            samples.add(now to qty)
        }
        // 读数上涨视为充值, 满格基准跟着重置
        if (peak <= 0f || qty > peak || (last >= 0f && qty > last + 0.5f)) e.putFloat("peakQty", qty)
        e.putFloat("lastQty", qty)
        e.putLong("lastCheck", now)
        e.putString("samples", samples.takeLast(MAX_SAMPLES).joinToString(",") { "${it.first}:${it.second}" })
    }
}
