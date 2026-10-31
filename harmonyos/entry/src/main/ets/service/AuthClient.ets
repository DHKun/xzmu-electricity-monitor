import { CookieJar, ParsedUrl, parseUrl, resolveUrl } from './CookieJar';
import { Deadline, HttpRequest, HttpResponse, HttpTransport, IoError } from './Http';
import { PowerApi } from './PowerApi';

const TYPE_ECARD: string = 'ecard';
const MAX_HOPS: number = 8;
const LOGIN_MARKER: string = 'id="lgn"';
// 服务器对没有 */* 兜底的 Accept 返回 406, 必须与浏览器和登录页脚本一致
const ACCEPT_HTML: string = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
const ACCEPT_JSON: string = 'application/json, text/javascript, */*; q=0.01';

export class LoginCreds {
  type: string = 'wx';
  username: string = '';
  password: string = '';
  customerCode: string = '';
  outid: string = '';
}

export enum AuthStatus {
  /** 缴费域已拿到新会话, 是否真正可用由调用方重查确认 */
  READY,
  NO_CREDENTIALS,
  /** 服务端明确拒绝(密码错误、验证码、需要绑卡等), 不能再自动重试 */
  REJECTED,
  TRANSIENT,
  UNKNOWN
}

export class AuthResult {
  status: AuthStatus;
  message: string;

  constructor(status: AuthStatus, message: string = '') {
    this.status = status;
    this.message = message;
  }
}

enum LandingKind {
  SESSION,
  LOGIN_FORM,
  ERROR_PAGE,
  TEMPORARY,
  UNRECOGNIZED
}

class Landing {
  kind: LandingKind;
  /** LOGIN_FORM 时是登录页地址, 其余情况是原因说明 */
  detail: string;

  constructor(kind: LandingKind, detail: string = '') {
    this.kind = kind;
    this.detail = detail;
  }
}

class LoginReply {
  errorCode?: number;
  desc?: string;
  errorMsg?: string;
}

function enc(s: string): string {
  return encodeURIComponent(s);
}

function formBody(c: LoginCreds): string {
  const fields: string[] = [`loginType=${enc(c.type)}`, `username=${enc(c.username)}`, `password=${enc(c.password)}`];
  if (c.type === TYPE_ECARD) {
    fields.push(`customerCode=${enc(c.customerCode)}`);
    fields.push(`outid=${enc(c.outid)}`);
  }
  fields.push(`${enc('scopes[]')}=base`);
  fields.push(`${enc('scopes[]')}=user_alter`);
  fields.push('force_bind_ecard=true');
  return fields.join('&');
}

function allowed(url: string): boolean {
  const u: ParsedUrl | null = parseUrl(url);
  return u !== null && u.scheme === 'https' && (u.host === PowerApi.OPEN_HOST || u.host === PowerApi.HOST);
}

/**
 * 不依赖页面的认证恢复: 走与登录页脚本相同的 HTTP 流程。
 * 先用授权域 SSO 换新会话; 必须登录时才提交一次凭据, 且只发给固定的登录接口。
 */
export class AuthClient {
  private http: HttpTransport;
  private now: () => number;

  constructor(http: HttpTransport, now: () => number) {
    this.http = http;
    this.now = now;
  }

  async recover(jar: CookieJar, creds: LoginCreds | null, deadline: Deadline): Promise<AuthResult> {
    try {
      // 旧缴费会话已不可用, 留着只会混进授权回跳
      jar.dropHost(PowerApi.HOST);
      let landing: Landing = await this.walk(PowerApi.authorizeUrl(false), jar, deadline);
      if (landing.kind === LandingKind.ERROR_PAGE) {
        landing = await this.walk(PowerApi.authorizeUrl(true), jar, deadline);
      }
      switch (landing.kind) {
        case LandingKind.SESSION:
          return new AuthResult(AuthStatus.READY);
        case LandingKind.LOGIN_FORM:
          return creds === null ? new AuthResult(AuthStatus.NO_CREDENTIALS) :
            await this.login(landing.detail, jar, creds, deadline);
        case LandingKind.TEMPORARY:
          return new AuthResult(AuthStatus.TRANSIENT, `授权服务暂时不可用(${landing.detail})`);
        case LandingKind.ERROR_PAGE:
          return new AuthResult(AuthStatus.UNKNOWN, '授权页面无法识别(错误页)');
        default:
          return new AuthResult(AuthStatus.UNKNOWN, `授权页面无法识别(${landing.detail})`);
      }
    } catch (e) {
      if (e instanceof IoError) {
        return new AuthResult(AuthStatus.TRANSIENT, `网络错误: ${e.message}`);
      }
      throw e as Error;
    }
  }

