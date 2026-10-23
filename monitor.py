#!/usr/bin/env python3
"""西藏民族大学宿舍电费监控器 — 查询剩余电量，低于阈值时桌面告警。

数据源: 智慧民大 App "电网缴费" 页面(新开普完美校园云, h5cloud.17wanxiao.com),
接口经 mitmproxy 抓包逆向获得。服务器要求请求同时携带 Cookie 和 Referer。

用法:
  ./monitor.py                  查一次, 低于阈值时告警
  ./monitor.py --loop 1800      每 30 分钟查一次, 常驻运行
  ./monitor.py --threshold 50   临时指定阈值(覆盖 config.ini)

配置: 复制 config.example.ini 为 config.ini 并填入自己的参数。
Cookie: 存放于 ~/.config/xzmu-electricity/cookie.txt,
        由 mitmdump 插件 cookie_grab.py 自动抓取维护。

退出码: 0=正常  1=查询失败  2=Cookie 失效(重新打开一次缴费页面即可续期)
"""
import argparse
import configparser
import json
import pathlib
import ssl
import subprocess
import sys
import time
import urllib.request

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
CONFIG_FILE = SCRIPT_DIR / "config.ini"
COOKIE_FILE = pathlib.Path.home() / ".config/xzmu-electricity/cookie.txt"
STATE_FILE = pathlib.Path.home() / ".cache/xzmu-electricity/state.json"

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE


def load_config() -> configparser.ConfigParser:
    if not CONFIG_FILE.exists():
        sys.exit(f"配置文件不存在: {CONFIG_FILE}\n"
                 f"请先: cp config.example.ini config.ini 并填入自己的参数")
    cfg = configparser.ConfigParser()
    cfg.read(CONFIG_FILE)
    return cfg


def build_url(cfg: configparser.ConfigParser) -> str:
    api = cfg["api"]
    host = api.get("host", "h5cloud.17wanxiao.com")
    port = api.get("port", "18443")
    return (f"https://{host}:{port}/CloudPayment/user/getRoomState.do"
            f"?payProId={api['pay_pro_id']}&schoolcode={api['school_code']}"
            f"&businesstype={api['business_type']}&roomverify={api['room_verify']}")


def build_referer(cfg: configparser.ConfigParser) -> str:
    api = cfg["api"]
    host = api.get("host", "h5cloud.17wanxiao.com")
    port = api.get("port", "18443")
    return (f"https://{host}:{port}/CloudPayment/bill/selectPayProject.do"
            f"?txcode=2&interurl=substituted_pay&payProId={api['pay_pro_id']}"
            f"&amtflag=0&payamt=1000")


def notify(title: str, body: str) -> None:
    print(f"[{time.strftime('%m-%d %H:%M:%S')}] {title}: {body}", flush=True)
    try:
        subprocess.run(["kdialog", "--title", title, "--passivepopup", body, "10"],
                       timeout=5)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    try:
        subprocess.run(["paplay", "/usr/share/sounds/freedesktop/stereo/complete.oga"],
                       timeout=5)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass


def load_cookie() -> str:
    if not COOKIE_FILE.exists():
        sys.exit(f"Cookie 文件不存在: {COOKIE_FILE}\n"
                 f"先用 mitmdump + cookie_grab.py 抓一次缴费页面")
    return COOKIE_FILE.read_text().strip()


def query(cfg: configparser.ConfigParser) -> dict:
    req = urllib.request.Request(build_url(cfg), headers={
        "Cookie": load_cookie(),
        "Referer": build_referer(cfg),
        "User-Agent": ("Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 "
                       "(KHTML, like Gecko) Version/4.0 Chrome/124.0.6367.219 "
                       "Mobile Safari/537.36"),
        "Accept": "application/json",
        "X-Requested-With": "XMLHttpRequest",
    })
    with urllib.request.urlopen(req, context=SSL_CTX, timeout=15) as r:
        text = r.read().decode()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # 服务器异常时返回 "RspBaseVO [code=ERROR, ...]" 文本
        if "ERROR" in text:
            return {"returncode": "SESSION_DEAD"}
        raise


def load_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {"alerted": False}


def save_state(s: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(s))


def check_once(cfg: configparser.ConfigParser, threshold: float) -> int:
    state = load_state()
    try:
        data = query(cfg)
    except Exception as e:
        notify("电费监控: 查询失败", str(e))
        return 1

    if data.get("returncode") != "100":
        notify("电费监控: Cookie 已失效",
               "重新打开一次 App 的电网缴费页面即可自动续期")
        return 2

    qty = float(data.get("quantity", "0"))
    unit = data.get("quantityunit", "度")
    desc = data.get("description", cfg["api"].get("room_label", ""))

    if qty < threshold:
        if not state.get("alerted"):
            notify(f"⚠️ 电费不足! {desc} 剩余 {qty}{unit}",
                   f"低于阈值 {threshold}{unit}, 请尽快充值")
            state["alerted"] = True
    else:
        if state.get("alerted"):
            notify(f"电费已恢复: {qty}{unit}", "回到阈值以上")
        state["alerted"] = False

    state["last_qty"] = qty
    state["last_ok"] = time.time()
    save_state(state)
    print(f"{desc}: 剩余 {qty}{unit} (阈值 {threshold})")
    return 0


def main() -> None:
    ap = argparse.ArgumentParser(description="宿舍电费监控器")
    ap.add_argument("--threshold", type=float, help="告警阈值(度), 覆盖 config.ini")
    ap.add_argument("--loop", type=int, metavar="秒", help="循环模式, 每隔 N 秒查询一次")
    args = ap.parse_args()

    cfg = load_config()
    threshold = args.threshold if args.threshold is not None \
        else cfg["monitor"].getfloat("threshold", fallback=20.0)

    if args.loop:
        while True:
            try:
                check_once(cfg, threshold)
            except KeyboardInterrupt:
                return
            time.sleep(args.loop)
    else:
        sys.exit(check_once(cfg, threshold))


if __name__ == "__main__":
    main()
