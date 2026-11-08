# Chart `demo-partner` – App 3: Partner API (API key)

Tài liệu này giải thích **từng khối trong `values.yaml`**: giá trị đó được template nào dùng, sinh ra resource gì, và Envoy Gateway xử lý ra sao.

| | |
|---|---|
| URL | `https://partner.gitlabonlinecom.click/v1/*` |
| Namespace | `demo-partner` |
| Ứng dụng | [go-httpbin](https://github.com/mccutchen/go-httpbin) 2.25.0 đóng vai API cho đối tác |
| Xác thực | **API key** trong header `x-api-key` (không dùng Cognito: đối tác là hệ thống bên ngoài, không phải người dùng đăng nhập) |
| Phân quyền | Theo **gói dịch vụ** (tier) của đối tác + **IP allowlist** |

Mỗi đối tác có một API key. Gói của đối tác quyết định hai thứ: **được ghi hay chỉ đọc**, và **bao nhiêu request mỗi phút**.

---

## 1. Cấu trúc chart

```
demo-partner/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── _helpers.tpl                  # label, hostname, parentRef
    ├── workload.yaml                 # Deployment + Service partner-api
    ├── apikeys-secret.yaml           # Secret chứa API key của từng đối tác
    ├── httproute.yaml                # Route /v1/* → /anything/v1/*, header
    ├── securitypolicy.yaml           # Xác thực API key + phân quyền theo gói + IP allowlist
    └── backendtrafficpolicy.yaml     # Rate limit theo gói, timeout, retry
```

| Template | Kind | Tên |
|---|---|---|
| `apikeys-secret.yaml` | `Secret` | `partner-api-keys` |
| `workload.yaml` | `Deployment`, `Service` | `partner-api` |
| `httproute.yaml` | `HTTPRoute` | `partner-api` |
| `securitypolicy.yaml` | `SecurityPolicy` | `partner-api-auth` |
| `backendtrafficpolicy.yaml` | `BackendTrafficPolicy` | `partner-api-traffic` |

## 2. Luồng request

```
Đối tác ── x-api-key: <key> ──► Envoy Gateway
   │
   ├─ SecurityPolicy "partner-api-auth"
   │    ① api_key_auth : so key với Secret partner-api-keys
   │                     sai/thiếu → 401
   │                     đúng → gắn x-partner-id: <client id>, XOÁ header x-api-key
   │    ② rbac         : ghi chỉ cho gói có allowWrite; đọc cho mọi đối tác; IP phải trong allowlist
   │
   ├─ BackendTrafficPolicy "partner-api-traffic"
   │    ③ ratelimit    : đếm theo x-partner-id, hạn mức theo gói → vượt thì 429
   │    ④ timeout 10s, retry khi lỗi kết nối
   │
   └─ ⑤ HTTPRoute: /v1/* → /anything/v1/*, thêm X-Gateway, Cache-Control: no-store
```

---

## 3. Giải thích từng khối trong `values.yaml`

### 3.1 Domain, hostname, Gateway

```yaml
domain: gitlabonlinecom.click
hostPrefix: partner

gateway:
  name: eg-gateway
  namespace: eg-gateway
  sectionName: https
```

`_helpers.tpl` ghép thành `partner.gitlabonlinecom.click` cho `HTTPRoute.spec.hostnames`, và `parentRefs` trỏ vào listener `https` của Gateway dùng chung. Namespace `demo-partner` phải có label `gateway.demo.io/attach=true`.

### 3.2 Image và số Pod

```yaml
image:
  repository: docker.io/mccutchen/go-httpbin
  tag: 2.25.0
  pullPolicy: IfNotPresent

replicas: 2
```

`workload.yaml` tạo một `Deployment` và một `Service` tên `partner-api` (port 8080). App này không có canary nên không dùng khối `versions` như hai app kia.

### 3.3 API key

```yaml
apiKeys:
  secretName: partner-api-keys
  header: x-api-key
  clientIdHeader: x-partner-id
  keys:
    partner-gold: ""
    partner-silver: ""
```

#### Secret chứa key (`apikeys-secret.yaml`)

```yaml
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: {{ .Values.apiKeys.secretName }}
stringData:
  {{- range $client, $key := .Values.apiKeys.keys }}
  {{ $client }}: {{ required (printf "Thiếu API key cho %s: ..." $client) $key | quote }}
  {{- end }}
```

Render với `--set apiKeys.keys.partner-gold=GOLD_KEY --set apiKeys.keys.partner-silver=SILVER_KEY`:

```yaml
stringData:
  partner-gold: "GOLD_KEY"
  partner-silver: "SILVER_KEY"
```

Quy ước của Envoy Gateway: **tên key trong Secret là "client id"** của đối tác, **giá trị là API key**. Client id này xuất hiện ở các bước sau (header `x-partner-id`, phân quyền, rate limit).

Hàm `required` chặn việc cài chart khi quên truyền key:

```
Error: execution error at (demo-partner/templates/apikeys-secret.yaml): Thiếu API key cho partner-gold: truyền --set apiKeys.keys.partner-gold=<key>
```

> **Không ghi API key thật vào `values.yaml` hay file values trong Git.** Script `02-cognito-setup.sh` sinh key ngẫu nhiên và lưu vào `config/cognito.env` (đã `.gitignore`). Khi cài, truyền key bằng `--set`.

#### Xác thực (`securitypolicy.yaml`, khối `apiKeyAuth`)

```yaml
apiKeyAuth:
  credentialRefs:
    - kind: Secret
      name: {{ $k.secretName }}           # partner-api-keys
  extractFrom:
    - headers:
        - {{ $k.header }}                 # đọc key từ header x-api-key
  forwardClientIDHeader: {{ $k.clientIdHeader }}   # gắn x-partner-id: partner-gold|partner-silver
  sanitize: true                          # xoá header x-api-key trước khi gửi vào backend
```

| Khoá values / trường | Ý nghĩa |
|---|---|
| `apiKeys.secretName` | Secret chứa danh sách key. Envoy Gateway theo dõi Secret này: đổi key thì Envoy cập nhật trong vài giây, không cần khởi động lại |
| `apiKeys.header` | Header đối tác gửi key. `extractFrom` còn hỗ trợ đọc từ query param hoặc cookie |
| `apiKeys.clientIdHeader` | Header Envoy gắn vào request sau khi xác thực, giá trị là client id. Backend biết ai đang gọi mà không cần biết key |
| `sanitize: true` | **Backend không bao giờ thấy API key**. Key không bị lộ qua log của ứng dụng |

Kết quả: thiếu key hoặc key sai → `401`. Key đúng → đi tiếp với header `x-partner-id`.

### 3.4 Gói dịch vụ (tier)

```yaml
tiers:
  - clientId: partner-gold
    requestsPerMinute: 100
    allowWrite: true
  - clientId: partner-silver
    requestsPerMinute: 5
    allowWrite: false
```

`tiers` là **nguồn duy nhất** để sinh cả luật phân quyền lẫn rate limit. `clientId` phải trùng tên key trong `apiKeys.keys`.

| Khoá | Dùng ở | Ý nghĩa |
|---|---|---|
| `clientId` | `securitypolicy.yaml`, `backendtrafficpolicy.yaml` | Tên đối tác, trùng tên key trong Secret |
| `requestsPerMinute` | `backendtrafficpolicy.yaml` | Hạn mức request mỗi phút của đối tác (mục 3.6) |
| `allowWrite` | `securitypolicy.yaml` | `true`: được POST/PUT/PATCH/DELETE; `false`: chỉ đọc (mục 3.5) |

### 3.5 Phân quyền và IP allowlist

```yaml
allowedCIDRs:
  - 0.0.0.0/0
```

Đầu `securitypolicy.yaml` gom danh sách đối tác được ghi từ `tiers`:

```yaml
{{- $writers := list -}}
{{- range .Values.tiers }}{{- if .allowWrite }}{{- $writers = append $writers .clientId }}{{- end }}{{- end -}}
```

Rồi sinh luật:

```yaml
authorization:
  defaultAction: Deny
  rules:
    - name: write-by-tier
      action: Allow
      operation:
        methods: ["POST", "PUT", "PATCH", "DELETE"]
      principal:
        clientCIDRs: {{ allowedCIDRs }}       # IP phải nằm trong allowlist
        headers:
          - name: x-partner-id                # VÀ là đối tác có allowWrite
            values: {{ $writers }}            # [partner-gold]
    - name: read-any-partner
      action: Allow
      operation:
        methods: ["GET", "HEAD"]
      principal:
        clientCIDRs: {{ allowedCIDRs }}
```

| Khái niệm | Giải thích |
|---|---|
| Nhiều loại principal trong một luật | `clientCIDRs` **và** `headers` phải khớp **cùng lúc** |
| `principal.headers` | So khớp header `x-partner-id` mà bước API key đã gắn vào. Bước phân quyền chạy **sau** bước API key nên đọc được header này |
| `clientCIDRs` | IP của client. Cần IP thật (NLB `preserve_client_ip`, hoặc F5 + `X-Forwarded-For`) |
| Đối tác chỉ đọc gửi `POST` | Không khớp luật nào → `defaultAction: Deny` → `403` |

**Chống giả mạo**: đối tác gói silver tự gửi header `X-Partner-Id: partner-gold` để được quyền ghi thì sẽ không thành công, vì `ClientTrafficPolicy` của platform xoá `x-partner-id` ngay khi request vào. Sau đó Envoy chỉ gắn lại giá trị đúng theo API key.

Production: thay `0.0.0.0/0` bằng IP NAT của các đối tác, ví dụ:

```bash
--set 'allowedCIDRs={203.0.113.10/32,198.51.100.0/24}'
```

> `allowedCIDRs` áp chung cho mọi đối tác. Muốn mỗi đối tác một danh sách IP riêng, cần tách luật theo từng `clientId` (thêm trường IP vào từng phần tử `tiers` và sửa template).

### 3.6 Rate limit theo gói

`backendtrafficpolicy.yaml` sinh một luật rate limit cho **mỗi** phần tử trong `tiers`:

```yaml
rateLimit:
  type: Global
  global:
    rules:
      {{- range .Values.tiers }}
      - clientSelectors:
          - headers:
              - name: x-partner-id
                type: Exact
                value: {{ .clientId }}
        limit:
          requests: {{ .requestsPerMinute }}
          unit: Minute
      {{- end }}
```

Kết quả render:

| Header `x-partner-id` | Hạn mức |
|---|---|
| `partner-gold` | 100 request/phút |
| `partner-silver` | 5 request/phút |

| Khái niệm | Giải thích |
|---|---|
| `type: Exact` | Luật chỉ áp cho đúng một đối tác. Mỗi đối tác một luật nên hạn mức khác nhau được |
| So với `Distinct` (dùng ở App 2) | `Distinct` = cùng một hạn mức cho mọi giá trị, mỗi giá trị một bộ đếm. `Exact` = hạn mức riêng cho từng giá trị cụ thể |
| `type: Global` | Bộ đếm trong Redis, dùng chung cho mọi Pod Envoy |
| Vượt hạn mức | `429` kèm `x-ratelimit-limit`, `x-ratelimit-remaining`, `x-ratelimit-reset` |
| Request bị 401/403 | Không bị tính vào hạn mức (bước rate limit chạy sau xác thực và phân quyền) |

> Một key có trong `apiKeys.keys` nhưng **không** có trong `tiers` sẽ xác thực được, đọc được, nhưng **không bị giới hạn** request và không được ghi. Luôn khai báo đủ cả hai chỗ.

### 3.7 Route, header, resilience

```yaml
resilience:
  requestTimeout: 10s
```

`httproute.yaml` (cố định, không có values riêng ngoài hostname):

```yaml
rules:
  - name: v1
    matches:
      - path: { type: PathPrefix, value: /v1 }
    filters:
      - type: URLRewrite
        urlRewrite:
          path:
            type: ReplacePrefixMatch
            replacePrefixMatch: /anything/v1      # /v1/quote → /anything/v1/quote
      - type: RequestHeaderModifier
        requestHeaderModifier:
          set:
            - name: X-Gateway
              value: envoy-gateway
      - type: ResponseHeaderModifier
        responseHeaderModifier:
          set:
            - name: Cache-Control
              value: no-store
    backendRefs:
      - name: partner-api
        port: 8080
```

Chỉ path bắt đầu bằng `/v1` mới có route. Gọi path khác (ví dụ `/v2/...`, `/admin`) → `404`. Đây là cách đơn giản để chỉ mở đúng phiên bản API dành cho đối tác.

`backendtrafficpolicy.yaml` thêm timeout 10s (`resilience.requestTimeout`) và retry 2 lần khi lỗi kết nối (`connect-failure`, `reset`, `refused-stream`).

### 3.8 Tài nguyên Pod

```yaml
resources:
  requests: { cpu: 20m, memory: 32Mi }
  limits: { memory: 128Mi }
```

---

## 4. Cài đặt và ghi đè values

```bash
source config/demo.env && source config/cognito.env
```

```bash
helm upgrade --install demo-partner helm/charts/demo-partner -n demo-partner -f helm/values/generated/demo-partner.yaml --set apiKeys.keys.partner-gold="$PARTNER_GOLD_KEY" --set apiKeys.keys.partner-silver="$PARTNER_SILVER_KEY" --wait
```

### Thêm đối tác mới

Ví dụ đối tác `partner-bronze`: chỉ đọc, 20 request/phút. Tạo file `partner-extra.yaml`:

```yaml
tiers:
  - clientId: partner-gold
    requestsPerMinute: 100
    allowWrite: true
  - clientId: partner-silver
    requestsPerMinute: 5
    allowWrite: false
  - clientId: partner-bronze
    requestsPerMinute: 20
    allowWrite: false
```

> Helm **thay thế toàn bộ** list khi ghi đè, không gộp từng phần tử. Vì vậy phải liệt kê lại cả các gói cũ.

```bash
helm upgrade demo-partner helm/charts/demo-partner -n demo-partner -f helm/values/generated/demo-partner.yaml -f partner-extra.yaml --set apiKeys.keys.partner-gold="$PARTNER_GOLD_KEY" --set apiKeys.keys.partner-silver="$PARTNER_SILVER_KEY" --set apiKeys.keys.partner-bronze="$(openssl rand -hex 24)"
```

### Đổi (rotate) key của một đối tác

Chạy lại `helm upgrade` với key mới cho client id đó. Key cũ hết hiệu lực ngay khi Secret được cập nhật.

## 5. Kiểm tra sau khi cài

```bash
kubectl get secret,deploy,svc,httproute,securitypolicy,backendtrafficpolicy -n demo-partner
```

```bash
kubectl get securitypolicy partner-api-auth -n demo-partner -o jsonpath='{.status.ancestors[0].conditions[0].reason}{"\n"}'
```

Thử nhanh:

```bash
curl -s -H "x-api-key: $PARTNER_SILVER_KEY" "https://partner.${DOMAIN}/v1/quote" | jq '{url, partner: .headers["X-Partner-Id"], apikey: .headers["X-Api-Key"]}'
```

Kết quả mong đợi: `partner` = `["partner-silver"]`, `apikey` = `null` (key đã bị xoá trước khi vào backend).

Chạy nhóm test: `tests/run-tests.sh partner` (11 test, PAR-01 đến PAR-11, xem `docs/08-testing.md`).

## 6. Lỗi thường gặp khi sửa values

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `helm install` báo `Thiếu API key cho ...` | Chưa truyền `--set apiKeys.keys.<client>=...` | Truyền key cho mọi client trong `apiKeys.keys` |
| Key đúng vẫn `401` | Gửi sai tên header (khác `apiKeys.header`) | Gửi đúng `x-api-key` |
| Đối tác gói ghi vẫn `403` khi `POST` | `clientId` trong `tiers` khác tên key trong `apiKeys.keys`, hoặc IP ngoài `allowedCIDRs` | Đồng bộ tên; kiểm tra IP thật bằng `jq .origin` trong response |
| Đối tác mới không bị giới hạn | Có trong `apiKeys.keys` nhưng thiếu trong `tiers` | Thêm vào `tiers` |
| Ghi đè `tiers` làm mất gói cũ | Helm thay cả list | Liệt kê đầy đủ các gói khi ghi đè |
| Mọi request `403` sau khi đặt `allowedCIDRs` | Envoy không thấy IP thật của đối tác | Kiểm tra `preserve_client_ip` (NLB) hoặc `clientIPDetection: xff` (F5) |
