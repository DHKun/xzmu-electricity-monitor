import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { Prefs } from '../service/Prefs';
import { PowerApi, queryUrl, RoomState } from '../service/PowerApi';
import { CardSync } from '../service/PowerSync';
import { bumpData } from './Actions';
import { Credentials, CredData } from '../service/Credentials';

const STEPS: string[] = ['登录', '选择项目', '选择房间'];

let nativeHandler: ((url: string) => void) | null = null;
/** 用户在登录页点登录时抓到的凭据 JSON, 绑定成功且勾选"记住密码"后才落盘 */
let capturedCredsJson: string = '';

/** 登录页: 点登录时读下输入框里的账号密码, 经 xzmuNative.onCreds 回传 */
const CAPTURE_SCRIPT: string = `(function(){
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
      if (d.p && window.xzmuNative) window.xzmuNative.onCreds(JSON.stringify(d));
    } catch(e){}
    function val(id){var e=document.getElementById(id); return e?e.value:'';}
  }, true);
})()`;

/** 注入网页的桥: H5 的余额查询 XHR 由此上报原生 */
class JsBridge {
  onRoomState(url: string): void {
    const h = nativeHandler;
    if (h !== null) {
      h(url);
    }
  }

  onCreds(json: string): void {
    capturedCredsJson = json;
  }
}

const HOOK_SCRIPT: string = `(function(){
  if (window.__xzmuScan) return;
  window.__xzmuScan = true;
  function report(u){
    u = String(u);
    if (u.indexOf('getRoomState.do') < 0) return;
    try { console.log('XZMU_REPORT:' + u); } catch(e) {}
    try { if (window.xzmuNative) window.xzmuNative.onRoomState(u); } catch(e) {}
  }
  var origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(method, url){ try { report(url); } catch(e) {} return origOpen.apply(this, arguments); };
  if (window.fetch) {
    var origFetch = window.fetch;
    window.fetch = function(input, init){ try { report(typeof input === 'string' ? input : (input && input.url) || ''); } catch(e) {} return origFetch.apply(this, arguments); };
  }
  var last = '';
  setInterval(function(){
    var ta = document.getElementById('thirdAccount');
    var m = location.href.match(/[?&]payProId=([0-9]+)/);
    if (ta && ta.value && m && ta.value !== last) {
      last = ta.value;
      report('getRoomState.do?payProId=' + m[1] + '&roomverify=' + encodeURIComponent(ta.value));
    }
  }, 500);
})()`;

/**
 * 原生主动轮询: 不依赖 JS 桥, 直接读 #thirdAccount 与 URL 里的 payProId.
 * 返回 XZMU|桥类型|脚本已注入|payProId|roomverify(URI 编码)
 */
const POLL_SCRIPT: string = `(function(){
  var ta = document.getElementById('thirdAccount');
  var m = location.href.match(/[?&]payProId=([0-9]+)/);
  return 'XZMU|' + (typeof window.xzmuNative) + '|' + (window.__xzmuScan === true) + '|' +
    (m ? m[1] : '') + '|' + (ta && ta.value ? encodeURIComponent(ta.value) : '');
})()`;

const CONSOLE_PREFIX: string = 'XZMU_REPORT:';

@Component
export struct SetupPage {
  @State step: number = 0;
  @State hintText: string = '用完美校园帐号或校园卡认证登录';
  @State loading: number = 0;
  @State verifying: boolean = false;
  @State rememberCreds: boolean = true;
  private stack: NavPathStack | null = null;
  private controller: webview.WebviewController = new webview.WebviewController();
  private pendingPayProId: string = '';
  private pendingRoomVerify: string = '';
  private binding: boolean = false;
  private lastAttemptKey: string = '';
  private forceLoginTried: boolean = false;
  private currentUrl: string = '';
  private pollTimer: number = -1;

