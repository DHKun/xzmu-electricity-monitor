export class ParsedUrl {
  scheme: string = '';
  host: string = '';
  path: string = '/';
}

/** 解析出的 host 已去掉 userinfo 和端口; 主机校验靠它, 不能用字符串包含判断 */
export function parseUrl(url: string): ParsedUrl | null {
  const m: RegExpMatchArray | null = url.match(new RegExp('^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]*)([^?#]*)'));
  if (m === null || m[2].includes('\\')) {
    return null;
  }
  const authority: string = m[2].substring(m[2].lastIndexOf('@') + 1);
  const host: string = authority.split(':')[0].toLowerCase();
  if (host.length === 0) {
    return null;
  }
  const out: ParsedUrl = new ParsedUrl();
  out.scheme = m[1].toLowerCase();
  out.host = host;
  out.path = m[3].length > 0 ? m[3] : '/';
  return out;
}

/** 解析重定向 Location */
export function resolveUrl(base: string, location: string): string | null {
  const loc: string = location.trim();
  if (new RegExp('^[a-zA-Z][a-zA-Z0-9+.-]*://').test(loc)) {
    return loc;
  }
  const m: RegExpMatchArray | null = base.match(new RegExp('^([a-zA-Z][a-zA-Z0-9+.-]*:)(//[^/?#]*)([^?#]*)'));
  if (m === null || loc.length === 0) {
    return null;
  }
  if (loc.startsWith('//')) {
    return m[1] + loc;
  }
  if (loc.startsWith('/')) {
    return m[1] + m[2] + loc;
  }
  return m[1] + m[2] + m[3].substring(0, m[3].lastIndexOf('/') + 1) + loc;
}

class CookieItem {
  host: string;
  domainWide: boolean;
  path: string;
  name: string;
  value: string;
  expiresAt: number;

  constructor(host: string, domainWide: boolean, path: string, name: string, value: string, expiresAt: number) {
    this.host = host;
    this.domainWide = domainWide;
    this.path = path;
    this.name = name;
    this.value = value;
    this.expiresAt = expiresAt;
  }
}

/**
 * 按 host + path 分作用域的 Cookie 存储。
 * 授权域和缴费域都有名为 SESSION 的 Cookie, 只存单一值会互相覆盖, 所以必须保留作用域。
 */
export class CookieJar {
  private items: CookieItem[];

  constructor(items: CookieItem[] = []) {
    this.items = items;
  }

  copy(): CookieJar {
    return new CookieJar(this.items.slice());
  }

  isEmpty(): boolean {
    return this.items.length === 0;
  }

  has(host: string, name: string): boolean {
    return this.items.some((it: CookieItem) => it.host === host && it.name === name);
  }

  dropHost(host: string): void {
    this.items = this.items.filter((it: CookieItem) => it.host !== host);
  }

  /** 请求 url 应携带的 Cookie 头 */
  header(url: string, now: number): string {
    const u: ParsedUrl | null = parseUrl(url);
    if (u === null) {
      return '';
    }
    return this.items
      .filter((it: CookieItem) => (it.expiresAt === 0 || it.expiresAt > now) &&
        CookieJar.hostMatches(it, u.host) && CookieJar.pathMatches(it.path, u.path))
      .sort((a: CookieItem, b: CookieItem) => b.path.length - a.path.length)
      .map((it: CookieItem) => `${it.name}=${it.value}`)
      .join('; ');
  }

  store(url: string, setCookies: string[], now: number): void {
    const u: ParsedUrl | null = parseUrl(url);
    if (u === null) {
      return;
    }
    for (let i = 0; i < setCookies.length; i++) {
      this.storeOne(u.host, u.path, setCookies[i], now);
    }
  }

  /** 从 "a=b; c=d" 形式的 Cookie 串导入(WebView 与旧版快照都只有这种形式) */
  importPlain(host: string, path: string, cookies: string): void {
    const parts: string[] = cookies.split(';');
    for (let i = 0; i < parts.length; i++) {
      const eq: number = parts[i].indexOf('=');
      if (eq > 0) {
        this.put(new CookieItem(host, false, path, parts[i].substring(0, eq).trim(),
          parts[i].substring(eq + 1).trim(), 0));
      }
    }
  }

  serialize(): string {
    return this.items.map((it: CookieItem) =>
      [it.host, it.domainWide ? '1' : '0', it.path, it.name, it.value, String(it.expiresAt)].join('\t')).join('\n');
  }

  static parse(text: string): CookieJar {
    const items: CookieItem[] = [];
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const f: string[] = lines[i].split('\t');
      if (f.length === 6) {
        const expiresAt: number = Number(f[5]);
        items.push(new CookieItem(f[0], f[1] === '1', f[2], f[3], f[4], isNaN(expiresAt) ? 0 : expiresAt));
      }
    }
    return new CookieJar(items);
  }

  private storeOne(host: string, requestPath: string, header: string, now: number): void {
    const parts: string[] = header.split(';').map((p: string) => p.trim());
    const eq: number = parts[0].indexOf('=');
    if (eq <= 0) {
      return;
    }
    const name: string = parts[0].substring(0, eq).trim();
    const value: string = parts[0].substring(eq + 1).trim();

    let domain: string | null = null;
    let path: string | null = null;
    let maxAge: number | null = null;
    let expires: number | null = null;
    for (let i = 1; i < parts.length; i++) {
      const at: number = parts[i].indexOf('=');
      const key: string = (at < 0 ? parts[i] : parts[i].substring(0, at)).trim().toLowerCase();
      const v: string = at < 0 ? '' : parts[i].substring(at + 1).trim();
      if (key === 'domain') {
        const d: string = v.replace(new RegExp('^\\.+'), '').toLowerCase();
        domain = d.length > 0 ? d : null;
      } else if (key === 'path') {
        path = v.startsWith('/') ? v : null;
      } else if (key === 'max-age') {
        const n: number = v.length > 0 ? Number(v) : NaN;
        maxAge = isNaN(n) ? null : n;
      } else if (key === 'expires') {
        const t: number = Date.parse(v);
        expires = isNaN(t) ? null : t;
      }
    }
    if (domain !== null && host !== domain && !host.endsWith(`.${domain}`)) {
      return;
    }
    const effectivePath: string = path !== null ? path : CookieJar.defaultPath(requestPath);
    const expiresAt: number = maxAge !== null ? now + maxAge * 1000 : (expires !== null ? expires : 0);
    const item: CookieItem = new CookieItem(domain !== null ? domain : host, domain !== null, effectivePath,
      name, value, expiresAt);
    this.remove(item);
    if (expiresAt === 0 || expiresAt > now) {
      this.items.push(item);
    }
  }

  private put(item: CookieItem): void {
    this.remove(item);
    this.items.push(item);
  }

  private remove(item: CookieItem): void {
    this.items = this.items.filter((it: CookieItem) =>
      !(it.host === item.host && it.path === item.path && it.name === item.name));
  }

  private static hostMatches(item: CookieItem, host: string): boolean {
    return host === item.host || (item.domainWide && host.endsWith(`.${item.host}`));
  }

  private static pathMatches(cookiePath: string, requestPath: string): boolean {
    return requestPath === cookiePath ||
    requestPath.startsWith(cookiePath.replace(new RegExp('/+$'), '') + '/');
  }

  private static defaultPath(requestPath: string): string {
    const slash: number = requestPath.lastIndexOf('/');
    return slash <= 0 ? '/' : requestPath.substring(0, slash);
  }
}
