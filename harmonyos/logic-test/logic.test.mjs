// 鸿蒙同步逻辑层的离线测试。这些 .ets 不依赖系统能力, 复制成 .ts 后用 Node 运行:
//   node --experimental-transform-types --no-warnings harmonyos/logic-test/logic.test.mjs
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../entry/src/main/ets/service');
const OUT = mkdtempSync(join(tmpdir(), 'xzmu-logic-'));
for (const name of ['Http', 'CookieJar', 'PowerApi', 'AuthClient', 'SyncEngine']) {
  const code = readFileSync(join(SRC, `${name}.ets`), 'utf8')
    .replace(/from '\.\/(\w+)'/g, "from './$1.ts'")
    // 接口运行时不存在, 不能出现在值导入里
    .replace(/\b(HttpTransport|SyncStore), /g, (m, _n, at, all) => (all.lastIndexOf('import', at) > all.lastIndexOf(';', at) ? '' : m));
  writeFileSync(join(OUT, `${name}.ts`), code);
}
const load = (name) => import(pathToFileURL(join(OUT, `${name}.ts`)).href);
const { Deadline, HttpResponse, IoError } = await load('Http');
const { CookieJar, parseUrl, resolveUrl } = await load('CookieJar');
const { PowerApi, RoomKind, classifyRoom } = await load('PowerApi');
const { AuthClient, AuthStatus, LoginCreds } = await load('AuthClient');
const { BUDGET_MS, CredsRead, Outcome, RecoveryState, Stage, SyncEngine, SyncSnapshot, Trigger, backoffMs } =
  await load('SyncEngine');

const DEAD_BODY = 'RspBaseVO [code=ERROR, msg=系统繁忙，请稍后重试, subCode=null, subMsg=null]';
const ANON = 'SESSION=anonymous; Path=/CloudPayment/; Secure; HttpOnly';
const LOGIN_PAGE = '<title>开放平台授权</title><a href="javascript:;" id="lgn" class="btn submit">授权登录</a>';
const ROOM_OK = '{"returncode":"100","quantity":"250.0","quantityunit":"度","description":"902房间"}';
const resp = (status, body, cookies = [], location = null) => new HttpResponse(status, body, cookies, location);
const toPay = resp(302, '', [], `https://${PowerApi.HOST}:18443/CloudPayment/user/pay.do?code=abc`);
const paySession = resp(200, 'ok', ['SESSION=fresh; Path=/CloudPayment/']);
const dead = resp(200, DEAD_BODY, [ANON]);
const ok = resp(200, ROOM_OK, ['SESSION=rotated; Path=/CloudPayment/']);

function creds() {
  const c = new LoginCreds();
  c.username = 'user';
  c.password = 'p&ss=word';
  return c;
}

class FakeHttp {
  script = [];
  requests = [];
  onSend = () => {};
  on(part, response) { this.script.push([part, response]); return this; }
  failOn(part) { return this.on(part, null); }
  async send(request) {
    this.requests.push(request);
    this.onSend(request);
    const i = this.script.findIndex(([part]) => request.url.includes(part));
    assert.notEqual(i, -1, `unexpected request: ${request.url}`);
    const [[, response]] = this.script.splice(i, 1);
    if (response === null) throw new IoError('offline');
    return response;
  }
  posts() { return this.requests.filter((r) => r.formBody !== null); }
}

function jarOf(plain) {
  const jar = new CookieJar();
  jar.importPlain(PowerApi.HOST, '/CloudPayment/', plain);
  return jar.serialize();
}

class FakeStore {
  bindingGen = 1;
  sessionGen = 1;
  bound = true;
  quantity = null;
  commits = [];
  constructor({ cookies = jarOf('SESSION=old'), state = new RecoveryState(), read = new CredsRead(creds()) } = {}) {
    Object.assign(this, { cookies, state, read });
  }
  begin() {
    if (!this.bound) return null;
    const s = new SyncSnapshot();
    Object.assign(s, { bindingGen: this.bindingGen, sessionGen: this.sessionGen, payProId: '3148',
      roomVerify: '101-1--9-902', cookies: this.cookies, state: this.state });
    return s;
  }
  creds() { return this.read; }
  async commit(base, c) {
    if (base.bindingGen !== this.bindingGen || base.sessionGen !== this.sessionGen) return false;
    this.commits.push(c);
    this.state = c.state;
    if (c.cookies !== null) this.cookies = c.cookies;
    if (c.quantity !== null) this.quantity = c.quantity;
    return true;
  }
}

