import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HttpRequest, HttpResponse, HttpTransport, IoError } from './Http';

function headerValues(v: string | string[] | undefined): string[] {
  if (v === undefined) {
    return [];
  }
  return typeof v === 'string' ? [v] : v;
}

/** 用 rcp 而不是 @kit.NetworkKit: http 模块的 maxRedirects: 0 遇到 302 会报错, 拿不到响应 */
export class KitTransport implements HttpTransport {
  private current: rcp.Session | null = null;

  /** 系统停止任务时中断进行中的请求 */
  abort(): void {
    const session: rcp.Session | null = this.current;
    if (session !== null) {
      session.cancel();
    }
  }

  async send(request: HttpRequest): Promise<HttpResponse> {
    const headers: rcp.RequestHeaders = {};
    const names: string[] = Object.keys(request.headers);
    for (let i = 0; i < names.length; i++) {
      if (request.headers[names[i]].length > 0) {
        headers[names[i].toLowerCase()] = request.headers[names[i]];
      }
    }
    if (request.formBody !== null) {
      headers['content-type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
    }
    const session: rcp.Session = rcp.createSession({
      requestConfiguration: {
        transfer: {
          autoRedirect: false,
          timeout: { connectMs: request.timeoutMs, transferMs: request.timeoutMs }
        }
      }
    });
    this.current = session;
    try {
      const resp: rcp.Response = await session.fetch(new rcp.Request(request.url,
        request.formBody !== null ? 'POST' : 'GET', headers,
        request.formBody !== null ? request.formBody : undefined));
      const body: string | null = resp.toString();
      const location: string[] = headerValues(resp.headers['location']);
      return new HttpResponse(resp.statusCode, body !== null ? body : '', headerValues(resp.headers['set-cookie']),
        location.length > 0 ? location[0] : null);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      throw new IoError(`${err.code} ${err.message}`);
    } finally {
      this.current = null;
      session.close();
    }
  }
}
