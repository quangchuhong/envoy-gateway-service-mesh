# Chart `demo-portal` – App 1: Web Portal (OIDC với AWS Cognito)

Tài liệu này giải thích **từng khối trong `values.yaml`**: giá trị đó được template nào dùng, sinh ra resource Kubernetes gì, và Envoy Gateway xử lý nó ra sao.

| | |
|---|---|
| URL | `https://portal.<domain>` |
| Namespace | `demo-portal` |
| Ứng dụng | [podinfo](https://github.com/stefanprodan/podinfo) 6.15.0, chạy 2 phiên bản `v1` và `v2` |
| Xác thực | Đăng nhập **OIDC** (Authorization Code) với **AWS Cognito**, thực hiện tại Envoy Gateway |
| Phân quyền | Theo claim `cognito:groups` trong ID token |

App **không có dòng code đăng nhập nào**. Envoy Gateway chặn request chưa đăng nhập, chuyển sang trang login của Cognito, nhận token, kiểm tra token, phân quyền, rồi mới chuyển request vào podinfo.

---

## 1. Cấu trúc chart

```
demo-portal/
├── Chart.yaml
├── values.yaml                         # Toàn bộ tham số (giải thích ở mục 3)
└── templates/
    ├── _helpers.tpl                    # Hàm dùng chung: label, hostname, parentRef
    ├── workload.yaml                   # Deployment + Service cho từng phiên bản (v1, v2)
    ├── httproute.yaml                  # Routing: canary theo header/trọng số, security headers
    ├── securitypolicy.yaml             # OIDC Cognito + JWT + phân quyền theo group
    └── backendtrafficpolicy.yaml       # Rate limit theo IP, timeout, retry, LB, health check
```

Resource được tạo ra khi cài chart:

| Template | Kind | Tên | Vai trò |
|---|---|---|---|
| `workload.yaml` | `Deployment` | `portal-v1`, `portal-v2` | Chạy podinfo, mỗi phiên bản một Deployment |
| `workload.yaml` | `Service` | `portal-v1`, `portal-v2` | Đích để HTTPRoute trỏ tới (port 9898) |
| `httproute.yaml` | `HTTPRoute` | `portal` | Gắn vào Gateway, định tuyến `portal.<domain>` |
| `securitypolicy.yaml` | `SecurityPolicy` | `portal-auth` | Đăng nhập, kiểm tra token, phân quyền |
| `backendtrafficpolicy.yaml` | `BackendTrafficPolicy` | `portal-traffic` | Hành vi Envoy khi gọi vào backend |

## 2. Luồng request

```
Trình duyệt ──► Envoy Gateway (Gateway eg-gateway, listener https)
   │
   ├─ HTTPRoute "portal" khớp hostname portal.<domain>
   │
   ├─ SecurityPolicy "portal-auth"
   │    ① oauth2 : chưa có cookie hợp lệ → 302 sang Cognito Hosted UI
   │               đã đăng nhập → đi tiếp
   │    ② jwt    : đọc ID token trong cookie PortalIdToken → verify → gắn x-user-email, x-jwt-sub
   │    ③ rbac   : xét cognito:groups theo bảng luật → Allow / 403
   │
   ├─ BackendTrafficPolicy "portal-traffic"
   │    ④ ratelimit: tối đa 300 request/phút/IP → vượt thì 429
   │    ⑤ timeout 15s, retry 2 lần khi lỗi kết nối, chọn Pod ít request nhất
   │
   └─ ⑥ HTTPRoute chọn backend: header x-canary: always → v2; còn lại 80% v1 / 20% v2
        và gắn security headers vào response
```

---

## 3. Giải thích từng khối trong `values.yaml`

### 3.1 Domain và hostname

```yaml
domain: gitlabonlinecom.click
hostPrefix: portal
```

Dùng trong `_helpers.tpl` để tạo hostname đầy đủ:

```yaml
{{- define "demo.host" -}}
{{ .Values.hostPrefix }}.{{ .Values.domain }}
{{- end -}}
```

Hostname `portal.gitlabonlinecom.click` này xuất hiện ở **2 chỗ**, và cả hai phải khớp với thực tế:

| Chỗ dùng | Kết quả render | Nếu sai |
|---|---|---|
| `HTTPRoute.spec.hostnames` | `- "portal.gitlabonlinecom.click"` | Request tới đúng domain nhưng Envoy trả `404` (không có route khớp) |
| `SecurityPolicy.oidc.redirectURL` | `https://portal.gitlabonlinecom.click/oauth2/callback` | Cognito báo `redirect_mismatch` |

> `redirectURL` phải **trùng từng ký tự** với *Callback URL* đã khai báo trong app client `portal-web` của Cognito (script `02-cognito-setup.sh` đã khai báo đúng giá trị này).

### 3.2 Gateway để gắn vào

```yaml
gateway:
  name: eg-gateway
  namespace: eg-gateway
  sectionName: https
```

Dùng trong `_helpers.tpl`:

```yaml
{{- define "demo.parentRef" -}}
- name: {{ .Values.gateway.name }}
  namespace: {{ .Values.gateway.namespace }}
  sectionName: {{ .Values.gateway.sectionName }}
{{- end -}}
```

Render ra `HTTPRoute.spec.parentRefs`:

```yaml
parentRefs:
  - name: eg-gateway
    namespace: eg-gateway
    sectionName: https     # chỉ gắn vào listener HTTPS, không gắn vào listener HTTP (port 80)
```

| Trường | Ý nghĩa |
|---|---|
| `name`, `namespace` | Gateway dùng chung do chart `eg-platform` tạo |
| `sectionName: https` | Tên listener trong Gateway. Gắn vào `https` nên route chỉ phục vụ HTTPS; HTTP đã được redirect ở platform |

Gateway chỉ nhận route từ namespace có label `gateway.demo.io/attach=true`. Nếu quên gắn label, `kubectl get httproute portal -n demo-portal -o yaml` sẽ báo `NotAllowedByListeners`.

### 3.3 Image và phiên bản ứng dụng

```yaml
image:
  repository: docker.io/stefanprodan/podinfo
  tag: 6.15.0
  pullPolicy: IfNotPresent

versions:
  v1:
    replicas: 2
    message: "Portal v1 (stable)"
    color: "#34577c"
  v2:
    replicas: 1
    message: "Portal v2 (canary)"
    color: "#e85d04"
```

`workload.yaml` **lặp qua từng phần tử** của `versions` để sinh một cặp Deployment + Service cho mỗi phiên bản:

```yaml
{{- range $ver, $cfg := .Values.versions }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portal-{{ $ver }}             # portal-v1, portal-v2
  ...
spec:
  replicas: {{ $cfg.replicas }}
  selector:
    matchLabels:
      app: portal
      version: {{ $ver }}             # Service của từng phiên bản chọn Pod theo label này
  template:
    spec:
      containers:
        - name: podinfo
          image: "{{ $.Values.image.repository }}:{{ $.Values.image.tag }}"
          command: ["./podinfo", "--port=9898", "--level=info"]
          env:
            - name: PODINFO_UI_MESSAGE
              value: {{ $cfg.message | quote }}
            - name: PODINFO_UI_COLOR
              value: {{ $cfg.color | quote }}
```

| Khoá | Ý nghĩa |
|---|---|
| `versions.<tên>` | Tên phiên bản, dùng làm hậu tố tên Deployment/Service và label `version` |
| `replicas` | Số Pod của phiên bản đó |
| `message`, `color` | Biến môi trường `PODINFO_UI_MESSAGE`, `PODINFO_UI_COLOR`: chữ và màu nền trên giao diện podinfo, giúp nhìn thấy ngay đang vào bản nào khi test canary |

> Bên trong vòng lặp `range`, dấu `.` trỏ vào phần tử đang lặp. Muốn đọc giá trị gốc thì phải dùng `$`, ví dụ `$.Values.image.tag`.

Các thiết lập cố định trong template (không nằm trong values):

| Thiết lập | Lý do |
|---|---|
| `readinessProbe /readyz`, `livenessProbe /healthz` | Pod chỉ nhận traffic khi sẵn sàng; Envoy Gateway chỉ đưa Pod Ready vào danh sách endpoint |
| `runAsNonRoot`, `readOnlyRootFilesystem`, `drop: ALL`, `seccompProfile: RuntimeDefault` | Chạy container theo chuẩn bảo mật *restricted* của Kubernetes |

### 3.4 Canary

```yaml
canary:
  v2Weight: 20
  header:
    name: x-canary
    value: always
```

Dùng trong `httproute.yaml`. Dòng đầu tiên chuyển giá trị sang số nguyên để tính toán:

```yaml
{{- $w2 := int .Values.canary.v2Weight -}}
```

Route có **2 rule**:

```yaml
rules:
  # Rule 1: có header x-canary: always → luôn vào v2
  - name: canary-by-header
    matches:
      - path: { type: PathPrefix, value: / }
        headers:
          - name: {{ .Values.canary.header.name }}
            value: {{ .Values.canary.header.value | quote }}
    backendRefs:
      - name: portal-v2
        port: 9898

  # Rule 2: còn lại → chia theo trọng số
  - name: canary-by-weight
    matches:
      - path: { type: PathPrefix, value: / }
    backendRefs:
      - name: portal-v1
        port: 9898
        weight: {{ sub 100 $w2 }}      # 100 - 20 = 80
      - name: portal-v2
        port: 9898
        weight: {{ $w2 }}              # 20
```

| Khoá | Ý nghĩa |
|---|---|
| `canary.v2Weight` | Phần trăm traffic vào v2. Chart tự tính v1 = `100 - v2Weight` |
| `canary.header.name/value` | Header cho tester nội bộ ép vào v2 mà không phụ thuộc may rủi |

**Vì sao rule 1 luôn được xét trước rule 2?** Theo Gateway API, khi hai rule có cùng path, rule có **nhiều điều kiện header hơn** được ưu tiên. Rule 1 có thêm điều kiện header nên thắng, không phụ thuộc vào thứ tự viết.

Các kịch bản thường dùng:

| Mục đích | Lệnh |
|---|---|
| Tắt canary (100% v1) | `--set canary.v2Weight=0` |
| Tăng dần | `--set canary.v2Weight=50` |
| Chuyển hẳn sang v2 | `--set canary.v2Weight=100` |

> Trọng số chia theo **từng request**. Cùng một người dùng có thể lúc vào v1, lúc vào v2. Nếu ứng dụng cần "dính" phiên bản theo user, cần thêm session persistence (không cấu hình trong demo).

#### Security headers

Cả hai rule cùng gọi một khối định nghĩa sẵn ở cuối file:

```yaml
{{- define "portal.securityHeaders" -}}
- type: ResponseHeaderModifier
  responseHeaderModifier:
    set:
      - name: Strict-Transport-Security      # Trình duyệt chỉ dùng HTTPS cho domain này trong 1 năm
        value: "max-age=31536000; includeSubDomains"
      - name: X-Frame-Options                # Không cho nhúng portal vào iframe (chống clickjacking)
        value: DENY
      - name: X-Content-Type-Options         # Không đoán kiểu nội dung (chống MIME sniffing)
        value: nosniff
      - name: Referrer-Policy                # Hạn chế lộ URL khi chuyển sang trang khác
        value: strict-origin-when-cross-origin
{{- end }}
```

`set` **ghi đè** nếu backend đã trả header cùng tên, nên chính sách bảo mật luôn do gateway quyết định.

### 3.5 AWS Cognito (OIDC)

```yaml
cognito:
  issuer: "https://cognito-idp.<REGION>.amazonaws.com/<USER_POOL_ID>"
  clientId: "<PORTAL_CLIENT_ID>"
  clientSecretName: portal-oidc-client
  scopes: ["openid", "email", "profile"]
  authorizationEndpoint: ""
  tokenEndpoint: ""
```

Các giá trị thật được script `03-gen-values.sh` điền vào `helm/values/generated/demo-portal.yaml` từ kết quả tạo Cognito.

Dùng trong `securitypolicy.yaml`, khối `oidc`:

```yaml
oidc:
  provider:
    issuer: {{ $c.issuer | quote }}
    {{- with $c.authorizationEndpoint }}
    authorizationEndpoint: {{ . | quote }}     # chỉ render nếu có giá trị
    {{- end }}
    {{- with $c.tokenEndpoint }}
    tokenEndpoint: {{ . | quote }}
    {{- end }}
  clientID: {{ $c.clientId | quote }}
  clientSecret:
    name: {{ $c.clientSecretName }}
  redirectURL: "https://{{ include "demo.host" . }}/oauth2/callback"
  logoutPath: /logout
  scopes:
    {{- toYaml $c.scopes | nindent 6 }}
  refreshToken: true
  cookieNames:
    idToken: PortalIdToken
    accessToken: PortalAccessToken
  cookieConfig:
    sameSite: Lax
  denyRedirect:
    headers:
      - name: X-Requested-With
        value: XMLHttpRequest
```

| Khoá values / trường | Ý nghĩa |
|---|---|
| `cognito.issuer` | Định danh User Pool: `https://cognito-idp.<region>.amazonaws.com/<pool_id>`. Envoy Gateway đọc `<issuer>/.well-known/openid-configuration` để biết các endpoint. **Không** có dấu `/` ở cuối |
| `cognito.clientId` | Client ID của app client `portal-web` |
| `cognito.clientSecretName` | Tên **Secret Kubernetes** (không phải chính secret). Secret phải có key đúng tên `client-secret`. Tạo bằng `kubectl create secret generic portal-oidc-client -n demo-portal --from-literal=client-secret=...` |
| `cognito.scopes` | `openid` bắt buộc để nhận ID token; `email`, `profile` để token có email |
| `cognito.authorizationEndpoint`, `tokenEndpoint` | Tuỳ chọn. Để trống thì lấy từ discovery. Script điền sẵn theo domain Hosted UI: `https://<prefix>.auth.<region>.amazoncognito.com/oauth2/authorize` và `.../oauth2/token` |
| `logoutPath: /logout` | Truy cập `https://portal.<domain>/logout` để Envoy xoá cookie phiên |
| `refreshToken: true` | Token hết hạn (30 phút) thì Envoy tự dùng refresh token xin token mới, user không phải đăng nhập lại |
| `cookieNames` | Đặt tên cố định cho cookie chứa ID token và access token. Tên `PortalIdToken` được dùng lại ở khối `jwt` bên dưới |
| `cookieConfig.sameSite: Lax` | Cookie vẫn được gửi khi Cognito redirect về (điều hướng top-level), nhưng không gửi theo request cross-site khác |
| `denyRedirect` | Request có header `X-Requested-With: XMLHttpRequest` (AJAX) mà chưa đăng nhập sẽ nhận `401` thay vì `302`. Lý do: AJAX không xử lý được trang login HTML |

### 3.6 Kiểm tra ID token (JWT)

Khối `jwt` dùng lại `cognito.issuer` và `cognito.clientId`:

```yaml
jwt:
  providers:
    - name: cognito
      issuer: {{ $c.issuer | quote }}
      audiences:
        - {{ $c.clientId | quote }}                   # ID token phải được cấp cho chính portal-web
      remoteJWKS:
        uri: "{{ $c.issuer }}/.well-known/jwks.json"  # public key để verify chữ ký
      extractFrom:
        cookies:
          - PortalIdToken                             # lấy token từ cookie do bước OIDC đặt
      claimToHeaders:
        - claim: email
          header: x-user-email
        - claim: sub
          header: x-jwt-sub
```

**Vì sao đã có OIDC lại cần thêm JWT?** Bước OIDC chỉ trả lời câu hỏi "đã đăng nhập chưa". Muốn **phân quyền theo group** thì Envoy phải đọc được claim `cognito:groups` trong token. Khối `jwt` lấy ID token từ cookie, verify chữ ký, và đưa các claim cho bước phân quyền dùng.

| Trường | Ý nghĩa |
|---|---|
| `name: cognito` | Tên provider, được các luật phân quyền tham chiếu (`provider: cognito`) |
| `audiences` | Kiểm tra claim `aud`. ID token của Cognito có `aud` = client id, nên chỉ chấp nhận token cấp cho `portal-web` |
| `remoteJWKS.uri` | Envoy tải và cache bộ public key của User Pool. Pod Envoy cần ra được Internet |
| `extractFrom.cookies` | Đọc token từ cookie thay vì header `Authorization` |
| `claimToHeaders` | Gắn `email`, `sub` thành header gửi vào podinfo. App biết ai đang dùng mà không cần tự giải mã token. Mở `https://portal.<domain>/headers` để xem |

> Client không giả mạo được `x-user-email`, `x-jwt-sub`: `ClientTrafficPolicy` của chart `eg-platform` xoá các header này ngay khi request vào, trước khi Envoy tự gắn lại từ token.

### 3.7 Phân quyền theo group

```yaml
authz:
  allowedGroups: ["devops-admin", "developer", "viewer"]
  adminGroups: ["devops-admin"]
  adminPaths: ["/env", "/configs"]
```

Template sinh luật bằng vòng lặp qua `adminPaths`. Với mỗi path admin, chart tạo **một cặp luật** Allow cho admin, rồi Deny cho mọi người còn lại:

```yaml
authorization:
  defaultAction: Deny
  rules:
    {{- range $i, $path := .Values.authz.adminPaths }}
    - name: admin-only-{{ $i }}
      action: Allow
      operation:
        path: { type: PathPrefix, value: {{ $path | quote }} }
      principal:
        jwt:
          provider: cognito
          claims:
            - name: "cognito:groups"
              valueType: StringArray
              values: {{ adminGroups }}
    - name: deny-admin-path-{{ $i }}
      action: Deny
      operation:
        path: { type: PathPrefix, value: {{ $path | quote }} }
      principal:
        clientCIDRs: ["0.0.0.0/0", "::/0"]
    {{- end }}
    - name: allow-portal-groups
      action: Allow
      principal:
        jwt:
          provider: cognito
          claims:
            - name: "cognito:groups"
              valueType: StringArray
              values: {{ allowedGroups }}
```

Với giá trị mặc định, bảng luật sau khi render:

| Thứ tự | Luật | Path | Ai | Kết quả |
|---|---|---|---|---|
| 1 | `admin-only-0` | `/env*` | group `devops-admin` | Allow |
| 2 | `deny-admin-path-0` | `/env*` | mọi IP (tức mọi người còn lại) | **Deny** |
| 3 | `admin-only-1` | `/configs*` | group `devops-admin` | Allow |
| 4 | `deny-admin-path-1` | `/configs*` | mọi người còn lại | **Deny** |
| 5 | `allow-portal-groups` | mọi path | `devops-admin`, `developer`, `viewer` | Allow |
| – | `defaultAction` | | không khớp luật nào | **Deny** (403) |

Cách đọc:

- Luật được xét **từ trên xuống**, gặp luật khớp đầu tiên thì dừng.
- `valueType: StringArray`: claim `cognito:groups` là **mảng** (một user có thể thuộc nhiều group). Luật khớp khi mảng chứa **ít nhất một** giá trị trong `values`.
- Mỗi luật **bắt buộc** có `principal`. Luật Deny dùng `clientCIDRs: ["0.0.0.0/0", "::/0"]` (mọi IPv4 và IPv6) để mang nghĩa "áp cho tất cả".
- User đăng nhập được nhưng **không thuộc group nào** sẽ không có claim `cognito:groups`, nên rơi xuống `defaultAction` và nhận 403.

| Khoá | Muốn đổi thì |
|---|---|
| `allowedGroups` | Thêm/bớt group được vào portal |
| `adminGroups` | Group được vào path nhạy cảm |
| `adminPaths` | Thêm path nhạy cảm (ví dụ `/api/admin`); chart tự sinh thêm cặp luật |

### 3.8 Rate limit và resilience

```yaml
rateLimit:
  requestsPerMinutePerIP: 300
resilience:
  requestTimeout: 15s
  retries: 2
```

Dùng trong `backendtrafficpolicy.yaml`:

```yaml
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: portal
  rateLimit:
    type: Global                         # bộ đếm dùng chung cho mọi Pod Envoy (lưu trong Redis)
    global:
      rules:
        - clientSelectors:
            - sourceCIDR:
                type: Distinct           # mỗi IP một bộ đếm riêng
                value: 0.0.0.0/0
          limit:
            requests: {{ .Values.rateLimit.requestsPerMinutePerIP }}
            unit: Minute
  loadBalancer:
    type: LeastRequest                   # gửi tới Pod đang có ít request nhất
  timeout:
    http:
      requestTimeout: {{ .Values.resilience.requestTimeout }}
  retry:
    numRetries: {{ .Values.resilience.retries }}
    retryOn:
      triggers: [connect-failure, reset, refused-stream]
  healthCheck:
    passive:                             # outlier detection
      consecutive5XxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
```

| Thiết lập | Ý nghĩa |
|---|---|
| `type: Global` | Envoy hỏi rate limit service (bộ đếm trong Redis). Có 2 hay 6 Pod Envoy thì giới hạn vẫn là 300/phút/IP. Nếu dùng `Local`, mỗi Pod Envoy đếm riêng nên giới hạn thực tế nhân lên theo số Pod |
| `sourceCIDR Distinct 0.0.0.0/0` | Áp cho mọi IP, mỗi IP một bộ đếm. Cần IP thật của client (NLB `preserve_client_ip` hoặc F5 + `X-Forwarded-For`), nếu không mọi người dùng sẽ chung một bộ đếm |
| Vượt giới hạn | Envoy trả `429 Too Many Requests` kèm header `x-ratelimit-*` |
| `requestTimeout: 15s` | Backend không trả lời trong 15s thì Envoy trả `504` |
| `retry` | Chỉ thử lại khi **lỗi kết nối** (Pod đang khởi động lại, kết nối bị reset). Không retry lỗi 5xx của ứng dụng, để tránh gửi lặp request không idempotent |
| `healthCheck.passive` | Pod trả 5 lỗi 5xx liên tiếp bị loại khỏi danh sách 30 giây. Không loại quá 50% số Pod cùng lúc |

### 3.9 Tài nguyên Pod

```yaml
resources:
  requests:
    cpu: 20m
    memory: 32Mi
  limits:
    memory: 128Mi
```

Áp cho container podinfo ở mọi phiên bản. Không đặt `limits.cpu` để tránh CPU throttling. Giới hạn memory để một Pod lỗi không chiếm hết bộ nhớ của node.

---

## 4. Ghi đè values

File values sinh tự động (`helm/values/generated/demo-portal.yaml`) chỉ chứa phần phụ thuộc môi trường:

```yaml
domain: gitlabonlinecom.click
cognito:
  issuer: "https://cognito-idp.ap-southeast-1.amazonaws.com/ap-southeast-1_AbCdEf123"
  clientId: "1abc2def3ghi4jkl5mno6pqr7s"
  authorizationEndpoint: "https://mycompany-eg-demo.auth.ap-southeast-1.amazoncognito.com/oauth2/authorize"
  tokenEndpoint: "https://mycompany-eg-demo.auth.ap-southeast-1.amazoncognito.com/oauth2/token"
```

Thứ tự ưu tiên khi Helm gộp values: `values.yaml` của chart < file truyền bằng `-f` < `--set`. Ví dụ đổi canary và thêm một path admin:

```bash
helm upgrade demo-portal helm/charts/demo-portal -n demo-portal -f helm/values/generated/demo-portal.yaml --set canary.v2Weight=50 --set 'authz.adminPaths={/env,/configs,/api/admin}'
```

Xem YAML sẽ được tạo ra **trước khi** áp dụng:

```bash
helm template demo-portal helm/charts/demo-portal -n demo-portal -f helm/values/generated/demo-portal.yaml
```

So sánh với bản đang chạy (cần plugin `helm-diff`):

```bash
helm diff upgrade demo-portal helm/charts/demo-portal -n demo-portal -f helm/values/generated/demo-portal.yaml
```

## 5. Kiểm tra sau khi cài

```bash
kubectl get deploy,svc,httproute,securitypolicy,backendtrafficpolicy -n demo-portal
```

Trạng thái từng policy phải là `Accepted`:

```bash
kubectl get securitypolicy portal-auth -n demo-portal -o jsonpath='{.status.ancestors[0].conditions[0].reason}{": "}{.status.ancestors[0].conditions[0].message}{"\n"}'
```

```bash
kubectl get backendtrafficpolicy portal-traffic -n demo-portal -o jsonpath='{.status.ancestors[0].conditions[0].reason}{"\n"}'
```

Route phải được Gateway chấp nhận:

```bash
kubectl get httproute portal -n demo-portal -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].reason}{"\n"}'
```

Chạy nhóm test của portal: `tests/run-tests.sh portal`. Các test bằng trình duyệt (POR-06 đến POR-12) có trong `docs/08-testing.md`.

## 6. Lỗi thường gặp khi sửa values

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `SecurityPolicy` báo `client secret not found` | Chưa tạo Secret, sai tên, hoặc key không phải `client-secret` | Tạo lại Secret đúng tên `cognito.clientSecretName` và đúng key |
| Cognito báo `redirect_mismatch` | Đổi `domain`/`hostPrefix` nhưng chưa sửa Callback URL trong Cognito | Cập nhật Callback URL của app client `portal-web` |
| Đăng nhập xong bị 401 | `cognito.clientId` không khớp `aud` trong ID token, hoặc `issuer` thừa `/` cuối | So sánh với `scripts/get-token.sh decode <id_token>` |
| Đăng nhập xong bị `403 RBAC: access denied` | User không thuộc group trong `allowedGroups` | Thêm user vào group trên Cognito, rồi đăng nhập lại |
| Canary không như mong muốn | `v2Weight` ngoài khoảng 0–100 | Giữ trong khoảng 0–100 |
| Mọi người cùng nhận 429 | Envoy không thấy IP thật, mọi request trông như từ cùng một IP | Kiểm tra `preserve_client_ip` ở NLB hoặc `clientIPDetection` khi có F5 |
