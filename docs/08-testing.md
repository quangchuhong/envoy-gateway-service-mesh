# 08 – Test case và hướng dẫn kiểm thử

Có hai loại test:

1. **48 test tự động** bằng `tests/run-tests.sh`: gọi API bằng `curl`, lấy token Cognito bằng AWS CLI.
2. **7 test thủ công** bằng trình duyệt cho luồng đăng nhập OIDC của portal (POR-06 đến POR-12), vì cần nhập mật khẩu trên Hosted UI.

## 1. Chuẩn bị

- Đã triển khai đủ docs 02 → 07 và tạo DNS wildcard `*.gitlabonlinecom.click` bằng `scripts/05-dns.sh`.
- Máy chạy test có `curl`, `jq`, `aws` và đọc được `config/demo.env`, `config/cognito.env`.
- Giữ `INSECURE_TLS=0`: môi trường hiện tại dùng cert thật `*.gitlabonlinecom.click` trên NLB, nên `curl` kiểm tra cert bình thường. Nếu test báo lỗi cert, nghĩa là NLB chưa dùng cert ACM (xem docs/04 mục 4). Chỉ đặt `INSECURE_TLS=1` khi cố ý chạy chế độ `nlb-tcp` với cert self-signed.
- DNS chưa lan truyền: đặt `GATEWAY_IP=<một IP của NLB>` trong `config/demo.env`. Script dùng `curl --resolve` nhưng vẫn gửi đúng hostname `*.gitlabonlinecom.click`, nên cert vẫn hợp lệ. Lấy IP:
  ```bash
  dig +short "$(kubectl get gateway -n eg-gateway eg-gateway -o jsonpath='{.status.addresses[0].value}')" | head -1
  ```

Kiểm tra nhanh trước khi chạy test (DNS, cert, Gateway đều đã sẵn sàng):

```bash
for h in portal api partner; do printf '%-10s ' "$h"; curl -s -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' "https://${h}.gitlabonlinecom.click/healthz"; done
```

Kết quả mong đợi: mỗi dòng `200 0` (`200` là health check của Envoy; `0` là cert hợp lệ).

## 2. Chạy test tự động

Chạy tất cả:

```bash
./tests/run-tests.sh
```

Chạy từng nhóm:

```bash
./tests/run-tests.sh orders
```

