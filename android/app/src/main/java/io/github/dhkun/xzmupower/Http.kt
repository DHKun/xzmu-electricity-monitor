package io.github.dhkun.xzmupower

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.min

data class HttpRequest(
    val url: String,
    val headers: Map<String, String>,
    val timeoutMs: Int,
    val formBody: String? = null,
)

data class HttpResponse(
    val status: Int,
    val body: String,
    val setCookies: List<String> = emptyList(),
    val location: String? = null,
)

/** 单次请求, 绝不自动跟随重定向: 跳转目标由调用方校验, 凭据才不会被带去任意来源 */
fun interface HttpTransport {
    @Throws(IOException::class)
    fun send(request: HttpRequest): HttpResponse
}

object UrlTransport : HttpTransport {
    override fun send(request: HttpRequest): HttpResponse {
        val conn = URL(request.url).openConnection() as HttpURLConnection
        try {
            conn.instanceFollowRedirects = false
            conn.useCaches = false
            conn.connectTimeout = request.timeoutMs
            conn.readTimeout = request.timeoutMs
            request.headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }
            request.formBody?.let { body ->
                conn.requestMethod = "POST"
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
                conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val status = conn.responseCode
            val stream = if (status >= 400) conn.errorStream else conn.inputStream
            val body = stream?.bufferedReader()?.use { it.readText() } ?: ""
            val setCookies = conn.headerFields.orEmpty().entries
                .filter { it.key.equals("Set-Cookie", ignoreCase = true) }
                .flatMap { it.value }
            return HttpResponse(status, body, setCookies, conn.getHeaderField("Location"))
        } finally {
            conn.disconnect()
        }
    }
}

/** 系统已取消本次任务; 不是失败, 不提交任何结果 */
class SyncCancelled : RuntimeException()

/** 一轮同步的总预算, 含查询、授权与重查, 各阶段不重新计时 */
class Deadline(private val now: () -> Long, budgetMs: Long, private val cancelled: () -> Boolean = { false }) {
    private val endAt = now() + budgetMs

    fun checkNotCancelled() {
        if (cancelled()) throw SyncCancelled()
    }

    /** 下一个请求可用的超时; 预算耗尽按临时故障处理 */
    fun nextTimeoutMs(): Int {
        checkNotCancelled()
        val left = endAt - now()
        if (left <= 0) throw IOException("超出本轮执行预算")
        return min(left, REQUEST_TIMEOUT_MS).toInt()
    }

    companion object {
        const val REQUEST_TIMEOUT_MS = 15_000L
    }
}
