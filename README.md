# Envoy Gateway làm API Gateway trên EKS (demo 3 ứng dụng + AWS Cognito)

Repo này triển khai **Envoy Gateway** làm API Gateway cho cụm EKS, với 3 ứng dụng demo ở 3 namespace riêng. Xác thực người dùng bằng **AWS Cognito**. Mọi thứ được triển khai bằng **Helm chart**; giai đoạn này chưa dùng Terraform.

## Kiến trúc mục tiêu và phạm vi giai đoạn này

```
 👤 User
   │ HTTPS
   ▼
 DNS (Route 53: *.gitlabonlinecom.click)
   │
   ▼
┌──────────────────────────────────────────────────────┐
│ F5 BIG-IP (LTM + Advanced WAF)          [DMZ]        │  ◄── GIAI ĐOẠN SAU (tạm bỏ)
│  TLS public, WAF, bot/L7 DDoS, rate limit theo IP,   │      Hiện dùng AWS NLB đứng thay vị trí này:
│  Insert X-Forwarded-For, LB tới Envoy Gateway        │      TLS bằng cert ACM, giữ IP client
└──────────────────┬───────────────────────────────────┘
                   │ HTTPS re-encrypt
                   ▼
╔═════════════ EKS ══════════════════════════════════════════════╗
║ Envoy Gateway (API Gateway)                     ns: eg-gateway ║
║  - OIDC / JWT (AWS Cognito) / API key                          ║
║  - Phân quyền theo claim, rate limit theo user / API key       ║
║  - Routing, canary, retry, timeout, circuit breaker, CORS      ║
║        │                                                       ║
║        ├──► App 1  demo-portal   (namespace demo-portal)       ║
║        ├──► App 2  demo-orders   (namespace demo-orders)       ║
║        └──► App 3  demo-partner  (namespace demo-partner)      ║
╚════════════════════════════════════════════════════════════════╝
```

| Thành phần | Giai đoạn này | Ghi chú |
|---|---|---|
| F5 BIG-IP + WAF | ❌ Tạm bỏ | Đã chuẩn bị sẵn điểm nối, xem [docs/10](docs/10-next-steps-f5-istio.md) |
| AWS NLB | ✅ Thay vị trí F5 | TLS bằng ACM, re-encrypt tới Envoy, giữ IP client |
| Envoy Gateway v1.9.3 | ✅ | Control plane + data plane (Envoy Proxy) |
| AWS Cognito | ✅ | IdP cho OIDC (người dùng) và JWT (người dùng + máy) |
| 3 app demo | ✅ | Mỗi app một namespace, một Helm chart |
| Istio sidecar | ⏸ Tuỳ chọn | Hướng dẫn tích hợp ở [docs/10](docs/10-next-steps-f5-istio.md) |

## 3 ứng dụng demo

| App | URL | Namespace | Kiểu xác thực | Tính năng Envoy Gateway được demo |
|---|---|---|---|---|
| **1. Portal** (web UI, podinfo) | `https://portal.gitlabonlinecom.click` | `demo-portal` | **OIDC** đăng nhập Cognito (Authorization Code) | Login tại gateway, JWT từ cookie, phân quyền theo `cognito:groups` (path admin), canary v1/v2 theo trọng số + header, security headers, rate limit theo IP, retry/timeout, passive health check |
| **2. Orders API** (REST, go-httpbin) | `https://api.gitlabonlinecom.click/orders` | `demo-orders` | **JWT** Cognito (user + máy) | Phân quyền theo group **và** scope, chặn ID token, rate limit theo user (`sub`), canary + routing theo header, URL rewrite, thêm/xoá header, CORS, retry, timeout, circuit breaker, fault injection, least-request LB, **TLS tới backend (`BackendTLSPolicy`, CA nội bộ)** |
| **3. Partner API** (REST, go-httpbin) | `https://partner.gitlabonlinecom.click/v1` | `demo-partner` | **API key** | Xác thực API key, ẩn key khỏi backend, phân quyền theo partner + IP allowlist, rate limit theo gói (gold/silver) |

