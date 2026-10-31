package io.github.dhkun.xzmupower

import java.io.IOException

const val DEAD_BODY = "RspBaseVO [code=ERROR, msg=系统繁忙，请稍后重试, subCode=null, subMsg=null]"
const val ANON_SESSION = "SESSION=anonymous; Path=/CloudPayment/; Secure; HttpOnly"
const val LOGIN_PAGE = "<title>开放平台授权</title><a href=\"javascript:;\" id=\"lgn\" class=\"btn submit\">授权登录</a>"
const val ROOM_OK = """{"returncode":"100","quantity":"250.0","quantityunit":"度","description":"902房间"}"""

/** 按顺序匹配 URL 片段回放响应, 并记录所有请求 */
class FakeHttp(private val script: MutableList<Pair<String, () -> HttpResponse>> = mutableListOf()) : HttpTransport {
    val requests = mutableListOf<HttpRequest>()
    var onSend: () -> Unit = {}

    fun on(urlPart: String, response: HttpResponse) = apply { script += urlPart to { response } }
    fun failOn(urlPart: String) = apply { script += urlPart to { throw IOException("offline") } }

    override fun send(request: HttpRequest): HttpResponse {
        requests += request
        onSend()
        val i = script.indexOfFirst { request.url.contains(it.first) }
        if (i < 0) throw AssertionError("unexpected request: ${request.url}")
        return script.removeAt(i).second()
    }

    fun passwordRequests() = requests.filter { it.formBody != null }
}

class FakeStore(
    var cookies: String = jarOf("SESSION=old"),
    var state: RecoveryState = RecoveryState(),
    var read: CredsRead = CredsRead(WX_CREDS),
) : SyncStore {
    var bindingGen = 1
    var sessionGen = 1
    var bound = true
    var quantity: Double? = null
    val commits = mutableListOf<SyncCommit>()

    override fun begin(): SyncSnapshot? =
        if (bound) SyncSnapshot(bindingGen, sessionGen, "3148", "101-1--9-902", cookies, state) else null

    override fun creds() = read

    override fun commit(base: SyncSnapshot, commit: SyncCommit): Boolean {
        if (base.bindingGen != bindingGen || base.sessionGen != sessionGen) return false
        commits += commit
        state = commit.state
        commit.cookies?.let { cookies = it }
        commit.quantity?.let { quantity = it }
        return true
    }

    companion object {
        val WX_CREDS = LoginCreds("wx", "user", "p&ss=word", "", "")
        fun jarOf(plain: String) = CookieJar().apply { importPlain(PowerApi.HOST, "/CloudPayment/", plain) }.serialize()
    }
}
