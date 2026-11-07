# Chart `eg-redis` – Redis lưu bộ đếm Global Rate Limit

Chart nhỏ nhất trong repo: một Redis duy nhất để **rate limit service** của Envoy Gateway lưu bộ đếm. Tài liệu giải thích vai trò của Redis, từng dòng cấu hình và cách thay bằng dịch vụ có quản lý khi lên production.

| | |
|---|---|
| Namespace | `envoy-gateway-system` (cùng namespace với control plane) |
| Image | `docker.io/library/redis:7.4-alpine` |
| Cài | **Trước** chart Envoy Gateway (`gateway-helm`) |
| Dùng cho | Demo, thử nghiệm. **Không dùng cho production** (xem mục 5) |

---

## 1. Vì sao cần Redis?

Repo dùng rate limit kiểu **Global** cho cả 3 app (`type: Global` trong `BackendTrafficPolicy`):

```
                ┌────────── Pod Envoy 1 ─┐
Request ──NLB──►│ filter ratelimit       │──┐
                └────────────────────────┘  │  gRPC: "user X còn được gọi không?"
                ┌────────── Pod Envoy 2 ─┐  ├────────────► envoy-ratelimit ──► Redis
Request ──NLB──►│ filter ratelimit       │──┘               (rate limit        (bộ đếm
                └────────────────────────┘                   service)           theo phút)
```

| Kiểu | Bộ đếm nằm ở | Ví dụ giới hạn 30 request/phút, có 3 Pod Envoy |
|---|---|---|
| `Local` | Bộ nhớ của **từng** Pod Envoy | Mỗi Pod cho 30 → thực tế khoảng 90/phút, và thay đổi theo số Pod (HPA) |
| `Global` | **Redis** dùng chung | Đúng 30/phút dù có 2 hay 6 Pod Envoy |

Rate limit theo user (App 2) và theo gói đối tác (App 3) cần con số chính xác, nên phải dùng `Global`, và do đó cần Redis.

Các thành phần liên quan:

| Thành phần | Do ai tạo | Vai trò |
|---|---|---|
| Redis (chart này) | `eg-redis` | Lưu bộ đếm |
| `envoy-ratelimit` Deployment | Envoy Gateway **tự tạo** khi có `config.envoyGateway.rateLimit` | Nhận câu hỏi từ Envoy, tăng/đọc bộ đếm trong Redis, trả lời cho phép hay `429` |
| Filter `ratelimit` trong Envoy | Envoy Gateway sinh từ `BackendTrafficPolicy` | Hỏi rate limit service trước khi chuyển request vào backend |

Liên kết giữa Redis và Envoy Gateway nằm ở `helm/envoy-gateway/values.yaml`:

```yaml
config:
  envoyGateway:
    rateLimit:
      backend:
        type: Redis
        redis:
          url: redis.envoy-gateway-system.svc.cluster.local:6379
```

URL này là tên DNS của Service `redis` mà chart này tạo: `<service>.<namespace>.svc.cluster.local:<port>`.

---

## 2. Cấu trúc chart

```
eg-redis/
├── Chart.yaml
├── values.yaml
└── templates/
    └── redis.yaml          # Deployment + Service "redis"
```

| Kind | Tên | Ghi chú |
|---|---|---|
| `Deployment` | `redis` | 1 replica |
| `Service` | `redis` | ClusterIP, cổng 6379. Tên Service phải khớp URL trong values của Envoy Gateway |

---

## 3. Giải thích `values.yaml`

```yaml
image:
  repository: docker.io/library/redis
  tag: 7.4-alpine
  pullPolicy: IfNotPresent

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    memory: 256Mi
```

| Khoá | Ý nghĩa |
|---|---|
| `image.repository`, `image.tag` | Redis 7.4 bản Alpine (nhỏ gọn). Có thể đổi sang Valkey (`docker.io/valkey/valkey`), tương thích giao thức Redis |
| `image.pullPolicy` | `IfNotPresent`: chỉ tải image khi node chưa có |
| `resources` | Bộ đếm rate limit rất nhỏ (mỗi user/đối tác một key, tự hết hạn sau mỗi phút), nên 64Mi là đủ cho demo. Giới hạn 256Mi để Redis lỗi không chiếm hết RAM của node |

## 4. Giải thích template `redis.yaml`

Các thiết lập cố định trong template (không có trong values):

```yaml
spec:
  replicas: 1
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999                 # user "redis" có sẵn trong image chính thức
        fsGroup: 999
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: redis
          args: ["--save", "", "--appendonly", "no"]
          readinessProbe:
            tcpSocket:
              port: redis
          livenessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir: {}
```

