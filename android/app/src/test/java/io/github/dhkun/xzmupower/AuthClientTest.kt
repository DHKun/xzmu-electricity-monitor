package io.github.dhkun.xzmupower

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CookieJarTest {
    private val pay = "https://${PowerApi.HOST}:18443/CloudPayment/user/getRoomState.do?a=1"
    private val open = "https://${PowerApi.OPEN_HOST}/api/authorize?x=1"

    @Test fun sameNameCookiesStayScopedByHost() {
        val jar = CookieJar()
        jar.store(open, listOf("SESSION=sso; Path=/; HttpOnly; SameSite=Lax"), 0)
        jar.store(pay, listOf("SESSION=pay; Path=/CloudPayment/; Secure; HttpOnly"), 0)
        assertEquals("SESSION=sso", jar.header(open, 0))
        assertEquals("SESSION=pay", jar.header(pay, 0))
    }

    @Test fun pathScopeIsRespected() {
        val jar = CookieJar()
        jar.store(pay, listOf("SESSION=pay; Path=/CloudPayment/"), 0)
        assertEquals("", jar.header("https://${PowerApi.HOST}:18443/other", 0))
    }

    @Test fun maxAgeZeroDeletesAndExpiredCookieIsNotSent() {
        val jar = CookieJar()
        jar.store(open, listOf("a=1;path=/", "b=2;path=/;Max-Age=10"), 1000)
        jar.store(open, listOf("a=x;path=/;Max-Age=0"), 1000)
        assertEquals("b=2", jar.header(open, 2000))
        assertEquals("", jar.header(open, 20_000))
    }

    @Test fun foreignDomainAttributeIsIgnored() {
        val jar = CookieJar()
        jar.store(open, listOf("evil=1; Domain=example.com; Path=/"), 0)
        assertEquals("", jar.header(open, 0))
    }

    @Test fun serializationRoundTrips() {
        val jar = CookieJar()
        jar.store(open, listOf("SESSION=sso; Path=/", "wide=1; Domain=.17wanxiao.com; Path=/; Max-Age=100"), 0)
        val back = CookieJar.parse(jar.serialize())
        assertEquals(jar.header(open, 0), back.header(open, 0))
        assertEquals("wide=1", back.header(pay, 0))
    }
}

class RoomClassifyTest {
    private fun classify(body: String, status: Int = 200) = PowerApi.classify(status, body, emptyList())

    @Test fun zeroQuantityIsValid() {
        val r = classify("""{"returncode":"100","quantity":"0","quantityunit":"度"}""")
        assertEquals(PowerApi.Kind.VALID, r.kind)
        assertEquals(0.0, r.quantity!!, 0.0)
    }

    @Test fun capturedDeadSessionBodyIsOnlySuspect() {
        assertEquals(PowerApi.Kind.SESSION_SUSPECT, classify(DEAD_BODY).kind)
    }

    @Test fun nonSuccessReturnCodeIsNotTreatedAsSessionFailure() {
        assertEquals(PowerApi.Kind.UNKNOWN, classify("""{"returncode":"200","returnmsg":"房间不存在"}""").kind)
    }

    @Test fun successCodeWithoutFiniteQuantityIsUnknown() {
        assertEquals(PowerApi.Kind.UNKNOWN, classify("""{"returncode":"100","quantity":"NaN"}""").kind)
        assertEquals(PowerApi.Kind.UNKNOWN, classify("""{"returncode":"100"}""").kind)
    }

    @Test fun serverErrorsAreTransientAndHtmlIsUnknown() {
        assertEquals(PowerApi.Kind.TRANSIENT, classify("bad gateway", 502).kind)
        assertEquals(PowerApi.Kind.UNKNOWN, classify("<html>maintenance</html>").kind)
    }
}

class AuthClientTest {
    private val deadline get() = Deadline({ 0L }, 90_000)
    private val noRedirectSession = HttpResponse(200, "<html>缴费</html>", listOf("SESSION=fresh; Path=/CloudPayment/"))
    private val toPay = HttpResponse(302, "", location = "https://${PowerApi.HOST}:18443/CloudPayment/user/pay.do?code=abc")

    @Test fun ssoRedirectRecoversWithoutSendingPassword() {
        val http = FakeHttp().on("api/authorize", toPay).on("pay.do", noRedirectSession)
        val jar = CookieJar()
        val r = AuthClient(http) { 0L }.recover(jar, FakeStore.WX_CREDS, deadline)
        assertEquals(AuthClient.Status.READY, r.status)
        assertTrue(http.passwordRequests().isEmpty())
        assertEquals("SESSION=fresh", jar.header(PowerApi.SESSION_URL, 0))
    }

    @Test fun passwordLoginFollowsPageProtocol() {
        val http = FakeHttp()
            .on("api/authorize", HttpResponse(200, LOGIN_PAGE, listOf("SESSION=form; Path=/")))
            .on("api/login", HttpResponse(200, """{"errorCode":0}""", listOf("SESSION=authed; Path=/")))
            .on("api/authorize", toPay)
            .on("pay.do", noRedirectSession)
        val r = AuthClient(http) { 0L }.recover(CookieJar(), FakeStore.WX_CREDS, deadline)
        assertEquals(AuthClient.Status.READY, r.status)

        val login = http.passwordRequests().single()
        assertTrue(login.url.startsWith("https://${PowerApi.OPEN_HOST}/api/login?response_type=code"))
        assertEquals("SESSION=form", login.headers["Cookie"])
        val body = login.formBody!!
        assertTrue(body, body.contains("loginType=wx") && body.contains("password=p%26ss%3Dword"))
        assertTrue(body, body.contains("scopes%5B%5D=base") && body.contains("scopes%5B%5D=user_alter"))
        assertFalse(body, body.contains("outid"))
        assertEquals("SESSION=authed", http.requests[2].headers["Cookie"])
    }

