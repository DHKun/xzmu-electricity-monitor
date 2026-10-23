"""mitmdump 插件: 抓到电费查询请求(getRoomState.do)时, 把当时的 Cookie 存下来
供 monitor.py 使用。

用法(与抓包同时进行):
    mitmdump -s cookie_grab.py -w capture.flow --listen-port 8080

这样只要在 App 里打开一次"电网缴费"页面, Cookie 就自动续期。
"""
import pathlib

from mitmproxy import http

COOKIE_FILE = pathlib.Path.home() / ".config/xzmu-electricity/cookie.txt"


class CookieGrabber:
    def response(self, flow: http.HTTPFlow) -> None:
        if "getRoomState" not in flow.request.path:
            return
        if not flow.response or b'"returncode"' not in (flow.response.raw_content or b""):
            return
        cookie = flow.request.headers.get("cookie")
        if not cookie:
            return
        COOKIE_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = COOKIE_FILE.with_suffix(".tmp")
        tmp.write_text(cookie)
        tmp.replace(COOKIE_FILE)
        print(f"[cookie_grab] 已更新 {COOKIE_FILE}")


addons = [CookieGrabber()]
