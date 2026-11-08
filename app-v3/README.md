# App v3: định tuyến L7 theo domain bằng Envoy, thẳng tới Pod

Ba website, mỗi website một domain riêng. Envoy (data plane của Envoy Gateway) đọc **Host header** của request HTTP (Layer 7) để chọn website, rồi chọn **một Pod** và gửi thẳng tới IP của Pod đó. Triển khai từng bước bằng `kubectl` + `helm`, không dùng script.

| Domain | Website | Số Pod | Envoy chọn Pod theo |
|---|---|---|---|
| `blog.gitlabonlinecom.click` | blog | 3 | `RoundRobin`: lần lượt từng Pod |
| `docs.gitlabonlinecom.click` | docs | 2 | `ConsistentHash` theo header `x-user`: cùng user luôn vào cùng Pod |
| `status.gitlabonlinecom.click`, `health.gitlabonlinecom.click` | status | 1 | `LeastRequest` (một app phục vụ hai domain) |

## 1. Request đi như thế nào

```
 curl https://blog.gitlabonlinecom.click/hello
   │  DNS *.gitlabonlinecom.click → NLB
   ▼
 NLB (TLS terminate bằng cert ACM, L4)         ← chưa biết domain/path, chỉ chuyển tiếp TCP
   │
   ▼
 Pod Envoy (namespace envoy-gateway-system)    ← LAYER 7
   ① listener 10443 nhận HTTP, đọc  Host: blog.gitlabonlinecom.click
   ② route_config → virtual_host "blog.gitlabonlinecom.click" → route PathPrefix /
   ③ cluster httproute/web-v3/blog/rule/0 = danh sách IP Pod blog (lấy từ EndpointSlice)
   ④ thuật toán RoundRobin chọn 1 Pod, mở kết nối TCP tới  10.x.x.x:8080
   ▼
 Pod blog-xxxx (namespace web-v3)              ← nhận request, trả về tên Pod/IP Pod đã xử lý
```

Điểm chính:

- **Định tuyến theo domain là việc của L7.** NLB (L4) chỉ thấy IP và cổng, không đọc được Host. Envoy giải mã HTTP nên đọc được Host, path, header, rồi mới quyết định.
- **Envoy gửi thẳng tới IP Pod**, không qua ClusterIP của Service và không qua kube-proxy/iptables. Service chỉ dùng để Envoy Gateway biết danh sách Pod (EndpointSlice). Nhờ vậy Envoy tự chọn Pod theo thuật toán (RoundRobin, ConsistentHash…), tự loại Pod lỗi, và giữ kết nối lâu dài tới từng Pod.
- Thêm hay bớt Pod: Envoy Gateway cập nhật danh sách endpoint cho Envoy trong vài giây, không cần restart.

## 2. Cấu trúc thư mục

```
app-v3/
├── README.md                       # guide này
└── web-domains/                    # Helm chart
    ├── Chart.yaml
    ├── values.yaml                 # danh sách website (sites)
    ├── app/web_app.py              # web server Python: trả tên Pod, IP Pod, node, Host...
    └── templates/
        ├── configmap.yaml          # code web_app.py
        └── sites.yaml              # mỗi site: Deployment + Service + HTTPRoute + BackendTrafficPolicy
```

### values.yaml

```yaml
sites:
  - name: blog
    hosts: [blog]                # → blog.<domain>
    replicas: 3
    loadBalancer:
      type: RoundRobin
  - name: docs
    hosts: [docs]
    replicas: 2
    loadBalancer:
      type: ConsistentHash
      consistentHash:
        type: Header
        header: { name: x-user }
  - name: status
    hosts: [status, health]      # một HTTPRoute, hai domain
    replicas: 1
    loadBalancer:
      type: LeastRequest
```

| Key | Ý nghĩa |
|---|---|
| `domain` | Domain gốc, ghép với `hosts` thành tên miền đầy đủ |
| `gateway.*` | Gateway `eg-gateway`, listener `https` |
| `sites[].name` | Tên Deployment, Service, HTTPRoute |
| `sites[].hosts` | Danh sách subdomain của site (→ `spec.hostnames` của HTTPRoute) |
| `sites[].replicas` | Số Pod |
| `sites[].message` / `color` | Nội dung hiển thị trên trang |
| `sites[].loadBalancer` | Chép nguyên vào `BackendTrafficPolicy.spec.loadBalancer` |

