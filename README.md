# XZMU 电费查询 · 低电量告警

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

监控**西藏民族大学**（秦汉校区）宿舍剩余电量，低于阈值时桌面弹窗 + 声音告警。
数据来自智慧民大 App「电网缴费」页面（新开普 · 完美校园云），接口经 mitmproxy 抓包逆向获得。

> 本项目仅供学习研究和个人宿舍电费查询使用，与西藏民族大学及新开普公司无关。
> 请保持低频请求（默认每天 4 次），勿对接口造成压力。

## 工作原理

App 的电网缴费页是个 WebView，加载新开普云缴费系统。页面里的「剩余电量」由一个 XHR 接口填充：

```
GET https://h5cloud.17wanxiao.com:18443/CloudPayment/user/getRoomState.do
    ?payProId=<项目ID>&schoolcode=<学校编码>&businesstype=2&roomverify=<房间校验码>

→ {"returncode":"100","quantity":"250.0","quantityunit":"度","canbuy":"true","description":"XXX房间"}
```

接口要点：

- 服务器要求请求**同时**携带 `Cookie`（会话）和 `Referer`（缴费页地址），缺一个都返回「系统繁忙」
- `roomverify` 编码了楼栋-楼层-房间（如 `101-1--9-XXX`），换房间需重新抓包
- Cookie 会过期，过期后重新打开一次缴费页面即可续期（`cookie_grab.py` 插件自动落盘）

## 安装

```bash
git clone https://github.com/DHKun/xzmu-electricity-monitor.git
cd xzmu-electricity-monitor
cp config.example.ini config.ini
# 编辑 config.ini, 填入你抓包得到的参数
./monitor.py
```

只依赖 Python 3 标准库。

## 抓包获取配置

`config.ini` 里的 `pay_pro_id` / `school_code` / `room_verify` 和 `Cookie` 都要从你自己的流量里抓：

1. 准备一个能装系统级 CA 证书的环境（推荐 root 的 Android 模拟器，user CA 对新 App 无效），
   安装 [mitmproxy](https://mitmproxy.org/) 的 CA 证书
2. 给设备设置全局代理并建立端口转发：
   ```bash
   adb reverse tcp:8080 tcp:8080
   adb shell settings put global http_proxy 127.0.0.1:8080
   mitmdump --listen-port 8080 -s cookie_grab.py -w capture.flow
   ```
3. 在 App 里打开「电网缴费」，等页面显示出剩余电量
4. 从 mitmproxy 中找到 `getRoomState.do` 请求：URL 上的参数填进 `config.ini`，
   请求头里的 `Cookie` 已被插件自动存到 `~/.config/xzmu-electricity/cookie.txt`
5. 查看抓到的流量可用 `mitmweb --rfile capture.flow`（浏览器打开 127.0.0.1:8081）

> 提示：若校园相关域名被你的代理软件（Clash/mihomo 等）转发到远程节点，会连接超时。
> 需为 `*.17wanxiao.com` 和学校域名添加 DIRECT 直连规则。

## 配置定时告警

以 systemd user timer 为例（每天 02/08/14/20 点检查，开机/唤醒后补跑）：

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/xzmu-electricity.service <<EOF
[Unit]
Description=XZMU dorm electricity check

[Service]
Type=oneshot
ExecStart=$PWD/monitor.py
EOF
cat > ~/.config/systemd/user/xzmu-electricity.timer <<EOF
[Unit]
Description=Check dorm electricity every 6 hours

[Timer]
OnCalendar=*-*-* 02/6:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now xzmu-electricity.timer
```

日志: `journalctl --user -u xzmu-electricity.service`

## Cookie 续期

Cookie 失效时 `monitor.py` 退出码为 2 并弹窗提示。两种续期方式：

- 手动：模拟器/手机抓包环境里重新打开一次电网缴费页面（mitmdump 带插件在跑即可）
- 自动：`./refresh-cookie.sh`（会用 adb 自动操作模拟器，tap 坐标按 1080x2280 写死，
  其他分辨率请手动点）

## 目录结构

```
monitor.py          监控器: 查询 + 阈值判断 + 桌面通知(kdialog/paplay)
config.example.ini  配置模板(复制为 config.ini, 已 gitignore)
cookie_grab.py      mitmdump 插件: 自动抓取/续期 Cookie
refresh-cookie.sh   可选: adb 自动操作模拟器刷新 Cookie
```

## License

[MIT](LICENSE)
