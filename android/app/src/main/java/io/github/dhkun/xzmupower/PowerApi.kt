package io.github.dhkun.xzmupower

import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.URLEncoder

/** 新开普云缴费接口封装。所有请求需同时携带 Cookie 和 Referer。 */
object PowerApi {

    const val HOST = "h5cloud.17wanxiao.com"
    const val PORT = "18443"
    const val OPEN_HOST = "open.17wanxiao.com"
    const val SCHOOL_CODE = "784" // 西藏民族大学
    const val CLIENT_ID = "513214c26445440fb9167a7159d9258b"

    const val UA = "Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Version/4.0 Chrome/124.0.6367.219 Mobile Safari/537.36"

    /** 缴费应用根路径, SESSION 的 Path 就是它 */
    const val SESSION_URL = "https://$HOST:$PORT/CloudPayment/"
    const val OPEN_URL = "https://$OPEN_HOST/"

    private val REDIRECT_URI = "https://$HOST:$PORT/CloudPayment/user/pay.do" +
            "?ecardFunc=index&paychannel=35&payUserSource=WX" +
            "&flag=basicopengroup_xzmzjf&hostType=OPEN_NEWCAP" +
            "&appId=$CLIENT_ID&versioncode=10431102&customer_code=$SCHOOL_CODE"

    /** OAuth 登录入口: 无会话时展示登录页; 会话有效时自动完成授权 */
    val AUTHORIZE_URL: String = authorizeUrl("false")

    /** 强制重新登录(会话存在但需要换账号/彻底过期时的兜底) */
    val AUTHORIZE_URL_FORCE: String = authorizeUrl("true")

    private fun authorizeUrl(forceLogin: String): String =
        "https://$OPEN_HOST/api/authorize?response_type=code&hidden=true" +
                "&customerCode=$SCHOOL_CODE&force_login=$forceLogin" +
                "&redirect_uri=" + URLEncoder.encode(REDIRECT_URI, "UTF-8") +
                "&client_id=$CLIENT_ID"

    /** 登录接口与授权页共用同一组查询参数 */
    fun loginUrl(authorizeUrl: String): String =
        "https://$OPEN_HOST/api/login?" + authorizeUrl.substringAfter('?')

    /** 登录成功后页面脚本跳转的地址 */
    val POST_LOGIN_AUTHORIZE_URL: String =
        "https://$OPEN_HOST/api/authorize?client_id=$CLIENT_ID&response_type=code" +
                "&redirect_uri=" + URLEncoder.encode(REDIRECT_URI, "UTF-8") + "&state="

    fun roomStateUrl(payProId: String, roomVerify: String) =
        "https://$HOST:$PORT/CloudPayment/user/getRoomState.do" +
                "?payProId=$payProId&schoolcode=$SCHOOL_CODE&businesstype=2&roomverify=" +
                URLEncoder.encode(roomVerify, "UTF-8")

    fun referer(payProId: String) =
        "https://$HOST:$PORT/CloudPayment/bill/selectPayProject.do" +
                "?txcode=2&interurl=substituted_pay&payProId=$payProId&amtflag=0&payamt=1000"

    enum class Kind {
        /** 取到了有效读数, 0 也是有效电量 */
        VALID,
        /** 形态与失效会话一致, 但也可能真是系统繁忙, 只有恢复认证后重查才能确认 */
        SESSION_SUSPECT,
        TRANSIENT,
        UNKNOWN,
    }

    data class Result(
        val kind: Kind,
        val quantity: Double?,
        val unit: String,
        val roomLabel: String,
        val message: String,
        val setCookies: List<String>,
    ) {
        val ok get() = kind == Kind.VALID
        val sessionDead get() = kind == Kind.SESSION_SUSPECT
    }

    private fun failure(kind: Kind, message: String, setCookies: List<String> = emptyList()) =
        Result(kind, null, "度", "", message, setCookies)

    fun classify(status: Int, body: String, setCookies: List<String>): Result {
        if (status == 429 || status >= 500) return failure(Kind.TRANSIENT, "服务器暂时不可用($status)", setCookies)
        val text = body.trimStart()
        if (text.startsWith("{")) {
            return try {
                val json = JSONObject(text)
                val rc = json.optString("returncode")
                val quantity = json.optString("quantity").toDoubleOrNull()?.takeIf { it.isFinite() }
                if (rc == "100" && quantity != null) {
                    Result(Kind.VALID, quantity, json.optString("quantityunit").ifEmpty { "度" },
                        json.optString("description"), rc, setCookies)
                } else {
                    failure(Kind.UNKNOWN, json.optString("returnmsg").ifEmpty { rc }, setCookies)
                }
            } catch (e: JSONException) {
                failure(Kind.UNKNOWN, "响应格式异常", setCookies)
            }
        }
        // 失效/缺失会话的实测响应: HTTP 200 + "RspBaseVO [code=ERROR, msg=系统繁忙...]"
        if (text.startsWith("RspBaseVO") && "code=ERROR" in text) {
            return failure(Kind.SESSION_SUSPECT, "会话可能已失效", setCookies)
        }
        return failure(Kind.UNKNOWN, text.take(80), setCookies)
    }

    /** 查询剩余电量。阻塞, 需在工作线程调用。 */
    fun fetchRoom(http: HttpTransport, url: String, cookie: String, referer: String, timeoutMs: Int): Result =
        try {
            val r = http.send(HttpRequest(url, mapOf(
                "Cookie" to cookie,
                "Referer" to referer,
                "User-Agent" to UA,
                "Accept" to "application/json",
                "X-Requested-With" to "XMLHttpRequest",
            ), timeoutMs))
            classify(r.status, r.body, r.setCookies)
        } catch (e: IOException) {
            failure(Kind.TRANSIENT, "网络错误: ${e.message}")
        }
}
