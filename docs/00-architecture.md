# 00 – Kiến trúc

## 1. Tổng quan giai đoạn này

F5 chưa được đặt vào. **AWS NLB** đứng ở vị trí của F5: nhận HTTPS từ Internet, terminate TLS bằng cert public trong ACM, rồi **re-encrypt** tới Envoy. Cách đi traffic này giống với mô hình F5 sau này, nên khi gắn F5 chỉ cần đổi vài giá trị (xem [docs/10](10-next-steps-f5-istio.md)).

Môi trường triển khai:

| Mục | Giá trị |
|---|---|
| AWS account / region | `609320954321` / `ap-southeast-1` |
| Domain | `gitlabonlinecom.click`, DNS wildcard `*.gitlabonlinecom.click` (Route 53) trỏ về NLB |
| Cert public | Cert `*.gitlabonlinecom.click` đã mua và import vào ACM: `arn:aws:acm:ap-southeast-1:609320954321:certificate/569f4470-6ac3-4ef2-be6e-7eb012397305` |
| App 1 – Portal | `https://portal.gitlabonlinecom.click` |
| App 2 – Orders API | `https://api.gitlabonlinecom.click/orders` |
| App 3 – Partner API | `https://partner.gitlabonlinecom.click/v1` |
| Cognito Hosted UI | `https://gitlabonlinecom-eg-demo.auth.ap-southeast-1.amazoncognito.com` |

Ba app dùng **chung một NLB và một cert wildcard**. Envoy phân biệt app theo header `Host`.

```
 Route 53: *.gitlabonlinecom.click ──Alias──► NLB
```

```
                                   ┌──────────────── AWS Cognito ─────────────────┐
                                   │ User Pool  : user, group (cognito:groups)    │
                                   │ Hosted UI  : trang đăng nhập (OIDC)          │
                                   │ JWKS       : public key để verify JWT        │
                                   └──────▲────────────────▲───────────────▲──────┘
                                ① login   │   ③ đổi code   │ JWKS          │ token máy
                                (browser) │   lấy token    │ (cache)       │ (client_credentials)
 👤 User ── HTTPS ──► NLB (ACM cert) ──TLS──► Envoy Proxy (data plane, ns envoy-gateway-system)
                      L4, giữ IP client       │ listener :443 (container 10443)
                                              │ health_check → fault → CORS → API key
                                              │ → OAuth2(OIDC) → JWT → RBAC → rate limit → router
                                              │                                 │
                                              │                   Rate limit service + Redis
                                              ├──► portal-v1 / portal-v2      (ns demo-portal)
                                              ├──► orders-api-v1 / -v2         (ns demo-orders)
                                              └──► partner-api                 (ns demo-partner)

 Envoy Gateway (control plane, ns envoy-gateway-system)
   watch Gateway API + CRD → dịch sang cấu hình Envoy (xDS) → đẩy xuống Envoy Proxy
   tự tạo Deployment/Service(NLB)/HPA/PDB của Envoy theo EnvoyProxy
```

## 2. Namespace và trách nhiệm

| Namespace | Thành phần | Ai quản lý | Chart |
|---|---|---|---|
| `envoy-gateway-system` | Envoy Gateway control plane, rate limit service, Redis; **Pod Envoy Proxy và Service NLB** (do controller tự tạo) | Platform team | `gateway-helm` (chính thức), `eg-redis` |
| `eg-gateway` | `Gateway`, `EnvoyProxy`, `ClientTrafficPolicy`, TLS secret, route redirect HTTP→HTTPS | Platform team | `eg-platform` |
| `demo-portal` | App 1 + `HTTPRoute` + `SecurityPolicy` + `BackendTrafficPolicy` | Team app | `demo-portal` |
| `demo-orders` | App 2 + 4 `HTTPRoute` + policy | Team app | `demo-orders` |
| `demo-partner` | App 3 + `HTTPRoute` + policy + Secret API key | Team app | `demo-partner` |

