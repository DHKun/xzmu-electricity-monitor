import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { Prefs } from '../service/Prefs';
import { PowerApi, queryUrl, RoomState } from '../service/PowerApi';

@Entry
@Component
struct Setup {
  @State hintText: string = '① 请登录(完美校园帐号或校园卡认证)';
  @State loading: number = 0;
  private controller: webview.WebviewController = new webview.WebviewController();
  private pendingPayProId: string = '';
  private pendingRoomVerify: string = '';
  private binding: boolean = false;
  private lastAttemptKey: string = '';
  private lastAttemptAt: number = 0;
  private forceLoginTried: boolean = false;

  aboutToAppear(): void {
    Prefs.init(getContext(this) as common.UIAbilityContext).catch(() => {});
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
    const key: string = `${payProId}|${roomVerify}`;
    const now: number = Date.now();
    if (key === this.lastAttemptKey && now - this.lastAttemptAt < 5000) {
      return;
    }
    this.lastAttemptKey = key;
    this.lastAttemptAt = now;
    this.pendingPayProId = payProId;
    this.pendingRoomVerify = roomVerify;
    this.hintText = `检测到房间 ${roomVerify}, 正在验证会话…`;
    this.tryFinish();
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
    let cookie: string = PowerApi.sessionCookie();
    if (cookie.length === 0) {
      cookie = Prefs.getCookieSnapshot();
    }
    queryUrl(PowerApi.roomStateUrl(payProId, roomVerify), cookie, PowerApi.referer(payProId))
      .then((r: RoomState) => {
        this.binding = false;
        if (r.ok && r.quantity > 0) {
          const label: string = r.roomLabel.length > 0 ? r.roomLabel : roomVerify;
          Prefs.saveBinding(payProId, roomVerify, label, cookie, r.quantity).then(() => {
            this.getUIContext().getPromptAction().showToast({
              message: `绑定成功! ${label} 剩余 ${r.quantity}${r.unit}`
            });
            router.back();
          });
        } else if (r.sessionDead) {
          this.hintText = '会话无效, 请重新登录后再选择房间';
        } else {
          this.hintText = `验证失败: ${r.message}, 请确认页面已显示剩余电量`;
        }
      })
      .catch(() => {
        this.binding = false;
        this.hintText = '验证失败, 请重试';
      });
  }

  build() {
    Column() {
      // 步骤提示条
      Column() {
        Text(this.hintText)
          .fontSize(15)
          .fontColor($r('app.color.power_label'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(14)
        Divider().color($r('app.color.power_separator')).strokeWidth(1)
      }
      .width('100%')
      .backgroundColor($r('app.color.power_card'))

      Web({ src: PowerApi.authorizeUrl(false), controller: this.controller })
        .width('100%')
        .layoutWeight(1)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .userAgent(PowerApi.UA)
        .onProgressChange((event: OnProgressChangeEvent) => {
          this.loading = event.newProgress;
        })
        .onLoadIntercept((event) => {
          const url: string = event.data.getRequestUrl();
          this.handleIntercept(url);
          return false;
        })
        .onInterceptRequest((event: OnInterceptRequestEvent): WebResourceResponse => {
          // XHR 等资源请求只走这里(等价安卓 shouldInterceptRequest), 空响应=放行
          this.handleIntercept(event.request.getRequestUrl());
          return new WebResourceResponse();
        })
        .onPageEnd((event: OnPageEndEvent) => {
          const url: string = event.url;
          if (url.includes('api/authorize')) {
            this.injectSchoolSearch();
            this.controller.runJavaScript('document.title').then((title: string) => {
              if (title.includes('提示') && !this.forceLoginTried) {
                this.forceLoginTried = true;
                this.controller.loadUrl(PowerApi.authorizeUrl(true));
              }
            });
            const step: string = '① 请登录(完美校园帐号或校园卡认证)';
            this.hintText = step;
          } else if (url.includes('bill/type.do') || url.includes('pay.do')) {
            this.hintText = '② 请点进您的宿舍用电项目(如"秦汉校区公寓用电")';
          } else if (url.includes('selectPayProject.do')) {
            this.hintText = '③ 请选择您的房间, 看到"剩余电量"后自动完成绑定';
          }
        })

      LoadingProgress().width(24).height(24).color($r('app.color.power_orange'))
        .margin({ top: 8 }).visibility(this.loading > 0 && this.loading < 100 ? Visibility.Visible : Visibility.None)

      Button('我已看到剩余电量, 完成绑定')
        .width('100%')
        .height(52)
        .margin(16)
        .fontSize(17)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.power_orange'))
        .borderRadius(14)
        .onClick(() => this.tryFinish())

      Blank().height(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.power_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
