# `helm/envoy-gateway` – Values cho chart chính thức Envoy Gateway (control plane)

Thư mục này **không phải một chart**. Nó chỉ chứa `values.yaml` dùng để cài chart chính thức của dự án Envoy Gateway:

```
oci://docker.io/envoyproxy/gateway-helm   phiên bản v1.9.3
```

Chart chính thức cài **control plane**: bộ controller theo dõi các resource Gateway API và CRD của Envoy Gateway, dịch chúng thành cấu hình Envoy, rồi đẩy xuống các Pod Envoy Proxy (data plane) do chart `eg-platform` khai báo.

| | |
|---|---|
| Namespace | `envoy-gateway-system` |
| Thứ tự cài | Sau `eg-redis`, trước `eg-platform` và các app |
| Mọi khoá trong `values.yaml` | Đã đối chiếu với `values.yaml` của `gateway-helm` v1.9.3 |

---

## 1. Chart chính thức cài những gì?

Kết quả `helm template` với `values.yaml` của repo:

| Kind | Tên | Vai trò |
|---|---|---|
| CRD (trong `crds/` của chart con) | `gateway.networking.k8s.io/*`, `gateway.envoyproxy.io/*` | Định nghĩa Gateway API (`Gateway`, `HTTPRoute`...) và CRD mở rộng (`EnvoyProxy`, `SecurityPolicy`, `BackendTrafficPolicy`, `ClientTrafficPolicy`...) |
| `Deployment` | `envoy-gateway` | **Controller**, 2 replica (một bản làm leader) |
| `Service` | `envoy-gateway` | Cổng 18000 (xDS cho Envoy), 18001 (xDS cho rate limit service), 18002 (Wasm), 19001 (metrics) |
| `ConfigMap` | `envoy-gateway-config` | Cấu hình của controller (kiểu `EnvoyGateway`), sinh từ khối `config.envoyGateway` |
| `Job` | `eg-gateway-helm-certgen` | Chạy một lần khi cài: sinh cert mTLS cho kênh xDS (Secret `envoy-gateway`, `envoy`, `envoy-rate-limit`) và **Secret HMAC `envoy-oidc-hmac`** dùng để ký cookie OIDC |
| `ServiceAccount`, `ClusterRole`, `Role` và các binding | | Quyền đọc Gateway API/CRD, quyền tạo Deployment/Service/HPA/PDB cho Envoy |
| `MutatingWebhookConfiguration` | topology injector | Gắn thông tin zone/node cho Pod Envoy (phục vụ định tuyến theo zone) |
| `ValidatingAdmissionPolicy` + binding | safe upgrade | Chặn cài đè CRD Gateway API bằng bản không tương thích |

Controller cũng **tự tạo** thêm khi chạy:

| Resource | Khi nào |
|---|---|
| `Deployment envoy-ratelimit` + Service | Khi `config.envoyGateway.rateLimit` được cấu hình (repo có cấu hình) |
| Deployment/Service/HPA/PDB của Envoy Proxy | Khi có `Gateway` thuộc GatewayClass của Envoy Gateway (chart `eg-platform`) |

---

## 2. Giải thích từng khối trong `values.yaml`

### 2.1 Controller: số replica và tài nguyên

```yaml
deployment:
  replicas: 2
  envoyGateway:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 1024Mi
```

Render ra `Deployment envoy-gateway`:

```yaml
spec:
  replicas: 2
  template:
    spec:
      containers:
        - name: envoy-gateway
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { memory: 1024Mi }
```

| Khoá | Ý nghĩa |
|---|---|
| `deployment.replicas: 2` | Hai Pod controller. Chỉ một Pod làm **leader** (ghi status, tạo resource cho Envoy); Pod kia chờ sẵn và lên thay nếu leader chết. Cả hai đều phục vụ xDS cho Envoy |
| `deployment.envoyGateway.resources` | Bộ nhớ của controller tăng theo số route/policy/Secret trong cluster. 256Mi–1Gi đủ cho demo và hệ thống vừa |

> **Khi controller ngừng hoạt động**, các Pod Envoy **vẫn chạy và phục vụ traffic** bằng cấu hình cuối cùng nhận được. Chỉ là thay đổi mới (route, policy) sẽ chưa được áp dụng cho tới khi controller chạy lại. Vì vậy control plane không nằm trên đường đi của request.

### 2.2 Cấu hình controller (`config.envoyGateway`)

Toàn bộ khối `config.envoyGateway` được chart đặt **nguyên văn** vào ConfigMap `envoy-gateway-config`, file `envoy-gateway.yaml`. Đây là cấu hình kiểu `EnvoyGateway` mà controller đọc khi khởi động.

Kết quả render:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyGateway
gateway:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
logging:
  level:
    default: info
