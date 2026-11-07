# 06 – App 2: Orders API (JWT Cognito)

| | |
|---|---|
| URL | `https://api.<domain>/orders` |
| Namespace | `demo-orders` |
| Backend | go-httpbin 2.25.0 giả lập API, 2 phiên bản: `orders-api-v1` (2 Pod), `orders-api-v2` (1 Pod) |
| Chart | `helm/charts/demo-orders` |

go-httpbin **trả lại nguyên request nó nhận được** (method, URL, header, body), nên rất tiện để kiểm tra những gì gateway đã thêm, xoá hay viết lại.

## 1. Bản đồ endpoint

| Gateway | Backend | HTTPRoute | Mục đích demo |
|---|---|---|---|
| `/orders/*` | `/anything/orders/*` | `orders-api` | API chính: canary, header, rate limit |
| `/orders/unstable` | `/unstable` (lỗi 500 ngẫu nhiên khoảng 50%) | `orders-unstable` | **Retry** |
| `/orders/slow` | `/delay/5` (trả lời sau 5 giây) | `orders-slow` | **Timeout**, **circuit breaker** |
| `/orders/chaos/*` | `/anything/chaos/*` | `orders-chaos` | **Fault injection** |

Tách thành 4 HTTPRoute vì mỗi route chỉ nên gắn một `BackendTrafficPolicy`. Gateway API ưu tiên `Exact` rồi tới `PathPrefix` dài hơn, nên `/orders/slow` không bị route `/orders` "nuốt".

## 2. Xác thực và phân quyền (`SecurityPolicy orders-api-auth`, gắn cả 4 route)

| Bước | Cấu hình |
|---|---|
| CORS | Cho phép origin `https://portal.<domain>`, method GET/POST/PUT/PATCH/DELETE/OPTIONS, header `authorization`, `content-type`, `x-api-version`; expose `x-backend-version`, `x-ratelimit-*`; cache preflight 600s |
| JWT | `Authorization: Bearer <token>`, issuer Cognito, JWKS từ `<issuer>/.well-known/jwks.json`. **Không** kiểm tra `aud` vì access token Cognito không có claim này |
| Claim → header | `sub` → `x-jwt-sub`, `client_id` → `x-jwt-client-id` |

Bảng luật phân quyền (xét theo thứ tự, không khớp luật nào → 403):

| # | Luật | Method | Điều kiện | Kết quả |
|---|---|---|---|---|
| 1 | `reject-id-tokens` | mọi | `token_use = id` | **Deny**: API chỉ nhận access token |
| 2 | `read-by-group` | GET, HEAD | `cognito:groups` ∈ viewer, developer, devops-admin | Allow |
| 3 | `read-by-scope` | GET, HEAD | scope `orders-api/read` | Allow |
| 4 | `write-by-group` | POST, PUT, PATCH | `cognito:groups` ∈ developer, devops-admin | Allow |
| 5 | `write-by-scope` | POST, PUT, PATCH | scope `orders-api/write` | Allow |
| 6 | `delete-by-admin` | DELETE | `cognito:groups` ∈ devops-admin | Allow |

Kết quả cho từng loại người gọi:

| Người gọi | GET | POST | DELETE |
|---|---|---|---|
| viewer | ✅ | ❌ 403 | ❌ 403 |
| developer | ✅ | ✅ | ❌ 403 |
| devops-admin | ✅ | ✅ | ✅ |
| user không có group | ❌ 403 | ❌ 403 | ❌ 403 |
| máy `orders-m2m` (scope read + write) | ✅ | ✅ | ❌ 403 |
| ID token (bất kỳ ai) | ❌ 403 | ❌ 403 | ❌ 403 |
| Không có token / token sai | ❌ 401 | ❌ 401 | ❌ 401 |

## 3. Traffic (`BackendTrafficPolicy`, mỗi route một policy)

| Policy | Route | Cấu hình |
|---|---|---|
| `orders-api-traffic` | `orders-api` | **Rate limit 30 request/phút cho mỗi `x-jwt-sub`** (mỗi user / mỗi client máy một bộ đếm); least request; timeout 10s; retry 2 lần khi connect-failure/reset; loại Pod khi 5 lỗi 5xx liên tiếp |
| `orders-unstable-traffic` | `orders-unstable` | Retry 3 lần khi 500/502/503, mỗi lần tối đa 1s, backoff 50–500ms; tổng timeout 5s |
| `orders-slow-traffic` | `orders-slow` | Timeout 2s; circuit breaker: tối đa 3 kết nối, 1 request chờ, 3 request song song |
| `orders-chaos-traffic` | `orders-chaos` | 50% request trả 503, 20% chậm thêm 500ms |

Routing trong `orders-api`:

- Header `x-api-version: v2` → 100% `orders-api-v2`.
- Không có header → 90% v1 / 10% v2 (canary).
- URL rewrite `/orders` → `/anything/orders`.
- Thêm `X-Gateway: envoy-gateway`, xoá `X-Debug-Internal` (request); thêm `Cache-Control: no-store` (response).
- Mỗi backend gắn `X-Backend-Version: v1|v2` vào cả request lẫn response để kiểm tra canary.

## 4. Triển khai

```bash
kubectl create namespace demo-orders
```

```bash
kubectl label namespace demo-orders gateway.demo.io/attach=true
```

```bash
helm upgrade --install demo-orders helm/charts/demo-orders -n demo-orders -f helm/values/generated/demo-orders.yaml --wait
```

```bash
kubectl get httproute,securitypolicy,backendtrafficpolicy -n demo-orders
```

## 5. Thử nhanh

```bash
TOKEN=$(./scripts/get-token.sh user dev)
```

```bash
curl -s -H "Authorization: Bearer $TOKEN" "https://api.${DOMAIN}/orders/42" | jq '{method, url, gw: .headers["X-Gateway"], sub: .headers["X-Jwt-Sub"], ver: .headers["X-Backend-Version"]}'
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X DELETE -H "Authorization: Bearer $TOKEN" "https://api.${DOMAIN}/orders/42"
```

Kết quả mong đợi: `403` (developer không được xoá).

Token của máy:

```bash
M2M=$(./scripts/get-token.sh m2m)
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $M2M" "https://api.${DOMAIN}/orders"
```

Kết quả mong đợi: `200`.

Xem header rate limit:

```bash
curl -s -D - -o /dev/null -H "Authorization: Bearer $M2M" "https://api.${DOMAIN}/orders" | grep -i ratelimit
```
