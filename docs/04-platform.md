# 04 – Platform: GatewayClass, EnvoyProxy, Gateway, NLB

Chart `helm/charts/eg-platform` dựng **cửa vào dùng chung** cho mọi app. Platform team quản lý chart này.

## 1. Resource trong chart

| File template | Resource | Vai trò |
|---|---|---|
| `gatewayclass.yaml` | `GatewayClass eg-demo` | "Gateway thuộc lớp này do Envoy Gateway quản lý", trỏ tới `EnvoyProxy` |
| `envoyproxy.yaml` | `EnvoyProxy eg-demo-proxy` | Cấu hình **data plane**: replica, resource, HPA, PDB, rải Pod theo AZ, Service NLB, drain, access log JSON |
| `gateway.yaml` | `Gateway eg-gateway` | Listener `http:80` và `https:443`, chỉ nhận route từ namespace có label |
| `http-redirect.yaml` | `HTTPRoute http-to-https-redirect` | Mọi request port 80 → 301 sang HTTPS |
| `clienttrafficpolicy.yaml` | `ClientTrafficPolicy eg-gateway-client` | IP client, `/healthz`, timeout, `X-Request-Id`, xoá header nội bộ, TLS ≥ 1.2 |
| `tls-secret.yaml` | `Secret eg-gateway-tls` | Cert cho listener HTTPS (self-signed, tự sinh, giữ nguyên qua các lần upgrade) |

## 2. Các quyết định thiết kế quan trọng

### 2.1 TLS: hai chế độ

| Chế độ | Khi nào | Luồng TLS |
|---|---|---|
| **nlb-tls** (mặc định khi có `ACM_CERT_ARN`) | Có cert ACM | User ─TLS (cert ACM, public)─► **NLB** ─TLS (cert self-signed)─► Envoy. Giống mô hình F5 re-encrypt |
| **nlb-tcp** | Không có ACM cert | User ─TLS─► NLB (chỉ chuyển TCP) ─► **Envoy** terminate TLS. Cần cert thật trong `eg-gateway-tls` nếu muốn trình duyệt không cảnh báo |

NLB **không verify** cert của target, nên đoạn NLB → Envoy dùng cert self-signed là đủ.

### 2.2 Listener HTTPS không đặt `hostname`

NLB, và F5 sau này, khi re-encrypt tới Envoy **có thể không gửi SNI**. Nếu listener có `hostname`, Envoy chọn filter chain theo SNI và sẽ từ chối các kết nối không có SNI. Vì vậy listener để trống `hostname`, và việc định tuyến theo domain do `HTTPRoute.hostnames` đảm nhận, dựa vào header `Host`.

### 2.3 Giữ IP thật của client

NLB là L4 nên không chèn `X-Forwarded-For`. Repo bật `preserve_client_ip.enabled=true` trên target group, nhờ đó Envoy thấy IP gốc trực tiếp (`clientIPDetection: direct`). IP này được dùng cho:

- rate limit theo IP của portal,
- `clientCIDRs` (IP allowlist) của partner,
- access log (`client_ip`).

Khi có F5 phía trước: đổi `clientTraffic.clientIPDetection: xff` (tin 1 hop `X-Forwarded-For` do F5 chèn).

### 2.4 Chống giả mạo header nội bộ

Envoy tự set `x-jwt-sub`, `x-jwt-client-id`, `x-user-email` (từ JWT) và `x-partner-id` (từ API key). Backend và rate limit tin các header này, nên `ClientTrafficPolicy` **xoá chúng ngay khi request vào** (`earlyRequestHeaders.remove`), trước mọi bước xử lý khác.

### 2.5 Cổng thực tế của Envoy

Envoy Gateway dịch các cổng < 1024 lên +10000 bên trong container: listener 443 chạy ở container port **10443**, listener 80 ở **10080**. Service NLB vẫn mở 80/443. Envoy có endpoint readiness `/ready` ở cổng **19003**.

## 3. Cài đặt

```bash
./scripts/03-gen-values.sh
```

```bash
helm upgrade --install eg-platform helm/charts/eg-platform -n eg-gateway --create-namespace -f helm/values/generated/eg-platform.yaml --wait
```

