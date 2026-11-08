"""web_app: web server nhỏ cho demo định tuyến theo domain.

Mọi path đều trả về thông tin Pod đã xử lý request (tên, IP, node) và những gì Envoy chuyển tới
(Host, path, X-Forwarded-For, X-Request-Id...). Trình duyệt nhận HTML, curl nhận JSON.
  GET /healthz -> {"status": "ok"}
"""
import html
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
APP = os.environ.get("APP_NAME", "web")
MESSAGE = os.environ.get("MESSAGE", "")
COLOR = os.environ.get("COLOR", "#2563eb")
POD = os.environ.get("POD_NAME", "unknown")
POD_IP = os.environ.get("POD_IP", "unknown")
NODE = os.environ.get("NODE_NAME", "unknown")


class Handler(BaseHTTPRequestHandler):
    server_version = f"{APP}/1.0"

    def log_message(self, fmt, *args):
        print(json.dumps({"app": APP, "pod": POD, "host": self.headers.get("host", ""),
                          "request_id": self.headers.get("x-request-id", ""), "line": fmt % args}), flush=True)

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/healthz":
            return self.reply(200, "application/json", json.dumps({"status": "ok"}).encode())
        info = {
            "app": APP,
            "message": MESSAGE,
            "pod": POD,
            "pod_ip": POD_IP,
            "node": NODE,
            "host": self.headers.get("host", ""),
            "path": self.path,
            "client_ip": self.headers.get("x-forwarded-for", ""),
            "request_id": self.headers.get("x-request-id", ""),
            "user": self.headers.get("x-user", ""),
            "peer": self.client_address[0],  # IP của Pod Envoy kết nối tới (không phải ClusterIP)
        }
        if "text/html" in self.headers.get("accept", ""):
            rows = "".join(f"<tr><th>{html.escape(k)}</th><td>{html.escape(str(v))}</td></tr>" for k, v in info.items())
            page = (f"<!doctype html><meta charset=utf-8><title>{html.escape(APP)}</title>"
                    f"<body style='font-family:sans-serif;margin:40px'>"
                    f"<h1 style='color:{html.escape(COLOR)}'>{html.escape(APP)}</h1><p>{html.escape(MESSAGE)}</p>"
                    f"<table cellpadding=6 border=1 style='border-collapse:collapse'>{rows}</table></body>")
            return self.reply(200, "text/html; charset=utf-8", page.encode())
        return self.reply(200, "application/json", json.dumps(info).encode())

    do_HEAD = do_GET

    def reply(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-App", APP)
        self.send_header("X-Pod-Name", POD)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


if __name__ == "__main__":
    print(json.dumps({"app": APP, "pod": POD, "msg": f"listening on :{PORT}"}), flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