provider:
  type: Kubernetes
  kubernetes:
    rateLimitDeployment:                          # chart tự thêm: image của rate limit service
      container:
        image: docker.io/envoyproxy/ratelimit:5ae0682e
    shutdownManager:
      image: docker.io/envoyproxy/gateway:v1.9.3
rateLimit:
  backend:
    type: Redis
    redis:
      url: redis.envoy-gateway-system.svc.cluster.local:6379
```

> Controller đọc ConfigMap này **khi khởi động**. Template Deployment của chart v1.9.3 **không** gắn checksum của ConfigMap, nên sau khi `helm upgrade` đổi khối `config`, Pod controller **không tự khởi động lại**. Hãy khởi động lại thủ công để chắc chắn cấu hình mới có hiệu lực:
>
> ```bash
> kubectl rollout restart deployment/envoy-gateway -n envoy-gateway-system
> ```

#### `gateway.controllerName`

```yaml
config:
  envoyGateway:
    gateway:
      controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

Tên định danh của controller. Controller chỉ quản lý các `GatewayClass` có `spec.controllerName` **trùng** giá trị này. GatewayClass `eg-demo` của chart `eg-platform` dùng đúng giá trị này. Nếu hai giá trị khác nhau, GatewayClass sẽ không bao giờ được `Accepted`.

Đổi tên này chỉ cần khi chạy **nhiều bản Envoy Gateway** trong cùng cluster (ví dụ một bản cho Gateway public, một bản cho Gateway nội bộ), mỗi bản quản lý GatewayClass riêng.

#### `provider.type`

```yaml
    provider:
      type: Kubernetes
```

Controller đọc resource từ Kubernetes API và tạo Pod Envoy trên Kubernetes. Đây là lựa chọn duy nhất phù hợp cho EKS.

#### `logging.level`

```yaml
    logging:
      level:
        default: info
```

Mức log của controller. Khi cần điều tra vì sao một policy không được áp dụng, tạm đặt `debug`:

```bash
helm upgrade eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.3 -n envoy-gateway-system -f helm/envoy-gateway/values.yaml --set config.envoyGateway.logging.level.default=debug
```

```bash
kubectl rollout restart deployment/envoy-gateway -n envoy-gateway-system
```

Log này là của **controller**, không phải access log của từng request. Access log của request nằm ở Pod Envoy Proxy (cấu hình trong chart `eg-platform`).

#### `rateLimit` – bật Global Rate Limit

```yaml
    rateLimit:
      backend:
        type: Redis
        redis:
          url: redis.envoy-gateway-system.svc.cluster.local:6379
```

| Trường | Ý nghĩa |
|---|---|
| `rateLimit` (có khối này) | Bật **Global Rate Limit**. Controller tự triển khai `Deployment envoy-ratelimit` và cấu hình filter `ratelimit` trong Envoy trỏ tới service này. Không có khối này thì `BackendTrafficPolicy` với `type: Global` không hoạt động |
| `backend.type: Redis` | Kiểu nơi lưu bộ đếm. Hiện Envoy Gateway hỗ trợ Redis |
| `backend.redis.url` | Địa chỉ Redis: `<service>.<namespace>.svc.cluster.local:<port>`, trỏ tới Service `redis` của chart `eg-redis`. Có thể là danh sách nhiều host cách nhau bởi dấu phẩy cho Redis Sentinel hoặc Cluster |

Các tuỳ chọn hữu ích khác (không bật trong demo, đã kiểm tra có trong API v1.9.3):

| Trường | Ý nghĩa |
|---|---|
| `rateLimit.failClosed: true` | Rate limit service hoặc Redis lỗi thì **chặn** request. Mặc định `false`: lỗi thì cho request đi qua (không có rate limit tạm thời) |
| `rateLimit.backend.redis.urlRef` | Đọc URL Redis từ Secret thay vì ghi thẳng vào values. Dùng khi URL có mật khẩu (ElastiCache AUTH) |
| `rateLimit.timeout` | Thời gian Envoy chờ rate limit service trả lời (mặc định 20ms) |
| `provider.kubernetes.rateLimitDeployment` | Tuỳ chỉnh Deployment `envoy-ratelimit` (số replica, tài nguyên) |
| `provider.kubernetes.rateLimitHpa`, `rateLimitPDB` | HPA và PDB cho rate limit service |

---

## 3. Các giá trị mặc định của chart **không** ghi đè

Repo chỉ ghi đè những gì cần thiết. Một số giá trị mặc định đáng biết của `gateway-helm` v1.9.3:

