# 05 – App 1: Portal (đăng nhập OIDC với Cognito)

| | |
|---|---|
| URL | `https://portal.<domain>` |
| Namespace | `demo-portal` |
| Backend | podinfo 6.15.0, 2 phiên bản: `portal-v1` (2 Pod, màu xanh) và `portal-v2` (1 Pod, màu cam) |
| Chart | `helm/charts/demo-portal` |

App **không có code đăng nhập**. Toàn bộ việc login, kiểm tra token và phân quyền do Envoy Gateway làm.

## 1. Tính năng được cấu hình

| Tính năng | Resource | Cấu hình |
|---|---|---|
| Đăng nhập OIDC (Authorization Code) với Cognito Hosted UI | `SecurityPolicy.oidc` | client `portal-web`, scope `openid email profile`, callback `/oauth2/callback`, logout `/logout`, tự refresh token |
| Không redirect với request AJAX | `oidc.denyRedirect` | Header `X-Requested-With: XMLHttpRequest` → 401 thay vì 302 |
| Verify ID token trong cookie | `SecurityPolicy.jwt` | Đọc cookie `PortalIdToken`, kiểm tra chữ ký JWKS, `iss`, `aud` = client `portal-web` |
| Chuyển thông tin user cho app | `jwt.claimToHeaders` | `email` → `x-user-email`, `sub` → `x-jwt-sub` |
| Phân quyền theo group | `SecurityPolicy.authorization` | `/env`, `/configs`: chỉ `devops-admin`; còn lại: `devops-admin`, `developer`, `viewer`; user không có group: 403 |
| Canary | `HTTPRoute` | 80% v1 / 20% v2; header `x-canary: always` → 100% v2 |
| Security headers | `HTTPRoute` `ResponseHeaderModifier` | HSTS, `X-Frame-Options: DENY`, `X-Content-Type-Options`, `Referrer-Policy` |
| Rate limit theo IP | `BackendTrafficPolicy.rateLimit` | Global, 300 request/phút cho mỗi IP |
| Resilience | `BackendTrafficPolicy` | timeout 15s, retry 2 lần (connect-failure/reset), least request, loại Pod lỗi 5xx liên tiếp |

## 2. Cách luật phân quyền được xét

Luật xét **theo thứ tự**, luật đầu tiên khớp được áp dụng, không khớp luật nào thì áp `defaultAction: Deny`:

| # | Luật | Path | Điều kiện | Kết quả |
|---|---|---|---|---|
| 1 | `admin-only-0` | `/env*` | `cognito:groups` chứa `devops-admin` | Allow |
| 2 | `deny-admin-path-0` | `/env*` | mọi IP | Deny |
| 3 | `admin-only-1` | `/configs*` | `devops-admin` | Allow |
| 4 | `deny-admin-path-1` | `/configs*` | mọi IP | Deny |
| 5 | `allow-portal-groups` | mọi path | thuộc 1 trong 3 group | Allow |
| – | `defaultAction` | | | Deny (403) |

## 3. Triển khai

Tạo namespace có label cho phép gắn route vào Gateway:

```bash
kubectl create namespace demo-portal
```

```bash
kubectl label namespace demo-portal gateway.demo.io/attach=true
```

Tạo Secret chứa client secret của Cognito (key bắt buộc là `client-secret`):

```bash
source config/demo.env && source config/cognito.env
```

```bash
kubectl create secret generic portal-oidc-client -n demo-portal --from-literal=client-secret="$PORTAL_CLIENT_SECRET"
```

Cài chart:

```bash
helm upgrade --install demo-portal helm/charts/demo-portal -n demo-portal -f helm/values/generated/demo-portal.yaml --wait
```

## 4. Kiểm tra trạng thái

```bash
kubectl get httproute,securitypolicy,backendtrafficpolicy -n demo-portal
```

```bash
kubectl get securitypolicy portal-auth -n demo-portal -o jsonpath='{.status.ancestors[0].conditions[0].reason}{" "}{.status.ancestors[0].conditions[0].message}{"\n"}'
```

Kết quả mong đợi: `Accepted Policy has been accepted.`

## 5. Thử nhanh

```bash
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "https://portal.${DOMAIN}/"
```

Kết quả mong đợi: `302 https://<prefix>.auth.<region>.amazoncognito.com/oauth2/authorize?...`

Sau đó mở `https://portal.<domain>` trong trình duyệt và làm theo các test POR-06 đến POR-12 trong [docs/08](08-testing.md).

## 6. Tuỳ chỉnh (`values.yaml`)

| Giá trị | Ý nghĩa |
|---|---|
| `canary.v2Weight` | % traffic vào v2 (0 = tắt canary, 100 = chuyển hẳn) |
| `authz.allowedGroups`, `adminGroups`, `adminPaths` | Phân quyền |
| `rateLimit.requestsPerMinutePerIP` | Rate limit theo IP |
| `cognito.authorizationEndpoint`, `tokenEndpoint` | Để trống thì Envoy Gateway tự đọc từ OIDC discovery |

**Chuyển hẳn sang v2** (promote canary):

```bash
helm upgrade demo-portal helm/charts/demo-portal -n demo-portal -f helm/values/generated/demo-portal.yaml --set canary.v2Weight=100
```

## 7. Logout

`https://portal.<domain>/logout` xoá cookie phiên tại Envoy. Session tại Cognito Hosted UI vẫn còn, nên lần sau mở portal sẽ được đăng nhập lại ngay (SSO). Muốn đăng xuất hẳn khỏi Cognito, mở:

```
https://<prefix>.auth.<region>.amazoncognito.com/logout?client_id=<PORTAL_CLIENT_ID>&logout_uri=https://portal.<domain>/
```

`logout_uri` này đã được khai báo trong app client `portal-web`.
