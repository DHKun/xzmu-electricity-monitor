import { AuthClient, AuthResult, AuthStatus, LoginCreds } from './AuthClient';
import { CookieJar } from './CookieJar';
import { Deadline, HttpTransport, IoError, SyncCancelled } from './Http';
import { fetchRoom, PowerApi, RoomKind, RoomResult } from './PowerApi';

export enum Trigger {
  PERIODIC = 'PERIODIC',
  /** 卡片进程很快被系统回收, 来不及记录认证失败, 所以只查询不恢复认证 */
  WIDGET = 'WIDGET',
  USER = 'USER'
}

export enum Stage {
  QUERY = 'QUERY',
  AUTH = 'AUTH',
  REQUERY = 'REQUERY'
}

export enum Outcome {
  OK = 'OK',
  TRANSIENT = 'TRANSIENT',
  UNKNOWN = 'UNKNOWN',
  /** 需要用户手动登录 */
  MANUAL = 'MANUAL',
  /** 退避期内或卡片触发, 没有发起自动恢复 */
  SKIPPED = 'SKIPPED',
  /** 已有另一轮同步在执行 */
  BUSY = 'BUSY',
  UNBOUND = 'UNBOUND',
  /** 被取消, 或绑定/会话在执行期间变了, 结果作废 */
  DISCARDED = 'DISCARDED'
}

/** 跨进程重启保留的恢复状态 */
export class RecoveryState {
  failCount: number = 0;
  nextAttemptAt: number = 0;
  /** 退避由认证恢复失败引起: 此时任何触发来源都不得绕过它提交密码 */
  authBackoff: boolean = false;
  needsLogin: boolean = false;
  lastOutcome: string = '';

  copy(): RecoveryState {
    const s: RecoveryState = new RecoveryState();
    s.failCount = this.failCount;
    s.nextAttemptAt = this.nextAttemptAt;
    s.authBackoff = this.authBackoff;
    s.needsLogin = this.needsLogin;
    s.lastOutcome = this.lastOutcome;
    return s;
  }
}

export class SyncSnapshot {
  bindingGen: number = 0;
  sessionGen: number = 0;
  payProId: string = '';
  roomVerify: string = '';
  cookies: string = '';
  state: RecoveryState = new RecoveryState();
}

export class SyncCommit {
  state: RecoveryState;
  /** 通过真实查询验证过的新 Cookie; null 表示不改动 */
  cookies: string | null;
  quantity: number | null;

  constructor(state: RecoveryState, cookies: string | null = null, quantity: number | null = null) {
    this.state = state;
    this.cookies = cookies;
    this.quantity = quantity;
  }
}

/** 凭据状态: 已开启但暂时读不出时不能当成"没有凭据" */
export class CredsRead {
  creds: LoginCreds | null;
  unavailable: boolean;

  constructor(creds: LoginCreds | null, unavailable: boolean = false) {
    this.creds = creds;
    this.unavailable = unavailable;
  }
}

export interface SyncStore {
  /** 未绑定时返回 null */
  begin(): SyncSnapshot | null;
  creds(): CredsRead;
  /** 代次与 base 一致才写入, 写入须是原子的; 返回是否已提交 */
  commit(base: SyncSnapshot, commit: SyncCommit): Promise<boolean>;
}

export class SyncReport {
  outcome: Outcome;
  stage: Stage;
  message: string;
  quantity: number | null;
  unit: string;

  constructor(outcome: Outcome, stage: Stage, message: string = '', quantity: number | null = null, unit: string = '度') {
    this.outcome = outcome;
    this.stage = stage;
    this.message = message;
    this.quantity = quantity;
    this.unit = unit;
  }
}

const MINUTE: number = 60000;
const BACKOFF_MS: number[] = [15 * MINUTE, 60 * MINUTE, 360 * MINUTE];
const CREDS_UNREADABLE_LIMIT: number = 3;

/** 第 n 次连续失败后至少等待的时长, 之后维持最大值 */
export function backoffMs(failCount: number): number {
  return BACKOFF_MS[Math.min(Math.max(failCount - 1, 0), BACKOFF_MS.length - 1)];
}

export const BUDGET_MS: number = 90000;

class SyncRun {
  private store: SyncStore;
  private http: HttpTransport;
  private auth: AuthClient;
  private now: () => number;
  private trigger: Trigger;
  private base: SyncSnapshot;
  private deadline: Deadline;
  private onRecovering: () => void;
  stage: Stage = Stage.QUERY;

  constructor(store: SyncStore, http: HttpTransport, now: () => number, trigger: Trigger, base: SyncSnapshot,
    deadline: Deadline, onRecovering: () => void) {
    this.store = store;
    this.http = http;
    this.auth = new AuthClient(http, now);
    this.now = now;
    this.trigger = trigger;
    this.base = base;
    this.deadline = deadline;
    this.onRecovering = onRecovering;
  }

  async execute(): Promise<SyncReport> {
    const jar: CookieJar = CookieJar.parse(this.base.cookies);
    if (jar.isEmpty()) {
      return this.recover(jar);
    }
    const r: RoomResult = await this.query(jar);
    switch (r.kind) {
      case RoomKind.VALID:
        return this.succeed(jar, r);
      case RoomKind.SESSION_SUSPECT:
        return this.recover(jar);
      case RoomKind.TRANSIENT:
        return this.fail(Outcome.TRANSIENT, r.message);
      default:
        return this.fail(Outcome.UNKNOWN, r.message);
    }
  }

  private query(jar: CookieJar): Promise<RoomResult> {
    const url: string = PowerApi.roomStateUrl(this.base.payProId, this.base.roomVerify);
    return fetchRoom(this.http, url, jar.header(url, this.now()), PowerApi.referer(this.base.payProId),
      this.deadline.nextTimeoutMs());
  }