Dùng chung cho cả 3 app (ở mức Gateway): redirect HTTP→HTTPS, TLS, health check `/healthz`, lấy IP client, sinh `X-Request-Id`, xoá header nội bộ client tự gửi, access log JSON, HPA/PDB cho Envoy, drain kết nối khi scale.

## Cấu trúc repo

```
.
├── README.md
├── config/demo.env.example        # Biến môi trường (domain, region, ACM cert, Cognito prefix)
├── docs/                          # Tài liệu từng bước (đọc theo thứ tự 00 → 10)
├── helm/
│   ├── envoy-gateway/values.yaml  # Values cho chart chính thức gateway-helm (bật Global Rate Limit)
│   └── charts/
│       ├── eg-redis/              # Redis cho rate limit
│       ├── eg-platform/           # GatewayClass, EnvoyProxy, Gateway, ClientTrafficPolicy, TLS
│       ├── demo-portal/           # App 1
│       ├── demo-orders/           # App 2
│       └── demo-partner/          # App 3
├── scripts/
│   ├── 01-check-prereqs.sh        # Kiểm tra công cụ, cụm, LB Controller
│   ├── 02-cognito-setup.sh        # Tạo Cognito bằng AWS CLI
│   ├── 03-gen-values.sh           # Sinh values từ config/*.env
│   ├── 04-deploy.sh               # helm upgrade --install theo thứ tự
│   ├── 05-dns.sh                  # Route 53: *.gitlabonlinecom.click → NLB của Gateway
│   ├── get-token.sh               # Lấy token Cognito (user / máy) để test
│   ├── render-all.sh              # helm template ra rendered/*.yaml
│   ├── validate.sh                # helm lint + kiểm tra schema CRD
│   └── 99-cleanup.sh              # Gỡ demo
└── tests/run-tests.sh             # 48 test case tự động
```

## Môi trường đang cấu hình

| Mục | Giá trị | Cấu hình ở |
|---|---|---|
| Region | `ap-southeast-1` | `config/demo.env.example` (`AWS_REGION`) |
| Cụm EKS / VPC | `eks-cluster-ver1` / `vpc-0a7f2229b36e6ceb5` | `config/demo.env.example` (`EKS_CLUSTER_NAME`) |
| Subnet của NLB | `subnet-01e7b81b2c34fbaae`, `subnet-0729b4d3570c85035`, `subnet-063d005e791e4932f` (subnet của cụm EKS) | `config/demo.env.example` (`NLB_SUBNETS`), mặc định `envoyProxy.service.nlb.subnets` của `eg-platform` |
| Domain | `gitlabonlinecom.click` | `config/demo.env.example` (`DOMAIN`), mặc định `domain` của các chart |
| Cert public (ACM) | `arn:aws:acm:ap-southeast-1:609320954321:certificate/569f4470-6ac3-4ef2-be6e-7eb012397305` (`*.gitlabonlinecom.click`) | `config/demo.env.example` (`ACM_CERT_ARN`), mặc định `envoyProxy.service.nlb.acmCertArn` của `eg-platform` |
| App 1 – Portal | `https://portal.gitlabonlinecom.click` | |
| App 2 – Orders API | `https://api.gitlabonlinecom.click/orders` | |
| App 3 – Partner API | `https://partner.gitlabonlinecom.click/v1` | |
| Cognito Hosted UI | `https://gitlabonlinecom-eg-demo.auth.ap-southeast-1.amazoncognito.com` | `config/demo.env.example` (`COGNITO_DOMAIN_PREFIX`) |

NLB terminate TLS bằng cert ACM ở trên (chế độ `nlb-tls`), rồi mã hoá lại tới Envoy. Cert phải cùng **account** và **region** với cụm EKS; `scripts/01-check-prereqs.sh` kiểm tra điều này cùng với trạng thái `ISSUED` và việc cert phủ đủ 3 hostname.

