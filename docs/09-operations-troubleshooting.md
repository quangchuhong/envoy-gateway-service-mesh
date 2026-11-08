# 09 – Vận hành và xử lý sự cố

## 1. Xem nhanh trạng thái

Mọi Gateway, route, policy:

```bash
kubectl get gateway,httproute -A
```

```bash
kubectl get securitypolicy,backendtrafficpolicy,clienttrafficpolicy -A
```

Lý do một policy không được áp dụng (cột `status.ancestors[].conditions`):

```bash
kubectl get securitypolicy -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.ancestors[0].conditions[0].reason,MSG:.status.ancestors[0].conditions[0].message'
```

```bash
kubectl get backendtrafficpolicy -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.ancestors[0].conditions[0].reason,MSG:.status.ancestors[0].conditions[0].message'
```

Route có được Gateway chấp nhận không:

```bash
kubectl get httproute -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,ACCEPTED:.status.parents[0].conditions[?(@.type=="Accepted")].reason'
```

## 2. Log

Log của control plane (lỗi dịch cấu hình, lỗi đọc OIDC discovery, lỗi Secret):

```bash
kubectl logs -n envoy-gateway-system deploy/envoy-gateway --tail=100
```

Access log JSON của Envoy (mỗi request một dòng):

```bash
kubectl logs -n eg-gateway -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -c envoy --tail=50 -f
```

Lọc request lỗi:

```bash
kubectl logs -n eg-gateway -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -c envoy --tail=500 | grep '^{' | jq -c 'select(.response_code >= 400) | {authority, path, response_code, response_flags, user_sub, partner_id, client_ip}'
```

Ý nghĩa `response_flags` thường gặp:

| Flag | Ý nghĩa |
|---|---|
| `RL` | Bị rate limit (429) |
| `UO` | Circuit breaker tràn (503) |
| `UT` | Hết timeout tới backend (504) |
| `FI` / `DI` | Fault injection: abort / delay |
| `UH` | Không có backend khoẻ |
| `UF` | Không kết nối được backend |
| `NR` | Không có route khớp (404) |

## 3. Xem cấu hình Envoy thực tế bằng `egctl`

Cài `egctl` cùng phiên bản (v1.9.3) theo tài liệu Envoy Gateway, sau đó:

```bash
egctl config envoy-proxy route -n eg-gateway -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway
```

```bash
egctl config envoy-proxy listener -n eg-gateway -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway
```

Kiểm tra chart offline (không cần cụm), dịch toàn bộ resource ra cấu hình Envoy:

```bash
./scripts/render-all.sh
```

```bash
cat rendered/*.yaml > /tmp/all.yaml && egctl x translate --from gateway-api --to gateway-api -f /tmp/all.yaml
```

> Khi dịch offline, `egctl` chỉ đọc **tên** Namespace (bỏ qua label), nên route sẽ báo `NotAllowedByListeners` do selector `gateway.demo.io/attach`. Trên cụm thật thì không gặp lỗi này. Ngoài ra OIDC offline sẽ báo thiếu secret `envoy-oidc-hmac` (secret này do job `certgen` tạo trên cụm).

## 4. Metrics

Envoy mở metrics Prometheus ở cổng `19001`, đường dẫn `/stats/prometheus`. Envoy Gateway đặt sẵn annotation `prometheus.io/scrape` cho Pod.

```bash
kubectl port-forward -n eg-gateway "$(kubectl get pod -n eg-gateway -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -o name | head -1)" 19001:19001
```

```bash
curl -s localhost:19001/stats/prometheus | grep -E "envoy_http_downstream_rq_xx|ratelimit|jwt_authn|rbac" | head -30
```

Metric hữu ích: `envoy_cluster_upstream_rq_retry` (số lần retry), `envoy_cluster_upstream_rq_pending_overflow` (circuit breaker), `envoy_http_jwt_authn_denied`, `envoy_http_rbac_denied`, `envoy_cluster_ratelimit_over_limit`.

