package io.github.dhkun.xzmupower

import java.io.IOException

enum class Trigger { PERIODIC, WIDGET, USER }

enum class Stage { QUERY, AUTH, REQUERY }

enum class Outcome {
    OK,
    TRANSIENT,
    UNKNOWN,
    /** 需要用户手动登录 */
    MANUAL,
    /** 退避期内, 没有发起自动恢复 */
    SKIPPED,
    /** 已有另一轮同步在执行 */
    BUSY,
    UNBOUND,
    /** 被取消, 或绑定/会话在执行期间变了, 结果作废 */
    DISCARDED,
}

/** 跨进程重启保留的恢复状态 */
data class RecoveryState(
    val failCount: Int = 0,
    val nextAttemptAt: Long = 0L,
    /** 退避由认证恢复失败引起: 此时任何触发来源都不得绕过它提交密码 */
    val authBackoff: Boolean = false,
    val needsLogin: Boolean = false,
    val lastOutcome: Outcome? = null,
)

data class SyncSnapshot(
    val bindingGen: Int,
    val sessionGen: Int,
    val payProId: String,
    val roomVerify: String,
    val cookies: String,
    val state: RecoveryState,
)

data class SyncCommit(
    val state: RecoveryState,
    /** 通过真实查询验证过的新 Cookie; null 表示不改动 */
    val cookies: String? = null,
    val quantity: Double? = null,
)

/** 凭据状态: 已开启但暂时读不出时不能当成"没有凭据" */
data class CredsRead(val creds: LoginCreds?, val unavailable: Boolean = false)

interface SyncStore {
    /** 未绑定时返回 null */
    fun begin(): SyncSnapshot?
    fun creds(): CredsRead
    /** 代次与 base 一致才写入, 写入须是原子的; 返回是否已提交 */
    fun commit(base: SyncSnapshot, commit: SyncCommit): Boolean
}

data class SyncReport(
    val outcome: Outcome,
    val stage: Stage,
    val message: String = "",
    val quantity: Double? = null,
    val unit: String = "度",
    /** 系统可以提前再安排一次, 不必等下个周期 */
    val retry: Boolean = false,
)

/**
 * 一轮同步: 查询 → 疑似失效则恢复认证 → 用新会话重查一次 → 提交。
 * 每轮最多一次认证恢复、两次查询; 只有真实查询成功才算恢复, 新 Cookie 也只在此时落盘。
 */