## Bắt đầu nhanh

Đọc chi tiết từng bước trong `docs/`. Tóm tắt:

```bash
cp config/demo.env.example config/demo.env
```

```bash
./scripts/01-check-prereqs.sh
```

```bash
./scripts/02-cognito-setup.sh
```

```bash
./scripts/03-gen-values.sh
```

```bash
./scripts/04-deploy.sh eg
```

```bash
./scripts/04-deploy.sh platform
```

Tạo bản ghi DNS wildcard `*.gitlabonlinecom.click` trỏ về NLB:

```bash
./scripts/05-dns.sh
```

```bash
./scripts/04-deploy.sh apps
```

```bash
./tests/run-tests.sh
```

## Tài liệu

| # | Tài liệu | Nội dung |
|---|---|---|
| 00 | [Kiến trúc](docs/00-architecture.md) | Luồng request, thứ tự filter, mô hình resource, phân vai |
| 01 | [Chuẩn bị](docs/01-prerequisites.md) | Công cụ, EKS, AWS Load Balancer Controller, ACM, DNS |
| 02 | [AWS Cognito](docs/02-cognito.md) | User pool, group, app client, user test, token |
| 03 | [Cài Envoy Gateway](docs/03-install-envoy-gateway.md) | Redis + control plane + Global Rate Limit |
| 04 | [Platform](docs/04-platform.md) | GatewayClass, EnvoyProxy, Gateway, NLB, ClientTrafficPolicy |
| 05 | [App 1 – Portal](docs/05-app1-portal.md) | OIDC Cognito, phân quyền group, canary |
| 06 | [App 2 – Orders API](docs/06-app2-orders.md) | JWT, scope, rate limit theo user, resilience |
| 07 | [App 3 – Partner API](docs/07-app3-partner.md) | API key, gói rate limit, IP allowlist |
| 08 | [Test case](docs/08-testing.md) | Danh sách test, cách chạy, test bằng trình duyệt |
| 09 | [Vận hành & xử lý sự cố](docs/09-operations-troubleshooting.md) | Log, egctl, metrics, lỗi thường gặp, gỡ cài |
| 10 | [Bước tiếp theo: F5, Istio](docs/10-next-steps-f5-istio.md) | Gắn F5 phía trước, tích hợp Istio mesh |

Giải thích chi tiết từng khối `values.yaml` và template của từng chart:

| Phần | Chart / thư mục | Tài liệu |
|---|---|---|
| Control plane | `helm/envoy-gateway` (values cho chart chính thức `gateway-helm`) | [helm/envoy-gateway/README.md](helm/envoy-gateway/README.md) |
| Rate limit backend | `eg-redis` | [helm/charts/eg-redis/README.md](helm/charts/eg-redis/README.md) |
| Gateway + data plane | `eg-platform` | [helm/charts/eg-platform/README.md](helm/charts/eg-platform/README.md) |
| App 1 | `demo-portal` | [helm/charts/demo-portal/README.md](helm/charts/demo-portal/README.md) |
| App 2 | `demo-orders` | [helm/charts/demo-orders/README.md](helm/charts/demo-orders/README.md) |
| App 3 | `demo-partner` | [helm/charts/demo-partner/README.md](helm/charts/demo-partner/README.md) |

## Phiên bản đã dùng

| Thành phần | Phiên bản |
|---|---|
| Envoy Gateway (chart `oci://docker.io/envoyproxy/gateway-helm`) | v1.9.3 |
| Helm | ≥ 3.14 |
| Kubernetes (EKS) | ≥ 1.30 |
| podinfo (App 1) | 6.15.0 |
| go-httpbin (App 2, 3) | 2.25.0 |
| Redis (rate limit) | 7.4-alpine |