  private async recover(old: CookieJar): Promise<SyncReport> {
    this.stage = Stage.AUTH;
    const state: RecoveryState = this.base.state;
    if (state.needsLogin) {
      return new SyncReport(Outcome.MANUAL, this.stage);
    }
    if (this.trigger === Trigger.WIDGET) {
      return new SyncReport(Outcome.SKIPPED, this.stage, '等待后台恢复登录');
    }
    if (state.authBackoff && this.now() < state.nextAttemptAt) {
      return new SyncReport(Outcome.SKIPPED, this.stage, '自动登录稍后重试');
    }
    const creds: CredsRead = this.store.creds();
    if (creds.unavailable) {
      // 连续读不出多半是凭据已不可用, 再等也没用, 交给用户
      return state.failCount >= CREDS_UNREADABLE_LIMIT ? this.manual('保存的密码无法读取') :
        this.fail(Outcome.TRANSIENT, '登录凭据暂时不可读取');
    }
    this.onRecovering();
    // 在副本上恢复: 没验证成功前不动已保存的状态
    const jar: CookieJar = old.copy();
    const a: AuthResult = await this.auth.recover(jar, creds.creds, this.deadline);
    switch (a.status) {
      case AuthStatus.READY:
        return this.requery(jar);
      case AuthStatus.NO_CREDENTIALS:
        return this.manual('需要重新登录');
      case AuthStatus.REJECTED:
        return this.manual(a.message.length > 0 ? a.message : '自动登录被拒绝');
      case AuthStatus.TRANSIENT:
        return this.fail(Outcome.TRANSIENT, a.message);
      default:
        return this.fail(Outcome.UNKNOWN, a.message);
    }
  }

  private async requery(jar: CookieJar): Promise<SyncReport> {
    this.stage = Stage.REQUERY;
    const r: RoomResult = await this.query(jar);
    if (r.kind === RoomKind.VALID) {
      return this.succeed(jar, r);
    }
    if (r.kind === RoomKind.TRANSIENT) {
      return this.fail(Outcome.TRANSIENT, r.message);
    }
    // 新会话仍查不到: 不是凭据问题, 也不再递归重登
    return this.fail(Outcome.UNKNOWN, '恢复登录后仍无法查询');
  }

  private async succeed(jar: CookieJar, r: RoomResult): Promise<SyncReport> {
    jar.store(PowerApi.SESSION_URL, r.setCookies, this.now());
    const state: RecoveryState = new RecoveryState();
    state.lastOutcome = Outcome.OK;
    if (!await this.commit(new SyncCommit(state, jar.serialize(), r.quantity))) {
      return new SyncReport(Outcome.DISCARDED, this.stage);
    }
    return new SyncReport(Outcome.OK, this.stage, r.message, r.quantity, r.unit);
  }

  private async manual(message: string): Promise<SyncReport> {
    const next: RecoveryState = this.base.state.copy();
    next.needsLogin = true;
    next.authBackoff = false;
    next.lastOutcome = Outcome.MANUAL;
    if (!await this.commit(new SyncCommit(next))) {
      return new SyncReport(Outcome.DISCARDED, this.stage);
    }
    return new SyncReport(Outcome.MANUAL, this.stage, message);
  }

  /** 用户/卡片刷新的查询失败不计入退避, 否则离线时多刷几次会推迟后台任务 */
  async fail(outcome: Outcome, message: string): Promise<SyncReport> {
    const inAuth: boolean = this.stage !== Stage.QUERY;
    const next: RecoveryState = this.base.state.copy();
    next.lastOutcome = outcome;
    if (inAuth || this.trigger === Trigger.PERIODIC) {
      next.failCount = next.failCount + 1;
      next.nextAttemptAt = this.now() + backoffMs(next.failCount);
      next.authBackoff = inAuth || next.authBackoff;
    }
    if (!await this.commit(new SyncCommit(next))) {
      return new SyncReport(Outcome.DISCARDED, this.stage);
    }
    return new SyncReport(outcome, this.stage, message);
  }

  private commit(c: SyncCommit): Promise<boolean> {
    this.deadline.checkNotCancelled();
    return this.store.commit(this.base, c);
  }
}

/**
 * 一轮同步: 查询 → 疑似失效则恢复认证 → 用新会话重查一次 → 提交。
 * 每轮最多一次认证恢复、两次查询; 只有真实查询成功才算恢复, 新 Cookie 也只在此时落盘。
 */
export class SyncEngine {
  private store: SyncStore;
  private http: HttpTransport;
  private now: () => number;

  constructor(store: SyncStore, http: HttpTransport, now: () => number) {
    this.store = store;
    this.http = http;
    this.now = now;
  }

  async run(trigger: Trigger, cancelled: () => boolean, onRecovering: () => void): Promise<SyncReport> {
    const base: SyncSnapshot | null = this.store.begin();
    if (base === null) {
      return new SyncReport(Outcome.UNBOUND, Stage.QUERY);
    }
    if (trigger === Trigger.PERIODIC && this.now() < base.state.nextAttemptAt) {
      return new SyncReport(Outcome.SKIPPED, Stage.QUERY);
    }
    const deadline: Deadline = new Deadline(this.now, BUDGET_MS, cancelled);
    const run: SyncRun = new SyncRun(this.store, this.http, this.now, trigger, base, deadline, onRecovering);
    try {
      try {
        return await run.execute();
      } catch (e) {
        if (e instanceof IoError) {
          return await run.fail(Outcome.TRANSIENT, `网络错误: ${e.message}`);
        }
        throw e as Error;
      }
    } catch (e) {
      if (e instanceof SyncCancelled) {
        return new SyncReport(Outcome.DISCARDED, run.stage);
      }
      throw e as Error;
    }
  }
}