function state(fields) {
  return Object.assign(new RecoveryState(), fields);
}

let clock = 1000000;
const now = () => clock;
const run = (store, http, trigger = Trigger.PERIODIC, cancelled = () => false) =>
  new SyncEngine(store, http, now).run(trigger, cancelled, () => {});
const deadline = () => new Deadline(() => 0, 90000, () => false);
const recover = (http, c = null, jar = new CookieJar()) => new AuthClient(http, () => 0).recover(jar, c, deadline());
const deadThenLogin = () => new FakeHttp()
  .on('getRoomState', dead)
  .on('api/authorize', resp(200, LOGIN_PAGE))
  .on('api/login', resp(200, '{"errorCode":0}'))
  .on('api/authorize', toPay)
  .on('pay.do', paySession);

test('Cookie 按主机隔离, 同名 SESSION 互不覆盖', () => {
  const pay = `https://${PowerApi.HOST}:18443/CloudPayment/user/getRoomState.do?a=1`;
  const open = `https://${PowerApi.OPEN_HOST}/api/authorize?x=1`;
  const jar = new CookieJar();
  jar.store(open, ['SESSION=sso; Path=/; HttpOnly; SameSite=Lax'], 0);
  jar.store(pay, ['SESSION=pay; Path=/CloudPayment/; Secure; HttpOnly'], 0);
  assert.equal(jar.header(open, 0), 'SESSION=sso');
  assert.equal(jar.header(pay, 0), 'SESSION=pay');
  assert.equal(jar.header(`https://${PowerApi.HOST}:18443/other`, 0), '');
  const back = CookieJar.parse(jar.serialize());
  assert.equal(back.header(pay, 0), 'SESSION=pay');
});

test('Cookie 过期、删除与外域属性', () => {
  const open = `https://${PowerApi.OPEN_HOST}/api/authorize`;
  const jar = new CookieJar();
  jar.store(open, ['a=1;path=/', 'b=2;path=/;Max-Age=10', 'evil=1; Domain=example.com; Path=/'], 1000);
  jar.store(open, ['a=x;path=/;Max-Age=0'], 1000);
  assert.equal(jar.header(open, 2000), 'b=2');
  assert.equal(jar.header(open, 20000), '');
});

test('轮换后的 SESSION 覆盖 WebView 导入值', () => {
  const jar = new CookieJar();
  jar.importPlain(PowerApi.HOST, '/CloudPayment/', 'SESSION=fromWebView; other=1');
  jar.store(PowerApi.SESSION_URL, ['SESSION=rotated; Path=/CloudPayment/; Secure'], 0);
  assert.equal(jar.header(PowerApi.SESSION_URL, 0), 'other=1; SESSION=rotated');
});

test('URL 解析不被 userinfo 骗过', () => {
  assert.equal(parseUrl(`https://${PowerApi.OPEN_HOST}@evil.example/x`).host, 'evil.example');
  assert.equal(parseUrl('https://evil.example\\@open.17wanxiao.com/'), null);
  assert.equal(parseUrl('https://H5CLOUD.17wanxiao.com:18443').path, '/');
  assert.equal(resolveUrl('https://a.com/x/y?q=1', 'z'), 'https://a.com/x/z');
  assert.equal(resolveUrl('https://a.com/x/y', '/z?k=1'), 'https://a.com/z?k=1');
  assert.equal(resolveUrl('https://a.com/x', '//b.com/z'), 'https://b.com/z');
});

test('电量响应分类', () => {
  const kind = (body, status = 200) => classifyRoom(status, body, []).kind;
  const zero = classifyRoom(200, '{"returncode":"100","quantity":"0"}', []);
  assert.equal(zero.kind, RoomKind.VALID);
  assert.equal(zero.quantity, 0);
  assert.equal(kind(DEAD_BODY), RoomKind.SESSION_SUSPECT);
  assert.equal(kind('{"returncode":"200","returnmsg":"房间不存在"}'), RoomKind.UNKNOWN);
  assert.equal(kind('{"returncode":"100","quantity":"NaN"}'), RoomKind.UNKNOWN);
  assert.equal(kind('{"returncode":"100"}'), RoomKind.UNKNOWN);
  assert.equal(kind('bad gateway', 502), RoomKind.TRANSIENT);
  assert.equal(kind('<html>maintenance</html>'), RoomKind.UNKNOWN);
});