### Mỗi site tạo ra

| Resource | Vai trò |
|---|---|
| Deployment `<name>` | Pod chạy `web_app.py`. Tên Pod, IP Pod, node được đưa vào qua Downward API. Pod được rải sang nhiều node |
| Service `<name>` (port 80 → 8080) | Chỉ để Envoy Gateway lấy danh sách IP Pod. Envoy kết nối thẳng `IP Pod:8080` |
| HTTPRoute `<name>` | `hostnames` = các domain của site, rule `PathPrefix /`, thêm header `X-Served-By-Route` |
| BackendTrafficPolicy `<name>-lb` | Thuật toán chọn Pod + passive health check (Pod trả 5xx liên tiếp 3 lần bị loại 30s) |

Response của app có header `X-App` và `X-Pod-Name`. Body JSON có `pod`, `pod_ip`, `node`, `host`, `client_ip`, `request_id`, và `peer` (IP của Pod Envoy đã kết nối tới, chứng minh request đến từ Envoy chứ không phải ClusterIP).

## 3. Chuẩn bị

Đã có: Gateway `eg-gateway` `Programmed`, DNS wildcard `*.gitlabonlinecom.click` → NLB, cert ACM wildcard. Các domain `blog`, `docs`, `status`, `health` dùng luôn bản ghi wildcard, không cần tạo DNS mới.

```bash
cd envoy-gateway-service-mesh
```

```bash
kubectl get gateway -n eg-gateway eg-gateway
```

```bash
dig +short blog.gitlabonlinecom.click
```

## 4. Tạo namespace

```bash
kubectl create namespace web-v3
```

Cho phép namespace gắn HTTPRoute vào listener `https` của Gateway:

```bash
kubectl label namespace web-v3 gateway.demo.io/attach=true
```

## 5. Xem trước manifest

```bash
helm lint app-v3/web-domains
```

```bash
helm template web-domains app-v3/web-domains -n web-v3 > /tmp/web-domains.yaml
```

```bash
grep -E "^kind:|^  name:" /tmp/web-domains.yaml | paste - -
```

Mong đợi 13 resource: 1 ConfigMap, và mỗi site (blog, docs, status) gồm Deployment, Service, HTTPRoute, BackendTrafficPolicy.

Xem phần định tuyến của một site:

```bash
grep -A22 "^kind: HTTPRoute" /tmp/web-domains.yaml | sed -n '1,24p'
```

Cho API server kiểm tra mà không tạo gì:

```bash
kubectl apply --dry-run=server -f /tmp/web-domains.yaml
```

## 6. Triển khai

Chọn **một** cách.

**Cách A: Helm quản lý release** (khuyến nghị):

```bash
helm upgrade --install web-domains app-v3/web-domains -n web-v3 --wait
```

**Cách B: chỉ dùng kubectl** với file đã render:

```bash
kubectl apply -f /tmp/web-domains.yaml
```

```bash
kubectl rollout status deploy/blog -n web-v3
```

## 7. Kiểm tra trạng thái

```bash
kubectl get pods -n web-v3 -o wide
```

Mong đợi 6 Pod `Running` (3 blog, 2 docs, 1 status), cột `IP` là IP Pod và cột `NODE` là node đang chạy.

```bash
kubectl get httproute -n web-v3 -o custom-columns='NAME:.metadata.name,HOSTS:.spec.hostnames,ACCEPTED:.status.parents[0].conditions[?(@.type=="Accepted")].status,REFS:.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status'
```

```bash
kubectl get backendtrafficpolicy -n web-v3 -o custom-columns='NAME:.metadata.name,LB:.spec.loadBalancer.type,STATUS:.status.ancestors[0].conditions[0].reason'
```

Mong đợi `ACCEPTED=True`, `REFS=True`, policy `Accepted`.

## 8. Test định tuyến theo domain

**Mỗi domain vào đúng app**:

```bash
curl -s https://blog.gitlabonlinecom.click/ | jq '{app, host, pod, pod_ip}'
```

