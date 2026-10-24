import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';

/** 新开普云缴费接口: 所有请求需同时携带 Cookie 与 Referer */
export class PowerApi {
  static readonly HOST: string = 'h5cloud.17wanxiao.com';
  static readonly PORT: string = '18443';
  static readonly SCHOOL_CODE: string = '784';
  static readonly CLIENT_ID: string = '513214c26445440fb9167a7159d9258b';
  static readonly UA: string = 'Mozilla/5.0 (Linux; OpenHarmony) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36';

  static authorizeUrl(forceLogin: boolean): string {
    const redirect: string = `https://${PowerApi.HOST}:${PowerApi.PORT}/CloudPayment/user/pay.do` +
      `?ecardFunc=index&paychannel=35&payUserSource=WX&flag=basicopengroup_xzmzjf` +
      `&hostType=OPEN_NEWCAP&appId=${PowerApi.CLIENT_ID}&versioncode=10431102&customer_code=${PowerApi.SCHOOL_CODE}`;
    return 'https://open.17wanxiao.com/api/authorize?response_type=code&hidden=true' +
      `&customerCode=${PowerApi.SCHOOL_CODE}&force_login=${forceLogin ? 'true' : 'false'}` +
      `&redirect_uri=${encodeURIComponent(redirect)}&client_id=${PowerApi.CLIENT_ID}`;
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

  /** 从 WebView CookieManager 取会话 Cookie(SESSION 的 Path=/CloudPayment/, 必须带路径取) */
  static sessionCookie(): string {
    const live: string = webview.WebCookieManager.fetchCookieSync(`https://${PowerApi.HOST}:${PowerApi.PORT}/CloudPayment/`);
    if (live.includes('SESSION=')) {
      return live;
    }
    return '';
  }

  static parseCookieValue(cookie: string, name: string): string {
    const parts: string[] = cookie.split(';');
    for (let i = 0; i < parts.length; i++) {
      const kv: string[] = parts[i].trim().split('=');
      if (kv.length >= 2 && kv[0] === name) {
        return kv.slice(1).join('=');
      }
    }
    return '';
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

/** getRoomState.do 响应体 */
class RoomStateVO {
  returncode: string = '';
  returnmsg: string = '';
  quantity: string = '0';
  quantityunit: string = '度';
  description: string = '';
}

export interface RoomState {
  ok: boolean;
  sessionDead: boolean;
  quantity: number;
  unit: string;
  roomLabel: string;
  message: string;
  setCookie: string;
}

export class PowerResult {
  static empty(): RoomState {
    return { ok: false, sessionDead: false, quantity: 0, unit: '度', roomLabel: '', message: '', setCookie: '' };
  }
}

/** 查询剩余电量(阻塞网络调用, 请在任务线程使用) */
export async function queryRoomState(payProId: string, roomVerify: string, cookie: string): Promise<RoomState> {
  if (cookie.length === 0) {
    const r: RoomState = PowerResult.empty();
    r.sessionDead = true;
    r.message = '无会话';
    return r;
  }
  const url: string = PowerApi.roomStateUrl(payProId, roomVerify);
  return queryUrl(url, cookie, PowerApi.referer(payProId));
}

export async function queryUrl(url: string, cookie: string, referer: string): Promise<RoomState> {
  const req: http.HttpRequest = http.createHttp();
  try {
    const resp: http.HttpResponse = await req.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'Cookie': cookie,
        'Referer': referer,
        'User-Agent': PowerApi.UA,
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest'
      },
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: 15000
    });
    const setCookie: string = resp.cookies !== undefined ? resp.cookies : '';
    const body: string = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
    if (body.startsWith('{')) {
      const vo: RoomStateVO = JSON.parse(body) as RoomStateVO;
      const state: RoomState = PowerResult.empty();
      state.ok = vo.returncode === '100';
      state.sessionDead = vo.returncode !== '100';
      state.quantity = parseFloat(vo.quantity);
      state.unit = vo.quantityunit.length > 0 ? vo.quantityunit : '度';
      state.roomLabel = vo.description;
      state.message = vo.returnmsg.length > 0 ? vo.returnmsg : vo.returncode;
      state.setCookie = setCookie;
      return state;
    }
    const r2: RoomState = PowerResult.empty();
    r2.sessionDead = body.includes('ERROR');
    r2.message = body.substring(0, 80);
    r2.setCookie = setCookie;
    return r2;
  } catch (e) {
    const r3: RoomState = PowerResult.empty();
    r3.message = `网络错误: ${e instanceof Error ? e.message : String(e)}`;
    return r3;
  } finally {
    req.destroy();
  }
}
