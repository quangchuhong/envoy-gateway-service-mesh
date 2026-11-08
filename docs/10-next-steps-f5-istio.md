# 10 – Bước tiếp theo: gắn F5 phía trước, tích hợp Istio

## 1. Gắn F5 BIG-IP (LTM + Advanced WAF) vào vị trí của NLB

```
User ─HTTPS─► F5 (TLS public, WAF, bot/DDoS, rate limit theo IP, insert XFF) ─HTTPS re-encrypt─► Envoy Gateway
```

### 1.1 Thay đổi phía Kubernetes (chỉ sửa values của `eg-platform`)

| Giá trị | Hiện tại (NLB) | Khi có F5 |
|---|---|---|
| `envoyProxy.service.type` | `LoadBalancer` | `NodePort` (F5 → NodePort) hoặc `ClusterIP` (F5 CIS → Pod IP) |
| `envoyProxy.service.nlb.enabled` | `true` | `false` |
| `envoyProxy.service.externalTrafficPolicy` | `Cluster` | `Local` (giữ IP nguồn, tránh hop chéo node) nếu dùng NodePort |
| `clientTraffic.clientIPDetection` | `direct` | `xff` |
| `clientTraffic.xffTrustedHops` | – | `1` (chỉ có F5 phía trước; `2` nếu có thêm CloudFront) |
| `tls.create` | `true` | Giữ `true` (F5 không verify cert backend), hoặc dùng cert nội bộ của công ty |

Ví dụ file values khi dùng F5 CIS:

```yaml
envoyProxy:
  service:
    type: ClusterIP
    nlb:
      enabled: false
clientTraffic:
  clientIPDetection: xff
  xffTrustedHops: 1
```

Không cần sửa chart của 3 app: route, xác thực, phân quyền, rate limit theo user và API key giữ nguyên.

### 1.2 Cấu hình phía F5

| Thành phần BIG-IP | Cấu hình |
|---|---|
| Virtual Server | `VIP:443` (kèm `VIP:80` redirect sang HTTPS) |
| Client SSL profile | Cert public `*.gitlabonlinecom.click` (chính cert đã mua, import file cert + private key + chain vào F5), TLS ≥ 1.2 |
| Advanced WAF policy | Chạy **Transparent** 1–2 tuần để tinh chỉnh false positive, rồi chuyển **Blocking** |
| HTTP profile | Bật **Insert X-Forwarded-For**; tăng *Max Header Size* (cookie OIDC và JWT khá lớn) |
| Server SSL profile | Re-encrypt tới Envoy (không cần verify cert). Listener của Envoy không đặt `hostname` nên **không cần SNI** |
| Pool | NodePort: `<node_ip>:<nodePort của 443>`; F5 CIS: Pod IP:**10443** (cổng thật trong container) |
| Monitor | HTTP `GET /ready` cổng **19003** trên Pod IP (readiness của Envoy), hoặc HTTPS `GET /healthz` qua listener |
| Timeout | Idle timeout của F5 ≥ timeout dài nhất của Envoy/backend |
| Slow ramp + drain | Slow ramp cho Pod mới; thời gian rút member khỏi pool ≤ `envoyProxy.shutdown.drainTimeout` (30s) |

### 1.3 Cert khi chuyển sang F5

Hiện tại cert `*.gitlabonlinecom.click` nằm trong ACM (`arn:aws:acm:ap-southeast-1:609320954321:certificate/569f4470-6ac3-4ef2-be6e-7eb012397305`) và chỉ NLB dùng được. ACM **không cho xuất private key** của cert, kể cả cert đã import, nên F5 không lấy cert từ ACM được.

- Dùng **bộ file gốc** (cert, private key, chain) mà bạn nhận khi mua cert để import vào F5 (*System → Certificate Management → SSL Certificate List*), rồi gắn vào Client SSL profile.
- Khi gia hạn cert: cập nhật cả trên F5 và (nếu vẫn giữ NLB song song) import lại vào ACM cùng ARN.
- Đoạn F5 → Envoy vẫn dùng cert self-signed `eg-gateway-tls` của chart như hiện nay.
- Khi đã chuyển hẳn sang F5 (`nlb.enabled: false`), bỏ `acmCertArn` khỏi values; NLB không còn được tạo.

### 1.4 Phân chia trách nhiệm để tránh trùng lặp

| Việc | F5 | Envoy Gateway |
|---|---|---|
| WAF, bot, L7 DDoS, IP reputation | ✅ | – |
| Rate limit thô theo IP | ✅ | (portal giữ 300/phút/IP làm lớp dự phòng) |
| Xác thực OIDC/JWT/API key, phân quyền | – | ✅ |
| Rate limit theo user / API key | – | ✅ |
| Routing, canary, retry, timeout, circuit breaker | – | ✅ |

## 2. Tích hợp Istio (sidecar) phía sau Envoy Gateway

Envoy Gateway làm API Gateway (North-South), Istio làm mesh bên trong (East-West: mTLS, AuthorizationPolicy giữa các service).

| Việc | Cách làm |
|---|---|
| Bật sidecar cho namespace app | `kubectl label namespace demo-orders istio-injection=enabled`, rồi restart Deployment |
| Cho Envoy Gateway nói chuyện mTLS với app | Inject sidecar Istio vào **Pod Envoy Proxy** (thêm label `sidecar.istio.io/inject: "true"` qua `envoyProxy` → `envoyDeployment.pod.labels`) |
| Envoy Gateway route qua **Service** thay vì Pod IP | Đặt `routingType: Service` trong `EnvoyProxy` (hoặc trong `BackendTrafficPolicy`), để sidecar Istio nhận diện đích và áp mTLS |
| Bật mTLS STRICT | `PeerAuthentication` mode `STRICT` khi mọi namespace đã có sidecar |
| Chỉ cho Envoy Gateway gọi app | `AuthorizationPolicy` của Istio cho phép principal `cluster.local/ns/envoy-gateway-system/sa/<serviceaccount của Envoy>` |

> Trước khi bật cho cụm thật, đọc mục tích hợp Istio trong tài liệu Envoy Gateway đúng phiên bản bạn dùng, và thử trên một namespace trước.

## 3. Chuyển sang Terraform

Khi cần đưa vào IaC:

| Phần | Gợi ý |
|---|---|
| Cognito | `aws_cognito_user_pool`, `aws_cognito_user_pool_domain`, `aws_cognito_user_group`, `aws_cognito_resource_server`, `aws_cognito_user_pool_client` (tương ứng từng lệnh trong `scripts/02-cognito-setup.sh`) |
| ACM, Route 53 | `aws_acm_certificate` + `aws_route53_record` (validation và wildcard) |
| Helm release | Provider `helm`: `helm_release` cho `eg-redis`, `gateway-helm`, `eg-platform`, 3 app, dùng lại đúng các chart trong repo |
| Secret | AWS Secrets Manager + External Secrets Operator cho client secret và API key |