## 5. Lỗi thường gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| Gateway không có `ADDRESS`, `PROGRAMMED=False` | AWS Load Balancer Controller chưa cài, subnet thiếu tag, IAM thiếu quyền | `kubectl logs -n kube-system deploy/aws-load-balancer-controller`; `kubectl describe svc -n eg-gateway` |
| Gateway không có `ADDRESS`, log của AWS Load Balancer Controller báo lỗi certificate | ARN cert sai, hoặc cert khác account/region với cụm | Chạy `scripts/01-check-prereqs.sh` (kiểm tra account `609320954321`, region `ap-southeast-1`, trạng thái `ISSUED`) |
| `curl` báo `SSL certificate problem` / trình duyệt cảnh báo cert | NLB đang ở chế độ `nlb-tcp`, Envoy trả cert self-signed | Kiểm tra listener 443 của NLB là `TLS` với cert ACM (docs/04 mục 4); `acmCertArn` trong `helm/values/generated/eg-platform.yaml` phải có giá trị |
| Trình duyệt báo cert **hết hạn** | Cert mua ngoài import vào ACM không tự gia hạn | Import cert mới vào **cùng ARN**: `aws acm import-certificate --certificate-arn <ARN> --certificate fileb://cert.pem --private-key fileb://key.pem --certificate-chain fileb://chain.pem`. NLB tự dùng cert mới |
| `Could not resolve host portal.gitlabonlinecom.click` | Chưa tạo bản ghi DNS, hoặc NLB bị tạo mới nên bản ghi trỏ vào NLB cũ | Chạy lại `scripts/05-dns.sh` |
| NLB có rồi nhưng target unhealthy | Security Group của node/Pod chặn cổng 10443/10080 từ NLB | AWS Load Balancer Controller tự thêm rule; kiểm tra lại nếu dùng SG tự quản lý hoặc Security Groups for Pods |
| HTTPRoute `NotAllowedByListeners` | Namespace thiếu label `gateway.demo.io/attach=true` | `kubectl label namespace <ns> gateway.demo.io/attach=true` |
| HTTPRoute `ResolvedRefs=False` | Sai tên/port Service trong `backendRefs` | Kiểm tra Service trong cùng namespace |
| `SecurityPolicy` báo `client secret not found` | Secret `portal-oidc-client` thiếu hoặc sai key (phải là `client-secret`) | Tạo lại Secret theo docs/05 |
| `SecurityPolicy` báo `HMAC secret not found` | Job `certgen` chưa chạy | `kubectl get job -n envoy-gateway-system`; cài lại chart Envoy Gateway |
| Portal: Cognito báo `redirect_mismatch` | Callback URL trong Cognito khác `https://portal.gitlabonlinecom.click/oauth2/callback` | Sửa callback của client `portal-web` |
| Portal: đăng nhập xong bị `401`/vòng lặp redirect | Cookie không được lưu (truy cập bằng HTTP, sai domain), đồng hồ lệch | Luôn dùng HTTPS; kiểm tra cookie trong DevTools |
| Portal: đăng nhập xong `403 RBAC: access denied` | User chưa thuộc group nào | `admin-add-user-to-group`, đăng nhập lại |
| API `401` với token đúng | Envoy không tải được JWKS (không ra Internet), issuer sai (thừa `/` cuối) | So issuer với `curl $COGNITO_ISSUER/.well-known/openid-configuration` |
| API `403` dù đúng group | Dùng ID token thay vì access token, hoặc group mới thêm nhưng token cũ | Lấy token mới; giải mã bằng `scripts/get-token.sh decode` |
| Không thấy `429` | Rate limit service không chạy, Redis lỗi, quên bật `rateLimit` trong values Envoy Gateway | `kubectl get deploy -n envoy-gateway-system envoy-ratelimit`; log của nó |
| Mọi request bị `429` | Bộ đếm theo IP (portal) mà mọi request đều đến từ cùng IP (NLB không giữ IP client) | Kiểm tra `preserve_client_ip.enabled=true` trên target group |

## 6. Gỡ cài đặt

Theo thứ tự ngược với lúc cài:

```bash
./scripts/99-cleanup.sh --dns
```

```bash
./scripts/99-cleanup.sh --apps
```

```bash
./scripts/99-cleanup.sh --platform
```

```bash
./scripts/99-cleanup.sh --eg
```

```bash
./scripts/99-cleanup.sh --cognito
```

Hoặc gỡ tất cả một lần: `./scripts/99-cleanup.sh --all`.

`--dns` xoá bản ghi `*.gitlabonlinecom.click` mà `05-dns.sh` đã tạo. Cert trong ACM **không** bị xoá (cert được mua và import riêng, dùng lại được cho lần triển khai sau). CRD **không** bị Helm xoá. Nếu chắc chắn không còn dùng Gateway API trên cụm:

```bash
kubectl get crd -o name | grep -E "gateway.envoyproxy.io|gateway.networking.k8s.io|gateway.networking.x-k8s.io" | xargs kubectl delete
```

> ⚠️ Lệnh trên xoá CRD Gateway API dùng chung. Nếu Istio hoặc controller khác trên cụm đang dùng Gateway API, **không** chạy lệnh này.
