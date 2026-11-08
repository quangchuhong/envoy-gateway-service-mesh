# 07 – App 3: Partner API (API key)

| | |
|---|---|
| URL | `https://partner.gitlabonlinecom.click/v1/*` |
| Namespace | `demo-partner` |
| Backend | go-httpbin 2.25.0, 2 Pod |
| Chart | `helm/charts/demo-partner` |

Mô phỏng API cho đối tác bên ngoài: mỗi đối tác có một API key và một **gói** (tier) quyết định quyền và hạn mức.

## 1. Tính năng được cấu hình

| Tính năng | Resource | Cấu hình |
|---|---|---|
| Xác thực API key | `SecurityPolicy.apiKeyAuth` | Đọc header `x-api-key`, so với Secret `partner-api-keys` |
| Chuyển danh tính đối tác cho backend | `forwardClientIDHeader` | Gắn `x-partner-id: partner-gold\|partner-silver` (tên key trong Secret) |
| Ẩn API key | `sanitize: true` | Xoá header `x-api-key` trước khi vào backend |
| Phân quyền theo gói | `authorization` | Ghi (POST/PUT/PATCH/DELETE) chỉ `partner-gold`; đọc (GET/HEAD) mọi partner |
| IP allowlist | `principal.clientCIDRs` | `allowedCIDRs` (demo: `0.0.0.0/0`) |
| Rate limit theo gói | `BackendTrafficPolicy.rateLimit` | `partner-gold` 100/phút, `partner-silver` 5/phút |
| URL rewrite + header | `HTTPRoute` | `/v1/*` → `/anything/v1/*`, thêm `X-Gateway`, `Cache-Control: no-store` |
| Resilience | `BackendTrafficPolicy` | timeout 10s, retry khi connect-failure/reset |

## 2. Gói dịch vụ (`values.yaml` → `tiers`)

```yaml
tiers:
  - clientId: partner-gold
    requestsPerMinute: 100
    allowWrite: true
  - clientId: partner-silver
    requestsPerMinute: 5
    allowWrite: false
```

Thêm một đối tác mới: thêm một dòng vào `tiers` và một key tương ứng vào `apiKeys.keys`. Chart tự sinh luật phân quyền và rate limit.

## 3. Triển khai

API key đã được sinh ngẫu nhiên ở bước Cognito và lưu trong `config/cognito.env` (`PARTNER_GOLD_KEY`, `PARTNER_SILVER_KEY`). Key **không** được ghi vào file values mà truyền bằng `--set`:

```bash
kubectl create namespace demo-partner
```

```bash
kubectl label namespace demo-partner gateway.demo.io/attach=true
```

```bash
source config/demo.env && source config/cognito.env
```

```bash
helm upgrade --install demo-partner helm/charts/demo-partner -n demo-partner -f helm/values/generated/demo-partner.yaml --set apiKeys.keys.partner-gold="$PARTNER_GOLD_KEY" --set apiKeys.keys.partner-silver="$PARTNER_SILVER_KEY" --wait
```

> Production: lưu API key trong **AWS Secrets Manager** và đồng bộ vào Secret `partner-api-keys` bằng External Secrets Operator. Khi đó tắt template `apikeys-secret.yaml` trong chart.

## 4. Thử nhanh

```bash
curl -s -H "x-api-key: $PARTNER_SILVER_KEY" "https://partner.${DOMAIN}/v1/quote" | jq '{url, partner: .headers["X-Partner-Id"], apikey: .headers["X-Api-Key"], origin}'
```

Kết quả mong đợi: `partner` = `["partner-silver"]`, `apikey` = `null` (đã bị xoá), `origin` là IP public của bạn.

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "x-api-key: $PARTNER_SILVER_KEY" "https://partner.${DOMAIN}/v1/order"
```

Kết quả mong đợi: `403` (gói silver không được ghi).

## 5. Xoay vòng (rotate) API key

1. Sinh key mới:
   ```bash
   NEW_KEY=$(openssl rand -hex 24)
   ```
2. Chạy lại `helm upgrade` với `--set apiKeys.keys.partner-silver="$NEW_KEY"`. Envoy Gateway theo dõi Secret và cập nhật Envoy trong vài giây, không cần restart.
3. Gửi key mới cho đối tác. Key cũ hết hiệu lực ngay khi Secret đổi.

Muốn đổi key không gián đoạn (key cũ và mới cùng chạy song song một thời gian), tạm thời thêm một client id mới, ví dụ `partner-silver-v2`, với key mới và cùng gói, rồi xoá client id cũ sau khi đối tác đã chuyển.