Hoặc:

```bash
./scripts/04-deploy.sh platform
```

## 4. Kiểm tra

Gateway phải `PROGRAMMED=True` và có `ADDRESS` (DNS name của NLB):

```bash
kubectl get gateway -n eg-gateway
```

Envoy Gateway tự tạo Deployment/Service/HPA/PDB của Envoy:

```bash
kubectl get deploy,svc,hpa,pdb -n eg-gateway -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway
```

```bash
kubectl get clienttrafficpolicy -n eg-gateway eg-gateway-client -o jsonpath='{.status.ancestors[0].conditions[*].reason}'
```

Kết quả mong đợi: `Accepted`.

NLB (khoảng 2–3 phút để chuyển sang `active`):

```bash
export NLB_DNS=$(kubectl get gateway -n eg-gateway eg-gateway -o jsonpath='{.status.addresses[0].value}')
```

```bash
echo "$NLB_DNS"
```

## 5. Tạo bản ghi DNS

Tạo bản ghi **wildcard** `*.<DOMAIN>` (Alias A) trỏ về NLB. Với cấu hình hiện tại là `*.gitlabonlinecom.click`, bản ghi này phủ cả `portal.`, `api.`, `partner.`, và `unknown.gitlabonlinecom.click` dùng cho test GW-03:

```bash
./scripts/05-dns.sh
```

Script làm các việc sau:

1. Lấy DNS name của NLB từ `status.addresses` của Gateway `eg-gateway`.
2. Tìm hosted zone ID chuẩn (canonical) của NLB (cần cho bản ghi Alias).
3. Tìm **public** hosted zone của `DOMAIN` trong Route 53 (hoặc dùng `HOSTED_ZONE_ID` nếu đã đặt trong `config/demo.env`).
4. `UPSERT` bản ghi Alias A `*.DOMAIN` → NLB, rồi chờ Route 53 xác nhận thay đổi đã áp dụng.

Chạy lại script là an toàn (`UPSERT` ghi đè bản ghi cũ). Cần chạy lại khi NLB bị tạo mới, ví dụ sau khi gỡ và cài lại `eg-platform`.

Làm bằng tay (tương đương script):

```bash
NLB_ZONE=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --query "LoadBalancers[?DNSName=='${NLB_DNS}'].CanonicalHostedZoneId" --output text)
```

```bash
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"*.${DOMAIN}\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"${NLB_ZONE}\",\"DNSName\":\"${NLB_DNS}\",\"EvaluateTargetHealth\":true}}}]}"
```

Kiểm tra listener trả lời (`/healthz` do `ClientTrafficPolicy` cấu hình):

```bash
curl -i "https://portal.${DOMAIN}/healthz"
```

Kết quả mong đợi: `HTTP/2 200` (hoặc `HTTP/1.1 200`).

> Chưa có DNS? Lấy một IP của NLB (`dig +short $NLB_DNS`) rồi dùng `curl --resolve portal.${DOMAIN}:443:<IP> ...`. Khi chạy test, đặt `GATEWAY_IP=<IP>` trong `config/demo.env`.

## 6. Tuỳ chỉnh thường gặp (`helm/charts/eg-platform/values.yaml`)

| Giá trị | Mặc định | Ý nghĩa |
|---|---|---|
| `envoyProxy.replicas`, `hpa.*` | 2, HPA 2–6 theo CPU 70% | Số Pod Envoy |
| `envoyProxy.service.nlb.sourceRanges` | `[]` | Giới hạn IP được vào NLB (nên đặt IP văn phòng/VPN khi demo) |
| `envoyProxy.service.nlb.scheme` | `internet-facing` | Đổi `internal` nếu chỉ dùng nội bộ |
| `envoyProxy.shutdown.drainTimeout` | `30s` | Thời gian drain khi Pod Envoy bị xoá, khớp `deregistration_delay` |
| `clientTraffic.clientIPDetection` | `direct` | `xff` khi có F5 |
| `clientTraffic.stripRequestHeaders` | 4 header | Header nội bộ bị xoá khi vào |
| `gateway.attachNamespaceLabel` | `gateway.demo.io/attach=true` | Label namespace được phép gắn route |