```bash
curl -s https://docs.gitlabonlinecom.click/ | jq '{app, host, pod, pod_ip}'
```

```bash
curl -s https://status.gitlabonlinecom.click/ | jq '{app, host, pod, pod_ip}'
```

**Hai domain cùng vào một app** (`status` và `health`, mong đợi cùng `app: status`, khác `host`):

```bash
curl -s https://health.gitlabonlinecom.click/ | jq '{app, host, pod}'
```

**Domain không có HTTPRoute**: Envoy trả 404, không tới Pod nào:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://nothing.gitlabonlinecom.click/
```

**Envoy quyết định theo Host header, không theo địa chỉ đã kết nối.** Kết nối tới `blog...` (DNS, TLS đều là blog) nhưng gửi `Host: docs...`, mong đợi `"app": "docs"`:

```bash
curl -s -H 'Host: docs.gitlabonlinecom.click' https://blog.gitlabonlinecom.click/ | jq '{app, host}'
```

**Mở bằng trình duyệt**: https://blog.gitlabonlinecom.click. Nhấn F5 vài lần: dòng `pod` đổi theo vòng RoundRobin.

## 9. Chứng minh Envoy gửi thẳng tới IP Pod

### 9.1. So IP Pod với response

Danh sách IP Pod blog:

```bash
kubectl get pods -n web-v3 -l app=blog -o custom-columns='POD:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName'
```

Gửi 9 request và đếm Pod nào trả lời (mong đợi cả 3 Pod đều xuất hiện, số lần gần đều nhau; mỗi Pod Envoy có vòng RoundRobin riêng nên không luôn đúng 3-3-3):

```bash
for i in $(seq 1 9); do curl -s https://blog.gitlabonlinecom.click/ | jq -r '.pod + "  " + .pod_ip'; done | sort | uniq -c
```

### 9.2. Request đến từ IP của Pod Envoy, không phải ClusterIP

```bash
curl -s https://blog.gitlabonlinecom.click/ | jq -r .peer
```

```bash
kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -o custom-columns='POD:.metadata.name,IP:.status.podIP'
```

`peer` trùng IP một Pod Envoy. ClusterIP của Service blog (`kubectl get svc -n web-v3 blog`) không xuất hiện trong đường đi.

### 9.3. Xem danh sách endpoint bên trong Envoy

Mở cổng admin của một Pod Envoy (terminal 1, để nguyên):

```bash
kubectl port-forward -n envoy-gateway-system "$(kubectl get pod -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -o name | head -1)" 19000:19000
```

Terminal 2: các endpoint Envoy đang dùng cho site blog:

```bash
curl -s localhost:19000/clusters | grep "web-v3/blog" | grep -E "health_flags|rq_total"
```

Kết quả mẫu:

```
httproute/web-v3/blog/rule/0::10.0.1.23:8080::health_flags::healthy
httproute/web-v3/blog/rule/0::10.0.1.23:8080::rq_total::3
httproute/web-v3/blog/rule/0::10.0.2.41:8080::health_flags::healthy
httproute/web-v3/blog/rule/0::10.0.2.41:8080::rq_total::3
httproute/web-v3/blog/rule/0::10.0.3.17:8080::health_flags::healthy
httproute/web-v3/blog/rule/0::10.0.3.17:8080::rq_total::3
```

Đây chính là IP Pod ở mục 9.1, cổng 8080 (targetPort), kèm số request mỗi Pod đã nhận.

Virtual host theo domain trong route config của Envoy:

```bash
curl -s "localhost:19000/config_dump?resource=dynamic_route_configs" | jq -r '.configs[].route_config.virtual_hosts[]? | select(any(.domains[]; test("blog|docs|status|health"))) | .name + "  ->  " + (.domains | join(", "))'
```

### 9.4. Envoy cập nhật endpoint khi scale

```bash
kubectl scale deploy/blog -n web-v3 --replicas=5
```

Sau vài giây, chạy lại lệnh `/clusters` ở mục 9.3: có 5 endpoint. Xoá một Pod:

```bash
kubectl delete pod -n web-v3 "$(kubectl get pod -n web-v3 -l app=blog -o jsonpath='{.items[0].metadata.name}')"
```

IP cũ biến mất khỏi `/clusters`, IP Pod mới xuất hiện. Không cần restart Envoy, không request nào phải chờ kube-proxy cập nhật iptables. Trả lại 3 Pod:

```bash
kubectl scale deploy/blog -n web-v3 --replicas=3
```

## 10. Test thuật toán chọn Pod

**docs: ConsistentHash theo `x-user`.** User `alice` gửi 5 lần, luôn cùng một Pod:

```bash
for i in $(seq 1 5); do curl -s -H 'x-user: alice' https://docs.gitlabonlinecom.click/ | jq -r .pod; done | sort | uniq -c
```

Thử các user khác nhau, mỗi user dính vào một Pod cố định (có thể trùng Pod với user khác):

```bash
for u in alice bob carol dave erin; do printf '%-6s ' "$u"; curl -s -H "x-user: $u" https://docs.gitlabonlinecom.click/ | jq -r .pod; done
```

Không gửi `x-user`: Envoy không có giá trị để băm, chọn Pod ngẫu nhiên:

```bash
for i in $(seq 1 6); do curl -s https://docs.gitlabonlinecom.click/ | jq -r .pod; done | sort | uniq -c
```

**blog: RoundRobin**: xem mục 9.1.

**Đổi thuật toán**: sửa `loadBalancer.type` của blog trong `app-v3/web-domains/values.yaml` (vd `Random`), rồi áp dụng:

```bash
helm upgrade --install web-domains app-v3/web-domains -n web-v3 --wait
```

```bash
kubectl get backendtrafficpolicy -n web-v3 blog-lb -o jsonpath='{.spec.loadBalancer.type}{"\n"}'
```

> Không dùng `--set sites[0]...`: Helm thay **cả danh sách** `sites` bằng phần tử đó, làm mất các site còn lại.

## 11. Thêm một website mới

Ví dụ `shop2.gitlabonlinecom.click`: thêm vào `sites` trong `app-v3/web-domains/values.yaml`:

```yaml
  - name: shop2
    hosts: [shop2]
    replicas: 2
    message: "Shop 2"
    color: "#9333ea"
    loadBalancer:
      type: RoundRobin