> Envoy Gateway mặc định tạo Deployment/Service/HPA/PDB của Envoy trong **namespace của controller** (`envoy-gateway-system`), không phải namespace của Gateway. Tìm chúng bằng label `gateway.envoyproxy.io/owning-gateway-name=eg-gateway`:
> ```bash
> kubectl get deploy,pod,svc,hpa,pdb -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway
> ```

Đây là mô hình **phân vai của Gateway API**: platform team sở hữu Gateway (cửa vào, TLS, cấu hình Envoy), còn team app tự khai báo route và policy trong namespace của mình. Gateway chỉ nhận `HTTPRoute` từ namespace có label `gateway.demo.io/attach=true`, nên namespace lạ không gắn được route vào cửa chung.

## 3. Mô hình resource

```
GatewayClass eg-demo ──parametersRef──► EnvoyProxy eg-demo-proxy (Deployment/Service/HPA/PDB/log của Envoy)
   └── Gateway eg-gateway (ns eg-gateway)
         ├── listener http  :80   ◄── HTTPRoute http-to-https-redirect
         │                         (chỉ route cùng namespace)
         ├── listener https :443  ◄── HTTPRoute từ namespace có label gateway.demo.io/attach=true
         └── ClientTrafficPolicy  (IP client, /healthz, timeout, request-id, xoá header nội bộ, TLS min 1.2)

HTTPRoute portal (demo-portal)        ◄── SecurityPolicy portal-auth (OIDC + JWT cookie + RBAC)
                                      ◄── BackendTrafficPolicy portal-traffic (rate limit IP, retry, timeout)
HTTPRoute orders-api/-unstable/-slow/-chaos (demo-orders)
                                      ◄── SecurityPolicy orders-api-auth (CORS + JWT + RBAC) [4 route]
                                      ◄── BackendTrafficPolicy (mỗi route 1 policy riêng)
HTTPRoute partner-api (demo-partner)  ◄── SecurityPolicy partner-api-auth (API key + RBAC)
                                      ◄── BackendTrafficPolicy partner-api-traffic (rate limit theo gói)
```

| Resource | Tác dụng ở phía | Gắn vào |
|---|---|---|
| `ClientTrafficPolicy` | Client → Envoy (listener) | Gateway |
| `SecurityPolicy` | Xác thực, phân quyền, CORS | Gateway hoặc HTTPRoute |
| `BackendTrafficPolicy` | Envoy → backend (LB, retry, timeout, rate limit, circuit breaker, fault) | Gateway hoặc HTTPRoute |
| `EnvoyProxy` | Hạ tầng của chính Envoy (Pod, Service, log) | GatewayClass |

> Mỗi HTTPRoute chỉ nên có **một** policy cùng loại. Vì vậy App 2 tách thành 4 HTTPRoute để mỗi nhóm endpoint có `BackendTrafficPolicy` riêng (retry cho `/orders/unstable`, timeout cho `/orders/slow`...).

## 4. Thứ tự xử lý trong Envoy (đã kiểm chứng trên cấu hình sinh ra)

Thứ tự HTTP filter mà Envoy Gateway v1.9.3 sinh cho Gateway này:

```
health_check → fault → cors → api_key_auth → oauth2 (OIDC) → jwt_authn → rbac (authorization) → ratelimit → router
```

Hệ quả cần nắm:

| Hệ quả | Giải thích |
|---|---|
| CORS preflight không cần token | Filter CORS trả lời `OPTIONS` trước bước JWT |
| Phân quyền dùng được header do bước xác thực sinh ra | `api_key_auth` gắn `x-partner-id`, `jwt_authn` gắn `x-jwt-sub` **trước** `rbac` |
| Rate limit theo user / theo API key chính xác | `ratelimit` chạy **sau** xác thực nên đọc được `x-jwt-sub`, `x-partner-id` |
| Request bị từ chối (401/403) **không** bị tính vào rate limit | `rbac` đứng trước `ratelimit` |
| Fault injection xảy ra **trước** xác thực | Route `/orders/chaos` có thể trả 503 ngay cả khi chưa gửi token |
| Client không giả mạo được `x-jwt-sub`, `x-partner-id` | `ClientTrafficPolicy` xoá các header này ngay khi request vào (early header mutation), sau đó Envoy tự set lại từ JWT/API key |

