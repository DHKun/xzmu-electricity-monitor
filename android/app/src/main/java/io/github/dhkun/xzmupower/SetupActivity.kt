package io.github.dhkun.xzmupower

import android.annotation.SuppressLint
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import java.util.concurrent.Executors

/**
 * 绑定流程:
 * 1. WebView 打开开放平台登录页(完美校园帐号 / 校园卡认证)
 * 2. 登录后自动跳到云缴费页面, 用户点进"XX校区公寓用电"选择自己的房间
 * 3. 页面加载剩余电量时会请求 getRoomState.do, 从中提取 payProId + roomverify
 * 4. 用 WebView 会话 Cookie 原生验证一次, 成功即完成绑定
 */
class SetupActivity : AppCompatActivity() {

    private val exec = Executors.newSingleThreadExecutor()
    private lateinit var webView: WebView
    private lateinit var progressBar: ProgressBar
    private lateinit var hintText: TextView
    private lateinit var doneBtn: Button

    private var pendingPayProId: String? = null
    private var pendingRoomVerify: String? = null
    private var binding = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_setup)

        webView = findViewById(R.id.webView)
        progressBar = findViewById(R.id.progressBar)
        hintText = findViewById(R.id.hintText)
        doneBtn = findViewById(R.id.doneBtn)

        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)

        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            userAgentString = PowerApi.UA
        }
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView, request: WebResourceRequest
            ) = intercept(request.url).let { null }

            override fun onPageFinished(view: WebView, url: String) {
                progressBar.visibility = View.GONE
                updateHint(url)
                if (url.contains("api/authorize")) injectSchoolSearch(view)
            }
        }
        webView.webChromeClient = object : android.webkit.WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                progressBar.progress = newProgress
                progressBar.visibility = if (newProgress < 100) View.VISIBLE else View.GONE
            }
        }

        doneBtn.setOnClickListener { tryFinish() }
        webView.loadUrl(PowerApi.AUTHORIZE_URL)
    }

    /** 登录页: 把"选择学校"下拉换成可搜索的弹层。脚本可安全重入, 选项延迟加载时靠重跑兜底 */
    private fun injectSchoolSearch(view: WebView) {
        try {
            val js = assets.open("school_search.js").bufferedReader().use { it.readText() }
            view.evaluateJavascript(js, null)
            view.postDelayed({ view.evaluateJavascript(js, null) }, 1200)
            view.postDelayed({ view.evaluateJavascript(js, null) }, 3000)
        } catch (_: Exception) { }
    }

    /** 从拦截到的请求里找 getRoomState.do, 提取绑定参数 */
    private fun intercept(uri: Uri) {
        if (binding) return
        if (!uri.toString().contains("getRoomState.do")) return
        val payProId = uri.getQueryParameter("payProId") ?: return
        val roomVerify = uri.getQueryParameter("roomverify") ?: return
        if (payProId == pendingPayProId && roomVerify == pendingRoomVerify) return
        pendingPayProId = payProId
        pendingRoomVerify = roomVerify
        runOnUiThread {
            hintText.text = "检测到房间 $roomVerify, 正在验证会话…"
            Toast.makeText(this, "检测到房间, 验证中…", Toast.LENGTH_SHORT).show()
        }
        tryFinish()
    }

    private fun updateHint(url: String) {
        val step = when {
            url.contains("open.17wanxiao.com") -> "① 请登录(完美校园帐号或校园卡认证)"
            url.contains("bill/type.do") || url.contains("pay.do") -> "② 请点进您的宿舍用电项目(如\"秦汉校区公寓用电\")"
            url.contains("selectPayProject.do") -> "③ 请选择您的房间, 看到\"剩余电量\"后自动完成绑定"
            else -> null
        }
        step?.let { hintText.text = it }
    }

    /** 用当前 WebView 会话原生验证一次, 成功则保存绑定 */
    private fun tryFinish() {
        val payProId = pendingPayProId ?: run {
            if (pendingRoomVerify == null)
                Toast.makeText(this, "请先在页面中选择房间", Toast.LENGTH_SHORT).show()
            return
        }
        val roomVerify = pendingRoomVerify ?: return
        if (binding) return
        binding = true
        doneBtn.isEnabled = false
        exec.execute {
            val cookie = CookieManager.getInstance().getCookie("https://" + PowerApi.HOST)
            val r = PowerApi.queryUrl(this, PowerApi.roomStateUrl(payProId, roomVerify),
                cookie ?: "", PowerApi.referer(payProId))
            runOnUiThread {
                binding = false
                doneBtn.isEnabled = true
                if (r.ok && r.quantity != null) {
                    Prefs.saveBinding(this, payProId, roomVerify, r.roomLabel)
                    Prefs.setCookieSnapshot(this, cookie)
                    Prefs.setLastQty(this, r.quantity!!.toFloat())
                    Prefs.setLastCheck(this, System.currentTimeMillis())
                    Toast.makeText(this,
                        "绑定成功! ${r.roomLabel} 剩余 ${r.quantity}${r.unit}", Toast.LENGTH_LONG).show()
                    startActivity(android.content.Intent(this, MainActivity::class.java))
                    finish()
                } else if (r.sessionDead) {
                    hintText.text = "会话无效, 请重新登录后再选择房间"
                    Toast.makeText(this, "会话无效, 请重新登录", Toast.LENGTH_LONG).show()
                } else {
                    hintText.text = "验证失败: ${r.message}, 请确认页面已显示剩余电量"
                }
            }
        }
    }

    override fun onBackPressed() {
        if (webView.canGoBack()) webView.goBack() else super.onBackPressed()
    }

    override fun onDestroy() {
        webView.destroy()
        super.onDestroy()
    }
}
