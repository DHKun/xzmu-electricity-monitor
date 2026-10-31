package io.github.dhkun.xzmupower

import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.URI
import java.net.URLEncoder

data class LoginCreds(
    val type: String,
    val username: String,
    val password: String,
    val customerCode: String,
    val outid: String,
)

/**
 * 不依赖页面的认证恢复: 走与登录页脚本相同的 HTTP 流程。
 * 先用授权域 SSO 换新会话; 必须登录时才提交一次凭据, 且只发给固定的登录接口。
 */
class AuthClient(private val http: HttpTransport, private val now: () -> Long) {

    enum class Status {
        /** 缴费域已拿到新会话, 是否真正可用由调用方重查确认 */
        READY,
        NO_CREDENTIALS,
        /** 服务端明确拒绝(密码错误、验证码、需要绑卡等), 不能再自动重试 */
        REJECTED,
        TRANSIENT,
        UNKNOWN,
    }

    data class Result(val status: Status, val message: String = "")

    private sealed interface Landing {
        data object Session : Landing
        data class LoginForm(val url: String) : Landing
        data object ErrorPage : Landing
        data class Temporary(val status: Int) : Landing
        data class Unrecognized(val detail: String) : Landing
    }

    fun recover(jar: CookieJar, creds: LoginCreds?, deadline: Deadline): Result = try {
        // 旧缴费会话已不可用, 留着只会混进授权回跳
        jar.dropHost(PowerApi.HOST)
        var landing = walk(PowerApi.AUTHORIZE_URL, jar, deadline)
        if (landing is Landing.ErrorPage) landing = walk(PowerApi.AUTHORIZE_URL_FORCE, jar, deadline)
        when (landing) {
            is Landing.Session -> Result(Status.READY)
            is Landing.LoginForm ->
                if (creds == null) Result(Status.NO_CREDENTIALS) else login(landing.url, jar, creds, deadline)
            is Landing.Temporary -> Result(Status.TRANSIENT, "授权服务暂时不可用(${landing.status})")
            is Landing.Unrecognized -> Result(Status.UNKNOWN, "授权页面无法识别(${landing.detail})")
            is Landing.ErrorPage -> Result(Status.UNKNOWN, "授权页面无法识别(错误页)")
        }
    } catch (e: IOException) {
        Result(Status.TRANSIENT, "网络错误: ${e.message}")
    }

    private fun login(formUrl: String, jar: CookieJar, creds: LoginCreds, deadline: Deadline): Result {
        val url = PowerApi.loginUrl(formUrl)
        val response = http.send(HttpRequest(url, mapOf(
            "Cookie" to jar.header(url, now()),
            "User-Agent" to PowerApi.UA,
            "Accept" to ACCEPT_JSON,
            "Referer" to formUrl,
            "X-Requested-With" to "XMLHttpRequest",
        ), deadline.nextTimeoutMs(), formBody(creds)))
        jar.store(url, response.setCookies, now())
        if (response.status == 429 || response.status >= 500) {
            return Result(Status.TRANSIENT, "登录服务暂时不可用(${response.status})")
        }
        val json = try {
            JSONObject(response.body.trim())
        } catch (e: JSONException) {
            return Result(Status.UNKNOWN, "登录响应无法识别")
        }
        if (!json.has("errorCode")) return Result(Status.UNKNOWN, "登录响应无法识别")
        if (json.optInt("errorCode", -1) != 0) {
            return Result(Status.REJECTED, json.optString("desc").ifEmpty { json.optString("errorMsg") })
        }
        return when (val landing = walk(PowerApi.POST_LOGIN_AUTHORIZE_URL, jar, deadline)) {
            is Landing.Session -> Result(Status.READY)
            is Landing.Temporary -> Result(Status.TRANSIENT, "授权服务暂时不可用(${landing.status})")
            is Landing.Unrecognized -> Result(Status.UNKNOWN, "登录后未回到缴费页面(${landing.detail})")
            else -> Result(Status.UNKNOWN, "登录后未回到缴费页面")
        }
    }

    private fun formBody(c: LoginCreds): String {
        val fields = mutableListOf("loginType" to c.type, "username" to c.username, "password" to c.password)
        if (c.type == Credentials.TYPE_ECARD) {
            fields += "customerCode" to c.customerCode
            fields += "outid" to c.outid
        }
        fields += "scopes[]" to "base"
        fields += "scopes[]" to "user_alter"
        fields += "force_bind_ecard" to "true"
        return fields.joinToString("&") { (k, v) -> "${enc(k)}=${enc(v)}" }
    }

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

    /** 手动跟随授权重定向: 只访问 https 的已知主机, 且跳数有限 */
    private fun walk(start: String, jar: CookieJar, deadline: Deadline): Landing {
        var url = start
        repeat(MAX_HOPS) {
            if (!allowed(url)) {
                return if (jar.has(PowerApi.HOST, "SESSION")) Landing.Session else Landing.Unrecognized("跳转到未知地址")
            }
            val r = http.send(HttpRequest(url, mapOf(
                "Cookie" to jar.header(url, now()),
                "User-Agent" to PowerApi.UA,
                "Accept" to ACCEPT_HTML,
            ), deadline.nextTimeoutMs()))
            jar.store(url, r.setCookies, now())
            if (r.status in 300..399) {
                val target = r.location?.let { resolve(url, it) } ?: return Landing.Unrecognized("跳转地址无效")
                url = target
                return@repeat
            }
            if (r.status == 429 || r.status >= 500) return Landing.Temporary(r.status)
            if (URI(url).host == PowerApi.HOST) {
                return if (r.status < 400 && jar.has(PowerApi.HOST, "SESSION")) Landing.Session
                else Landing.Unrecognized("HTTP ${r.status}")
            }
            return when {
                r.status >= 400 -> Landing.Unrecognized("HTTP ${r.status}")
                LOGIN_MARKER in r.body -> Landing.LoginForm(url)
                ERROR_TITLE.containsMatchIn(r.body) -> Landing.ErrorPage
                else -> Landing.Unrecognized("页面没有登录表单")
            }
        }
        return Landing.Unrecognized("跳转次数过多")
    }

    private fun allowed(url: String): Boolean {
        val uri = runCatching { URI(url) }.getOrNull() ?: return false
        return uri.scheme == "https" && (uri.host == PowerApi.OPEN_HOST || uri.host == PowerApi.HOST)
    }

    private fun resolve(base: String, location: String): String? =
        runCatching { URI(base).resolve(location.trim()).toString() }.getOrNull()

    companion object {
        private const val MAX_HOPS = 8
        private const val LOGIN_MARKER = "id=\"lgn\""
        // 服务器对没有 */* 兜底的 Accept 返回 406, 必须与浏览器和登录页脚本一致
        private const val ACCEPT_HTML = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        private const val ACCEPT_JSON = "application/json, text/javascript, */*; q=0.01"
        private val ERROR_TITLE = Regex("<title>[^<]*提示")
    }
}