class SyncEngine(
    private val store: SyncStore,
    private val http: HttpTransport,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val auth = AuthClient(http, now)

    fun run(trigger: Trigger, cancelled: () -> Boolean = { false }, onRecovering: () -> Unit = {}): SyncReport {
        val base = store.begin() ?: return SyncReport(Outcome.UNBOUND, Stage.QUERY)
        if (trigger == Trigger.PERIODIC && now() < base.state.nextAttemptAt) {
            return SyncReport(Outcome.SKIPPED, Stage.QUERY, retry = true)
        }
        val deadline = Deadline(now, BUDGET_MS, cancelled)
        val run = Run(trigger, base, deadline, onRecovering)
        return try {
            try {
                run.execute()
            } catch (e: IOException) {
                run.fail(Outcome.TRANSIENT, "网络错误: ${e.message}")
            }
        } catch (e: SyncCancelled) {
            SyncReport(Outcome.DISCARDED, run.stage)
        }
    }

    private inner class Run(
        val trigger: Trigger,
        val base: SyncSnapshot,
        val deadline: Deadline,
        val onRecovering: () -> Unit,
    ) {
        var stage = Stage.QUERY

        fun execute(): SyncReport {
            val jar = CookieJar.parse(base.cookies)
            if (jar.isEmpty()) return recover(jar)
            val r = query(jar)
            return when (r.kind) {
                PowerApi.Kind.VALID -> succeed(jar, r)
                PowerApi.Kind.SESSION_SUSPECT -> recover(jar)
                PowerApi.Kind.TRANSIENT -> fail(Outcome.TRANSIENT, r.message)
                PowerApi.Kind.UNKNOWN -> fail(Outcome.UNKNOWN, r.message)
            }
        }

        private fun query(jar: CookieJar): PowerApi.Result {
            val url = PowerApi.roomStateUrl(base.payProId, base.roomVerify)
            return PowerApi.fetchRoom(http, url, jar.header(url, now()), PowerApi.referer(base.payProId), deadline.nextTimeoutMs())
        }

        private fun recover(old: CookieJar): SyncReport {
            stage = Stage.AUTH
            val state = base.state
            if (state.needsLogin) return SyncReport(Outcome.MANUAL, stage)
            if (state.authBackoff && now() < state.nextAttemptAt) {
                return SyncReport(Outcome.SKIPPED, stage, "自动登录稍后重试", retry = true)
            }
            val creds = store.creds()
            if (creds.unavailable) {
                // 连续读不出多半是密钥已失效(如恢复备份), 再等也没用, 交给用户
                return if (state.failCount >= CREDS_UNREADABLE_LIMIT) manual("保存的密码无法读取")
                else fail(Outcome.TRANSIENT, "登录凭据暂时不可读取")
            }
            onRecovering()
            // 在副本上恢复: 没验证成功前不动已保存的状态
            val jar = old.copy()
            val a = auth.recover(jar, creds.creds, deadline)
            return when (a.status) {
                AuthClient.Status.READY -> requery(jar)
                AuthClient.Status.NO_CREDENTIALS -> manual("需要重新登录")
                AuthClient.Status.REJECTED -> manual(a.message.ifEmpty { "自动登录被拒绝" })
                AuthClient.Status.TRANSIENT -> fail(Outcome.TRANSIENT, a.message)
                AuthClient.Status.UNKNOWN -> fail(Outcome.UNKNOWN, a.message)
            }
        }

        private fun requery(jar: CookieJar): SyncReport {
            stage = Stage.REQUERY
            val r = query(jar)
            return when (r.kind) {
                PowerApi.Kind.VALID -> succeed(jar, r)
                PowerApi.Kind.TRANSIENT -> fail(Outcome.TRANSIENT, r.message)
                // 新会话仍查不到: 不是凭据问题, 也不再递归重登
                else -> fail(Outcome.UNKNOWN, "恢复登录后仍无法查询")
            }
        }

        private fun succeed(jar: CookieJar, r: PowerApi.Result): SyncReport {
            jar.store(PowerApi.SESSION_URL, r.setCookies, now())
            val committed = commit(SyncCommit(RecoveryState(lastOutcome = Outcome.OK), jar.serialize(), r.quantity))
            if (!committed) return SyncReport(Outcome.DISCARDED, stage)
            return SyncReport(Outcome.OK, stage, r.message, r.quantity, r.unit)
        }

        private fun manual(message: String): SyncReport {
            val next = base.state.copy(needsLogin = true, authBackoff = false, lastOutcome = Outcome.MANUAL)
            if (!commit(SyncCommit(next))) return SyncReport(Outcome.DISCARDED, stage)
            return SyncReport(Outcome.MANUAL, stage, message)
        }

        /** 用户/组件刷新的查询失败不计入退避, 否则离线时多刷几次会推迟后台任务 */
        fun fail(outcome: Outcome, message: String): SyncReport {
            val inAuth = stage != Stage.QUERY
            val s = base.state
            val next = if (inAuth || trigger == Trigger.PERIODIC) {
                val fails = s.failCount + 1
                s.copy(failCount = fails, nextAttemptAt = now() + backoffMs(fails),
                    authBackoff = inAuth || s.authBackoff, lastOutcome = outcome)
            } else {
                s.copy(lastOutcome = outcome)
            }
            if (!commit(SyncCommit(next))) return SyncReport(Outcome.DISCARDED, stage)
            return SyncReport(outcome, stage, message, retry = true)
        }

        private fun commit(c: SyncCommit): Boolean {
            deadline.checkNotCancelled()
            return store.commit(base, c)
        }
    }

    companion object {
        const val BUDGET_MS = 90_000L
        private const val CREDS_UNREADABLE_LIMIT = 3
        private const val MINUTE = 60_000L
        private val BACKOFF_MS = longArrayOf(15 * MINUTE, 60 * MINUTE, 360 * MINUTE)

        /** 第 n 次连续失败后至少等待的时长, 之后维持最大值 */
        fun backoffMs(failCount: Int): Long = BACKOFF_MS[(failCount - 1).coerceIn(0, BACKOFF_MS.lastIndex)]
    }
}
