#!/usr/bin/env bash
# 自动刷新 Cookie: 在模拟器里重新打开 App 的电网缴费页面,
# 让 mitmdump 的 cookie_grab 插件自动续期。
#
# 前提: 模拟器在运行、智慧民大 App 已登录、mitmdump 带 cookie_grab.py 在跑。
# 注意: 脚本里的 tap 坐标按 1080x2280 分辨率(pixel_4 机型)写死,
#       其他分辨率请自行调整, 或手动在模拟器里点一次缴费页(效果相同)。
#
# 用法: ./refresh-cookie.sh
set -e
SERIAL="${ANDROID_SERIAL:-emulator-5556}"
PKG="com.lysoft.android.lyyd.report.mobile.xzmz"   # 智慧民大包名, 其他学校自行修改

# mitmdump 是否带 cookie_grab 插件?
if ! pgrep -f 'cookie_grab' >/dev/null; then
  echo "[!] 当前没有带 cookie_grab 插件的 mitmdump 在跑, 先启动:"
  echo "    mitmdump -s cookie_grab.py -w capture.flow --listen-port 8080 &"
  exit 1
fi

# 确保代理链路
adb -s "$SERIAL" reverse tcp:8080 tcp:8080 >/dev/null
adb -s "$SERIAL" shell settings put global http_proxy 127.0.0.1:8080

# 冷启动 App -> 关通知弹窗(若有) -> 点首页常用服务里的电网缴费
adb -s "$SERIAL" shell am force-stop "$PKG"
sleep 1
adb -s "$SERIAL" shell am start -n "$PKG/com.lysoft.android.lyyd.report.config.dispatch.DispatchActivity" >/dev/null
sleep 14
adb -s "$SERIAL" shell input tap 324 1204 2>/dev/null || true   # 通知弹窗"取消"
sleep 2
adb -s "$SERIAL" shell input tap 667 1526                        # 电网缴费图标
sleep 12

echo "已打开电网缴费页面。页面加载成功后 Cookie 即自动更新(见 mitmdump 输出)。"
