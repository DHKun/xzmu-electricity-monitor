import { HttpRequest, HttpResponse, HttpTransport, IoError } from './Http';

/** 新开普云缴费接口: 所有请求需同时携带 Cookie 与 Referer */
export class PowerApi {
  static readonly HOST: string = 'h5cloud.17wanxiao.com';
  static readonly PORT: string = '18443';
  static readonly OPEN_HOST: string = 'open.17wanxiao.com';
  static readonly SCHOOL_CODE: string = '784';
  static readonly CLIENT_ID: string = '513214c26445440fb9167a7159d9258b';
  static readonly UA: string = 'Mozilla/5.0 (Linux; OpenHarmony) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36';

  /** 缴费应用根路径, SESSION 的 Path 就是它 */
  static readonly SESSION_URL: string = `https://${PowerApi.HOST}:${PowerApi.PORT}/CloudPayment/`;
  static readonly SESSION_PATH: string = '/CloudPayment/';
  static readonly OPEN_URL: string = `https://${PowerApi.OPEN_HOST}/`;

  private static redirectUri(): string {
    return `https://${PowerApi.HOST}:${PowerApi.PORT}/CloudPayment/user/pay.do` +
      `?ecardFunc=index&paychannel=35&payUserSource=WX&flag=basicopengroup_xzmzjf` +
      `&hostType=OPEN_NEWCAP&appId=${PowerApi.CLIENT_ID}&versioncode=10431102&customer_code=${PowerApi.SCHOOL_CODE}`;
  }

  static authorizeUrl(forceLogin: boolean): string {
    return `https://${PowerApi.OPEN_HOST}/api/authorize?response_type=code&hidden=true` +
      `&customerCode=${PowerApi.SCHOOL_CODE}&force_login=${forceLogin ? 'true' : 'false'}` +
      `&redirect_uri=${encodeURIComponent(PowerApi.redirectUri())}&client_id=${PowerApi.CLIENT_ID}`;
  }

  /** 登录接口与授权页共用同一组查询参数 */
  static loginUrl(authorizeUrl: string): string {
    return `https://${PowerApi.OPEN_HOST}/api/login?${authorizeUrl.substring(authorizeUrl.indexOf('?') + 1)}`;
  }

  /** 登录成功后页面脚本跳转的地址 */
  static postLoginAuthorizeUrl(): string {
    return `https://${PowerApi.OPEN_HOST}/api/authorize?client_id=${PowerApi.CLIENT_ID}&response_type=code` +
      `&redirect_uri=${encodeURIComponent(PowerApi.redirectUri())}&state=`;
  }

  static roomStateUrl(payProId: string, roomVerify: string): string {
    return `https://${PowerApi.HOST}:${PowerApi.PORT}/CloudPayment/user/getRoomState.do` +
      `?payProId=${payProId}&schoolcode=${PowerApi.SCHOOL_CODE}&businesstype=2&roomverify=` +
      encodeURIComponent(roomVerify);
  }

  static referer(payProId: string): string {
    return `https://${PowerApi.HOST}:${PowerApi.PORT}/CloudPayment/bill/selectPayProject.do` +
      `?txcode=2&interurl=substituted_pay&payProId=${payProId}&amtflag=0&payamt=1000`;
  }

  static extractParam(url: string, name: string): string {
    const qIndex: number = url.indexOf('?');
    if (qIndex < 0) {
      return '';
    }
    const pairs: string[] = url.substring(qIndex + 1).split('&');
    for (let i = 0; i < pairs.length; i++) {
      const kv: string[] = pairs[i].split('=');
      if (kv[0] === name) {
        return decodeURIComponent(kv.slice(1).join('='));
      }
    }
    return '';
  }
}

export enum RoomKind {
  /** 取到了有效读数, 0 也是有效电量 */
  VALID,
  /** 形态与失效会话一致, 但也可能真是系统繁忙, 只有恢复认证后重查才能确认 */
  SESSION_SUSPECT,
  TRANSIENT,
  UNKNOWN
}

export class RoomResult {
  kind: RoomKind;
  quantity: number = 0;
  unit: string = '度';
  roomLabel: string = '';
  message: string;
  setCookies: string[];

  constructor(kind: RoomKind, message: string, setCookies: string[] = []) {
    this.kind = kind;
    this.message = message;
    this.setCookies = setCookies;
  }

  get ok(): boolean {
    return this.kind === RoomKind.VALID;
  }
}

/** getRoomState.do 响应体 */
class RoomStateVO {
  returncode?: string;
  returnmsg?: string;
  quantity?: string | number;
  quantityunit?: string;
  description?: string;
}

function finiteQuantity(raw: string | number | undefined): number | null {
  const text: string = raw === undefined || raw === null ? '' : String(raw).trim();
  if (text.length === 0) {
    return null;
  }
  const n: number = Number(text);
  return isFinite(n) ? n : null;
}

export function classifyRoom(status: number, body: string, setCookies: string[]): RoomResult {
  if (status === 429 || status >= 500) {
    return new RoomResult(RoomKind.TRANSIENT, `服务器暂时不可用(${status})`, setCookies);
  }
  const text: string = body.trimStart();
  if (text.startsWith('{')) {
    let vo: RoomStateVO;
    try {
      vo = JSON.parse(text) as RoomStateVO;
    } catch (e) {
      return new RoomResult(RoomKind.UNKNOWN, '响应格式异常', setCookies);
    }
    const quantity: number | null = finiteQuantity(vo.quantity);
    const rc: string = vo.returncode !== undefined ? vo.returncode : '';
    if (rc === '100' && quantity !== null) {
      const r: RoomResult = new RoomResult(RoomKind.VALID, rc, setCookies);
      r.quantity = quantity;
      r.unit = vo.quantityunit !== undefined && vo.quantityunit.length > 0 ? vo.quantityunit : '度';
      r.roomLabel = vo.description !== undefined ? vo.description : '';
      return r;
    }
    const msg: string = vo.returnmsg !== undefined && vo.returnmsg.length > 0 ? vo.returnmsg : rc;
    return new RoomResult(RoomKind.UNKNOWN, msg, setCookies);
  }
  // 失效/缺失会话的实测响应: HTTP 200 + "RspBaseVO [code=ERROR, msg=系统繁忙...]"
  if (text.startsWith('RspBaseVO') && text.includes('code=ERROR')) {
    return new RoomResult(RoomKind.SESSION_SUSPECT, '会话可能已失效', setCookies);
  }
  return new RoomResult(RoomKind.UNKNOWN, text.substring(0, 80), setCookies);
}

/** 查询剩余电量 */
export async function fetchRoom(http: HttpTransport, url: string, cookie: string, referer: string,
  timeoutMs: number): Promise<RoomResult> {
  const headers: Record<string, string> = {
    'Cookie': cookie,
    'Referer': referer,
    'User-Agent': PowerApi.UA,
    'Accept': 'application/json',
    'X-Requested-With': 'XMLHttpRequest'
  };
  try {
    const r: HttpResponse = await http.send(new HttpRequest(url, headers, timeoutMs));
    return classifyRoom(r.status, r.body, r.setCookies);
  } catch (e) {
    if (e instanceof IoError) {
      return new RoomResult(RoomKind.TRANSIENT, `网络错误: ${e.message}`);
    }
    throw e as Error;
  }
}
