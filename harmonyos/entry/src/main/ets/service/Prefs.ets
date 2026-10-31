import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Outcome, RecoveryState, Stage, SyncCommit, SyncReport, SyncSnapshot, Trigger } from './SyncEngine';

const STORE: string = 'config';
const MAX_SAMPLES: number = 120;
const MAX_RUNS: number = 30;

/** 持有期间其他进程拿不到同一把锁; 进程退出时系统自动释放, 不会卡死 */
export class RunLock {
  private file: fileIo.File;

  constructor(file: fileIo.File) {
    this.file = file;
  }

  release(): void {
    try {
      this.file.unlock();
    } catch (e) {
      // 关闭文件同样会释放
    }
    fileIo.closeSync(this.file);
  }
}

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

  /** 自动恢复已无能为力, 需要用户手动登录 */
  static getNeedsLogin(): boolean {
    return Prefs.sp().getSync('needsLogin', false) as boolean;
  }

  static isManualAlerted(): boolean {
    return Prefs.sp().getSync('manualAlerted', false) as boolean;
  }

  static async setManualAlerted(v: boolean): Promise<void> {
    await Prefs.write((sp: preferences.Preferences) => sp.putSync('manualAlerted', v));
  }

  /** 持久 Cookie, 没有时表示尚未从旧版迁移 */
  static hasCookieJar(): boolean {
    return Prefs.sp().hasSync('cookieJar');
  }

  private static lockFile(name: string): fileIo.File {
    const ctx: common.Context | null = Prefs.ctx;
    if (ctx === null) {
      throw new Error('Prefs not initialized');
    }
    return fileIo.openSync(`${ctx.filesDir}/${name}`, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
  }

  /** 整轮同步的跨进程互斥; 已被占用时返回 null */
  static tryRunLock(): RunLock | null {
    const file: fileIo.File = Prefs.lockFile('sync.lock');
    try {
      file.tryLock(true);
      return new RunLock(file);
    } catch (e) {
      fileIo.closeSync(file);
      return null;
    }
  }

  /** 绑定、会话、提交的"读检查再写"临界区; reload 只是刷新缓存, 不是互斥 */
  private static async locked(body: () => Promise<void>): Promise<void> {
    const file: fileIo.File = Prefs.lockFile('state.lock');
    const lock: RunLock = new RunLock(file);
    try {
      await file.lock(true);
      await body();
    } finally {
      lock.release();
    }
  }

  private static gen(sp: preferences.Preferences, key: string): number {
    return sp.getSync(key, 0) as number;
  }

  private static putRecovery(sp: preferences.Preferences, r: RecoveryState): void {
    sp.putSync('failCount', r.failCount);
    sp.putSync('nextAttemptAt', r.nextAttemptAt);
    sp.putSync('authBackoff', r.authBackoff);
    sp.putSync('needsLogin', r.needsLogin);
    sp.putSync('lastOutcome', r.lastOutcome);
  }

  private static recovery(): RecoveryState {
    const sp: preferences.Preferences = Prefs.sp();
    const r: RecoveryState = new RecoveryState();
    r.failCount = sp.getSync('failCount', 0) as number;
    r.nextAttemptAt = sp.getSync('nextAttemptAt', 0) as number;
    r.authBackoff = sp.getSync('authBackoff', false) as boolean;
    r.needsLogin = sp.getSync('needsLogin', false) as boolean;
    r.lastOutcome = sp.getSync('lastOutcome', '') as string;
    return r;
  }

  static syncSnapshot(): SyncSnapshot {
    const sp: preferences.Preferences = Prefs.sp();
    const s: SyncSnapshot = new SyncSnapshot();
    s.bindingGen = Prefs.gen(sp, 'bindingGen');
    s.sessionGen = Prefs.gen(sp, 'sessionGen');
    s.payProId = Prefs.getPayProId();
    s.roomVerify = Prefs.getRoomVerify();
    s.cookies = sp.getSync('cookieJar', '') as string;
    s.state = Prefs.recovery();
    return s;
  }

  /** 一轮同步的结果一次性落盘; 期间绑定或会话变过就整体放弃 */
  static async commitSync(base: SyncSnapshot, c: SyncCommit): Promise<boolean> {
    let committed: boolean = false;
    await Prefs.locked(async () => {
      await Prefs.write((sp: preferences.Preferences) => {
        if (!Prefs.getConfigured() || Prefs.gen(sp, 'bindingGen') !== base.bindingGen ||
          Prefs.gen(sp, 'sessionGen') !== base.sessionGen) {
          return;
        }
        Prefs.putRecovery(sp, c.state);
        if (!c.state.needsLogin) {
          sp.putSync('manualAlerted', false);
        }
        if (c.cookies !== null) {
          sp.putSync('cookieJar', c.cookies);
        }
        if (c.quantity !== null) {
          Prefs.applyReading(sp, c.quantity);
        }
        committed = true;
      });
    });
    return committed;
  }

  static async seedCookieJar(cookies: string): Promise<void> {
    await Prefs.locked(async () => {
      await Prefs.write((sp: preferences.Preferences) => {
        if (!sp.hasSync('cookieJar')) {
          sp.putSync('cookieJar', cookies);
        }
      });
    });
  }

  /** 新的交互登录生效: 更新会话代次, 让进行中的同步作废, 并解除认证退避 */
  static async replaceSession(cookies: string): Promise<void> {
    await Prefs.locked(async () => {
      await Prefs.write((sp: preferences.Preferences) => {
        sp.putSync('cookieJar', cookies);
        sp.putSync('sessionGen', Prefs.gen(sp, 'sessionGen') + 1);
        const r: RecoveryState = Prefs.recovery();
        r.failCount = 0;
        r.nextAttemptAt = 0;
        r.authBackoff = false;
        Prefs.putRecovery(sp, r);
      });
    });
  }

  /** 登录凭据变了: 进行中的认证结果不得再写回 */
  static async bumpSessionGen(): Promise<void> {
    await Prefs.locked(async () => {
      await Prefs.write((sp: preferences.Preferences) => {
        sp.putSync('sessionGen', Prefs.gen(sp, 'sessionGen') + 1);
      });
    });
  }

  /** 最近的执行记录, 用于判断是没被调度、网络失败还是恢复失败; 不含账号、房间与 Cookie */
  static getRunLog(): string[] {
    const raw: string = Prefs.sp().getSync('runLog', '') as string;
    return raw.length > 0 ? raw.split('\n') : [];
  }

  static async appendRun(startedAt: number, trigger: Trigger, r: SyncReport, notifyBlocked: boolean): Promise<void> {
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    const d: Date = new Date(startedAt);
    const time: string = `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
      `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
    // 认证阶段的失败原因是固定文案; 查询阶段的 message 可能带响应原文, 不记录
    const failed: boolean = r.stage !== Stage.QUERY && (r.outcome === Outcome.UNKNOWN || r.outcome === Outcome.TRANSIENT);
    const why: string = failed ? ` ${r.message.substring(0, 60)}` : '';
    const note: string = notifyBlocked ? ' 通知受限' : '';
    const line: string = `${time} ${trigger} ${r.stage} ${r.outcome} ${Date.now() - startedAt}ms${why}${note}`;
    await Prefs.write((sp: preferences.Preferences) => {
      const lines: string[] = Prefs.getRunLog();
      lines.push(line);
      sp.putSync('runLog', lines.slice(Math.max(0, lines.length - MAX_RUNS)).join('\n'));
    });
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

  /** 绑定新房间: 读数历史、告警与恢复状态一并重置, 代次变化让进行中的旧同步作废 */
  static async saveBinding(payProId: string, roomVerify: string, roomLabel: string,
                           cookies: string, qty: number): Promise<void> {
    await Prefs.locked(async () => {
      await Prefs.write((sp: preferences.Preferences) => {
        sp.putSync('payProId', payProId);
        sp.putSync('roomVerify', roomVerify);
        sp.putSync('roomLabel', roomLabel);
        sp.putSync('cookieJar', cookies);
        sp.putSync('samples', '');
        sp.putSync('peakQty', -1.0);
        sp.putSync('alerted', false);
        sp.putSync('manualAlerted', false);
        sp.putSync('configured', true);
        sp.putSync('bindingGen', Prefs.gen(sp, 'bindingGen') + 1);
        Prefs.putRecovery(sp, new RecoveryState());
        Prefs.applyReading(sp, qty);
      });
    });
  }

  static async setThreshold(v: number): Promise<void> {
    await Prefs.write((sp: preferences.Preferences) => sp.putSync('threshold', v));
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
      if (sp.hasSync('cookieJar')) {
        sp.deleteSync('cookieJar');
      }
      sp.putSync('threshold', 20.0);
      sp.putSync('lastQty', 244.0);
      sp.putSync('peakQty', 300.0);
      sp.putSync('lastAt', now);
      sp.putSync('needsLogin', false);
      sp.putSync('manualAlerted', false);
      sp.putSync('alerted', false);
      sp.putSync('samples', parts.join(','));
    });
  }

  static async setAlerted(v: boolean): Promise<void> {
    await Prefs.write((sp: preferences.Preferences) => sp.putSync('alerted', v));
  }
}
