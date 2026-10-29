package io.github.dhkun.xzmupower

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient

/**
 * 会话过期后的静默重新登录(无界面)。
 *
 * 做法等同于用户手动登录: 隐藏 WebView 打开授权页, 填入本机保存的账号密码、点登录按钮,
 * 由登录页自己的脚本提交。先试 force_login=false —— 若完美校园的 SSO 仍在, 会直接换到
 * 新会话, 连密码都不用填; 只有弹出登录表单时才自动填凭据。
 *
 * 成功回调 true 后, 新的会话 Cookie 已在 CookieManager 里, 调用方照常查询即可。
 * 出现验证码 / 密码错误 / 超时则回调 false, 调用方退回提示手动登录。
 */
class SilentLogin(private val activity: Context, private val container: ViewGroup) {

    private val main = Handler(Looper.getMainLooper())
    private var webView: WebView? = null
    private var done = false
    private var filled = false
    private var forcedOnce = false
    private var callback: ((Boolean) -> Unit)? = null

    @SuppressLint("SetJavaScriptEnabled")
    fun start(onResult: (Boolean) -> Unit) {
        if (!Credentials.has(activity)) {
            onResult(false)
            return
        }
        callback = onResult
        val wv = WebView(activity)
        webView = wv
        // 1x1 且全透明: 挂到视图树里让脚本正常跑, 用户看不见
        container.addView(wv, ViewGroup.LayoutParams(1, 1))
        wv.alpha = 0f
        wv.visibility = View.INVISIBLE

        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(wv, true)
        wv.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            userAgentString = PowerApi.UA
        }
        wv.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                if (done) return
                // 按解析出的 host 判断, 不能用 contains:
                // 授权页 URL 的 redirect_uri 参数里本身就含缴费域名字符串
                val host = runCatching { android.net.Uri.parse(url).host }.getOrNull()
                when {
                    // 已回到云缴费域名: 授权成功, 会话 Cookie 已就绪
                    host == PowerApi.HOST -> finish(true)
                    url.contains("api/authorize") -> handleAuthorize(view)
                }
            }
        }
        wv.loadUrl(PowerApi.AUTHORIZE_URL)
        // 整体超时
        main.postDelayed({ if (!done) finish(false) }, TIMEOUT_MS)
    }

    private fun handleAuthorize(view: WebView) {
        // 先判断是不是会话失效错误页("提示"), 是则换强制登录再来一遍
        view.evaluateJavascript("document.title") { title ->
            if (title != null && title.contains("提示") && !forcedOnce) {
                forcedOnce = true
                view.loadUrl(PowerApi.AUTHORIZE_URL_FORCE)
                return@evaluateJavascript
            }
            // 停在授权页说明需要登录表单; 填一次凭据并点登录
            if (!filled) {
                filled = true
                view.postDelayed({ fillAndSubmit(view) }, 600)
            }
        }
    }

    private fun fillAndSubmit(view: WebView) {
        if (done) return
        val type = Credentials.loginType(activity)
        val u = js(Credentials.username(activity))
        val p = js(Credentials.password(activity))
        val cc = js(Credentials.customerCode(activity))
        val outid = js(Credentials.outid(activity))
        // 填好对应登录方式的输入框, 再触发页面自己的登录按钮
        val script = if (type == Credentials.TYPE_ECARD) """
            (function(){
              try {
                var sw = document.getElementById('ecard-login-switch');
                if (sw) sw.click();
                setTimeout(function(){
                  var sel = document.getElementById('customerSelect');
                  if (sel && '$cc') { sel.value='$cc'; sel.dispatchEvent(new Event('change',{bubbles:true})); }
                  set('outid','$outid'); set('username_','$u'); set('password_','$p');
                  var b=document.getElementById('lgn'); if(b) b.click();
                }, 300);
              } catch(e){}
              function set(id,v){var e=document.getElementById(id); if(e){e.value=v; e.dispatchEvent(new Event('input',{bubbles:true}));}}
            })();
        """ else """
            (function(){
              function set(id,v){var e=document.getElementById(id); if(e){e.value=v; e.dispatchEvent(new Event('input',{bubbles:true}));}}
              try { set('username','$u'); set('password','$p');
                var b=document.getElementById('lgn'); if(b) b.click(); } catch(e){}
            })();
        """
        view.evaluateJavascript(script, null)
        // 登录是 ajax 提交, 密码错时页面不跳转; 轮询错误提示以便尽快失败,
        // 登录成功则会跳转到缴费域名, 由 onPageFinished 判定成功
        val ecard = type == Credentials.TYPE_ECARD
        for (delay in longArrayOf(if (ecard) 4000 else 2500, 5000, 8000)) {
            main.postDelayed({ checkError(view) }, delay)
        }
    }

    private fun checkError(view: WebView) {
        if (done) return
        view.evaluateJavascript(
            "(function(){var e=document.getElementById('login_err');return e?e.innerText:'';})()"
        ) { err ->
            // 报错(含验证码提示)或迟迟没跳转, 都视为自动登录失败
            if (!err.isNullOrBlank() && err.trim('"').isNotEmpty()) finish(false)
            // 没报错就等超时兜底
        }
    }

    private fun finish(ok: Boolean) {
        if (done) return
        done = true
        main.removeCallbacksAndMessages(null)
        webView?.let {
            it.stopLoading()
            container.removeView(it)
            it.destroy()
        }
        webView = null
        val cb = callback
        callback = null
        cb?.invoke(ok)
    }

    private fun js(s: String) = s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "")

    companion object {
        private const val TIMEOUT_MS = 25_000L
    }
}