Nhóm `routing` (24 test RT-xx cho demo định tuyến `shop.<domain>`) chạy riêng, không nằm trong lần chạy mặc định; xem [docs/12](12-traffic-routing.md#4-test):

```bash
./tests/run-tests.sh routing
```

Script in `PASS`/`FAIL` cho từng test và ghi báo cáo Markdown vào `tests/results/last-run.md`. Exit code khác 0 nếu có test FAIL.

> ⏱ **Chờ khoảng 60 giây giữa hai lần chạy**: bộ đếm rate limit tính theo phút. Chạy lại ngay sẽ làm các request đầu tiên bị 429 và một số test thất bại sai.

## 3. Danh sách test case

### Nhóm GW – Gateway dùng chung

| Mã | Mô tả | Cách kiểm tra | Kết quả mong đợi | Tính năng |
|---|---|---|---|---|
| GW-01 | HTTP chuyển sang HTTPS | `curl http://partner.gitlabonlinecom.click/v1/test` | `301`, `Location: https://partner.gitlabonlinecom.click/v1/test` | HTTPRoute `RequestRedirect` |
| GW-02 | Health check của listener | `GET https://partner.gitlabonlinecom.click/healthz` | `200` | `ClientTrafficPolicy.healthCheck` |
| GW-03 | Host không có route | `GET https://unknown.gitlabonlinecom.click/` | `404` | Định tuyến theo hostname |
| GW-04 | Sinh request ID | Gọi partner, xem header backend nhận | Có `X-Request-Id` | `headers.requestID: PreserveOrGenerate` |

### Nhóm POR – App 1 Portal (OIDC Cognito)

| Mã | Mô tả | Cách kiểm tra | Kết quả mong đợi | Tính năng |
|---|---|---|---|---|
| POR-01 | Chưa đăng nhập bị chuyển hướng | `GET https://portal.gitlabonlinecom.click/` | `302` | `SecurityPolicy.oidc` |
| POR-02 | Chuyển tới Cognito Hosted UI | `Location` của POR-01 | Bắt đầu bằng `https://gitlabonlinecom-eg-demo.auth.ap-southeast-1.amazoncognito.com/oauth2/authorize` | OIDC provider |
| POR-03 | `redirect_uri` đúng | `Location` của POR-01 | Chứa `redirect_uri=` trỏ về `https://portal.gitlabonlinecom.click/oauth2/callback` | `oidc.redirectURL` |
| POR-04 | AJAX chưa đăng nhập không bị redirect | Gửi header `X-Requested-With: XMLHttpRequest` | `401` | `oidc.denyRedirect` |
| POR-05 | Cookie ID token giả không vào được | Gửi `Cookie: PortalIdToken=abc.def.ghi` | `302` hoặc `401` | Cookie HMAC của OAuth2 + JWT |

**Test thủ công bằng trình duyệt** (mỗi user dùng một cửa sổ ẩn danh riêng; email và mật khẩu lấy trong `config/cognito.env`):

| Mã | Các bước | Kết quả mong đợi | Tính năng |
|---|---|---|---|
| POR-06 | Mở `https://portal.gitlabonlinecom.click`, đăng nhập bằng `USER_ADMIN_EMAIL` / `USER_ADMIN_PASSWORD` | Hiện trang podinfo, có message `Portal v1 (stable)` hoặc `Portal v2 (canary)` | OIDC Authorization Code |
| POR-07 | Sau POR-06, mở DevTools và xem cookie của `https://portal.gitlabonlinecom.click` (cách mở trên macOS: xem ghi chú dưới bảng) | Có `PortalIdToken`, `PortalAccessToken` (tên đặt trong chart), cùng các cookie `OauthHMAC-…`, `OauthExpires-…`, `RefreshToken-…` do Envoy đặt (đuôi ngẫu nhiên), tất cả có cờ `HttpOnly`, `Secure` | Cookie phiên |
| POR-08 | Mở `https://portal.gitlabonlinecom.click/headers` | JSON chứa `X-User-Email` = email của bạn, `X-Jwt-Sub`; response có `Strict-Transport-Security`, `X-Frame-Options: DENY` | `claimToHeaders`, security headers |
| POR-09 | Admin mở `https://portal.gitlabonlinecom.click/env` | `200`, hiện biến môi trường | Phân quyền path admin |
| POR-10 | Đăng nhập bằng `USER_VIEWER_*`, mở `/` rồi `/env` | `/` được vào; `/env` trả `403 RBAC: access denied` | Deny path admin với group khác |
| POR-11 | Đăng nhập bằng `USER_NOGROUP_*` | `403` ở mọi trang | `defaultAction: Deny` |
| POR-12 | Đã đăng nhập, bấm F5 khoảng 20 lần ở `/` | Khoảng 20% lần hiện **màu cam / Portal v2**. Thêm header `x-canary: always` (dùng extension ModHeader) thì luôn là v2 | Canary theo trọng số + header |

**Mở DevTools để xem cookie (POR-07) trên macOS** (phím F12 thường không dùng được):

| Trình duyệt | Mở DevTools | Xem cookie |
|---|---|---|
| Chrome / Edge / Brave | `Cmd ⌘ + Option ⌥ + I`, hoặc menu **View → Developer → Developer Tools** | Tab **Application** (nếu ẩn thì bấm `»`) → **Storage → Cookies** |
| Safari | Bật một lần: **Safari → Settings → Advanced → Show features for web developers**; sau đó `Cmd ⌘ + Option ⌥ + I` | Tab **Storage → Cookies** |
| Firefox | `Cmd ⌘ + Option ⌥ + I` | Tab **Storage → Cookies** |

Giải mã ID token: copy giá trị `PortalIdToken` rồi chạy `./scripts/get-token.sh decode "<giá trị>" | jq '{email, "cognito:groups", aud, token_use}'`. Kết quả mong đợi: `cognito:groups` là group của user, `aud` là client ID của `portal-web`, `token_use` là `id`.

Logout: mở `https://portal.gitlabonlinecom.click/logout` (xoá cookie Envoy), rồi mở URL logout của Cognito ở [docs/05](05-app1-portal.md) mục 7.

### Nhóm ORD – App 2 Orders API (JWT Cognito)

| Mã | Mô tả | Kết quả mong đợi | Tính năng |
|---|---|---|---|
| ORD-01 | Không có token | `401` | JWT bắt buộc |
| ORD-02 | Token sai | `401` | Verify chữ ký JWKS |
| ORD-03 | Dùng **ID token** của admin | `403` | Luật `reject-id-tokens` (`token_use=id`) |
| ORD-04 | viewer `GET /orders` | `200` | Phân quyền theo group |
| ORD-05 | viewer `POST /orders` | `403` | |
| ORD-06 | developer `POST /orders` | `200` | |
| ORD-07 | developer `DELETE /orders/1` | `403` | |
| ORD-08 | admin `DELETE /orders/1` | `200` | |
| ORD-09 | user không có group `GET` | `403` | `defaultAction: Deny` |
| ORD-10 | Client máy (scope read) `GET` | `200` | Phân quyền theo **scope** |
| ORD-11 | Client máy (scope write) `POST` | `200` | |
| ORD-12 | Client máy `DELETE` | `403` | Không có luật nào cho máy xoá |
| ORD-13 | `GET /orders/123` | Backend nhận `/anything/orders/123` | `URLRewrite ReplacePrefixMatch` |
| ORD-14 | Header gateway thêm vào | Backend nhận `X-Gateway: envoy-gateway` | `RequestHeaderModifier.set` |
| ORD-15 | Client gửi `X-Debug-Internal` | Backend **không** nhận header này | `RequestHeaderModifier.remove` |
| ORD-16 | Client gửi `X-Jwt-Sub: hacker` | Backend nhận `X-Jwt-Sub` = `sub` thật trong token | `earlyRequestHeaders.remove` + `claimToHeaders` |
| ORD-17 | 5 request có `x-api-version: v2` | Cả 5 có `x-backend-version: v2` | Routing theo header |
| ORD-18 | 45 request không có header | Số request vào v2 trong khoảng 1..15 (kỳ vọng khoảng 4–5) | Canary 90/10 |
| ORD-19 | Preflight CORS từ `https://portal.gitlabonlinecom.click` | `access-control-allow-origin: https://portal.gitlabonlinecom.click` | CORS |
| ORD-20 | Preflight CORS từ origin lạ | Không có `access-control-allow-origin` | CORS |
| ORD-21 | 30 request `/orders/unstable` (backend lỗi khoảng 50%) | ≥ 25 request `200` (không có retry chỉ khoảng 15) | Retry 3 lần khi 5xx |
| ORD-22 | `/orders/slow` (backend chậm 5s) | `504` | Timeout 2s |
| ORD-23 | Thời gian của ORD-22 | < 4 giây | |
| ORD-24 | 15 request song song tới `/orders/slow` | Có request bị `503` ngay lập tức | Circuit breaker |
| ORD-25 | 40 request `/orders/chaos/x` | Số `503` trong khoảng 8..32 (kỳ vọng khoảng 20) | Fault injection 50% |
| ORD-26 | 35 request liên tiếp bằng token máy | Có `429` sau khoảng request thứ 30 | Rate limit 30/phút theo `sub` |
| ORD-27 | Ngay sau ORD-26, viewer gọi API | `200` (bộ đếm riêng từng user) | Rate limit `Distinct` |
| ORD-28 | Xem trường `url` mà backend trả về ở ORD-13 | Bắt đầu bằng `https://`: Envoy → Pod đi qua TLS | `BackendTLSPolicy` |

### Nhóm PAR – App 3 Partner API (API key)

| Mã | Mô tả | Kết quả mong đợi | Tính năng |
|---|---|---|---|
| PAR-01 | Không có API key | `401` | `apiKeyAuth` |
| PAR-02 | API key sai | `401` | |
| PAR-03 | Key silver `GET /v1/quote` | `200` | |
| PAR-04 | Backend nhận danh tính đối tác | `X-Partner-Id: partner-silver` | `forwardClientIDHeader` |
| PAR-05 | Backend **không** thấy API key | Không có `X-Api-Key` | `sanitize: true` |
| PAR-06 | Key silver `POST` | `403` | Phân quyền theo gói |
| PAR-07 | Key gold `POST` | `200` | |
| PAR-08 | Key silver + tự gửi `X-Partner-Id: partner-gold` | Backend vẫn nhận `partner-silver` | Chống giả mạo header |
| PAR-09 | Như PAR-08 nhưng `POST` | `403` | |
| PAR-10 | 8 request liên tiếp bằng key silver | Có `429` | Rate limit 5/phút gói silver |
| PAR-11 | 10 request bằng key gold | Không có `429` | Rate limit 100/phút gói gold |

## 4. Kiểm tra bổ sung bằng tay (không nằm trong script)

| Mục | Cách làm | Kỳ vọng |
|---|---|---|
| IP client thật | `curl -s -H "x-api-key: $PARTNER_GOLD_KEY" https://partner.gitlabonlinecom.click/v1/ip \| jq .origin` | Trùng IP public của bạn (`curl ifconfig.me`) |
| Access log có user | `kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -c envoy --tail=20` | Dòng JSON có `user_sub`, `client_id`, `partner_id`, `response_flags` |
| Rate limit dùng Redis | `kubectl exec -n envoy-gateway-system deploy/redis -- redis-cli --scan \| head` | Có key do rate limit service tạo |
| HPA của Envoy | `kubectl get hpa -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway` | min 2, max 6 |
| Drain khi rollout | Trong lúc chạy `while true; do curl -s -o /dev/null -w '%{http_code}\n' -H "x-api-key: $PARTNER_GOLD_KEY" https://partner.gitlabonlinecom.click/v1/x; sleep 0.2; done`, chạy `kubectl rollout restart deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway` | Không có `5xx` (có thể có `429` vì rate limit gold 100/phút) |
| Đổi trọng số canary | `helm upgrade demo-portal ... --set canary.v2Weight=50` rồi refresh portal | Khoảng một nửa số lần là v2 |
| Thu hồi user | `admin-user-global-sign-out` user dev, chờ token hết hạn (30 phút) | Gọi API bằng token mới không được (không đăng nhập lại được nếu đã `admin-disable-user`) |

## 5. Đọc kết quả thất bại

| Test FAIL | Nguyên nhân hay gặp | Xem ở |
|---|---|---|
| Hầu hết test, lỗi kết nối | DNS chưa trỏ, NLB chưa active, Security Group chặn | [docs/04](04-platform.md) mục 5, [docs/09](09-operations-troubleshooting.md) |
| Hầu hết test, `curl: (60) SSL certificate problem` | NLB chưa dùng cert ACM (đang ở `nlb-tcp`, Envoy trả cert self-signed) | [docs/04](04-platform.md) mục 4: kiểm tra listener 443 của NLB là `TLS` với cert `569f4470-...` |
| Hầu hết test, `curl: (6) Could not resolve host` | Chưa chạy `scripts/05-dns.sh` hoặc DNS chưa lan truyền | Chạy `05-dns.sh`, hoặc tạm đặt `GATEWAY_IP` |
| POR-01 trả `500` | Envoy Gateway không đọc được OIDC discovery hoặc Secret `portal-oidc-client` sai key | `kubectl get securitypolicy portal-auth -n demo-portal -o yaml` (phần status) |
| ORD-0x trả `401` dù token đúng | Envoy không tải được JWKS (cụm không ra được Internet), issuer sai | Log Envoy: `Jwks remote fetch is failed` |
| ORD-26 / PAR-10 không có `429` | Rate limit service hoặc Redis lỗi | `kubectl logs -n envoy-gateway-system deploy/envoy-ratelimit` |
| PAR-03/04/05 trả `429` | Chạy test hai lần trong cùng một phút | Chờ 60 giây rồi chạy lại |
| ORD-18 có v2 = 0 | Ngẫu nhiên (xác suất < 1%) | Chạy lại nhóm `orders` sau 60 giây |