test('SSO 回跳不发送密码', async () => {
  const http = new FakeHttp().on('api/authorize', toPay).on('pay.do', paySession);
  const jar = new CookieJar();
  assert.equal((await recover(http, creds(), jar)).status, AuthStatus.READY);
  assert.equal(http.posts().length, 0);
  assert.equal(jar.header(PowerApi.SESSION_URL, 0), 'SESSION=fresh');
});

test('密码登录与页面协议一致', async () => {
  const http = new FakeHttp()
    .on('api/authorize', resp(200, LOGIN_PAGE, ['SESSION=form; Path=/']))
    .on('api/login', resp(200, '{"errorCode":0}', ['SESSION=authed; Path=/']))
    .on('api/authorize', toPay)
    .on('pay.do', paySession);
  assert.equal((await recover(http, creds())).status, AuthStatus.READY);
  const [login] = http.posts();
  assert.ok(login.url.startsWith(`https://${PowerApi.OPEN_HOST}/api/login?response_type=code`));
  assert.equal(login.headers.Cookie, 'SESSION=form');
  assert.ok(login.formBody.includes('loginType=wx') && login.formBody.includes('password=p%26ss%3Dword'));
  assert.ok(login.formBody.includes('scopes%5B%5D=base') && login.formBody.includes('scopes%5B%5D=user_alter'));
  assert.ok(!login.formBody.includes('outid'));
  assert.equal(http.requests[2].headers.Cookie, 'SESSION=authed');
});

test('校园卡登录携带卡片字段', async () => {
  const http = new FakeHttp().on('api/authorize', resp(200, LOGIN_PAGE))
    .on('api/login', resp(200, '{"errorCode":1,"desc":"密码错误"}'));
  const c = Object.assign(new LoginCreds(), { type: 'ecard', username: '名字', password: 'pw', customerCode: '784', outid: '2020001' });
  assert.equal((await recover(http, c)).status, AuthStatus.REJECTED);
  const body = http.posts()[0].formBody;
  assert.ok(body.includes('loginType=ecard') && body.includes('customerCode=784') && body.includes('outid=2020001'));
});

test('所有认证请求的 Accept 都带 */* (服务器否则返回 406)', async () => {
  const http = new FakeHttp().on('api/authorize', resp(200, LOGIN_PAGE)).on('api/login', resp(200, '{"errorCode":1}'));
  await recover(http, creds());
  assert.equal(http.requests.length, 2);
  for (const r of http.requests) assert.ok(r.headers.Accept.includes('*/*'), r.url);
  const r406 = await recover(new FakeHttp().on('api/authorize', resp(406, '{}')));
  assert.equal(r406.status, AuthStatus.UNKNOWN);
  assert.ok(r406.message.includes('406'));
});

test('错误页只强制重试一次', async () => {
  const http = new FakeHttp().on('force_login=false', resp(200, '<title>提示</title>'))
    .on('force_login=true', resp(200, LOGIN_PAGE));
  assert.equal((await recover(http)).status, AuthStatus.NO_CREDENTIALS);
  assert.equal(http.requests.length, 2);
});

test('登录响应的跳转绝不跟随, 未知主机与明文跳转不请求', async () => {
  const login = new FakeHttp().on('api/authorize', resp(200, LOGIN_PAGE))
    .on('api/login', resp(302, '', [], 'https://evil.example/steal'));
  assert.equal((await recover(login, creds())).status, AuthStatus.UNKNOWN);
  assert.equal(login.requests.length, 2);
  for (const target of ['https://evil.example/x', `http://${PowerApi.OPEN_HOST}/x`,
    `https://${PowerApi.OPEN_HOST}@evil.example/x`]) {
    const http = new FakeHttp().on('api/authorize', resp(302, '', [], target));
    assert.equal((await recover(http, creds())).status, AuthStatus.UNKNOWN);
    assert.equal(http.requests.length, 1);
  }
});

