import { webview } from '@kit.ArkWeb';
import { PowerApi } from '../service/PowerApi';
import { CredData } from '../service/Credentials';

/** 从 URL 取 host(去端口); 不能用 includes, 授权页 URL 的 redirect_uri 参数里含缴费域名 */
function hostOf(u: string): string {
  const m: RegExpMatchArray | null = u.match(new RegExp('^https?://([^/]+)'));
  return m !== null ? m[1].split(':')[0] : '';
}

/**
 * 会话过期后的静默重新登录(无界面)。1×1 全透明的 Web 打开授权页,
 * 先试 force_login=false —— 完美校园 SSO 仍在则直接换新会话; 弹出登录表单时
 * 才用本机保存的账号密码自动填、点登录(等同用户手动登录)。
 *
 * 回到缴费域名即成功(新会话 Cookie 已就绪); 报错/验证码/超时则失败。
 */
@Component
export struct SilentWeb {
  creds: CredData = new CredData();
  onResult: (ok: boolean) => void = () => {};
  private controller: webview.WebviewController = new webview.WebviewController();
  private filled: boolean = false;
  private forced: boolean = false;
  private finished: boolean = false;
  private timer: number = -1;

  aboutToAppear(): void {
    this.timer = setTimeout(() => this.finish(false), 25000);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  finish(ok: boolean): void {
    if (this.finished) {
      return;
    }
    this.finished = true;
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.onResult(ok);
  }

  handleAuthorize(): void {
    this.controller.runJavaScript('document.title').then((title: string) => {
      const t: string = title.replace(new RegExp('"', 'g'), '');
      if (t.includes('提示') && !this.forced) {
        this.forced = true;
        this.controller.loadUrl(PowerApi.authorizeUrl(true));
        return;
      }
      if (!this.filled) {
        this.filled = true;
        setTimeout(() => this.fillSubmit(), 600);
      }
    }).catch(() => {});
  }

  fillSubmit(): void {
    if (this.finished) {
      return;
    }
    const u: string = this.jsStr(this.creds.username);
    const p: string = this.jsStr(this.creds.password);
    const cc: string = this.jsStr(this.creds.customerCode);
    const outid: string = this.jsStr(this.creds.outid);
    let script: string;
    if (this.creds.type === 'ecard') {
      script = `(function(){
        try {
          var sw=document.getElementById('ecard-login-switch'); if(sw) sw.click();
          setTimeout(function(){
            var sel=document.getElementById('customerSelect');
            if(sel && '${cc}'){ sel.value='${cc}'; sel.dispatchEvent(new Event('change',{bubbles:true})); }
            set('outid','${outid}'); set('username_','${u}'); set('password_','${p}');
            var b=document.getElementById('lgn'); if(b) b.click();
          }, 300);
        } catch(e){}
        function set(id,v){var e=document.getElementById(id); if(e){e.value=v; e.dispatchEvent(new Event('input',{bubbles:true}));}}
      })()`;
    } else {
      script = `(function(){
        function set(id,v){var e=document.getElementById(id); if(e){e.value=v; e.dispatchEvent(new Event('input',{bubbles:true}));}}
        try { set('username','${u}'); set('password','${p}');
          var b=document.getElementById('lgn'); if(b) b.click(); } catch(e){}
      })()`;
    }
    this.controller.runJavaScript(script).catch(() => {});
    // 登录是 ajax, 密码错不跳转; 轮询错误提示尽快失败, 成功则跳转到缴费域名
    const first: number = this.creds.type === 'ecard' ? 4000 : 2500;
    setTimeout(() => this.checkError(), first);
    setTimeout(() => this.checkError(), 5000);
    setTimeout(() => this.checkError(), 8000);
  }

  checkError(): void {
    if (this.finished) {
      return;
    }
    this.controller.runJavaScript(
      `(function(){var e=document.getElementById('login_err');return e?e.innerText:'';})()`
    ).then((r: string) => {
      const s: string = r.replace(new RegExp('"', 'g'), '').trim();
      if (s.length > 0) {
        this.finish(false);
      }
    }).catch(() => {});
  }

  private jsStr(s: string): string {
    return s.replace(new RegExp('\\\\', 'g'), '\\\\').replace(new RegExp("'", 'g'), "\\'");
  }

  build() {
    Web({ src: PowerApi.authorizeUrl(false), controller: this.controller })
      .width(1)
      .height(1)
      .opacity(0)
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .userAgent(PowerApi.UA)
      .onPageEnd((event: OnPageEndEvent) => {
        if (this.finished) {
          return;
        }
        const host: string = hostOf(event.url);
        if (host === PowerApi.HOST) {
          this.finish(true);
        } else if (event.url.includes('api/authorize')) {
          this.handleAuthorize();
        }
      })
  }
}