| Thiết lập | Ý nghĩa |
|---|---|
| `replicas: 1` | Một Redis duy nhất, không có bản sao |
| `--save ""` | Tắt ghi snapshot (RDB) xuống đĩa |
| `--appendonly no` | Tắt ghi log thao tác (AOF) |
| `emptyDir` | Thư mục dữ liệu tạm, mất khi Pod bị xoá |
| `readinessProbe tcpSocket` | Service chỉ gửi kết nối khi Redis đã mở cổng 6379 |
| `livenessProbe redis-cli ping` | Redis treo (không trả lời `PONG`) thì Kubernetes khởi động lại |
| `runAsUser: 999`, `drop: ALL` | Chạy không phải root, bỏ mọi Linux capability |

**Vì sao không cần lưu dữ liệu?** Bộ đếm rate limit chỉ có ý nghĩa trong cửa sổ thời gian ngắn (1 phút). Redis khởi động lại thì mọi bộ đếm về 0, và hậu quả duy nhất là trong phút đó người dùng được gọi thêm một lượt hạn mức. Không lưu xuống đĩa giúp Redis nhẹ và nhanh hơn.

**Khi Redis ngừng hoạt động thì sao?** Rate limit service không đọc/ghi được bộ đếm. Mặc định của Envoy Gateway là **fail-open**: request **vẫn được cho qua** (không bị chặn), chỉ tạm thời không có rate limit. Hệ thống không sập vì Redis, nhưng cũng mất lớp bảo vệ trong thời gian đó.

Muốn ngược lại (**fail-closed**: rate limit lỗi thì chặn request), đặt trong `helm/envoy-gateway/values.yaml`:

```yaml
config:
  envoyGateway:
    rateLimit:
      failClosed: true
```

Chỉ nên bật khi Redis có sẵn sàng cao (ElastiCache Multi-AZ), vì khi đó sự cố Redis sẽ làm **mọi** route có rate limit trả lỗi.

## 5. Dùng cho production

Chart này cố ý đơn giản cho demo. Production nên thay bằng **Amazon ElastiCache** (Redis OSS hoặc Valkey):

| Hạng mục | Chart demo | Production khuyến nghị |
|---|---|---|
| Sẵn sàng cao | 1 Pod | ElastiCache Multi-AZ, có replica và tự failover |
| Mã hoá đường truyền | Không | Bật TLS (in-transit encryption) |
| Xác thực | Không | Bật AUTH token hoặc RBAC user |
| Vận hành | Tự quản | AWS quản lý vá lỗi, backup, giám sát |

Khi dùng ElastiCache:

1. Không cài chart `eg-redis`.
2. Sửa `helm/envoy-gateway/values.yaml`, trỏ URL tới endpoint ElastiCache. Để không ghi mật khẩu vào values, dùng `redis.urlRef` để đọc URL từ một Secret, và cấu hình TLS cho Redis theo tài liệu Envoy Gateway đúng phiên bản.
3. Mở Security Group của ElastiCache cho Pod `envoy-ratelimit` (cổng 6379).

## 6. Cài đặt

```bash
helm upgrade --install eg-redis helm/charts/eg-redis -n envoy-gateway-system --create-namespace --wait
```

Cài **trước** Envoy Gateway để rate limit service kết nối được Redis ngay khi khởi động. Nếu cài sau, `envoy-ratelimit` sẽ báo lỗi kết nối cho tới khi Redis sẵn sàng rồi tự kết nối lại.

## 7. Kiểm tra

```bash
kubectl get deploy,svc,pod -n envoy-gateway-system -l app.kubernetes.io/name=redis
```

```bash
kubectl exec -n envoy-gateway-system deploy/redis -- redis-cli ping
```

Kết quả mong đợi: `PONG`.

Sau khi đã có traffic đi qua các route có rate limit, Redis sẽ có key do rate limit service tạo:

```bash
kubectl exec -n envoy-gateway-system deploy/redis -- redis-cli --scan | head
```

Rate limit service kết nối Redis bình thường (không có lỗi kết nối trong log):

```bash
kubectl logs -n envoy-gateway-system deploy/envoy-ratelimit --tail=20
```

## 8. Lỗi thường gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| Không bao giờ thấy `429` | Redis không chạy, hoặc URL trong values của Envoy Gateway sai | `redis-cli ping`; so URL với `<service>.<namespace>.svc.cluster.local:6379` |
| `envoy-ratelimit` log lỗi kết nối Redis | Cài Redis sau Envoy Gateway, hoặc đổi tên Service/namespace | Cài Redis trước; giữ tên Service `redis` trong `envoy-gateway-system` |
| Pod Redis bị `OOMKilled` | Quá nhiều key (rất nhiều user/IP khác nhau) | Tăng `resources.limits.memory`, hoặc chuyển sang ElastiCache |
| Hạn mức "reset" bất thường | Pod Redis bị khởi động lại (dữ liệu không lưu xuống đĩa) | Hành vi chấp nhận được trong demo; production dùng ElastiCache |