test('跳转次数有上限, 网络故障是临时的, 无法解析不算拒绝', async () => {
  const loop = new FakeHttp();
  for (let i = 0; i < 20; i++) loop.on('api/authorize', resp(302, '', [], '/api/authorize?loop=1'));
  assert.equal((await recover(loop)).status, AuthStatus.UNKNOWN);
  assert.ok(loop.requests.length <= 8);
  assert.equal((await recover(new FakeHttp().failOn('api/authorize'))).status, AuthStatus.TRANSIENT);
  const waf = new FakeHttp().on('api/authorize', resp(200, LOGIN_PAGE)).on('api/login', resp(200, '<html>waf</html>'));
  assert.equal((await recover(waf, creds())).status, AuthStatus.UNKNOWN);
});

test('有效会话: 提交读数和轮换后的 Cookie', async () => {
  const store = new FakeStore();
  assert.equal((await run(store, new FakeHttp().on('getRoomState', ok))).outcome, Outcome.OK);
  assert.equal(store.quantity, 250);
  assert.equal(CookieJar.parse(store.cookies).header(PowerApi.SESSION_URL, clock), 'SESSION=rotated');
});

test('过期会话在后台自行恢复, 不进入人工状态', async () => {
  const store = new FakeStore();
  const http = deadThenLogin().on('getRoomState', ok);
  const r = await run(store, http);
  assert.equal(r.outcome, Outcome.OK);
  assert.equal(r.stage, Stage.REQUERY);
  assert.equal(store.state.needsLogin, false);
  assert.equal(store.commits.length, 1);
  assert.equal(http.posts().length, 1);
  assert.equal(http.requests.filter((q) => q.url.includes('getRoomState')).length, 2);
});

test('失败查询带回的匿名会话不落盘', async () => {
  const store = new FakeStore();
  const before = store.cookies;
  await run(store, new FakeHttp().on('getRoomState', dead).failOn('api/authorize'));
  assert.equal(store.cookies, before);
});

test('恢复后的零电量正常提交', async () => {
  const store = new FakeStore();
  const http = new FakeHttp().on('getRoomState', dead).on('api/authorize', toPay).on('pay.do', paySession)
    .on('getRoomState', resp(200, '{"returncode":"100","quantity":"0"}'));
  assert.equal((await run(store, http)).outcome, Outcome.OK);
  assert.equal(store.quantity, 0);
});

test('密码被拒后转人工, 不再重新提交', async () => {
  const store = new FakeStore();
  const http = new FakeHttp().on('getRoomState', dead).on('api/authorize', resp(200, LOGIN_PAGE))
    .on('api/login', resp(200, '{"errorCode":1,"desc":"验证码错误"}')).on('getRoomState', dead);
  assert.equal((await run(store, http)).outcome, Outcome.MANUAL);
  assert.equal(store.state.needsLogin, true);
  clock += 24 * 3600000;
  assert.equal((await run(store, http, Trigger.USER)).outcome, Outcome.MANUAL);
  assert.equal(http.posts().length, 1);
});

test('查询成功清除人工状态', async () => {
  const store = new FakeStore({ state: state({ needsLogin: true }) });
  assert.equal((await run(store, new FakeHttp().on('getRoomState', ok), Trigger.USER)).outcome, Outcome.OK);
  assert.equal(store.state.needsLogin, false);
});

test('没有凭据转人工; 凭据暂不可读是临时故障, 持续不可读才转人工', async () => {
  const none = new FakeHttp().on('getRoomState', dead).on('api/authorize', resp(200, LOGIN_PAGE));
  assert.equal((await run(new FakeStore({ read: new CredsRead(null) }), none)).outcome, Outcome.MANUAL);
  const flaky = new FakeStore({ read: new CredsRead(null, true) });
  assert.equal((await run(flaky, new FakeHttp().on('getRoomState', dead))).outcome, Outcome.TRANSIENT);
  assert.equal(flaky.state.needsLogin, false);
  const gone = new FakeStore({ state: state({ failCount: 3 }), read: new CredsRead(null, true) });
  assert.equal((await run(gone, new FakeHttp().on('getRoomState', dead))).outcome, Outcome.MANUAL);
});

test('断网保留 Cookie 并退避', async () => {
  const store = new FakeStore();
  const before = store.cookies;
  assert.equal((await run(store, new FakeHttp().failOn('getRoomState'))).outcome, Outcome.TRANSIENT);
  assert.equal(store.cookies, before);
  assert.equal(store.quantity, null);
  assert.equal(store.state.failCount, 1);
  assert.equal(store.state.nextAttemptAt, clock + 15 * 60000);
  assert.deepEqual([1, 2, 3, 9].map(backoffMs), [15, 60, 360, 360].map((m) => m * 60000));
});

