import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE: string = 'config';
const MAX_SAMPLES: number = 120;

/** 一次电量读数 */
export class Sample {
  at: number = 0;
  qty: number = 0;
}

/**
 * 配置存储. App、卡片扩展、后台任务各跑在独立进程, Preferences 实例按进程缓存,
 * 所以每个进程入口先 reload(), 每次写入前也 reload(), 避免拿旧缓存覆盖别的进程写的数据.
 */
export class Prefs {
  private static ctx: common.Context | null = null;
  private static store: preferences.Preferences | null = null;

  static init(ctx: common.Context): void {
    Prefs.ctx = ctx;
    Prefs.reload();
  }

  /** 丢弃本进程缓存, 从磁盘重新读取 */
  static reload(): void {
    const ctx: common.Context | null = Prefs.ctx;
    if (ctx === null) {
      return;
    }
    try {
      preferences.removePreferencesFromCacheSync(ctx, STORE);
    } catch (e) {
      // 首次打开时缓存里本就没有
    }
    Prefs.store = preferences.getPreferencesSync(ctx, { name: STORE });
  }

  private static sp(): preferences.Preferences {
    if (!Prefs.store) {
      throw new Error('Prefs not initialized');
    }
    return Prefs.store;
  }

  /** 先 reload 再同步写入, 写入与落盘之间不让出线程 */
  private static async write(apply: (sp: preferences.Preferences) => void): Promise<void> {
    Prefs.reload();
    const sp: preferences.Preferences = Prefs.sp();
    apply(sp);
    await sp.flush();
  }

  static getConfigured(): boolean {
    return Prefs.sp().getSync('configured', false) as boolean;
  }

  static async setConfigured(v: boolean): Promise<void> {
    await Prefs.write((sp: preferences.Preferences) => sp.putSync('configured', v));
  }

  static getPayProId(): string {
    return Prefs.sp().getSync('payProId', '') as string;
  }

  static getRoomVerify(): string {
    return Prefs.sp().getSync('roomVerify', '') as string;
  }

  static getRoomLabel(): string {
    return Prefs.sp().getSync('roomLabel', '') as string;
  }

  static getThreshold(): number {
    return Prefs.sp().getSync('threshold', 20.0) as number;
  }

  static getCookieSnapshot(): string {
    return Prefs.sp().getSync('cookieSnapshot', '') as string;
  }

  static getLastQty(): number {
    return Prefs.sp().getSync('lastQty', -1.0) as number;
  }

  /** 最近一次成功查询的时间戳(ms), 0 表示从未成功 */
  static getLastAt(): number {
    return Prefs.sp().getSync('lastAt', 0) as number;
  }

  /** 上次充值后的最高读数, 作为仪表盘满格 */
  static getPeakQty(): number {
    return Prefs.sp().getSync('peakQty', -1.0) as number;
  }

  static isSessionDead(): boolean {
    return Prefs.sp().getSync('sessionDead', false) as boolean;
  }

  static isAlerted(): boolean {
    return Prefs.sp().getSync('alerted', false) as boolean;
  }

  static getSamples(): Sample[] {
    const raw: string = Prefs.sp().getSync('samples', '') as string;
    const out: Sample[] = [];
    if (raw.length === 0) {
      return out;
    }
    const items: string[] = raw.split(',');
    for (let i = 0; i < items.length; i++) {
      const kv: string[] = items[i].split(':');
      if (kv.length === 2) {
        const s: Sample = new Sample();
        s.at = Number(kv[0]);
        s.qty = Number(kv[1]);
        if (!isNaN(s.at) && !isNaN(s.qty)) {
          out.push(s);
        }
      }
    }
    return out;
  }

  static getFormIds(): string[] {
    const raw: string = Prefs.sp().getSync('formIds', '') as string;
    return raw.length > 0 ? raw.split(',') : [];
  }

  static async addFormId(formId: string): Promise<void> {
    await Prefs.write((sp: preferences.Preferences) => {
      const ids: string[] = Prefs.getFormIds();
      if (!ids.includes(formId)) {
        ids.push(formId);
        sp.putSync('formIds', ids.join(','));
      }
    });
  }

  static async removeFormId(formId: string): Promise<void> {
    await Prefs.write((sp: preferences.Preferences) => {
      const ids: string[] = Prefs.getFormIds().filter((id: string) => id !== formId);
      sp.putSync('formIds', ids.join(','));
    });
  }

