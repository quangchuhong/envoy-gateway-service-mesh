# Chart `demo-orders` – App 2: Orders REST API (JWT AWS Cognito)

Tài liệu này giải thích **từng khối trong `values.yaml`**: giá trị đó được template nào dùng, sinh ra resource gì, và Envoy Gateway xử lý ra sao.

| | |
|---|---|
| URL | `https://api.gitlabonlinecom.click/orders` |
| Namespace | `demo-orders` |
| Ứng dụng | [go-httpbin](https://github.com/mccutchen/go-httpbin) 2.25.0 đóng vai API, 2 phiên bản `v1` và `v2` |
| Xác thực | `Authorization: Bearer <access token>` do **AWS Cognito** cấp, cho cả **người dùng** và **máy** (Client Credentials) |
| Phân quyền | Theo `cognito:groups` (người dùng) **hoặc** `scope` (máy) |

go-httpbin **trả lại nguyên request nó nhận được** (method, URL, header, body). Nhờ vậy dễ thấy gateway đã viết lại URL, thêm/xoá header gì trước khi request tới backend.

---

## 1. Cấu trúc chart

```
demo-orders/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── _helpers.tpl                     # label, hostname, parentRef
    ├── workload.yaml                    # Deployment + Service cho v1, v2
    ├── httproutes.yaml                  # 4 HTTPRoute (orders-api, -unstable, -slow, -chaos)
    ├── securitypolicy.yaml              # CORS + JWT + phân quyền (gắn cả 4 route)
    ├── backendtrafficpolicies.yaml      # 4 BackendTrafficPolicy, mỗi route 1 policy
    └── backend-tls.yaml                 # CA nội bộ + cert backend + BackendTLSPolicy (TLS Envoy -> Pod)
```

Resource được tạo:

| Template | Kind | Tên |
|---|---|---|
| `workload.yaml` | `Deployment`, `Service` | `orders-api-v1`, `orders-api-v2` |
| `httproutes.yaml` | `HTTPRoute` | `orders-api`, `orders-unstable`, `orders-slow`, `orders-chaos` |
| `securitypolicy.yaml` | `SecurityPolicy` | `orders-api-auth` |
| `backendtrafficpolicies.yaml` | `BackendTrafficPolicy` | `orders-api-traffic`, `orders-unstable-traffic`, `orders-slow-traffic`, `orders-chaos-traffic` |
| `backend-tls.yaml` | `Secret`, `ConfigMap`, `BackendTLSPolicy` | `orders-api-backend-tls`, `orders-api-backend-ca`, `orders-api-backend-tls` |

### Vì sao tách thành 4 HTTPRoute?

`BackendTrafficPolicy` gắn vào **cả một HTTPRoute**, và mỗi route chỉ nên có **một** policy cùng loại. Các endpoint cần hành vi khác nhau (retry, timeout, fault injection), nên mỗi nhóm endpoint là một route riêng với policy riêng.

| Gateway nhận | Backend nhận | HTTPRoute | BackendTrafficPolicy | Mục đích |
|---|---|---|---|---|
| `/orders/*` | `/anything/orders/*` | `orders-api` | `orders-api-traffic` | API chính: canary, rate limit theo user |
| `/orders/unstable` | `/unstable` | `orders-unstable` | `orders-unstable-traffic` | **Retry** (backend lỗi 500 ngẫu nhiên khoảng 50%) |
| `/orders/slow` | `/delay/5` | `orders-slow` | `orders-slow-traffic` | **Timeout**, **circuit breaker** (backend chậm 5s) |
| `/orders/chaos/*` | `/anything/chaos/*` | `orders-chaos` | `orders-chaos-traffic` | **Fault injection** |

Bốn route cùng hostname `api.gitlabonlinecom.click` nhưng không đè nhau, vì Gateway API chọn route theo thứ tự ưu tiên: path `Exact` > `PathPrefix` dài hơn > `PathPrefix` ngắn hơn. `/orders/slow` (Exact) và `/orders/chaos` (prefix dài) luôn thắng `/orders`.

## 2. Luồng request

```
Client ── Authorization: Bearer <access token> ──► Envoy Gateway
   │
   ├─ SecurityPolicy "orders-api-auth"
   │    ① cors : OPTIONS preflight từ https://portal.gitlabonlinecom.click → trả lời ngay, chưa cần token
   │    ② jwt  : verify token (JWKS Cognito, issuer) → gắn x-jwt-sub, x-jwt-client-id
   │    ③ rbac : chặn ID token; xét group / scope theo method → Allow / 403
   │
   ├─ BackendTrafficPolicy của route tương ứng
   │    ④ rate limit theo x-jwt-sub (route orders-api) / retry / timeout / circuit breaker / fault
   │
   └─ ⑤ HTTPRoute: URL rewrite, thêm/xoá header, chọn v1/v2 (header hoặc trọng số)
```

---

## 3. Giải thích từng khối trong `values.yaml`

### 3.1 Domain, hostname, Gateway

```yaml
domain: gitlabonlinecom.click
hostPrefix: api

gateway:
  name: eg-gateway
  namespace: eg-gateway
  sectionName: https
```

Giống chart `demo-portal`: `_helpers.tpl` ghép thành `api.gitlabonlinecom.click`, đặt vào `hostnames` của **cả 4** HTTPRoute, và `parentRefs` trỏ vào listener `https` của Gateway `eg-gateway`. Namespace `demo-orders` phải có label `gateway.demo.io/attach=true`.

### 3.2 Image và phiên bản

```yaml
image:
  repository: docker.io/mccutchen/go-httpbin
  tag: 2.25.0
  pullPolicy: IfNotPresent

versions:
  v1:
    replicas: 2
  v2:
    replicas: 1
```

`workload.yaml` lặp qua `versions` để tạo `Deployment` + `Service` tên `orders-api-<phiên bản>`, port 8080. Probe dùng `GET /status/200` của go-httpbin. Container chạy với user `65532` (non-root), root filesystem chỉ đọc.

Khác với portal, hai phiên bản dùng **cùng image**. Để phân biệt request đã vào bản nào, chart gắn header ở tầng gateway (mục 3.3).

### 3.3 Canary và routing theo header

```yaml
canary:
  v2Weight: 10
  header:
    name: x-api-version
    value: v2
```

Đầu `httproutes.yaml` khai báo một khối dùng chung `orders.backend`, nhận tham số qua `dict`:

```yaml
{{- define "orders.backend" -}}
- name: orders-api-{{ .ver }}
  port: 8080
  {{- if hasKey . "weight" }}
  weight: {{ .weight }}
  {{- end }}
  filters:
    - type: RequestHeaderModifier          # backend nhận header này → go-httpbin in ra trong body
      requestHeaderModifier:
        set:
          - name: X-Backend-Version
            value: {{ .ver }}
    - type: ResponseHeaderModifier         # client nhận header này trong response
      responseHeaderModifier:
        set:
          - name: X-Backend-Version
            value: {{ .ver }}
{{- end }}
```

Route `orders-api` gọi khối trên như sau:

```yaml
rules:
  - name: version-by-header                 # có header x-api-version: v2 → 100% v2
    matches:
      - path: { type: PathPrefix, value: /orders }
        headers:
          - name: {{ .Values.canary.header.name }}
            value: {{ .Values.canary.header.value | quote }}
    backendRefs:
      {{- include "orders.backend" (dict "ver" "v2") | nindent 8 }}

  - name: canary-by-weight                  # còn lại: 90% v1 / 10% v2
    matches:
      - path: { type: PathPrefix, value: /orders }
    backendRefs:
      {{- include "orders.backend" (dict "ver" "v1" "weight" (sub 100 $w2)) | nindent 8 }}
      {{- include "orders.backend" (dict "ver" "v2" "weight" $w2) | nindent 8 }}
```

| Khoá | Ý nghĩa |
|---|---|
| `canary.v2Weight` | % traffic vào v2 khi client **không** gửi header chọn phiên bản |
| `canary.header` | Client chủ động chọn phiên bản API bằng header `x-api-version: v2` |

Filter đặt **trong `backendRefs`** chỉ áp cho request đi tới backend đó. Đây là cách biết request rơi vào v1 hay v2: xem header `X-Backend-Version` trong response.

### 3.4 Filter dùng chung cho route chính: URL rewrite và header

Khối `orders.commonFilters` được dùng ở cả hai rule của `orders-api`:

```yaml
- type: URLRewrite
  urlRewrite:
    path:
      type: ReplacePrefixMatch
      replacePrefixMatch: /anything/orders    # /orders/123 → /anything/orders/123
- type: RequestHeaderModifier
  requestHeaderModifier:
    set:
      - name: X-Gateway
        value: envoy-gateway                  # backend biết request đã qua gateway
    remove:
      - X-Debug-Internal                      # header client không được phép gửi vào backend
- type: ResponseHeaderModifier
  responseHeaderModifier:
    set:
      - name: Cache-Control
        value: no-store                       # không cho cache dữ liệu API
```

| Filter | Ví dụ |
|---|---|
| `ReplacePrefixMatch` | Thay **phần khớp** (`/orders`) bằng giá trị mới, giữ nguyên phần còn lại của path |
| `ReplaceFullPath` (dùng ở route `-unstable`, `-slow`) | Thay **toàn bộ** path: `/orders/slow` → `/delay/5` |
| `RequestHeaderModifier.set` | Thêm hoặc ghi đè header gửi vào backend |
| `RequestHeaderModifier.remove` | Xoá header trước khi gửi vào backend |
| `ResponseHeaderModifier.set` | Thêm hoặc ghi đè header trả về client |

Các khối này không có giá trị trong `values.yaml` vì là quy ước cố định của API. Muốn đổi, sửa trực tiếp `templates/httproutes.yaml`.

### 3.5 AWS Cognito (JWT)

```yaml
cognito:
  issuer: "https://cognito-idp.<REGION>.amazonaws.com/<USER_POOL_ID>"
  scopes:
    read: orders-api/read
    write: orders-api/write
```

Khối `jwt` trong `securitypolicy.yaml`:

```yaml
jwt:
  providers:
    - name: cognito
      issuer: {{ $c.issuer | quote }}
      remoteJWKS:
        uri: "{{ $c.issuer }}/.well-known/jwks.json"
      claimToHeaders:
        - claim: sub
          header: x-jwt-sub          # dùng cho rate limit theo user ở mục 3.8
        - claim: client_id
          header: x-jwt-client-id    # app client đã xin token (portal, cli, m2m...)
```

| Khoá | Ý nghĩa |
|---|---|
| `cognito.issuer` | User Pool phát hành token. Envoy chỉ chấp nhận token có `iss` đúng giá trị này và chữ ký đúng với JWKS |
| `cognito.scopes.read/write` | Scope của resource server `orders-api` (tạo ở bước Cognito). Dùng trong luật phân quyền cho client máy |

**Không có `audiences`** (khác với portal): **access token của Cognito không có claim `aud`**. Nếu đặt `audiences`, mọi access token sẽ bị từ chối với lỗi `401 Audiences in Jwt are not allowed`. Thay vào đó, chart dùng `token_use` và `scope` trong luật phân quyền để giới hạn loại token.

Token không có `Authorization` hoặc sai chữ ký/hết hạn → `401`. Token hợp lệ nhưng không đủ quyền → `403`.

### 3.6 Phân quyền theo group và scope

```yaml
authz:
  readGroups: ["viewer", "developer", "devops-admin"]
  writeGroups: ["developer", "devops-admin"]
  deleteGroups: ["devops-admin"]
```

Khối `authorization` (đã rút gọn):

```yaml
authorization:
  defaultAction: Deny
  rules:
    - name: reject-id-tokens            # 1. API chỉ nhận access token
      action: Deny
      principal:
        jwt:
          provider: cognito
          claims:
            - name: token_use
              values: ["id"]
    - name: read-by-group               # 2. GET/HEAD cho người dùng thuộc readGroups
      action: Allow
      operation: { methods: ["GET", "HEAD"] }
      principal:
        jwt:
          provider: cognito
          claims:
            - name: "cognito:groups"
              valueType: StringArray
              values: <readGroups>
    - name: read-by-scope               # 3. GET/HEAD cho máy có scope orders-api/read
      action: Allow
      operation: { methods: ["GET", "HEAD"] }
      principal:
        jwt:
          provider: cognito
          scopes: ["orders-api/read"]
    - name: write-by-group              # 4. POST/PUT/PATCH cho writeGroups
    - name: write-by-scope              # 5. POST/PUT/PATCH cho scope orders-api/write
    - name: delete-by-admin             # 6. DELETE chỉ deleteGroups
```

| Khái niệm | Giải thích |
|---|---|
| Thứ tự luật | Xét từ trên xuống, luật khớp đầu tiên quyết định. Không khớp luật nào → `defaultAction: Deny` (403) |
| `claims` | So sánh giá trị claim trong token. Nhiều claim trong cùng một luật phải khớp **tất cả** |
| `valueType: StringArray` | Claim là mảng (`cognito:groups`), khớp khi mảng chứa ít nhất một giá trị trong `values` |
| `scopes` | Envoy đọc claim `scope` (chuỗi các scope cách nhau bởi dấu cách). Luật khớp khi token có **đủ** các scope liệt kê |
| `operation.methods` | Giới hạn luật theo HTTP method |
| Hai luật cho cùng một quyền | Người dùng có `cognito:groups` nhưng không có scope tuỳ chỉnh; client máy (Client Credentials) có scope nhưng không có group. Mỗi loại cần luật riêng, cùng dẫn tới Allow |
| Luật `reject-id-tokens` đứng đầu | ID token cũng có `cognito:groups`. Nếu không chặn trước, ID token sẽ được Allow ở luật 2. ID token chỉ để biết danh tính, không nên dùng để gọi API |

Kết quả với giá trị mặc định:

| Người gọi | GET | POST | DELETE |
|---|---|---|---|
| `viewer` | ✅ | ❌ 403 | ❌ 403 |
| `developer` | ✅ | ✅ | ❌ 403 |
| `devops-admin` | ✅ | ✅ | ✅ |
| User không có group | ❌ 403 | ❌ 403 | ❌ 403 |
| Máy `orders-m2m` (scope read + write) | ✅ | ✅ | ❌ 403 |
| Bất kỳ ai dùng ID token | ❌ 403 | ❌ 403 | ❌ 403 |

Ví dụ cho phép máy được xoá: thêm vào `values.yaml` một scope `delete`, tạo scope đó trên resource server Cognito, rồi thêm luật `delete-by-scope` trong template theo mẫu `write-by-scope`.

### 3.7 CORS

```yaml
cors:
  extraAllowOrigins: []
```

Khối `cors` trong `securitypolicy.yaml`:

```yaml
cors:
  allowOrigins:
    - "https://portal.{{ .Values.domain }}"            # luôn cho phép portal
    {{- range .Values.cors.extraAllowOrigins }}
    - {{ . | quote }}                                  # thêm origin từ values
    {{- end }}
  allowMethods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
  allowHeaders: ["authorization", "content-type", "x-api-version"]
  exposeHeaders: ["x-backend-version", "x-ratelimit-limit", "x-ratelimit-remaining", "x-ratelimit-reset"]
  maxAge: 600s
```

| Trường | Ý nghĩa |
|---|---|
| `allowOrigins` | Trang web ở các origin này được phép gọi API bằng JavaScript trên trình duyệt. Origin khác bị trình duyệt chặn |
| `allowHeaders` | Header JavaScript được phép gửi. Phải có `authorization` để gửi token |
| `exposeHeaders` | Header JavaScript được phép **đọc** từ response (mặc định trình duyệt ẩn header tuỳ chỉnh) |
| `maxAge` | Trình duyệt cache kết quả preflight 10 phút |

Preflight (`OPTIONS`) được Envoy trả lời ở bước CORS, **trước** bước JWT, nên không cần token. Ví dụ thêm origin:

```bash
--set 'cors.extraAllowOrigins={https://admin.gitlabonlinecom.click}'
```

### 3.8 Rate limit theo user

```yaml
rateLimit:
  requestsPerMinutePerSubject: 30
```

Trong `orders-api-traffic`:

```yaml
rateLimit:
  type: Global
  global:
    rules:
      - clientSelectors:
          - headers:
              - name: x-jwt-sub          # header do bước JWT sinh từ claim "sub"
                type: Distinct           # mỗi giá trị một bộ đếm riêng
        limit:
          requests: {{ .Values.rateLimit.requestsPerMinutePerSubject }}
          unit: Minute
```

Cách hoạt động:

1. Bước JWT đọc claim `sub` của token và gắn vào header `x-jwt-sub`.
   - Token người dùng: `sub` = ID của user.
   - Token máy (Client Credentials): `sub` = client ID.
2. `type: Distinct` khiến **mỗi giá trị `sub`** có bộ đếm riêng. User A gọi nhiều không ảnh hưởng user B.
3. Bộ đếm `Global` lưu trong Redis, dùng chung cho mọi Pod Envoy.
4. Vượt 30 request/phút → `429`, kèm header `x-ratelimit-limit`, `x-ratelimit-remaining`, `x-ratelimit-reset`.

Hai điều kiện đảm bảo an toàn:

- Client **không giả mạo** được `x-jwt-sub` để "mượn" hạn mức của người khác: `ClientTrafficPolicy` của platform xoá header này khi request vào, sau đó Envoy tự set lại từ token đã verify.
- Request bị từ chối ở bước xác thực/phân quyền (401/403) **không** bị tính vào hạn mức, vì bước rate limit chạy sau.

Rate limit chỉ gắn vào route `orders-api`. Các route demo `-unstable`, `-slow`, `-chaos` không giới hạn, để test resilience không bị 429 làm nhiễu.

### 3.9 Resilience

```yaml
resilience:
  main:
    requestTimeout: 10s
  unstable:
    numRetries: 3
    perRetryTimeout: 1s
    requestTimeout: 5s
  slow:
    requestTimeout: 2s
    circuitBreaker:
      maxConnections: 3
      maxPendingRequests: 1
      maxParallelRequests: 3
```

#### `resilience.main` → `orders-api-traffic`

```yaml
loadBalancer:
  type: LeastRequest
timeout:
  http:
    requestTimeout: 10s
retry:
  numRetries: 2
  retryOn:
    triggers: [connect-failure, reset, refused-stream]
healthCheck:
  passive:
    consecutive5XxErrors: 5
    interval: 10s
    baseEjectionTime: 30s
    maxEjectionPercent: 50
```

Route chính chỉ retry khi **lỗi kết nối**, không retry lỗi 5xx. Lý do: `POST` tạo đơn hàng không idempotent, retry có thể tạo đơn trùng.

#### `resilience.unstable` → `orders-unstable-traffic` (demo RETRY)

```yaml
timeout:
  http:
    requestTimeout: 5s              # tổng thời gian, gồm cả các lần thử lại
retry:
  numRetries: 3
  perRetry:
    timeout: 1s                     # mỗi lần thử tối đa 1s
    backOff:
      baseInterval: 50ms            # chờ tăng dần giữa các lần thử
      maxInterval: 500ms
  retryOn:
    httpStatusCodes: [500, 502, 503]
    triggers: [retriable-status-codes, connect-failure, reset]
```

Backend `/unstable` lỗi khoảng 50%. Với 3 lần thử lại, xác suất cả 4 lần đều lỗi là 0,5⁴ ≈ 6%. Nhờ vậy client thấy khoảng 94% thành công thay vì 50%. Trigger `retriable-status-codes` là bắt buộc để `httpStatusCodes` có tác dụng.

#### `resilience.slow` → `orders-slow-traffic` (demo TIMEOUT + CIRCUIT BREAKER)

```yaml
timeout:
  http:
    requestTimeout: 2s
circuitBreaker:
  maxConnections: 3
  maxPendingRequests: 1
  maxParallelRequests: 3
```

| Thiết lập | Hành vi |
|---|---|
| `requestTimeout: 2s` | Backend `/delay/5` mất 5s, Envoy cắt sau 2s và trả `504` |
| `maxConnections: 3` | Tối đa 3 kết nối đồng thời tới backend |
| `maxPendingRequests: 1` | Chỉ cho 1 request xếp hàng chờ kết nối |
| `maxParallelRequests: 3` | Tối đa 3 request đang xử lý cùng lúc |
| Vượt ngưỡng | Trả `503` **ngay lập tức** (response flag `UO`), không dồn thêm tải vào backend đang chậm |

Circuit breaker đặt ngưỡng rất thấp để dễ thấy trong demo. Với hệ thống thật, đặt theo năng lực backend, thường vài trăm đến vài nghìn.

### 3.10 Fault injection

```yaml
chaos:
  abortPercent: 50
  abortStatus: 503
  delayPercent: 20
  delay: 500ms
```

Trong `orders-chaos-traffic`:

```yaml
faultInjection:
  abort:
    httpStatus: 503
    percentage: 50          # 50% request bị gateway trả 503, không tới backend
  delay:
    fixedDelay: 500ms
    percentage: 20          # 20% request bị gateway giữ lại thêm 500ms
```

Dùng để thử khả năng chịu lỗi của **client** (frontend có hiển thị lỗi hợp lý không, retry phía client có hoạt động không) mà không cần làm hỏng backend thật.

> Bước fault injection chạy **trước** bước xác thực trong Envoy, nên route `/orders/chaos` có thể trả 503 ngay cả với request chưa có token. Chỉ bật fault injection trên route dành riêng cho thử nghiệm.

### 3.11 TLS từ Envoy tới backend (BackendTLSPolicy)

```yaml
backendTLS:
  enabled: true
  hostname: orders-api.demo-orders.svc
  secretName: orders-api-backend-tls
  caConfigMapName: orders-api-backend-ca
  validityDays: 365
```

Mặc định Envoy gọi Pod bằng HTTP thường. Bật `backendTLS` thì **đoạn Envoy → Pod cũng được mã hoá**, và Envoy **kiểm tra cert của backend** trước khi gửi request:

```
User ─TLS (ACM)─► NLB ─TLS─► Envoy ─TLS (CA nội bộ, kiểm tra cert)─► Pod orders-api
```

Cụm chưa có cert-manager, nên chart tự sinh cert bằng hàm `genCA` / `genSignedCert` của Helm (`templates/backend-tls.yaml`):

| Resource | Nội dung | Ai dùng |
|---|---|---|
| CA nội bộ `demo-orders-backend-ca` | Sinh một lần, chỉ dùng để ký cert backend | – |
| `Secret orders-api-backend-tls` (`kubernetes.io/tls`) | Cert + private key của backend, `CN`/SAN = `orders-api.demo-orders.svc` | Mount vào Pod go-httpbin tại `/etc/tls` |
| `ConfigMap orders-api-backend-ca` | Chỉ `ca.crt` (public, không có key) | Envoy dùng để kiểm tra cert backend |

Template dùng `lookup` để **giữ nguyên CA và cert** qua các lần `helm upgrade`: chỉ sinh bộ mới khi Secret hoặc ConfigMap chưa tồn tại.

**Thay đổi ở Pod và Service** (`templates/workload.yaml`) khi `enabled: true`:

```yaml
args:
  - -https-cert-file=/etc/tls/tls.crt      # go-httpbin phục vụ HTTPS trên cổng 8080
  - -https-key-file=/etc/tls/tls.key
readinessProbe:
  httpGet: { path: /status/200, port: https, scheme: HTTPS }
# Service: port đổi tên từ "http" thành "https" (BackendTLSPolicy tham chiếu qua sectionName)
```

**BackendTLSPolicy** (Gateway API chuẩn, `gateway.networking.k8s.io/v1`):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: orders-api-backend-tls
spec:
  targetRefs:                         # gắn vào Service backend, KHÔNG gắn vào HTTPRoute
    - group: ""
      kind: Service
      name: orders-api-v1
      sectionName: https
    - group: ""
      kind: Service
      name: orders-api-v2
      sectionName: https
  validation:
    caCertificateRefs:                # CA để kiểm tra cert backend
      - group: ""
        kind: ConfigMap
        name: orders-api-backend-ca
    hostname: orders-api.demo-orders.svc   # SNI gửi đi + tên bắt buộc có trong cert backend
```

| Trường | Ý nghĩa |
|---|---|
| `targetRefs` | Áp cho mọi route trỏ tới 2 Service này (cả 4 HTTPRoute của Orders API) |
| `sectionName: https` | Chỉ áp cho port tên `https` của Service |
| `caCertificateRefs` | Envoy chỉ tin cert do CA này ký. Cert tự ký khác hoặc do CA khác ký đều bị từ chối |
| `hostname` | Envoy gửi SNI này và đòi cert backend phải có đúng tên này. Không cần trùng tên DNS của Service |

Đã kiểm chứng trên cấu hình Envoy sinh ra (`egctl x translate`): cả 6 cluster backend của Orders API có transport socket TLS, `sni: orders-api.demo-orders.svc` và kiểm tra SAN `exact: orders-api.demo-orders.svc`.

**Cách thấy TLS hoạt động:** go-httpbin dựng trường `url` theo loại kết nối nó nhận. Khi Envoy → Pod là TLS, `url` bắt đầu bằng `https://` (test **ORD-28**):

```bash
curl -s -H "Authorization: Bearer $(./scripts/get-token.sh user dev)" "https://api.gitlabonlinecom.click/orders/1" | jq -r .url
```

Kết quả mong đợi: `https://api.gitlabonlinecom.click/anything/orders/1`.

| Thao tác | Cách làm |
|---|---|
| Tắt (quay về HTTP) | `--set backendTLS.enabled=false` |
| Xoay vòng (rotate) CA và cert | `kubectl delete -n demo-orders secret/orders-api-backend-tls configmap/orders-api-backend-ca`, chạy lại `helm upgrade`, rồi `kubectl rollout restart deploy -n demo-orders` để Pod nạp cert mới |
| Production | Dùng cert-manager (CA Issuer hoặc AWS Private CA) cấp và tự gia hạn cert; chart chỉ cần trỏ `secretName`/`caConfigMapName` tới resource do cert-manager tạo |

> Lần đầu bật trên cụm đang chạy HTTP, trong vài giây rollout có thể có lỗi `503`: Envoy đã chuyển sang TLS nhưng một số Pod cũ vẫn chạy HTTP. Sau khi rollout xong thì hết.

### 3.12 Tài nguyên Pod

```yaml
resources:
  requests: { cpu: 20m, memory: 32Mi }
  limits: { memory: 128Mi }
```

Áp cho container go-httpbin ở mọi phiên bản.

---

## 4. Ghi đè values

File sinh tự động `helm/values/generated/demo-orders.yaml`:

```yaml
domain: gitlabonlinecom.click
cognito:
  issuer: "https://cognito-idp.ap-southeast-1.amazonaws.com/ap-southeast-1_AbCdEf123"
```

Ví dụ: tăng hạn mức lên 100 request/phút và chuyển 50% traffic sang v2:

```bash
helm upgrade demo-orders helm/charts/demo-orders -n demo-orders -f helm/values/generated/demo-orders.yaml --set rateLimit.requestsPerMinutePerSubject=100 --set canary.v2Weight=50
```

Xem trước YAML:

```bash
helm template demo-orders helm/charts/demo-orders -n demo-orders -f helm/values/generated/demo-orders.yaml
```

## 5. Kiểm tra sau khi cài

```bash
kubectl get deploy,svc,httproute,securitypolicy,backendtrafficpolicy -n demo-orders
```

```bash
kubectl get backendtrafficpolicy -n demo-orders -o custom-columns='NAME:.metadata.name,STATUS:.status.ancestors[0].conditions[0].reason'
```

Thử bằng token thật:

```bash
TOKEN=$(./scripts/get-token.sh user dev)
```

```bash
curl -s -H "Authorization: Bearer $TOKEN" "https://api.${DOMAIN}/orders/42" | jq '{url, gw: .headers["X-Gateway"], sub: .headers["X-Jwt-Sub"], ver: .headers["X-Backend-Version"]}'
```

Chạy nhóm test: `tests/run-tests.sh orders` (28 test, ORD-01 đến ORD-28, xem `docs/08-testing.md`).

## 6. Lỗi thường gặp khi sửa values

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| Mọi request `401 Audiences in Jwt are not allowed` | Đã thêm `audiences` vào provider | Bỏ `audiences`; access token Cognito không có `aud` |
| `401 Jwt issuer is not configured` | `cognito.issuer` sai region/pool ID hoặc thừa `/` cuối | So với `iss` trong token (`scripts/get-token.sh decode`) |
| Token máy luôn `403` | Scope trong `cognito.scopes` khác scope thật trên Cognito | Scope có dạng `<resource server>/<tên>`, ví dụ `orders-api/read` |
| Người dùng mới thêm vào group vẫn `403` | Token cũ chưa có group mới | Lấy token mới (token sống 30 phút) |
| Không bao giờ thấy `429` | Rate limit service hoặc Redis lỗi | `kubectl logs -n envoy-gateway-system deploy/envoy-ratelimit` |
| `/orders/slow` trả `404` | Sửa path trong route nhưng `ReplaceFullPath` trỏ tới path không tồn tại ở backend | Kiểm tra `replaceFullPath` khớp endpoint của backend |
| Hai route đè nhau | Thêm route cùng path type và độ dài | Dùng `Exact` hoặc prefix dài hơn cho endpoint đặc biệt |
