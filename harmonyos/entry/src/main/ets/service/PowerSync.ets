import { formBindingData, formProvider } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Prefs } from './Prefs';
import { PowerResult, queryRoomState, RoomState } from './PowerApi';
import { AlertEval, AlertNotify } from './AlertEval';
import { PowerLevel, PowerStatus, PowerView } from './PowerStatus';

const TAG: string = 'PowerSync';
const DOMAIN: number = 0x0000;

/** 桌面卡片绑定数据, 字段名与 PowerCard / PowerCardWide 的 @LocalStorageProp 一一对应 */
export class CardData {
  configured: boolean = false;
  qty: string = '--';
  room: string = '';
  level: number = PowerLevel.UNKNOWN;
  pct: number = 0;
  sub: string = '';
  time: string = '';
  busy: boolean = false;
}

export class CardSync {
  static build(busy: boolean): CardData {
    const v: PowerView = PowerStatus.load();
    const card: CardData = new CardData();
    card.configured = v.configured;
    card.qty = PowerStatus.fmtQty(v.qty);
    card.room = v.room.length > 0 ? v.room : '我的宿舍';
    card.level = v.level;
    card.pct = v.percent;
    card.time = PowerStatus.fmtShortTime(v.lastAt);
    card.busy = busy;
    if (v.sessionDead) {
      card.sub = '登录已过期';
    } else if (v.daysLeft >= 0) {
      card.sub = `约可用 ${v.daysLeft} 天`;
    } else {
      card.sub = PowerStatus.levelText(v.level);
    }
    return card;
  }

  static push(formId: string, card: CardData): void {
    const data: formBindingData.FormBindingData = formBindingData.createFormBindingData(card);
    formProvider.updateForm(formId, data).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'updateForm %{public}s failed: %{public}s', formId, e.message);
    });
  }

  static pushAll(busy: boolean): void {
    const card: CardData = CardSync.build(busy);
    const ids: string[] = Prefs.getFormIds();
    for (let i = 0; i < ids.length; i++) {
      CardSync.push(ids[i], card);
    }
  }
}

export class PowerSync {
  /**
   * 查询并把结果落到所有地方: 存储、低电量通知、桌面卡片.
   * liveCookie 为 WebView 里的实时会话(仅 App 进程能拿到), 为空时用快照.
   */
  static async syncNow(liveCookie: string): Promise<RoomState> {
    Prefs.reload();
    if (!Prefs.getConfigured()) {
      const r: RoomState = PowerResult.empty();
      r.message = '未绑定';
      return r;
    }
    const cookie: string = liveCookie.length > 0 ? liveCookie : Prefs.getCookieSnapshot();
    const r: RoomState = await queryRoomState(Prefs.getPayProId(), Prefs.getRoomVerify(), cookie);
    const refreshed: string = PowerSync.mergeSession(cookie, r.setCookie);
    if (r.ok && r.quantity > 0) {
      if (refreshed.length > 0) {
        await Prefs.setCookieSnapshot(refreshed);
      }
      await Prefs.recordReading(r.quantity);
      await AlertEval.evaluate(r.quantity, r.unit);
    } else if (r.sessionDead) {
      const wasDead: boolean = Prefs.isSessionDead();
      await Prefs.setSessionDead(true);
      if (!wasDead) {
        AlertNotify.publish('电费监控: 登录已过期', '打开 App 重新登录一次即可恢复自动查询');
      }
    }
    CardSync.pushAll(false);
    return r;
  }

  /** 服务端轮换 SESSION 时, 把新值合并进原 Cookie 串 */
  static mergeSession(cookie: string, setCookie: string): string {
    const m: RegExpMatchArray | null = setCookie.match(new RegExp('SESSION=([^;,\\s]+)'));
    if (m === null) {
      return cookie;
    }
    const fresh: string = `SESSION=${m[1]}`;
    if (cookie.length === 0) {
      return fresh;
    }
    if (cookie.includes('SESSION=')) {
      return cookie.replace(new RegExp('SESSION=[^;]*'), fresh);
    }
    return `${cookie}; ${fresh}`;
  }
}
