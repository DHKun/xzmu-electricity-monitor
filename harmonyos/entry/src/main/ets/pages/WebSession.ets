import { webview } from '@kit.ArkWeb';
import { CookieJar } from '../service/CookieJar';
import { PowerApi } from '../service/PowerApi';
import { Prefs } from '../service/Prefs';

/**
 * WebView 登录态与后台 Cookie 的唯一交接点, 只在 App 进程使用。
 * 持久存储是权威, WebView 只在交互登录后导入一次, 避免旧 Cookie 盖掉后台刚拿到的新会话。
 */
export class WebSession {
  private static read(): CookieJar {
    const jar: CookieJar = new CookieJar();
    try {
      // SESSION 的 Path=/CloudPayment/, 必须带路径取
      jar.importPlain(PowerApi.HOST, PowerApi.SESSION_PATH,
        webview.WebCookieManager.fetchCookieSync(PowerApi.SESSION_URL));
      jar.importPlain(PowerApi.OPEN_HOST, '/', webview.WebCookieManager.fetchCookieSync(PowerApi.OPEN_URL));
    } catch (e) {
      // WebView 内核未就绪时当作没有实时会话
    }
    return jar;
  }

  /** 绑定页验证查询要用的缴费域 Cookie 串 */
  static payCookie(): string {
    return WebSession.read().header(PowerApi.SESSION_URL, Date.now());
  }

  /** 验证查询可能已轮换会话, 它的响应 Cookie 要盖在 WebView 读到的值上 */
  static serialized(setCookies: string[]): string {
    const jar: CookieJar = WebSession.read();
    jar.store(PowerApi.SESSION_URL, setCookies, Date.now());
    return jar.serialize();
  }

  /** 用户刚完成登录: 换入新会话, 进行中的旧同步结果随之作废 */
  static async adopt(): Promise<void> {
    await Prefs.replaceSession(WebSession.serialized([]));
  }

  /** 升级自旧版: 从 WebView 与 Cookie 快照建立持久存储, 只做一次 */
  static async migrateIfNeeded(): Promise<void> {
    if (Prefs.hasCookieJar()) {
      return;
    }
    const jar: CookieJar = WebSession.read();
    if (!jar.has(PowerApi.HOST, 'SESSION')) {
      jar.importPlain(PowerApi.HOST, PowerApi.SESSION_PATH, Prefs.getCookieSnapshot());
    }
    await Prefs.seedCookieJar(jar.serialize());
  }
}
