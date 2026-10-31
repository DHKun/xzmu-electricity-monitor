---
id: background-sync
type: architecture-design
status: draft
title: 后台同步与会话恢复
tags: [background-monitoring, session-recovery]
---

Android 与鸿蒙 App 如何在手机本地持续查询电量、恢复过期会话并提醒。两端实现互相对应：
`SyncEngine`（一轮同步）、`AuthClient`（认证恢复）、`CookieJar`、`PowerSync`（平台入口）。

## 目的

用户不必想起并打开 App。进程被系统回收后，监控在下一次系统给的执行机会里自行继续；
会话过期且能自动恢复时，用户什么都不会收到，只有确实要人工处理时才提醒一次。

## 保证边界

- 调度周期是意图，不是时钟：Android 约 6 小时，鸿蒙约 2 小时，系统可以延后。
- 用户强行停止应用、关闭后台运行，或系统不再给执行机会时，不保证恢复。重新打开 App 会修复调度。
  鸿蒙实测：`aa force-stop` 会清掉 WorkScheduler 的任务注册，下次启动 App 才重新注册。
- 需要验证码、密码被拒、没有保存密码时，无法自动恢复，必须人工登录。
- 不用服务器、常驻通知、精确闹钟或伪装用途来保活。

## 一轮同步

查询 → 疑似失效则恢复认证 → 用新会话重查一次 → 提交。

- 每轮最多一次认证恢复、两次查询，总预算 90 秒，单个请求不超过 15 秒。预算覆盖整轮，各阶段不重新计时。
- 只有真实查询成功才算恢复。回到缴费域名或拿到新 Cookie 都不算，因为失败的查询也会返回匿名 `SESSION`。
- 认证在 Cookie 副本上进行，验证成功才落盘，失败时已保存的状态不变。

| 结果 | 处理 |
| --- | --- |
| 有效读数 | 可解析的有限数值，`0` 是有效电量 |
| 疑似失效 | 恢复认证后重查 |
| 临时故障（网络、超时、429、5xx） | 持久退避，保留凭据和读数 |
| 需要人工（服务端拒绝、没有凭据） | 停止自动提交密码，提醒一次 |
| 无法识别 | 不猜测为失效，不重复提交密码 |

**失效无法直接判定。** 无效会话实测返回 HTTP 200 + `RspBaseVO [code=ERROR, msg=系统繁忙...]`，
与真实的系统繁忙完全相同，所以只记为疑似，由重查确认。JSON 的非 100 返回码不算失效。

退避下限依次为 15 分钟、1 小时、6 小时，此后维持 6 小时，跨进程重启保留。
用户和卡片刷新的**查询**失败不计入退避，否则离线时多刷几次会推迟后台任务；
但任何触发来源都不能绕过**认证**退避，也不能在需要人工时重新提交密码。

## 认证协议

来自公开的 `wx_utils.js` / `pc-login.js`，登录页没有验证码，也没有页面级加密：

1. GET `/api/authorize`。SSO 仍有效时直接 302 回缴费域；否则返回含 `id="lgn"` 的登录页；
   标题含“提示”的错误页换 `force_login=true` 重试一次。
2. POST `/api/login` + 授权页的查询串，表单字段 `loginType`、`username`、`password`、
   `scopes[]`、`force_bind_ecard`；校园卡另加 `customerCode`、`outid`。响应 JSON 的 `errorCode` 为 0 表示成功。
3. GET `/api/authorize`（不带 `force_login`），302 回缴费域拿到新 `SESSION`。

**未确认：** 第 2、3 步和 `errorCode` 含义只读过脚本，尚未用真实账号验证。
SSO 回跳的真实响应、登录是否触发风控也未观察过。

凭据边界：重定向手动跟随，只访问 https 的 `open.17wanxiao.com` 和 `h5cloud.17wanxiao.com`，跳数上限 8。
登录响应的跳转不跟随，密码只发给固定的登录接口。主机比较用解析出的 host，不能用字符串包含，
授权 URL 的 `redirect_uri` 参数里本身就含缴费域名。

Cookie 按 host + path 保存：授权域和缴费域都有名为 `SESSION` 的 Cookie，只存一个值会互相覆盖。

## 状态与并发

持久存储是权威。WebView 只在交互登录后导入一次（`WebSession`），且要合并验证查询响应里的
`Set-Cookie`，否则旧 WebView 会话会覆盖轮换后的会话。

提交前比较绑定代次和会话代次：换绑、重新登录、修改或清除凭据都会递增代次，让进行中的旧同步作废。

- **Android** 所有入口在同一进程，进程内互斥即可。`SharedPreferences` 的 `commit` 保证原子提交。
- **鸿蒙** App、卡片、后台任务是不同进程，用两把文件锁，进程退出时系统自动释放，不会卡死：
  - `sync.lock`：整轮同步互斥，用 `tryLock`，占用时直接返回。状态必须在拿到锁**之后**读，否则可能用到上一轮之前的退避状态。
  - `state.lock`：所有写入都在 `Prefs.write` 内持锁，锁内 reload、修改、flush。`flush` 落盘的是整份存储，不加锁会用旧内容盖掉别的进程的写入；`reload` 只是刷新缓存，不是互斥。实测两进程并发计数，不加锁丢失约两千次更新，加锁零丢失。

## 平台决定

- **鸿蒙卡片不恢复认证。** 卡片进程可能在提交密码后被回收，来不及记录退避，重复点刷新就能绕过退避。Android 小组件走 WorkManager，没有这个问题。
- **鸿蒙网络层用 `rcp`，不用 `@kit.NetworkKit` 的 `http`。** `maxRedirects: 0` 遇到真实 302 会报错，拿不到响应，与 SDK 文档“0 表示禁用”不符；`rcp` 的 `autoRedirect: false` 能拿到 302 和 `Location`。
- **鸿蒙 `webview` 不进入扩展进程的导入链**，只在 `pages/WebSession.ets` 使用。
- **隐藏 WebView 只作首页兜底。** HTTP 恢复遇到无法识别的页面时，首页每次打开最多试一次；后台路径不依赖它。
- **Android 任务用 `ExistingPeriodicWorkPolicy.UPDATE`**，重复注册不产生重复任务，也不重置周期。

## 通知与诊断

把“发现会话失效”和“通知用户”分开：只有确定要人工处理时才发登录提醒。
是否已提醒以实际发布结果为准，通知被禁止时不标记，开启后下一轮补发，并在同步记录里写“通知受限”。

同步记录保留最近 30 条，含触发来源、阶段、结果、耗时；不含账号、房间、Cookie 和响应原文。
Android 长按设置页版本号查看，鸿蒙点按版本号查看。没有通知不能直接推断为进程被杀，要看记录。

## 已知的坑

- **Accept 必须带 `*/*`。** 授权页对 `text/html,application/xhtml+xml` 返回 406，后台恢复会全部失败。
- **Android 12 及以下没有 `POST_NOTIFICATIONS` 运行时权限**，直接检查会得到“未授予”，要用 `Actions.notificationsOn`。
- **模拟响应测不出这类问题。** 406 和 302 都是全部单元测试通过后，在模拟器上连真实服务器才发现的。改动网络层后必须跑真实链路。
- 模拟器验证：Android 用 `kill -9` + 拨时钟 + `cmd jobscheduler run -f`；鸿蒙用 `hidumper -s 1904 -a '-t <bundle> PowerWorkScheduler'`，约 15–20 秒后才启动，偶尔不启动，要看 `onWorkStart` 再判断结果。

## 不在范围内

桌面脚本 `monitor.py`（仍需手动维护 Cookie）、查询频率设置、自建服务器。
