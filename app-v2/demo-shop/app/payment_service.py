"""payment-service: dịch vụ thanh toán giả lập (nội bộ, KHÔNG public qua gateway).

  POST /payments        {"order_id": "...", "amount": 100}  -> 201 APPROVED | 402 DECLINED | 400
  GET  /payments        danh sách giao dịch
  GET  /payments/<id>   một giao dịch
  GET  /healthz

Duyệt nếu amount <= APPROVAL_LIMIT, ngược lại từ chối. Dữ liệu lưu trong RAM (mất khi Pod restart).
"""
import json
import os
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
APPROVAL_LIMIT = float(os.environ.get("APPROVAL_LIMIT", "1000"))

payments = {}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    server_version = "payment-service/1.0"

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Service", "payment-service")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Log JSON một dòng, kèm request id để lần theo request qua nhiều service
        print(json.dumps({
            "service": "payment-service",
            "request_id": self.headers.get("x-request-id", ""),
            "caller": self.headers.get("x-caller", ""),
            "line": fmt % args,
        }), flush=True)

    def path_only(self):
        return self.path.split("?", 1)[0].rstrip("/") or "/"

    def do_GET(self):
        p = self.path_only()
        if p == "/healthz":
            return self.send_json(200, {"status": "ok"})
        if p == "/payments":
            with lock:
                return self.send_json(200, {"payments": list(payments.values())})
        if p.startswith("/payments/"):
            with lock:
                pay = payments.get(p.split("/")[2])
            return self.send_json(200, pay) if pay else self.send_json(404, {"error": "payment_not_found"})
        return self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path_only() != "/payments":
            return self.send_json(404, {"error": "not_found"})
        try:
            data = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            order_id = str(data["order_id"])
            amount = float(data["amount"])
        except (ValueError, KeyError, TypeError):
            return self.send_json(400, {"error": "invalid_body", "expected": {"order_id": "str", "amount": "number"}})
        approved = 0 < amount <= APPROVAL_LIMIT
        pay = {
            "id": "pay-" + uuid.uuid4().hex[:8],
            "order_id": order_id,
            "amount": amount,
            "status": "APPROVED" if approved else "DECLINED",
            "reason": None if approved else f"amount exceeds limit {APPROVAL_LIMIT:g}",
            "caller": self.headers.get("x-caller", ""),
            "request_id": self.headers.get("x-request-id", ""),
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        with lock:
            payments[pay["id"]] = pay
        return self.send_json(201 if approved else 402, pay)


if __name__ == "__main__":
    print(json.dumps({"service": "payment-service", "msg": f"listening on :{PORT}, limit {APPROVAL_LIMIT:g}"}), flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