test('退避期内后台不发请求, 用户刷新也不能绕过认证退避', async () => {
  const quiet = new FakeHttp();
  const r = await run(new FakeStore({ state: state({ failCount: 1, nextAttemptAt: clock + 1000 }) }), quiet);
  assert.equal(r.outcome, Outcome.SKIPPED);
  assert.equal(quiet.requests.length, 0);
  const http = new FakeHttp().on('getRoomState', dead);
  const store = new FakeStore({ state: state({ failCount: 2, nextAttemptAt: clock + 1000, authBackoff: true }) });
  assert.equal((await run(store, http, Trigger.USER)).outcome, Outcome.SKIPPED);
  assert.equal(http.requests.length, 1);
});

test('用户刷新的查询失败不延长退避', async () => {
  const store = new FakeStore();
  await run(store, new FakeHttp().failOn('getRoomState'), Trigger.USER);
  assert.equal(store.state.failCount, 0);
  assert.equal(store.state.nextAttemptAt, 0);
});

test('卡片触发绝不提交密码', async () => {
  const store = new FakeStore();
  const http = new FakeHttp().on('getRoomState', dead);
  assert.equal((await run(store, http, Trigger.WIDGET)).outcome, Outcome.SKIPPED);
  assert.equal(http.requests.length, 1);
  assert.equal(store.commits.length, 0);
});

test('未知返回不当作会话失效', async () => {
  const store = new FakeStore();
  const http = new FakeHttp().on('getRoomState', resp(200, '{"returncode":"999"}'));
  assert.equal((await run(store, http)).outcome, Outcome.UNKNOWN);
  assert.equal(http.requests.length, 1);
});

test('恢复后仍失效: 结束本轮, 不递归重登', async () => {
  const store = new FakeStore();
  const http = deadThenLogin().on('getRoomState', dead);
  assert.equal((await run(store, http)).outcome, Outcome.UNKNOWN);
  assert.equal(http.posts().length, 1);
  assert.equal(store.state.needsLogin, false);
  assert.equal(store.state.authBackoff, true);
});

test('空 Cookie 直接走恢复', async () => {
  const http = new FakeHttp().on('api/authorize', toPay).on('pay.do', paySession).on('getRoomState', ok);
  assert.equal((await run(new FakeStore({ cookies: '' }), http)).outcome, Outcome.OK);
  assert.equal(http.requests.filter((q) => q.url.includes('getRoomState')).length, 1);
});

test('执行中换绑或凭据变化: 迟到结果作废', async () => {
  const rebind = new FakeStore();
  const http = new FakeHttp().on('getRoomState', ok);
  http.onSend = () => { rebind.bindingGen++; };
  assert.equal((await run(rebind, http)).outcome, Outcome.DISCARDED);
  assert.equal(rebind.quantity, null);

  const session = new FakeStore();
  const before = session.cookies;
  const login = deadThenLogin().on('getRoomState', ok);
  login.onSend = (q) => { if (q.url.includes('api/login')) session.sessionGen++; };
  assert.equal((await run(session, login)).outcome, Outcome.DISCARDED);
  assert.equal(session.cookies, before);
});

test('取消后不提交任何结果', async () => {
  const store = new FakeStore();
  let stopped = false;
  const http = new FakeHttp().on('getRoomState', ok);
  http.onSend = () => { stopped = true; };
  assert.equal((await run(store, http, Trigger.PERIODIC, () => stopped)).outcome, Outcome.DISCARDED);
  assert.equal(store.commits.length, 0);
});

test('预算覆盖整轮', async () => {
  const store = new FakeStore();
  const http = new FakeHttp().on('getRoomState', dead);
  http.onSend = () => { clock += BUDGET_MS + 1; };
  assert.equal((await run(store, http)).outcome, Outcome.TRANSIENT);
  assert.equal(http.requests.length, 1);
});

test('未绑定不碰网络', async () => {
  const store = new FakeStore();
  store.bound = false;
  const http = new FakeHttp();
  assert.equal((await run(store, http)).outcome, Outcome.UNBOUND);
  assert.equal(http.requests.length, 0);
});
