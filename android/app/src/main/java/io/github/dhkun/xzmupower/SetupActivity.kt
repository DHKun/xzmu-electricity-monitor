package io.github.dhkun.xzmupower

import android.annotation.SuppressLint
import android.content.Intent
import android.content.res.ColorStateList
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.CheckBox
import android.widget.TextView
import android.widget.Toast
import org.json.JSONObject
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.button.MaterialButton
import com.google.android.material.color.MaterialColors
import com.google.android.material.progressindicator.LinearProgressIndicator
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
    private lateinit var progressBar: LinearProgressIndicator
    private lateinit var hintText: TextView
    private lateinit var doneBtn: MaterialButton
    private val steps = arrayOf("登录", "选择项目", "选择房间")
    private var webBackCallback: OnBackPressedCallback? = null

    private var pendingPayProId: String? = null
    private var pendingRoomVerify: String? = null
    private var binding = false
    private var lastAttemptKey: String? = null
    private var lastAttemptAt = 0L
    private var forceLoginTried = false
    /** 用户在登录页输入的凭据(点登录时抓到), 绑定成功且勾选"记住密码"后才落盘 */
    private var capturedCreds: String? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_setup)

        val root = findViewById<View>(R.id.root)
        ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime())
            v.updatePadding(top = bars.top, bottom = bars.bottom)
            insets
        }
        // 从首页"重新绑定"进来时可返回; 首次绑定没有上一页
        val toolbar = findViewById<MaterialToolbar>(R.id.toolbar)
        if (intent.getBooleanExtra(EXTRA_REBIND, false)) {
            toolbar.setNavigationIcon(R.drawable.ic_arrow_back)
            toolbar.setNavigationIconTint(MaterialColors.getColor(toolbar, com.google.android.material.R.attr.colorOnSurface))
            toolbar.setNavigationOnClickListener { finish() }
        }

        webView = findViewById(R.id.webView)
        progressBar = findViewById(R.id.progressBar)
        hintText = findViewById(R.id.hintText)
        doneBtn = findViewById(R.id.doneBtn)
        setStep(0)

        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)

        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            userAgentString = PowerApi.UA
        }
        // 只暴露一个凭据回传方法给 17wanxiao 登录页, 供"记住密码·自动续期"
        webView.addJavascriptInterface(CredBridge(), "xzmuCap")
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView, request: WebResourceRequest
            ) = intercept(request.url).let { null }

            override fun onPageFinished(view: WebView, url: String) {
                webBackCallback?.isEnabled = view.canGoBack()
                progressBar.visibility = View.INVISIBLE
                updateHint(url)
                if (url.contains("api/authorize")) {
                    injectSchoolSearch(view)
                    captureCreds(view)
                    // "提示"页 = 会话失效错误页, 自动降级到强制登录
                    view.evaluateJavascript("document.title") { title ->
                        if (title?.contains("提示") == true && !forceLoginTried) {
                            forceLoginTried = true
                            runOnUiThread { webView.loadUrl(PowerApi.AUTHORIZE_URL_FORCE) }
                        }
                    }
                }
            }
        }
        webView.webChromeClient = object : android.webkit.WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                progressBar.setProgressCompat(newProgress, true)
                progressBar.visibility = if (newProgress < 100) View.VISIBLE else View.INVISIBLE
            }
        }

        // 网页能后退时返回键先退网页; 否则交给系统, 保留预测性返回动画
        val webBack = object : OnBackPressedCallback(false) {
            override fun handleOnBackPressed() = webView.goBack()
        }
        onBackPressedDispatcher.addCallback(this, webBack)
        webBackCallback = webBack

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

    /** 登录页: 用户点登录按钮时, 读下当时输入框里的账号密码, 存在内存里备用 */
    private fun captureCreds(view: WebView) {
        view.evaluateJavascript("""
            (function(){
              if (window.__xzmuCap) return; window.__xzmuCap = true;
              document.addEventListener('click', function(ev){
                var hit = ev.target && (ev.target.id==='lgn' ||
                          (ev.target.closest && ev.target.closest('#lgn')));
                if (!hit) return;
                try {
                  var wx = document.getElementById('wx-login-div');
                  var isWx = wx && getComputedStyle(wx).display !== 'none';
                  var d;
                  if (isWx) { d = {t:'wx', u:val('username'), p:val('password'), cc:'', outid:''}; }
                  else { var s=document.getElementById('customerSelect');
                         d = {t:'ecard', u:val('username_'), p:val('password_'),
                              cc: s?s.value:'', outid: val('outid')}; }
                  if (d.p) xzmuCap.onCreds(JSON.stringify(d));
                } catch(e){}
                function val(id){var e=document.getElementById(id); return e?e.value:'';}
              }, true);
            })();
        """, null)
    }

    private inner class CredBridge {
        @JavascriptInterface
        fun onCreds(json: String) { capturedCreds = json }
    }

    /** 从拦截到的请求里找 getRoomState.do, 提取绑定参数。
     *  注意: shouldInterceptRequest 在 WebView 后台线程回调, UI 操作必须切主线程 */
    private fun intercept(uri: Uri) {
        if (binding) return
        if (!uri.toString().contains("getRoomState.do")) return
        val payProId = uri.getQueryParameter("payProId") ?: return
        val roomVerify = uri.getQueryParameter("roomverify") ?: return
        val key = "$payProId|$roomVerify"
        // 同一参数 5 秒内只自动验证一次, 防止页面重试刷爆
        if (key == lastAttemptKey && System.currentTimeMillis() - lastAttemptAt < 5000) return
        lastAttemptKey = key
        lastAttemptAt = System.currentTimeMillis()
        pendingPayProId = payProId
        pendingRoomVerify = roomVerify
        runOnUiThread {
            hintText.text = "检测到房间 $roomVerify, 正在验证…"
            tryFinish()
        }
    }

    private fun updateHint(url: String) {
        when {
            url.contains("open.17wanxiao.com") -> {
                setStep(0)
                hintText.text = "用完美校园帐号或校园卡认证登录"
            }
            url.contains("bill/type.do") || url.contains("pay.do") -> {
                setStep(1)
                hintText.text = "点进宿舍用电项目, 如\"秦汉校区公寓用电\""
            }
            url.contains("selectPayProject.do") -> {
                setStep(2)
                hintText.text = "选择房间, 显示剩余电量后自动完成绑定"
            }
        }
    }

    /** 步骤条: 已完成打勾, 当前步骤实心主色, 未到的步骤浅色 */
    private fun setStep(current: Int) {
        val primary = MaterialColors.getColor(hintText, androidx.appcompat.R.attr.colorPrimary)
        val onPrimary = MaterialColors.getColor(hintText, com.google.android.material.R.attr.colorOnPrimary)
        val idle = MaterialColors.getColor(hintText, com.google.android.material.R.attr.colorSurfaceContainerHighest)
        val onIdle = MaterialColors.getColor(hintText, com.google.android.material.R.attr.colorOnSurfaceVariant)
        val onSurface = MaterialColors.getColor(hintText, com.google.android.material.R.attr.colorOnSurface)
        val ids = intArrayOf(R.id.step1, R.id.step2, R.id.step3)
        for (i in ids.indices) {
            val step = findViewById<View>(ids[i])
            val num = step.findViewById<TextView>(R.id.stepNum)
            val label = step.findViewById<TextView>(R.id.stepLabel)
            val done = i < current
            val active = i <= current
            num.text = if (done) "✓" else (i + 1).toString()
            num.backgroundTintList = ColorStateList.valueOf(if (active) primary else idle)
            num.setTextColor(if (active) onPrimary else onIdle)
            label.text = steps[i]
            label.setTextColor(if (i == current) onSurface else onIdle)
        }
        findViewById<View>(R.id.line1).setBackgroundColor(if (current >= 1) primary else idle)
        findViewById<View>(R.id.line2).setBackgroundColor(if (current >= 2) primary else idle)
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
        doneBtn.text = "正在验证…"
        exec.execute {
            val cookie = CookieManager.getInstance().getCookie(PowerApi.SESSION_URL)
            val r = PowerApi.fetchRoom(UrlTransport, PowerApi.roomStateUrl(payProId, roomVerify),
                cookie ?: "", PowerApi.referer(payProId), Deadline.REQUEST_TIMEOUT_MS.toInt())
            runOnUiThread {
                binding = false
                doneBtn.isEnabled = true
                doneBtn.text = "已看到剩余电量, 完成绑定"
                if (r.ok && r.quantity != null) {
                    Prefs.saveBinding(this, payProId, roomVerify, r.roomLabel)
                    WebSession.adoptInteractiveLogin(this)
                    AlertNotify.cancelLogin(this)
                    Prefs.recordReading(this, r.quantity.toFloat())
                    saveCredsIfOptedIn()
                    PowerWidget.updateAll(this)
                    Toast.makeText(this,
                        "绑定成功 · ${r.roomLabel} 剩余 ${r.quantity}${r.unit}", Toast.LENGTH_LONG).show()
                    // 首次绑定没有首页在栈里; 重新绑定时首页 onResume 会自动刷新
                    if (!intent.getBooleanExtra(EXTRA_REBIND, false)) {
                        startActivity(Intent(this, MainActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
                    }
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


    /** 勾了"记住密码"且抓到了凭据就加密落盘; 没勾则清掉之前可能存过的 */
    private fun saveCredsIfOptedIn() {
        val remember = findViewById<CheckBox>(R.id.rememberCheck).isChecked
        val creds = capturedCreds
        if (remember && creds != null) {
            try {
                val o = JSONObject(creds)
                Credentials.save(this, o.optString("t", Credentials.TYPE_WX),
                    o.optString("u"), o.optString("p"), o.optString("cc"), o.optString("outid"))
            } catch (_: Exception) { }
        } else if (!remember) {
            Credentials.clear(this)
        }
    }

    override fun onDestroy() {
        webView.destroy()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_REBIND = "rebind"
    }
}