## 5. Luồng chi tiết từng app

### App 1 – Portal (OIDC)

```
Browser ─GET https://portal/──► Envoy
  oauth2: chưa có cookie hợp lệ ──► 302 https://gitlabonlinecom-eg-demo.auth.ap-southeast-1.amazoncognito.com/oauth2/authorize
                                     ?client_id=<portal-web>&redirect_uri=https://portal/oauth2/callback&...
Browser ─► Cognito Hosted UI: nhập email + mật khẩu (+ TOTP nếu bật)
Cognito ─302─► https://portal/oauth2/callback?code=...&state=...
Envoy (oauth2) ─POST /oauth2/token (back-channel, client secret)─► Cognito ─► id_token, access_token, refresh_token
Envoy set cookie: PortalIdToken, PortalAccessToken, OauthHMAC, OauthExpires ... rồi 302 về trang ban đầu
Request tiếp theo (có cookie):
  jwt_authn: đọc ID token từ cookie PortalIdToken → verify chữ ký (JWKS), iss, aud = client portal-web
             → gắn x-user-email, x-jwt-sub
  rbac     : /env, /configs chỉ cho devops-admin; còn lại cần thuộc devops-admin|developer|viewer
  ratelimit: 300 request/phút/IP
  router   : 80% portal-v1, 20% portal-v2 (header x-canary: always → 100% v2)
```

### App 2 – Orders API (JWT)

```
Client ─Authorization: Bearer <access token Cognito>─► Envoy
  cors     : trả lời preflight cho origin https://portal.gitlabonlinecom.click
  jwt_authn: verify chữ ký + issuer (không kiểm tra aud vì access token Cognito không có aud)
             gắn x-jwt-sub (sub), x-jwt-client-id (client_id)
  rbac     : token_use=id → 403 | GET/HEAD: group viewer/developer/devops-admin hoặc scope orders-api/read
             POST/PUT/PATCH: group developer/devops-admin hoặc scope orders-api/write | DELETE: devops-admin
  ratelimit: 30 request/phút cho mỗi giá trị x-jwt-sub (mỗi user / mỗi client máy)
  router   : /orders → /anything/orders (URL rewrite), 90% v1 / 10% v2, header x-api-version: v2 → v2
             retry (connect-failure/reset), timeout 10s, outlier detection, least request
```

### App 3 – Partner API (API key)

```
Partner ─x-api-key: <key>─► Envoy
  api_key_auth: so với Secret partner-api-keys → gắn x-partner-id: partner-gold|partner-silver, xoá x-api-key
  rbac        : POST/PUT/PATCH/DELETE chỉ partner-gold; GET/HEAD mọi partner; cả hai phải từ IP trong allowlist
  ratelimit   : partner-gold 100/phút, partner-silver 5/phút
  router      : /v1/* → /anything/v1/*
```

## 6. Mức độ đã kiểm chứng

Toàn bộ chart trong repo đã được kiểm tra **offline**, không có cụm thật:

1. `helm lint` và `helm template` thành công cả 5 chart.
2. `kubeconform -strict` với schema lấy từ CRD của `gateway-helm` v1.9.3 (Gateway API + Envoy Gateway): toàn bộ resource render ra hợp lệ.
3. `egctl x translate` (bộ dịch thật của Envoy Gateway v1.9.3): `Gateway`, 7 `HTTPRoute`, 3 `SecurityPolicy`, 6 `BackendTrafficPolicy`, `ClientTrafficPolicy` đều **Accepted**. Cấu hình Envoy sinh ra có đủ các filter ở mục 4 (`oauth2`, `jwt_authn`, `api_key_auth`, `rbac`, `ratelimit`, `cors`, `fault`, `health_check`).

Những gì **chưa** kiểm chứng được offline (phụ thuộc AWS thật): tạo NLB, kết nối tới Cognito (discovery, JWKS, đổi token), hành vi runtime. Phần này được kiểm tra bằng bộ test ở [docs/08](08-testing.md) sau khi triển khai lên EKS.
