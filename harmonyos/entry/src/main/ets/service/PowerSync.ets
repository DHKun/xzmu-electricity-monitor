import { formBindingData, formProvider } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Prefs, RunLock } from './Prefs';
import { AlertEval, AlertNotify } from './AlertEval';
import { Credentials } from './Credentials';
import { CookieJar } from './CookieJar';
import { HttpTransport } from './Http';
import { KitTransport } from './HttpClient';
import { PowerApi } from './PowerApi';
import { PowerLevel, PowerStatus, PowerView } from './PowerStatus';
import { CredsRead, Outcome, Stage, SyncCommit, SyncEngine, SyncReport, SyncSnapshot, SyncStore, Trigger } from './SyncEngine';

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
    if (v.needsLogin) {
      card.sub = '需要重新登录';
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

class PrefsSyncStore implements SyncStore {
  begin(): SyncSnapshot | null {
    if (!Prefs.getConfigured()) {
      return null;
    }
    const snapshot: SyncSnapshot = Prefs.syncSnapshot();
    // 卡片和后台进程读不到 WebView, 未迁移时只能用旧版快照; 成功后随提交落盘
    if (!Prefs.hasCookieJar()) {
      const jar: CookieJar = new CookieJar();
      jar.importPlain(PowerApi.HOST, PowerApi.SESSION_PATH, Prefs.getCookieSnapshot());
      snapshot.cookies = jar.serialize();
    }
    return snapshot;
  }

  creds(): CredsRead {
    return Credentials.forLogin();
  }

  commit(base: SyncSnapshot, commit: SyncCommit): Promise<boolean> {
    return Prefs.commitSync(base, commit);
  }
}

export class PowerSync {
  /** 同步入口: 首页、后台任务、桌面卡片共用; 文件锁保证跨进程同一时间只有一轮 */
  static async sync(trigger: Trigger, cancelled: () => boolean = () => false, onRecovering: () => void = () => {},
    http: HttpTransport = new KitTransport()): Promise<SyncReport> {
    Prefs.reload();
    const lock: RunLock | null = Prefs.tryRunLock();
    if (lock === null) {
      CardSync.pushAll(false);
      return new SyncReport(Outcome.BUSY, Stage.QUERY);
    }
    const startedAt: number = Date.now();
    try {
      const engine: SyncEngine = new SyncEngine(new PrefsSyncStore(), http, () => Date.now());
      const r: SyncReport = await engine.run(trigger, cancelled, onRecovering);
      Prefs.reload();
      let lowAlertBlocked: boolean = false;
      if (r.outcome === Outcome.OK && r.quantity !== null) {
        lowAlertBlocked = await AlertEval.evaluate(r.quantity, r.unit);
        await AlertNotify.cancelLogin();
      }
      const loginPending: boolean = Prefs.getNeedsLogin() && !Prefs.isManualAlerted();
      const loginPosted: boolean = loginPending && await AlertNotify.login();
      if (loginPosted) {
        await Prefs.setManualAlerted(true);
      }
      await Prefs.appendRun(startedAt, trigger, r, lowAlertBlocked || (loginPending && !loginPosted));
      CardSync.pushAll(false);
      return r;
    } finally {
      lock.release();
    }
  }
}
