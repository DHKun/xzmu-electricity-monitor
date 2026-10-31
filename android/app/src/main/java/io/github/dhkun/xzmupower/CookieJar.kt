package io.github.dhkun.xzmupower

import java.net.URI
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * 按 host + path 分作用域的 Cookie 存储。
 * 授权域和缴费域都有名为 SESSION 的 Cookie, 只存单一值会互相覆盖, 所以必须保留作用域。
 */
class CookieJar private constructor(private val items: MutableList<Item>) {

    constructor() : this(mutableListOf())

    private data class Item(
        val host: String,
        val domainWide: Boolean,
        val path: String,
        val name: String,
        val value: String,
        val expiresAt: Long,
    )

    fun copy() = CookieJar(items.toMutableList())

    fun isEmpty() = items.isEmpty()

    fun has(host: String, name: String) = items.any { it.host == host && it.name == name }

    fun dropHost(host: String) {
        items.removeAll { it.host == host }
    }

    /** 请求 url 应携带的 Cookie 头 */
    fun header(url: String, now: Long): String {
        val uri = URI(url)
        val host = uri.host ?: return ""
        val path = uri.rawPath.orEmpty().ifEmpty { "/" }
        return items
            .filter { (it.expiresAt == 0L || it.expiresAt > now) && hostMatches(it, host) && pathMatches(it.path, path) }
            .sortedByDescending { it.path.length }
            .joinToString("; ") { "${it.name}=${it.value}" }
    }

    fun store(url: String, setCookies: List<String>, now: Long) {
        val uri = URI(url)
        val host = uri.host ?: return
        setCookies.forEach { storeOne(host, uri.rawPath.orEmpty(), it, now) }
    }

    /** 从 "a=b; c=d" 形式的 Cookie 串导入(WebView 与旧版快照都只有这种形式) */
    fun importPlain(host: String, path: String, cookies: String?) {
        cookies.orEmpty().split(';').forEach { part ->
            val eq = part.indexOf('=')
            if (eq > 0) put(Item(host, false, path, part.substring(0, eq).trim(), part.substring(eq + 1).trim(), 0L))
        }
    }

    fun serialize(): String = items.joinToString("\n") {
        listOf(it.host, if (it.domainWide) "1" else "0", it.path, it.name, it.value, it.expiresAt).joinToString("\t")
    }

    private fun storeOne(host: String, requestPath: String, header: String, now: Long) {
        val parts = header.split(';').map { it.trim() }
        val eq = parts[0].indexOf('=')
        if (eq <= 0) return
        val name = parts[0].substring(0, eq).trim()
        val value = parts[0].substring(eq + 1).trim()

        var domain: String? = null
        var path: String? = null
        var maxAge: Long? = null
        var expires: Long? = null
        parts.drop(1).forEach { attr ->
            val i = attr.indexOf('=')
            val key = (if (i < 0) attr else attr.substring(0, i)).trim().lowercase(Locale.ROOT)
            val v = if (i < 0) "" else attr.substring(i + 1).trim()
            when (key) {
                "domain" -> domain = v.trimStart('.').lowercase(Locale.ROOT).ifEmpty { null }
                "path" -> path = v.takeIf { it.startsWith("/") }
                "max-age" -> maxAge = v.toLongOrNull()
                "expires" -> expires = parseDate(v)
            }
        }
        val scope = domain
        if (scope != null && host != scope && !host.endsWith(".$scope")) return

        val effectivePath = path ?: defaultPath(requestPath)
        val expiresAt = maxAge?.let { now + it * 1000 } ?: expires ?: 0L
        val item = Item(scope ?: host, scope != null, effectivePath, name, value, expiresAt)
        if (expiresAt != 0L && expiresAt <= now) remove(item) else put(item)
    }

    private fun put(item: Item) {
        remove(item)
        items.add(item)
    }

    private fun remove(item: Item) {
        items.removeAll { it.host == item.host && it.path == item.path && it.name == item.name }
    }

    private fun hostMatches(item: Item, host: String) =
        host == item.host || (item.domainWide && host.endsWith(".${item.host}"))

    private fun pathMatches(cookiePath: String, requestPath: String) =
        requestPath == cookiePath || requestPath.startsWith(cookiePath.trimEnd('/') + "/")

    private fun defaultPath(requestPath: String): String {
        val slash = requestPath.lastIndexOf('/')
        return if (slash <= 0) "/" else requestPath.substring(0, slash)
    }

    private fun parseDate(s: String): Long? {
        for (pattern in DATE_PATTERNS) {
            val date = SimpleDateFormat(pattern, Locale.US).parse(s, ParsePosition(0))
            if (date != null) return date.time
        }
        return null
    }

    companion object {
        private val DATE_PATTERNS = listOf("EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz")

        fun parse(text: String?): CookieJar {
            val items = text.orEmpty().lineSequence().mapNotNull { line ->
                val f = line.split('\t')
                if (f.size == 6) Item(f[0], f[1] == "1", f[2], f[3], f[4], f[5].toLongOrNull() ?: 0L) else null
            }
            return CookieJar(items.toMutableList())
        }
    }
}
