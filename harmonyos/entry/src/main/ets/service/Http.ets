/** 网络层的纯接口, 不依赖系统能力, 便于脱离设备测试 */
export class HttpRequest {
  url: string;
  headers: Record<string, string>;
  timeoutMs: number;
  formBody: string | null;

  constructor(url: string, headers: Record<string, string>, timeoutMs: number, formBody: string | null = null) {
    this.url = url;
    this.headers = headers;
    this.timeoutMs = timeoutMs;
    this.formBody = formBody;
  }
}

export class HttpResponse {
  status: number;
  body: string;
  setCookies: string[];
  location: string | null;

  constructor(status: number, body: string, setCookies: string[] = [], location: string | null = null) {
    this.status = status;
    this.body = body;
    this.setCookies = setCookies;
    this.location = location;
  }
}

/** 网络失败、超时、预算耗尽 */
export class IoError extends Error {
}

/** 系统已取消本次任务; 不是失败, 不提交任何结果 */
export class SyncCancelled extends Error {
}

/** 单次请求, 绝不自动跟随重定向: 跳转目标由调用方校验, 凭据才不会被带去任意来源 */
export interface HttpTransport {
  send(request: HttpRequest): Promise<HttpResponse>;
}

/** 一轮同步的总预算, 含查询、授权与重查, 各阶段不重新计时 */
export class Deadline {
  static readonly REQUEST_TIMEOUT_MS: number = 15000;
  private now: () => number;
  private cancelled: () => boolean;
  private endAt: number;

  constructor(now: () => number, budgetMs: number, cancelled: () => boolean) {
    this.now = now;
    this.cancelled = cancelled;
    this.endAt = now() + budgetMs;
  }

  checkNotCancelled(): void {
    if (this.cancelled()) {
      throw new SyncCancelled();
    }
  }

  /** 下一个请求可用的超时; 预算耗尽按临时故障处理 */
  nextTimeoutMs(): number {
    this.checkNotCancelled();
    const left: number = this.endAt - this.now();
    if (left <= 0) {
      throw new IoError('超出本轮执行预算');
    }
    return Math.min(left, Deadline.REQUEST_TIMEOUT_MS);
  }
}