```

Xem trước rồi áp dụng:

```bash
helm template web-domains app-v3/web-domains -n web-v3 | grep -A5 "name: shop2" | head -20
```

```bash
helm upgrade --install web-domains app-v3/web-domains -n web-v3 --wait
```

```bash
curl -s https://shop2.gitlabonlinecom.click/ | jq '{app, pod}'
```

Không cần tạo DNS hay cert mới vì wildcard đã phủ. Cách B: render lại `/tmp/web-domains.yaml` rồi `kubectl apply -f`.

## 12. Xử lý sự cố

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| 404 với domain của site | HTTPRoute chưa được nhận, hoặc sai domain | Mục 7; `Accepted=False` `NotAllowedByListeners` → thiếu label namespace |
| 503 `no healthy upstream` | Pod chưa Ready | `kubectl get pods -n web-v3`; `kubectl describe pod` |
| Không phân giải được domain | DNS wildcard chưa trỏ NLB, hoặc domain trùng bản ghi cụ thể khác (vd trỏ ALB GitLab) | `dig +short <domain>`; tránh trùng tên với `gitlab`, `jenkins`, `nexus`, `grafana`… |
| Lỗi cert trên trình duyệt | Domain không thuộc `*.gitlabonlinecom.click` (vd `a.b.gitlabonlinecom.click`) | Wildcard chỉ phủ một cấp subdomain |
| docs không dính Pod | Không gửi header `x-user`, hoặc proxy phía trước xoá header | Kiểm tra `jq .user` trong response |
| RoundRobin không đều | Có nhiều Pod Envoy, mỗi Pod có vòng RoundRobin riêng | Bình thường, phân bố đều khi nhiều request |
| `/clusters` không có `web-v3` | Port-forward nhầm Pod Envoy của Gateway khác | Dùng label `owning-gateway-name=eg-gateway` |

## 13. Gỡ

Cách A:

```bash
helm uninstall web-domains -n web-v3
```

Cách B:

```bash
kubectl delete -f /tmp/web-domains.yaml
```

```bash
kubectl delete namespace web-v3
```