  aboutToAppear(): void {
    nativeHandler = (url: string) => {
      this.handleIntercept(url);
    };
    Prefs.init(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.pollTimer = setInterval(() => {
      this.pollPage();
    }, 1000);
  }

  aboutToDisappear(): void {
    nativeHandler = null;
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /** 缴费域名下每秒读一次页面状态; 钩子脚本没跑就补注入 */
  pollPage(): void {
    if (this.binding || !this.currentUrl.includes(PowerApi.HOST)) {
      return;
    }
    try {
      this.controller.runJavaScript(POLL_SCRIPT).then((raw: string) => {
        const at: number = raw.indexOf('XZMU|');
        if (at < 0) {
          return;
        }
        // 结果可能带 JSON 引号, 去掉首尾引号再拆
        const parts: string[] = raw.substring(at).replace(new RegExp('"+$'), '').split('|');
        if (parts.length < 5) {
          return;
        }
        if (parts[2] !== 'true') {
          this.injectHook();
        }
        if (parts[3].length > 0 && parts[4].length > 0) {
          this.handleIntercept(`getRoomState.do?payProId=${parts[3]}&roomverify=${parts[4]}`);
        }
      }).catch(() => {});
    } catch (e) {
      // controller 尚未挂载
    }
  }

  injectHook(): void {
    try {
      this.controller.runJavaScript(HOOK_SCRIPT).catch(() => {});
    } catch (e) {
      // controller 尚未挂载
    }
  }

  /** 登录页: 把"选择学校"下拉换成可搜索弹层(与安卓版同一脚本) */
  injectSchoolSearch(): void {
    this.controller.runJavaScript(`(function(){
      var sel = document.getElementById('customerSelect');
      if (!sel || sel.__searchable) return;
      var opts = [];
      for (var i = 0; i < sel.options.length; i++) {
        var o = sel.options[i];
        if (o.value) opts.push({v: o.value, t: o.text.trim()});
      }
      if (opts.length < 2) return;
      sel.__searchable = true;
      sel.style.display = 'none';
      var parent = sel.parentNode;
      var box = document.createElement('input');
      box.setAttribute('readonly','readonly');
      box.placeholder = '🔍 点击搜索学校';
      box.style.cssText = 'width:100%;box-sizing:border-box;padding:12px;font-size:15px;border:1px solid #eee;border-radius:8px;background:#f7f7f7;color:#333;';
      parent.insertBefore(box, sel);
      var overlay = document.createElement('div');
      overlay.style.cssText = 'position:fixed;left:0;top:0;right:0;bottom:0;background:rgba(0,0,0,.45);display:none;z-index:99999;';
      var panel = document.createElement('div');
      panel.style.cssText = 'position:absolute;left:0;right:0;bottom:0;top:12%;background:#fff;border-radius:12px 12px 0 0;display:flex;flex-direction:column;overflow:hidden;';
      var search = document.createElement('input');
      search.placeholder = '输入学校名称关键字';
      search.style.cssText = 'margin:12px;padding:12px;font-size:16px;border:1px solid #FFB830;border-radius:8px;outline:none;';
      var list = document.createElement('div');
      list.style.cssText = 'flex:1;overflow-y:auto;-webkit-overflow-scrolling:touch;';
      panel.appendChild(search); panel.appendChild(list); overlay.appendChild(panel);
      document.body.appendChild(overlay);
      function render(kw){
        list.innerHTML='';
        var k=(kw||'').trim().toLowerCase(); var n=0;
        for (var i=0;i<opts.length && n<80;i++){
          var it=opts[i];
          if (k && it.t.toLowerCase().indexOf(k)<0) continue;
          n++;
          var d=document.createElement('div');
          d.textContent=it.t;
          d.style.cssText='padding:14px 16px;border-bottom:1px solid #f2f2f2;font-size:15px;color:#333;';
          (function(item){
            d.onclick=function(){
              sel.value=item.v;
              sel.dispatchEvent(new Event('change',{bubbles:true}));
              box.value=item.t;
              overlay.style.display='none';
            };
          })(it);
          list.appendChild(d);
        }
        if(n===0){ list.innerHTML='<div style="padding:24px;text-align:center;color:#999;">没有匹配的学校</div>'; }
      }
      box.onclick=function(){ overlay.style.display='block'; search.value=''; render(''); setTimeout(function(){search.focus();},120); };
      overlay.onclick=function(e){ if(e.target===overlay) overlay.style.display='none'; };
      search.oninput=function(){ render(search.value); };
    })()`);
  }

  /** 拦截 getRoomState.do, 提取绑定参数并原生验证 */
  handleIntercept(url: string): void {
    if (this.binding || !url.includes('getRoomState.do')) {
      return;
    }
    const payProId: string = PowerApi.extractParam(url, 'payProId');
    const roomVerify: string = PowerApi.extractParam(url, 'roomverify');
    if (payProId.length === 0 || roomVerify.length === 0) {
      return;
    }
    // 三条通道会重复上报同一房间; 自动验证每页每房间只做一次, 失败后靠按钮重试
    const key: string = `${payProId}|${roomVerify}`;
    if (key === this.lastAttemptKey) {
      return;
    }
    this.lastAttemptKey = key;
    this.pendingPayProId = payProId;
    this.pendingRoomVerify = roomVerify;
    this.hintText = `检测到房间 ${roomVerify}, 正在验证…`;
    this.tryFinish();
  }

  /** 勾了"记住密码"且抓到了凭据就存进安全存储; 没勾则清掉之前可能存过的 */
  saveCredsIfOptedIn(): void {
    if (this.rememberCreds && capturedCredsJson.length > 0) {
      try {
        const o: Record<string, string> = JSON.parse(capturedCredsJson) as Record<string, string>;
        const c: CredData = new CredData();
        c.type = o.t !== undefined ? o.t : 'wx';
        c.username = o.u !== undefined ? o.u : '';
        c.password = o.p !== undefined ? o.p : '';
        c.customerCode = o.cc !== undefined ? o.cc : '';
        c.outid = o.outid !== undefined ? o.outid : '';
        Credentials.save(c);
      } catch (e) {
      }
    } else if (!this.rememberCreds) {
      Credentials.clear();
    }
  }

  tryFinish(): void {
    const payProId: string = this.pendingPayProId;
    const roomVerify: string = this.pendingRoomVerify;
    if (this.binding) {
      return;
    }
    if (payProId.length === 0 || roomVerify.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请先在页面中选择房间' });
      return;
    }
    this.binding = true;
    this.verifying = true;
    let cookie: string = PowerApi.sessionCookie();
    if (cookie.length === 0) {
      cookie = Prefs.getCookieSnapshot();
    }
    queryUrl(PowerApi.roomStateUrl(payProId, roomVerify), cookie, PowerApi.referer(payProId))
      .then((r: RoomState) => {
        this.binding = false;
        this.verifying = false;
        if (r.ok && r.quantity > 0) {
          const label: string = r.roomLabel.length > 0 ? r.roomLabel : roomVerify;
          Prefs.saveBinding(payProId, roomVerify, label, cookie, r.quantity).then(() => {
            CardSync.pushAll(false);
            this.saveCredsIfOptedIn();
            bumpData();
            this.getUIContext().getPromptAction().showToast({
              message: `绑定成功 · ${label} 剩余 ${r.quantity}${r.unit}`
            });
            if (this.stack !== null) {
              // 可能是从设置页进来的, 绑定成功直接回首页
              this.stack.clear();
            }
          });
        } else if (r.sessionDead) {
          this.hintText = '会话无效, 请重新登录后再选择房间';
        } else {
          this.hintText = `验证失败: ${r.message}, 请确认页面已显示剩余电量`;
        }
      })
      .catch(() => {
        this.binding = false;
        this.verifying = false;
        this.hintText = '验证失败, 请重试';
      });
  }

  @Builder
  stepBar() {
    Row() {
      ForEach(STEPS, (label: string, i: number) => {
        if (i > 0) {
          Divider()
            .strokeWidth(2)
            .color(i <= this.step ? $r('app.color.set_blue') : $r('app.color.power_separator'))
            .layoutWeight(1)
            .margin({ left: 6, right: 6, bottom: 18 })
        }
        Column({ space: 4 }) {
          Stack() {
            if (i < this.step) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(14)
                .fontColor([Color.White])
            } else {
              Text(String(i + 1))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(i === this.step ? Color.White : $r('app.color.power_secondary'))
            }
          }
          .width(26)
          .height(26)
          .borderRadius(13)
          .backgroundColor(i <= this.step ? $r('app.color.set_blue') : $r('app.color.power_fill'))

          Text(label)
            .fontSize(12)
            .fontColor(i === this.step ? $r('app.color.power_label') : $r('app.color.power_secondary'))
        }
      }, (label: string) => label)
    }
    .width('100%')
    .padding({ left: 24, right: 24 })
  }

  build() {
    NavDestination() {
      Column() {
        Column({ space: 10 }) {
          this.stepBar()
          Row({ space: 6 }) {
            if (this.verifying) {
              LoadingProgress().width(16).height(16).color($r('app.color.set_blue'))
            }
            Text(this.hintText)
              .fontSize(13)
              .fontColor($r('app.color.power_secondary'))
              .textAlign(TextAlign.Center)
          }
        }
        .width('100%')
        .padding({ top: 4, bottom: 12 })

        Stack({ alignContent: Alignment.Top }) {
          Web({ src: PowerApi.authorizeUrl(false), controller: this.controller })
            .width('100%')
            .height('100%')
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .userAgent(PowerApi.UA)
            .onProgressChange((event: OnProgressChangeEvent) => {
              this.loading = event.newProgress;
            })
            .javaScriptProxy({
              object: new JsBridge(),
              name: 'xzmuNative',
              methodList: ['onRoomState', 'onCreds'],
              controller: this.controller
            })
            .onConsole((event: OnConsoleEvent) => {
              const msg: string = event.message.getMessage();
              if (msg.startsWith(CONSOLE_PREFIX)) {
                this.handleIntercept(msg.substring(CONSOLE_PREFIX.length));
              }
              return false;
            })
            .onPageEnd((event: OnPageEndEvent) => {
              const url: string = event.url;
              this.currentUrl = url;
              this.lastAttemptKey = '';
              if (url.includes(PowerApi.HOST)) {
                this.injectHook();
              }
              if (url.includes('api/authorize')) {
                this.injectSchoolSearch();
                this.controller.runJavaScript(CAPTURE_SCRIPT).catch(() => {});
                this.controller.runJavaScript('document.title').then((title: string) => {
                  if (title.includes('提示') && !this.forceLoginTried) {
                    this.forceLoginTried = true;
                    this.controller.loadUrl(PowerApi.authorizeUrl(true));
                  }
                });
                this.step = 0;
                this.hintText = '用完美校园帐号或校园卡认证登录';
              } else if (url.includes('bill/type.do') || url.includes('pay.do')) {
                this.step = 1;
                this.hintText = '点进宿舍用电项目, 如"秦汉校区公寓用电"';
              } else if (url.includes('selectPayProject.do')) {
                this.step = 2;
                this.hintText = '选择房间, 显示剩余电量后自动完成绑定';
              }
            })

          // 顶部细进度条, 替代原来的转圈
          Progress({ value: this.loading, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(2)
            .color($r('app.color.set_blue'))
            .backgroundColor(Color.Transparent)
            .style({ strokeWidth: 2 })
            .visibility(this.loading > 0 && this.loading < 100 ? Visibility.Visible : Visibility.None)
        }
        .width('100%')
        .layoutWeight(1)
        .borderRadius({ topLeft: 20, topRight: 20 })
        .clip(true)

        Row({ space: 8 }) {
          Checkbox()
            .select(this.rememberCreds)
            .selectedColor($r('app.color.set_blue'))
            .width(20)
            .height(20)
            .onChange((v: boolean) => { this.rememberCreds = v; })
          Text('记住密码, 会话过期时自动续期(加密存本机)')
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 18, right: 16, top: 4 })
        .onClick(() => { this.rememberCreds = !this.rememberCreds; })

        Row() {
          Button({ type: ButtonType.Capsule }) {
            Row({ space: 8 }) {
              if (this.verifying) {
                LoadingProgress().width(20).height(20).color(Color.White)
              }
              Text(this.verifying ? '正在验证…' : '已看到剩余电量, 完成绑定')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
            }
          }
          .width('100%')
          .height(48)
          .backgroundColor($r('app.color.set_blue'))
          .enabled(!this.verifying)
          .onClick(() => this.tryFinish())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 0, right: 0 })
    }
    .title('绑定宿舍', { backgroundColor: $r('sys.color.background_secondary') })
    .backgroundColor($r('sys.color.background_secondary'))
    .onReady((ctx: NavDestinationContext) => {
      this.stack = ctx.pathStack;
    })
  }
}