| Giá trị mặc định | Ý nghĩa |
|---|---|
| Image controller `docker.io/envoyproxy/gateway:v1.9.3` | Đúng phiên bản chart. Muốn dùng registry nội bộ (ECR), đặt `global.imageRegistry` |
| Image rate limit `docker.io/envoyproxy/ratelimit:5ae0682e` | Chart tự điền vào `rateLimitDeployment` |
| `securityContext` của controller | Non-root (65532), `readOnlyRootFilesystem`, `drop: ALL`, `seccompProfile: RuntimeDefault` |
| Probe | Startup và liveness `GET /healthz`, readiness `GET /readyz` cổng 8081 |
| Annotation Pod | `prometheus.io/scrape: "true"`, `prometheus.io/port: "19001"` |
| `topologyInjector.enabled: true` | Webhook gắn thông tin zone cho Pod Envoy |

Xem toàn bộ giá trị mặc định:

```bash
helm show values oci://docker.io/envoyproxy/gateway-helm --version v1.9.3
```

---

## 4. Cài đặt

Cài Redis trước (chart `eg-redis`), sau đó:

```bash
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.3 -n envoy-gateway-system -f helm/envoy-gateway/values.yaml --wait --timeout 5m
```

```bash
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
```

Hoặc cài cả Redis và Envoy Gateway:

```bash
./scripts/04-deploy.sh eg
```

Xem trước toàn bộ YAML (bao gồm CRD):

```bash
helm template eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.3 -n envoy-gateway-system -f helm/envoy-gateway/values.yaml --include-crds
```

## 5. Kiểm tra

```bash
kubectl get deploy,pod,job -n envoy-gateway-system
```

Kết quả mong đợi: `envoy-gateway` 2/2, `envoy-ratelimit` sẵn sàng, `redis` sẵn sàng.

Job `eg-gateway-helm-certgen` là Helm hook (`pre-install`, `pre-upgrade`) và có `ttlSecondsAfterFinished: 30`, nên Kubernetes **tự xoá job 30 giây sau khi chạy xong**. Không thấy job trong `kubectl get job` là bình thường. Bằng chứng job đã chạy thành công là các Secret nó tạo ra (kiểm tra bên dưới).

Cấu hình controller thực tế đang dùng:

```bash
kubectl get configmap envoy-gateway-config -n envoy-gateway-system -o jsonpath='{.data.envoy-gateway\.yaml}'
```

Secret do job `certgen` tạo:

```bash
kubectl get secret -n envoy-gateway-system envoy-gateway envoy envoy-rate-limit envoy-oidc-hmac
```

Thiếu `envoy-oidc-hmac` thì `SecurityPolicy` có OIDC (App 1) sẽ báo `HMAC secret not found`.

CRD đã có:

```bash
kubectl get crd | grep -E "gateway.networking.k8s.io|gateway.envoyproxy.io"
```

Log của controller (lỗi dịch cấu hình, lỗi đọc OIDC discovery, Secret thiếu):

```bash
kubectl logs -n envoy-gateway-system deploy/envoy-gateway --tail=50
```

## 6. Nâng cấp

1. Đọc release notes của phiên bản mới.
2. **Cập nhật CRD trước.** `helm upgrade` **không** nâng cấp CRD nằm trong thư mục `crds/`. Dùng chart riêng cho CRD:
   ```bash
   helm upgrade --install eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version <phiên bản mới> -n envoy-gateway-system
   ```
   Hoặc render rồi apply:
   ```bash
   helm template eg oci://docker.io/envoyproxy/gateway-helm --version <phiên bản mới> --include-crds | kubectl apply --server-side -f -
   ```
3. Nâng cấp control plane: `helm upgrade` với `--version <phiên bản mới>`.
4. Đổi `EG_VERSION` trong `config/demo.env`.
5. Chạy lại `tests/run-tests.sh`.

## 7. Lỗi thường gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `helm install` báo xung đột CRD | Cluster đã có Gateway API CRD (từ Istio hoặc controller khác) | Xem `docs/03-install-envoy-gateway.md` mục 6 |
| GatewayClass mãi không `Accepted` | `controllerName` trong values khác `GatewayClass.spec.controllerName` | Đồng bộ hai giá trị |
| `BackendTrafficPolicy` có rate limit `Global` báo lỗi | Thiếu khối `config.envoyGateway.rateLimit` | Thêm khối `rateLimit` và `helm upgrade` |
| Không có Deployment `envoy-ratelimit` | Như trên | Như trên |
| `SecurityPolicy` OIDC báo `HMAC secret not found` | Job `certgen` lỗi, hoặc Secret bị xoá | Chạy lại `helm upgrade eg ...` (job là hook `pre-upgrade` nên sẽ chạy lại và tạo Secret). Muốn xem log của job, chạy `kubectl logs -n envoy-gateway-system job/eg-gateway-helm-certgen -f` **ngay** trong lúc upgrade, vì job bị xoá sau 30 giây |
| Đổi `config` nhưng không có tác dụng | Controller chưa khởi động lại | `kubectl rollout restart deploy/envoy-gateway -n envoy-gateway-system` |
| Không kéo được image (cluster không ra Internet) | Image nằm trên Docker Hub | Mirror sang ECR và đặt `global.imageRegistry` |