    @Test fun ecardLoginSendsCardFields() {
        val http = FakeHttp()
            .on("api/authorize", HttpResponse(200, LOGIN_PAGE))
            .on("api/login", HttpResponse(200, """{"errorCode":1,"desc":"密码错误"}"""))
        val creds = LoginCreds("ecard", "名字", "pw", "784", "2020001")
        AuthClient(http) { 0L }.recover(CookieJar(), creds, deadline)
        val body = http.passwordRequests().single().formBody!!
        assertTrue(body, body.contains("loginType=ecard") && body.contains("customerCode=784") && body.contains("outid=2020001"))
    }

    @Test fun nonZeroErrorCodeIsRejected() {
        val http = FakeHttp()
            .on("api/authorize", HttpResponse(200, LOGIN_PAGE))
            .on("api/login", HttpResponse(200, """{"errorCode":202102,"desc":"未绑定一卡通"}"""))
        val r = AuthClient(http) { 0L }.recover(CookieJar(), FakeStore.WX_CREDS, deadline)
        assertEquals(AuthClient.Status.REJECTED, r.status)
        assertEquals("未绑定一卡通", r.message)
        assertEquals(1, http.passwordRequests().size)
    }

    @Test fun missingCredentialsStopAtLoginForm() {
        val http = FakeHttp().on("api/authorize", HttpResponse(200, LOGIN_PAGE))
        val r = AuthClient(http) { 0L }.recover(CookieJar(), null, deadline)
        assertEquals(AuthClient.Status.NO_CREDENTIALS, r.status)
    }

    @Test fun errorPageRetriesOnceWithForcedLogin() {
        val http = FakeHttp()
            .on("force_login=false", HttpResponse(200, "<title>提示</title>"))
            .on("force_login=true", HttpResponse(200, LOGIN_PAGE))
        val r = AuthClient(http) { 0L }.recover(CookieJar(), null, deadline)
        assertEquals(AuthClient.Status.NO_CREDENTIALS, r.status)
        assertEquals(2, http.requests.size)
    }

    @Test fun loginRedirectIsNeverFollowed() {
        val http = FakeHttp()
            .on("api/authorize", HttpResponse(200, LOGIN_PAGE))
            .on("api/login", HttpResponse(302, "", location = "https://evil.example/steal"))
        val r = AuthClient(http) { 0L }.recover(CookieJar(), FakeStore.WX_CREDS, deadline)
        assertEquals(AuthClient.Status.UNKNOWN, r.status)
        assertEquals(2, http.requests.size)
    }

    @Test fun redirectToUnknownHostIsNotRequested() {
        val http = FakeHttp().on("api/authorize", HttpResponse(302, "", location = "https://evil.example/x"))
        val r = AuthClient(http) { 0L }.recover(CookieJar(), FakeStore.WX_CREDS, deadline)
        assertEquals(AuthClient.Status.UNKNOWN, r.status)
        assertEquals(1, http.requests.size)
    }

    @Test fun cleartextRedirectIsNotRequested() {
        val http = FakeHttp().on("api/authorize", HttpResponse(302, "", location = "http://${PowerApi.OPEN_HOST}/x"))
        assertEquals(AuthClient.Status.UNKNOWN, AuthClient(http) { 0L }.recover(CookieJar(), null, deadline).status)
        assertEquals(1, http.requests.size)
    }

    @Test fun redirectLoopIsBounded() {
        val http = FakeHttp()
        repeat(20) { http.on("api/authorize", HttpResponse(302, "", location = "/api/authorize?loop=1")) }
        assertEquals(AuthClient.Status.UNKNOWN, AuthClient(http) { 0L }.recover(CookieJar(), null, deadline).status)
        assertTrue(http.requests.size <= 8)
    }

    @Test fun networkFailureIsTransient() {
        val http = FakeHttp().failOn("api/authorize")
        assertEquals(AuthClient.Status.TRANSIENT, AuthClient(http) { 0L }.recover(CookieJar(), null, deadline).status)
    }

    @Test fun unparsableLoginResponseIsUnknownNotRejected() {
        val http = FakeHttp()
            .on("api/authorize", HttpResponse(200, LOGIN_PAGE))
            .on("api/login", HttpResponse(200, "<html>waf</html>"))
        assertEquals(AuthClient.Status.UNKNOWN, AuthClient(http) { 0L }.recover(CookieJar(), FakeStore.WX_CREDS, deadline).status)
    }

    @Test fun staleLandingWithoutSessionFails() {
        val http = FakeHttp().on("api/authorize", toPay).on("pay.do", HttpResponse(200, "ok"))
        val r = AuthClient(http) { 0L }.recover(CookieJar(), null, deadline)
        assertEquals(AuthClient.Status.UNKNOWN, r.status)
        assertNull(CookieJar().header(PowerApi.SESSION_URL, 0).ifEmpty { null })
    }
}
