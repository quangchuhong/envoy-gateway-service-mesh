# 03 – Cài Envoy Gateway (control plane)

## 1. Thành phần được cài

| Thành phần | Namespace | Nguồn |
|---|---|---|
| Redis (lưu bộ đếm rate limit) | `envoy-gateway-system` | Chart `helm/charts/eg-redis` |
| CRD Gateway API + CRD Envoy Gateway | cluster | Chart chính thức `gateway-helm` v1.9.3 |
| Envoy Gateway controller (2 replica) | `envoy-gateway-system` | Chart chính thức |
| Rate limit service (`envoy-ratelimit`) | `envoy-gateway-system` | Envoy Gateway **tự tạo** khi bật `rateLimit` |
| Job `certgen` | `envoy-gateway-system` | Sinh cert cho xDS (mTLS control plane ↔ Envoy) và secret HMAC `envoy-oidc-hmac` dùng cho OIDC |

## 2. Cấu hình (`helm/envoy-gateway/values.yaml`)

```yaml
deployment:
  replicas: 2                      # control plane HA, có leader election
config:
  envoyGateway:
    rateLimit:                     # bật Global Rate Limit
      backend:
        type: Redis
        redis:
          url: redis.envoy-gateway-system.svc.cluster.local:6379
```

Mọi khoá đã được đối chiếu với `values.yaml` của `gateway-helm` v1.9.3 và với mã nguồn kiểu `EnvoyGateway` của phiên bản đó.

> **Production**: thay Redis trong cụm bằng **Amazon ElastiCache (Redis/Valkey)** Multi-AZ có TLS + AUTH. Envoy Gateway hỗ trợ `redis.urlRef` để đọc URL từ Secret và cấu hình TLS cho Redis.

## 3. Cài đặt

Bước 1, Redis (cài trước để rate limit service kết nối được ngay khi khởi động):

```bash
helm upgrade --install eg-redis helm/charts/eg-redis -n envoy-gateway-system --create-namespace --wait
```

Bước 2, Envoy Gateway:

```bash
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.3 -n envoy-gateway-system -f helm/envoy-gateway/values.yaml --wait --timeout 5m
```

Hoặc chạy cả hai bằng:

```bash
./scripts/04-deploy.sh eg
```

## 4. Kiểm tra

```bash
kubectl get pods -n envoy-gateway-system
```

Kết quả mong đợi: `envoy-gateway-xxx` (2 Pod), `envoy-ratelimit-xxx`, `redis-xxx` đều `Running`, và job `eg-gateway-helm-certgen` ở trạng thái `Completed`.

```bash
kubectl get crd | grep -E "gateway.networking.k8s.io|gateway.envoyproxy.io"
```

```bash
kubectl get secret -n envoy-gateway-system envoy-oidc-hmac
```

Secret `envoy-oidc-hmac` phải tồn tại. Thiếu nó, `SecurityPolicy` có OIDC sẽ báo `HMAC secret not found`.

```bash
kubectl logs -n envoy-gateway-system deploy/envoy-ratelimit --tail=20
```

Log không được có lỗi kết nối Redis.

## 5. Dùng `helm template` thay cho `helm install`

Muốn xem trước hoặc đưa vào repo GitOps (ArgoCD/Flux):

```bash
helm template eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.3 -n envoy-gateway-system -f helm/envoy-gateway/values.yaml --include-crds > rendered/envoy-gateway.yaml
```

Nếu apply file này bằng `kubectl`, phải dùng **server-side apply**, vì CRD rất lớn:

```bash
kubectl apply --server-side -f rendered/envoy-gateway.yaml
```

## 6. Cụm đã có Gateway API CRD

Nếu cụm đã có CRD Gateway API (ví dụ cài kèm Istio hoặc một controller khác), chart sẽ cố cài bản đi kèm (bundle của v1.9.3) và có thể xung đột:

- Xem phiên bản đang có:
  ```bash
  kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'
  ```
- Nếu CRD đang có **cũ hơn** bản đi kèm Envoy Gateway: cho chart nâng cấp, sau đó kiểm tra lại controller khác vẫn chạy bình thường.
- Nếu không muốn chart động vào CRD Gateway API: cài thêm `--skip-crds`, rồi tự cài CRD của Envoy Gateway (`gateway.envoyproxy.io`) bằng chart `gateway-crds-helm` cùng phiên bản.

## 7. Nâng cấp sau này

1. Đọc release notes của phiên bản mới.
2. Cập nhật CRD trước (Helm **không** tự nâng cấp CRD khi `helm upgrade`), dùng `helm template ... --include-crds` rồi `kubectl apply --server-side`, hoặc dùng chart `gateway-crds-helm`.
3. `helm upgrade` control plane.
4. Chạy lại `tests/run-tests.sh`.
