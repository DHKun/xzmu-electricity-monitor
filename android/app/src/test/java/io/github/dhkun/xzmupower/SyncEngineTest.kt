package io.github.dhkun.xzmupower

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncEngineTest {
    private var clock = 1_000_000L
    private val dead = HttpResponse(200, DEAD_BODY, listOf(ANON_SESSION))
    private val ok = HttpResponse(200, ROOM_OK, listOf("SESSION=rotated; Path=/CloudPayment/"))
    private val toPay = HttpResponse(302, "", location = "https://${PowerApi.HOST}:18443/CloudPayment/user/pay.do?code=abc")
    private val paySession = HttpResponse(200, "ok", listOf("SESSION=fresh; Path=/CloudPayment/"))

    private fun engine(store: FakeStore, http: FakeHttp) = SyncEngine(store, http) { clock }
    private fun header(store: FakeStore) = CookieJar.parse(store.cookies).header(PowerApi.SESSION_URL, clock)

    private fun deadThenLogin(http: FakeHttp = FakeHttp()) = http
        .on("getRoomState", dead)
        .on("api/authorize", HttpResponse(200, LOGIN_PAGE))
        .on("api/login", HttpResponse(200, """{"errorCode":0}"""))
        .on("api/authorize", toPay)
        .on("pay.do", paySession)

    @Test fun validSessionCommitsReadingAndRotatedCookie() {
        val store = FakeStore()
        val r = engine(store, FakeHttp().on("getRoomState", ok)).run(Trigger.PERIODIC)
        assertEquals(Outcome.OK, r.outcome)
        assertEquals(250.0, store.quantity!!, 0.0)
        assertEquals("SESSION=rotated", header(store))
    }

    @Test fun expiredSessionRecoversInBackgroundWithoutManualState() {
        val store = FakeStore()
        val http = deadThenLogin().on("getRoomState", ok)
        val r = engine(store, http).run(Trigger.PERIODIC)
        assertEquals(Outcome.OK, r.outcome)
        assertEquals(Stage.REQUERY, r.stage)
        assertFalse(store.state.needsLogin)
        assertEquals(1, store.commits.size)
        assertEquals(1, http.passwordRequests().size)
        assertEquals(2, http.requests.count { "getRoomState" in it.url })
    }

    @Test fun anonymousSessionFromFailedQueryIsNeverPersisted() {
        val store = FakeStore()
        val http = FakeHttp().on("getRoomState", dead).failOn("api/authorize")
        val before = store.cookies
        engine(store, http).run(Trigger.PERIODIC)
        assertEquals(before, store.cookies)
    }

    @Test fun zeroReadingAfterRecoveryIsCommitted() {
        val store = FakeStore()
        val http = FakeHttp().on("getRoomState", dead).on("api/authorize", toPay).on("pay.do", paySession)
            .on("getRoomState", HttpResponse(200, """{"returncode":"100","quantity":"0"}"""))
        assertEquals(Outcome.OK, engine(store, http).run(Trigger.PERIODIC).outcome)
        assertEquals(0.0, store.quantity!!, 0.0)
    }

    @Test fun rejectedPasswordNeedsManualLoginAndIsNotResubmitted() {
        val store = FakeStore()
        val http = FakeHttp().on("getRoomState", dead)
            .on("api/authorize", HttpResponse(200, LOGIN_PAGE))
            .on("api/login", HttpResponse(200, """{"errorCode":1,"desc":"验证码错误"}"""))
            .on("getRoomState", dead)
        assertEquals(Outcome.MANUAL, engine(store, http).run(Trigger.PERIODIC).outcome)
        assertTrue(store.state.needsLogin)

        clock += 24 * 3_600_000L
        val again = engine(store, http).run(Trigger.USER)
        assertEquals(Outcome.MANUAL, again.outcome)
        assertEquals(1, http.passwordRequests().size)
    }

    @Test fun manualStateClearsOnceAQuerySucceeds() {
        val store = FakeStore(state = RecoveryState(needsLogin = true))
        assertEquals(Outcome.OK, engine(store, FakeHttp().on("getRoomState", ok)).run(Trigger.USER).outcome)
        assertFalse(store.state.needsLogin)
    }

    @Test fun noCredentialsNeedsManualLogin() {
        val store = FakeStore(read = CredsRead(null))
        val http = FakeHttp().on("getRoomState", dead).on("api/authorize", HttpResponse(200, LOGIN_PAGE))
        assertEquals(Outcome.MANUAL, engine(store, http).run(Trigger.PERIODIC).outcome)
        assertTrue(http.passwordRequests().isEmpty())
    }

    @Test fun unreadableCredentialsAreTransientNotManual() {
        val store = FakeStore(read = CredsRead(null, unavailable = true))
        val r = engine(store, FakeHttp().on("getRoomState", dead)).run(Trigger.PERIODIC)
        assertEquals(Outcome.TRANSIENT, r.outcome)
        assertFalse(store.state.needsLogin)
    }

    @Test fun permanentlyUnreadableCredentialsEventuallyNeedManualLogin() {
        val store = FakeStore(state = RecoveryState(failCount = 3), read = CredsRead(null, unavailable = true))
        val r = engine(store, FakeHttp().on("getRoomState", dead)).run(Trigger.PERIODIC)
        assertEquals(Outcome.MANUAL, r.outcome)
        assertTrue(store.state.needsLogin)
    }

    @Test fun offlineKeepsCookiesAndBacksOff() {
        val store = FakeStore()
        val before = store.cookies
        val r = engine(store, FakeHttp().failOn("getRoomState")).run(Trigger.PERIODIC)
        assertEquals(Outcome.TRANSIENT, r.outcome)
        assertTrue(r.retry)
        assertEquals(before, store.cookies)
        assertNull(store.quantity)
        assertEquals(1, store.state.failCount)
        assertEquals(clock + 15 * 60_000L, store.state.nextAttemptAt)
    }

    @Test fun backoffGrowsThenStaysAtSixHours() {
        assertEquals(15 * 60_000L, SyncEngine.backoffMs(1))
        assertEquals(60 * 60_000L, SyncEngine.backoffMs(2))
        assertEquals(360 * 60_000L, SyncEngine.backoffMs(3))
        assertEquals(360 * 60_000L, SyncEngine.backoffMs(9))
    }

    @Test fun periodicRunInsideBackoffDoesNothing() {
        val store = FakeStore(state = RecoveryState(failCount = 1, nextAttemptAt = clock + 1000))
        val http = FakeHttp()
        val r = engine(store, http).run(Trigger.PERIODIC)
        assertEquals(Outcome.SKIPPED, r.outcome)
        assertTrue(http.requests.isEmpty())
    }

    @Test fun userRefreshCannotBypassAuthBackoff() {
        val store = FakeStore(state = RecoveryState(failCount = 2, nextAttemptAt = clock + 1000, authBackoff = true))
        val http = FakeHttp().on("getRoomState", dead)
        val r = engine(store, http).run(Trigger.USER)
        assertEquals(Outcome.SKIPPED, r.outcome)
        assertEquals(1, http.requests.size)
    }

    @Test fun userQueryFailureDoesNotExtendBackoff() {
        val store = FakeStore()
        engine(store, FakeHttp().failOn("getRoomState")).run(Trigger.USER)
        assertEquals(0, store.state.failCount)
        assertEquals(0L, store.state.nextAttemptAt)
    }

    @Test fun unknownJsonIsNotTreatedAsSessionFailure() {
        val store = FakeStore()
        val http = FakeHttp().on("getRoomState", HttpResponse(200, """{"returncode":"999"}"""))
        assertEquals(Outcome.UNKNOWN, engine(store, http).run(Trigger.PERIODIC).outcome)
        assertTrue(http.passwordRequests().isEmpty())
        assertEquals(1, http.requests.size)
    }

    @Test fun deadAfterRecoveryEndsRoundWithoutRecursiveLogin() {
        val store = FakeStore()
        val http = deadThenLogin().on("getRoomState", dead)
        val r = engine(store, http).run(Trigger.PERIODIC)
        assertEquals(Outcome.UNKNOWN, r.outcome)
        assertEquals(1, http.passwordRequests().size)
        assertFalse(store.state.needsLogin)
        assertTrue(store.state.authBackoff)
    }

    @Test fun emptyJarGoesStraightToRecovery() {
        val store = FakeStore(cookies = "")
        val http = FakeHttp().on("api/authorize", toPay).on("pay.do", paySession).on("getRoomState", ok)
        assertEquals(Outcome.OK, engine(store, http).run(Trigger.PERIODIC).outcome)
        assertEquals(1, http.requests.count { "getRoomState" in it.url })
    }

    @Test fun rebindDuringRunDiscardsLateResult() {
        val store = FakeStore()
        val http = FakeHttp().on("getRoomState", ok)
        http.onSend = { store.bindingGen++ }
        val r = engine(store, http).run(Trigger.PERIODIC)
        assertEquals(Outcome.DISCARDED, r.outcome)
        assertNull(store.quantity)
    }

    @Test fun credentialChangeDuringRecoveryDiscardsOldSession() {
        val store = FakeStore()
        val http = deadThenLogin().on("getRoomState", ok)
        val before = store.cookies
        http.onSend = { if ("api/login" in http.requests.last().url) store.sessionGen++ }
        assertEquals(Outcome.DISCARDED, engine(store, http).run(Trigger.PERIODIC).outcome)
        assertEquals(before, store.cookies)
    }

    @Test fun cancellationDuringRunCommitsNothing() {
        val store = FakeStore()
        var stopped = false
        val http = FakeHttp().on("getRoomState", ok)
        http.onSend = { stopped = true }
        val r = engine(store, http).run(Trigger.PERIODIC, { stopped })
        assertEquals(Outcome.DISCARDED, r.outcome)
        assertTrue(store.commits.isEmpty())
    }

    @Test fun budgetCoversWholeRound() {
        val store = FakeStore()
        val http = FakeHttp().on("getRoomState", dead)
        http.onSend = { clock += SyncEngine.BUDGET_MS + 1 }
        val r = engine(store, http).run(Trigger.PERIODIC)
        assertEquals(Outcome.TRANSIENT, r.outcome)
        assertEquals(1, http.requests.size)
    }

    @Test fun unboundDoesNotTouchNetwork() {
        val store = FakeStore().apply { bound = false }
        val http = FakeHttp()
        assertEquals(Outcome.UNBOUND, engine(store, http).run(Trigger.PERIODIC).outcome)
        assertTrue(http.requests.isEmpty())
    }
}
