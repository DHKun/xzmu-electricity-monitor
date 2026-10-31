package io.github.dhkun.xzmupower

import android.content.Context
import android.webkit.CookieManager
import java.util.concurrent.locks.ReentrantLock

/** 同步入口: 首页、后台任务、桌面组件共用。App 的所有入口都在同一进程, 进程内互斥即可 */
object PowerSync {
    private val running = ReentrantLock()

    /** 阻塞, 需在工作线程调用 */
    fun sync(
        ctx: Context,
        trigger: Trigger,
        cancelled: () -> Boolean = { false },
        onRecovering: () -> Unit = {},
    ): SyncReport {
        if (!running.tryLock()) return SyncReport(Outcome.BUSY, Stage.QUERY)
        val startedAt = System.currentTimeMillis()
        try {
            val r = SyncEngine(PrefsSyncStore(ctx), UrlTransport).run(trigger, cancelled, onRecovering)
            var lowAlertBlocked = false
            if (r.outcome == Outcome.OK && r.quantity != null) {
                lowAlertBlocked = AlertEval.evaluate(ctx, r.quantity, r.unit)
                AlertNotify.cancelLogin(ctx)
            }
            val loginPending = Prefs.needsLogin(ctx) && !Prefs.manualAlerted(ctx)
            val loginPosted = loginPending && AlertNotify.login(ctx)
            if (loginPosted) Prefs.setManualAlerted(ctx, true)
            Prefs.appendRun(ctx, startedAt, trigger, r,
                notifyBlocked = lowAlertBlocked || (loginPending && !loginPosted))
            PowerWidget.updateAll(ctx)
            return r
        } finally {
            running.unlock()
        }
    }

    private class PrefsSyncStore(private val ctx: Context) : SyncStore {
        override fun begin(): SyncSnapshot? {
            if (!Prefs.configured(ctx)) return null
            WebSession.migrateIfNeeded(ctx)
            return Prefs.syncSnapshot(ctx)
        }

        override fun creds() = Credentials.forLogin(ctx)

        override fun commit(base: SyncSnapshot, commit: SyncCommit) = Prefs.commitSync(ctx, base, commit)
    }
}

/** WebView 登录态与后台 Cookie 的唯一交接点: 持久存储是权威, WebView 只在交互登录后导入一次 */
object WebSession {
    private fun readWebCookies(): CookieJar {
        val jar = CookieJar()
        runCatching {
            val cm = CookieManager.getInstance()
            cm.flush()
            jar.importPlain(PowerApi.HOST, "/CloudPayment/", cm.getCookie(PowerApi.SESSION_URL))
            jar.importPlain(PowerApi.OPEN_HOST, "/", cm.getCookie(PowerApi.OPEN_URL))
        }
        return jar
    }

    /**
     * 用户刚完成交互登录: 换入 WebView 里的新会话, 进行中的旧同步结果随之作废。
     * 验证查询可能已轮换会话, 它的响应 Cookie 要盖在 WebView 读到的值上。
     */
    fun adoptInteractiveLogin(ctx: Context, setCookies: List<String> = emptyList()) {
        val jar = readWebCookies()
        jar.store(PowerApi.SESSION_URL, setCookies, System.currentTimeMillis())
        Prefs.replaceSession(ctx, jar.serialize())
    }

    /** 升级自旧版: 从 WebView 与 Cookie 快照建立持久存储, 只做一次 */
    fun migrateIfNeeded(ctx: Context) {
        if (Prefs.cookieJar(ctx) != null) return
        val jar = readWebCookies()
        if (!jar.has(PowerApi.HOST, "SESSION")) {
            jar.importPlain(PowerApi.HOST, "/CloudPayment/", Prefs.cookieSnapshot(ctx))
        }
        Prefs.seedCookieJar(ctx, jar.serialize())
    }
}
