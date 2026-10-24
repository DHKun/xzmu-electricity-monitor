package io.github.dhkun.xzmupower

import android.content.Context
import android.webkit.CookieManager
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** 新开普云缴费接口封装。所有请求需同时携带 Cookie 和 Referer。 */
object PowerApi {

    const val HOST = "h5cloud.17wanxiao.com"
    const val PORT = "18443"
    const val SCHOOL_CODE = "784" // 西藏民族大学
    const val CLIENT_ID = "513214c26445440fb9167a7159d9258b"

    /** OAuth 登录入口: 无会话时展示登录页; 会话有效时自动完成授权 */
    val AUTHORIZE_URL: String = authorizeUrl("false")

    /** 强制重新登录(会话存在但需要换账号/彻底过期时的兜底) */
    val AUTHORIZE_URL_FORCE: String = authorizeUrl("true")

    private fun authorizeUrl(forceLogin: String): String = run {
        val redirect = "https://$HOST:$PORT/CloudPayment/user/pay.do" +
                "?ecardFunc=index&paychannel=35&payUserSource=WX" +
                "&flag=basicopengroup_xzmzjf&hostType=OPEN_NEWCAP" +
                "&appId=$CLIENT_ID&versioncode=10431102&customer_code=$SCHOOL_CODE"
        "https://open.17wanxiao.com/api/authorize?response_type=code&hidden=true" +
                "&customerCode=$SCHOOL_CODE&force_login=$forceLogin" +
                "&redirect_uri=" + URLEncoder.encode(redirect, "UTF-8") +
                "&client_id=$CLIENT_ID"
    }

    fun roomStateUrl(payProId: String, roomVerify: String) =
        "https://$HOST:$PORT/CloudPayment/user/getRoomState.do" +
                "?payProId=$payProId&schoolcode=$SCHOOL_CODE&businesstype=2&roomverify=" +
                URLEncoder.encode(roomVerify, "UTF-8")

    fun referer(payProId: String) =
        "https://$HOST:$PORT/CloudPayment/bill/selectPayProject.do" +
                "?txcode=2&interurl=substituted_pay&payProId=$payProId&amtflag=0&payamt=1000"

    const val UA = "Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Version/4.0 Chrome/124.0.6367.219 Mobile Safari/537.36"

    data class Result(
        val ok: Boolean,          // returncode == 100
        val sessionDead: Boolean, // 会话失效
        val quantity: Double?,
        val unit: String,
        val roomLabel: String,
        val message: String,
        val setCookie: String?,   // 响应中的新 Cookie(如有), 用于续期
    )

    /** 从 WebView CookieManager 取会话 Cookie, 失败时回退到快照。
     *  注意 SESSION 的 Path=/CloudPayment/, getCookie 的 URL 必须带上这个路径才能取到 */
    fun sessionCookie(ctx: Context): String? {
        CookieManager.getInstance().apply { setAcceptCookie(true); flush() }
        val live = CookieManager.getInstance().getCookie("https://$HOST:$PORT/CloudPayment/")
        if (!live.isNullOrBlank() && live.contains("SESSION=")) return live
        return Prefs.cookieSnapshot(ctx)?.takeIf { it.isNotBlank() && it.contains("SESSION=") }
    }

    /** 查询剩余电量。阻塞, 需在工作线程调用。 */
    fun queryRoomState(ctx: Context, payProId: String, roomVerify: String): Result {
        val cookie = sessionCookie(ctx)
            ?: return Result(false, true, null, "度", "", "无会话", null)
        return queryUrl(ctx, roomStateUrl(payProId, roomVerify), cookie, referer(payProId))
    }

    fun queryUrl(ctx: Context, url: String, cookie: String, referer: String): Result {
        var conn: HttpURLConnection? = null
        try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15000
                readTimeout = 15000
                requestMethod = "GET"
                setRequestProperty("Cookie", cookie)
                setRequestProperty("Referer", referer)
                setRequestProperty("User-Agent", UA)
                setRequestProperty("Accept", "application/json")
                setRequestProperty("X-Requested-With", "XMLHttpRequest")
            }
            val setCookie = conn.headerFields?.entries
                ?.filter { it.key.equals("Set-Cookie", true) }
                ?.flatMap { it.value }?.joinToString("; ")
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            if (body.trimStart().startsWith("{")) {
                val json = JSONObject(body)
                val rc = json.optString("returncode")
                return Result(
                    ok = rc == "100",
                    sessionDead = rc != "100",
                    quantity = json.optString("quantity").toDoubleOrNull(),
                    unit = json.optString("quantityunit", "度"),
                    roomLabel = json.optString("description", ""),
                    message = json.optString("returnmsg", rc),
                    setCookie = setCookie,
                )
            }
            // 服务器异常时返回 "RspBaseVO [code=ERROR, ...]" 文本
            return Result(false, "ERROR" in body, null, "度", "", body.take(80), setCookie)
        } catch (e: Exception) {
            return Result(false, false, null, "度", "", "网络错误: ${e.message}", null)
        } finally {
            conn?.disconnect()
        }
    }
}