  static async saveBinding(payProId: string, roomVerify: string, roomLabel: string,
                           cookie: string, qty: number): Promise<void> {
    await Prefs.write((sp: preferences.Preferences) => {
      sp.putSync('payProId', payProId);
      sp.putSync('roomVerify', roomVerify);
      sp.putSync('roomLabel', roomLabel);
      sp.putSync('cookieSnapshot', cookie);
      sp.putSync('samples', '');
      sp.putSync('peakQty', -1.0);
      sp.putSync('sessionDead', false);
      sp.putSync('alerted', false);
      sp.putSync('configured', true);
      Prefs.applyReading(sp, qty);
    });
  }

  static async setThreshold(v: number): Promise<void> {
    await Prefs.write((sp: preferences.Preferences) => sp.putSync('threshold', v));
  }

  static async setCookieSnapshot(v: string): Promise<void> {
    if (v.length > 0) {
      await Prefs.write((sp: preferences.Preferences) => sp.putSync('cookieSnapshot', v));
    }
  }

  static async setSessionDead(v: boolean): Promise<void> {
    await Prefs.write((sp: preferences.Preferences) => sp.putSync('sessionDead', v));
  }

  /** 记录一次成功读数: 更新最新值、满格基准、历史采样 */
  static async recordReading(qty: number): Promise<void> {
    await Prefs.write((sp: preferences.Preferences) => {
      sp.putSync('sessionDead', false);
      Prefs.applyReading(sp, qty);
    });
  }

  private static applyReading(sp: preferences.Preferences, qty: number): void {
    const now: number = Date.now();
    const peak: number = sp.getSync('peakQty', -1.0) as number;
    const last: number = sp.getSync('lastQty', -1.0) as number;
    // 读数上涨视为充值, 满格基准跟着重置
    if (peak <= 0 || qty > peak || (last >= 0 && qty > last + 0.5)) {
      sp.putSync('peakQty', qty);
    }
    sp.putSync('lastQty', qty);
    sp.putSync('lastAt', now);
    const samples: Sample[] = Prefs.getSamples();
    const prev: Sample | undefined = samples.length > 0 ? samples[samples.length - 1] : undefined;
    // 同一读数半小时内只记一次, 采样只用于估算日均
    if (prev === undefined || prev.qty !== qty || now - prev.at > 30 * 60 * 1000) {
      const s: Sample = new Sample();
      s.at = now;
      s.qty = qty;
      samples.push(s);
    }
    const kept: Sample[] = samples.slice(Math.max(0, samples.length - MAX_SAMPLES));
    sp.putSync('samples', kept.map((x: Sample) => `${x.at}:${x.qty}`).join(','));
  }

  /** 调试构建专用: 写入一套示例数据, 便于在模拟器上不登录就查看已绑定界面 */
  static async seedDemo(): Promise<void> {
    const now: number = Date.now();
    const h: number = 3600000;
    // 近 7 天每 6 小时一个读数, 中间有一次充值
    const qtys: number[] = [62, 59, 55, 52, 49, 46, 42, 38, 300, 297, 293, 289, 286, 282, 277, 273,
      270, 266, 262, 259, 256, 252, 248, 244];
    const parts: string[] = [];
    for (let i = 0; i < qtys.length; i++) {
      parts.push(`${now - (qtys.length - 1 - i) * 6 * h}:${qtys[i]}`);
    }
    await Prefs.write((sp: preferences.Preferences) => {
      sp.putSync('configured', true);
      sp.putSync('payProId', '3148');
      sp.putSync('roomVerify', '101-1--9-902');
      sp.putSync('roomLabel', '902房间');
      sp.putSync('cookieSnapshot', 'SESSION=demo');
      sp.putSync('threshold', 20.0);
      sp.putSync('lastQty', 244.0);
      sp.putSync('peakQty', 300.0);
      sp.putSync('lastAt', now);
      sp.putSync('sessionDead', false);
      sp.putSync('alerted', false);
      sp.putSync('samples', parts.join(','));
    });
  }

  static async setAlerted(v: boolean): Promise<void> {
    await Prefs.write((sp: preferences.Preferences) => sp.putSync('alerted', v));
  }
}