  private async login(formUrl: string, jar: CookieJar, creds: LoginCreds, deadline: Deadline): Promise<AuthResult> {
    const url: string = PowerApi.loginUrl(formUrl);
    const headers: Record<string, string> = {
      'Cookie': jar.header(url, this.now()),
      'User-Agent': PowerApi.UA,
      'Accept': ACCEPT_JSON,
      'Referer': formUrl,
      'X-Requested-With': 'XMLHttpRequest'
    };
    const r: HttpResponse = await this.http.send(new HttpRequest(url, headers, deadline.nextTimeoutMs(), formBody(creds)));
    jar.store(url, r.setCookies, this.now());
    if (r.status === 429 || r.status >= 500) {
      return new AuthResult(AuthStatus.TRANSIENT, `登录服务暂时不可用(${r.status})`);
    }
    let reply: LoginReply | null = null;
    try {
      reply = JSON.parse(r.body.trim()) as LoginReply;
    } catch (e) {
      reply = null;
    }
    if (reply === null || typeof reply !== 'object' || reply.errorCode === undefined) {
      return new AuthResult(AuthStatus.UNKNOWN, '登录响应无法识别');
    }
    if (Number(reply.errorCode) !== 0) {
      const msg: string = reply.desc !== undefined && reply.desc.length > 0 ? reply.desc :
        (reply.errorMsg !== undefined ? reply.errorMsg : '');
      return new AuthResult(AuthStatus.REJECTED, msg);
    }
    const landing: Landing = await this.walk(PowerApi.postLoginAuthorizeUrl(), jar, deadline);
    if (landing.kind === LandingKind.SESSION) {
      return new AuthResult(AuthStatus.READY);
    }
    if (landing.kind === LandingKind.TEMPORARY) {
      return new AuthResult(AuthStatus.TRANSIENT, `授权服务暂时不可用(${landing.detail})`);
    }
    return new AuthResult(AuthStatus.UNKNOWN, `登录后未回到缴费页面(${landing.detail})`);
  }

  /** 手动跟随授权重定向: 只访问 https 的已知主机, 且跳数有限 */
  private async walk(start: string, jar: CookieJar, deadline: Deadline): Promise<Landing> {
    let url: string = start;
    for (let hop = 0; hop < MAX_HOPS; hop++) {
      if (!allowed(url)) {
        return jar.has(PowerApi.HOST, 'SESSION') ? new Landing(LandingKind.SESSION) :
          new Landing(LandingKind.UNRECOGNIZED, '跳转到未知地址');
      }
      const headers: Record<string, string> = {
        'Cookie': jar.header(url, this.now()),
        'User-Agent': PowerApi.UA,
        'Accept': ACCEPT_HTML
      };
      const r: HttpResponse = await this.http.send(new HttpRequest(url, headers, deadline.nextTimeoutMs()));
      jar.store(url, r.setCookies, this.now());
      if (r.status >= 300 && r.status <= 399) {
        const next: string | null = r.location !== null ? resolveUrl(url, r.location) : null;
        if (next === null) {
          return new Landing(LandingKind.UNRECOGNIZED, '跳转地址无效');
        }
        url = next;
        continue;
      }
      if (r.status === 429 || r.status >= 500) {
        return new Landing(LandingKind.TEMPORARY, String(r.status));
      }
      const here: ParsedUrl | null = parseUrl(url);
      if (here !== null && here.host === PowerApi.HOST) {
        return r.status < 400 && jar.has(PowerApi.HOST, 'SESSION') ? new Landing(LandingKind.SESSION) :
          new Landing(LandingKind.UNRECOGNIZED, `HTTP ${r.status}`);
      }
      if (r.status >= 400) {
        return new Landing(LandingKind.UNRECOGNIZED, `HTTP ${r.status}`);
      }
      if (r.body.includes(LOGIN_MARKER)) {
        return new Landing(LandingKind.LOGIN_FORM, url);
      }
      if (new RegExp('<title>[^<]*提示').test(r.body)) {
        return new Landing(LandingKind.ERROR_PAGE);
      }
      return new Landing(LandingKind.UNRECOGNIZED, '页面没有登录表单');
    }
    return new Landing(LandingKind.UNRECOGNIZED, '跳转次数过多');
  }
}
