"""order-service: dịch vụ đơn hàng giả lập, public qua Envoy Gateway tại /api/orders.

  GET  /api/orders        danh sách đơn
  GET  /api/orders/<id>   một đơn
  POST /api/orders        {"item": "book", "amount": 100}
                          -> gọi payment-service (east-west, trong cụm) rồi trả:
                             201 PAID | 402 PAYMENT_DECLINED | 502 PAYMENT_ERROR | 400
  GET  /healthz

Khách hàng (customer) lấy từ header x-jwt-sub do Envoy Gateway điền từ claim "sub" của JWT.
Header x-request-id do Envoy sinh được chuyển tiếp sang payment-service để lần theo request.
"""
import json
import os
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
PAYMENT_URL = os.environ.get("PAYMENT_URL", "http://payment-service:8080").rstrip("/")
PAYMENT_TIMEOUT = float(os.environ.get("PAYMENT_TIMEOUT", "3"))

orders = {}
lock = threading.Lock()


def call_payment(order, request_id):
    """POST sang payment-service. Trả về (http_status, body_dict); status 0 = không gọi được."""
    req = urllib.request.Request(
        PAYMENT_URL + "/payments",
        data=json.dumps({"order_id": order["id"], "amount": order["amount"]}).encode(),
        headers={"Content-Type": "application/json", "X-Request-Id": request_id, "X-Caller": "order-service"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=PAYMENT_TIMEOUT) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:  # 4xx/5xx từ payment-service (vd 402 DECLINED)
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {"error": "invalid_payment_response"}
    except Exception as e:  # timeout, DNS, connection refused, bị NetworkPolicy chặn...
        return 0, {"error": type(e).__name__, "detail": str(e)}


class Handler(BaseHTTPRequestHandler):
    server_version = "order-service/1.0"

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Service", "order-service")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(json.dumps({
            "service": "order-service",
            "request_id": self.headers.get("x-request-id", ""),
            "customer": self.headers.get("x-jwt-sub", ""),
            "line": fmt % args,
        }), flush=True)

    def path_only(self):
        return self.path.split("?", 1)[0].rstrip("/") or "/"

    def do_GET(self):
        p = self.path_only()
        if p == "/healthz":
            return self.send_json(200, {"status": "ok"})
        if p == "/api/orders":
            with lock:
                return self.send_json(200, {"orders": list(orders.values())})
        if p.startswith("/api/orders/"):
            with lock:
                order = orders.get(p.split("/")[3])
            return self.send_json(200, order) if order else self.send_json(404, {"error": "order_not_found"})
        return self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path_only() != "/api/orders":
            return self.send_json(404, {"error": "not_found"})
        try:
            data = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            item = str(data["item"]).strip()
            amount = float(data["amount"])
            if not item or amount <= 0:
                raise ValueError
        except (ValueError, KeyError, TypeError):
            return self.send_json(400, {"error": "invalid_body", "expected": {"item": "str", "amount": "number > 0"}})

        request_id = self.headers.get("x-request-id", "")
        order = {
            "id": "ord-" + uuid.uuid4().hex[:8],
            "item": item,
            "amount": amount,
            "customer": self.headers.get("x-jwt-sub") or "anonymous",
            "status": "PENDING",
            "request_id": request_id,
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        code, payment = call_payment(order, request_id)
        if code == 201:
            order["status"], http = "PAID", 201
        elif code == 402:
            order["status"], http = "PAYMENT_DECLINED", 402
        else:
            order["status"], http = "PAYMENT_ERROR", 502
        order["payment"] = payment
        with lock:
            orders[order["id"]] = order
        return self.send_json(http, order)


if __name__ == "__main__":
    print(json.dumps({"service": "order-service", "msg": f"listening on :{PORT}, payment {PAYMENT_URL}"}), flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
