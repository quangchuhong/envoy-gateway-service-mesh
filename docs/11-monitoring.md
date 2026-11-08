# 11. Monitoring: Prometheus + Grafana (dùng chung ALB của GitLab)

Mục tiêu: thu thập metrics của Envoy Gateway (cổng `19001`) bằng Prometheus và xem dashboard chính thức của Envoy Gateway trên Grafana tại `https://grafana.gitlabonlinecom.click`. Grafana **không tạo ALB mới**: Ingress của Grafana gia nhập Ingress group của GitLab nên AWS Load Balancer Controller chỉ thêm một rule theo host vào ALB đang chạy.

## 1. Kiến trúc

```
                         Route 53
   grafana.gitlabonlinecom.click ──► ALB của GitLab (đang có) ──host: grafana.*──► Service monitoring-grafana :80
   gitlab.<...>                   ──►        (cùng ALB)       ──host: gitlab.*──►  GitLab (giữ nguyên)
   *.gitlabonlinecom.click        ──► NLB của Envoy Gateway  (portal / orders / partner)

   Namespace monitoring
   ├── Prometheus Operator ── đọc PodMonitor/ServiceMonitor ──► cấu hình Prometheus
   ├── Prometheus  ── scrape ──► envoy-gateway-system
   │                              ├── Pod Envoy Proxy      :19001 /stats/prometheus   (PodMonitor envoy-proxy)
   │                              ├── envoy-gateway        :19001 /metrics            (ServiceMonitor envoy-gateway-controller)
   │                              └── envoy-ratelimit      :19001 /metrics            (PodMonitor envoy-ratelimit)
   └── Grafana  ── sidecar nạp ConfigMap label grafana_dashboard=1 ──► thư mục "Envoy Gateway"
```

Bản ghi cụ thể `grafana.<DOMAIN>` được Route 53 ưu tiên hơn wildcard `*.<DOMAIN>` (đang trỏ NLB Envoy), nên hai bên không đụng nhau.

| Thành phần | Nguồn | Ghi chú |
|---|---|---|
| kube-prometheus-stack `92.12.0` | `oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack` | Prometheus Operator, Prometheus, Grafana, node-exporter, kube-state-metrics |
| Values chung | `helm/monitoring/kube-prometheus-stack-values.yaml` | Tắt Alertmanager và các target control plane EKS không scrape được |
| Values Ingress (sinh tự động) | `helm/values/generated/monitoring-ingress.yaml` | Chép annotation cấp ALB từ Ingress GitLab (gitignored) |
| Chart `eg-monitoring` | `helm/charts/eg-monitoring` | PodMonitor/ServiceMonitor + 5 dashboard Envoy Gateway, xem [README](../helm/charts/eg-monitoring/README.md) |
| Script | `scripts/06-monitoring.sh` | `detect`, `install`, `dns`, `password` |

## 2. Cách dùng chung ALB hoạt động

AWS Load Balancer Controller gom mọi Ingress có cùng annotation `alb.ingress.kubernetes.io/group.name` (ở bất kỳ namespace nào) vào **một** ALB. Mỗi Ingress đóng góp rule của mình (host + path → target group).

Annotation chia làm hai loại:

- **Cấp ALB/listener** (`scheme`, `subnets`, `security-groups`, `listen-ports`, `ssl-policy`, `wafv2-acl-arn`, `load-balancer-attributes`, `tags`, `inbound-cidrs`, `ssl-redirect`, …): mọi Ingress trong group phải **giống nhau hoặc bỏ trống**. Nếu khác nhau, controller báo lỗi kiểu `conflicting ... settings` và **ngừng reconcile cả group** (ALB của GitLab không bị xoá nhưng không cập nhật nữa). Vì vậy `detect` chép nguyên các annotation này từ Ingress GitLab.
- **Cấp rule/target group** (`target-type`, `healthcheck-path`, `success-codes`, …): riêng cho từng Ingress. Grafana dùng `target-type: ip`, health check `/api/health`.
- `certificate-arn`: các cert của mọi Ingress trong group được gộp lên listener HTTPS (SNI). Script dùng `ACM_CERT_ARN` (cert `*.gitlabonlinecom.click`), nếu trống thì dùng cert của GitLab.

> Không đặt `alb.ingress.kubernetes.io/group.order` cho Grafana: rule theo host không chồng lên rule của GitLab nên thứ tự không quan trọng.

## 3. Chuẩn bị

1. Đã cài xong bước 03–05 (Envoy Gateway đang chạy trong `envoy-gateway-system`).
2. Thêm vào `config/demo.env` (xem `config/demo.env.example`):

   ```bash
   export GRAFANA_HOST=grafana.gitlabonlinecom.click
   export GITLAB_INGRESS_NAMESPACE=gitlab
   export ALB_GROUP_NAME=
   export PROM_STORAGE_CLASS=
   ```

3. Kiểm tra Ingress của GitLab có Ingress group:

   ```bash
   kubectl get ingress -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName,GROUP:.metadata.annotations.alb\.ingress\.kubernetes\.io/group\.name,ADDRESS:.status.loadBalancer.ingress[0].hostname'
   ```

   Cột `GROUP` của Ingress GitLab phải có giá trị. Nếu `<none>`, xem mục 7.

4. Cert ACM phải phủ `grafana.gitlabonlinecom.click`. Cert wildcard `*.gitlabonlinecom.click` hiện tại đã phủ.

## 4. Cài đặt

### 4.1. Detect (chỉ đọc, không thay đổi gì trên cụm)

```bash
./scripts/06-monitoring.sh detect
```

Kết quả mong đợi:

```
==> Tìm Ingress ALB của GitLab (namespace gitlab)
[OK] Ingress GitLab: gitlab/gitlab-webservice-default hosts: gitlab.gitlabonlinecom.click
[OK] ALB group: gitlab
       - gitlab/gitlab-webservice-default  gitlab.gitlabonlinecom.click
[OK] ALB hiện tại: k8s-gitlab-xxxx.ap-southeast-1.elb.amazonaws.com
[OK] Đã sinh .../helm/values/generated/monitoring-ingress.yaml (Grafana: https://grafana.gitlabonlinecom.click)
       alb.ingress.kubernetes.io/scheme: internet-facing
       alb.ingress.kubernetes.io/listen-ports: [{"HTTP":80},{"HTTPS":443}]
       ...
```

Đọc kỹ danh sách annotation: các annotation cấp ALB phải trùng với Ingress GitLab. So sánh nhanh:

```bash
kubectl get ingress -n gitlab <tên-ingress-gitlab> -o jsonpath='{.metadata.annotations}' | jq
```

### 4.2. Install

```bash
./scripts/06-monitoring.sh install
```

Script làm theo thứ tự:

1. `detect` (sinh lại values Ingress).
2. Tạo namespace `monitoring` và Secret `grafana-admin` (mật khẩu ngẫu nhiên, chỉ tạo lần đầu; Grafana đọc qua `admin.existingSecret`).
3. `helm upgrade --install monitoring` kube-prometheus-stack `92.12.0` (`--wait`, tối đa 10 phút).
4. `helm upgrade --install eg-monitoring` (PodMonitor/ServiceMonitor + dashboard).
5. Chờ Ingress `monitoring-grafana` nhận địa chỉ ALB (phải trùng địa chỉ ALB của GitLab).
6. UPSERT bản ghi Route 53 `A alias grafana.gitlabonlinecom.click → ALB`.
7. In tài khoản admin.

Lấy lại mật khẩu bất cứ lúc nào:

```bash
./scripts/06-monitoring.sh password
```

### 4.3. Cài thủ công (tương đương script)

```bash
./scripts/06-monitoring.sh detect
```

```bash
kubectl create namespace monitoring
```

```bash
kubectl create secret generic grafana-admin -n monitoring --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
```

```bash
helm upgrade --install monitoring oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
  --version 92.12.0 -n monitoring \
  -f helm/monitoring/kube-prometheus-stack-values.yaml \
  -f helm/values/generated/monitoring-ingress.yaml \
  --wait --timeout 10m
```

```bash
helm upgrade --install eg-monitoring helm/charts/eg-monitoring -n monitoring --wait
```

```bash
./scripts/06-monitoring.sh dns
```

## 5. Kiểm tra

### 5.1. Pod và Ingress

```bash
kubectl get pods -n monitoring
```

```bash
kubectl get ingress -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.rules[*].host,ADDRESS:.status.loadBalancer.ingress[0].hostname'
```

Ingress `monitoring/monitoring-grafana` và Ingress GitLab phải có **cùng ADDRESS**. Nếu Grafana có địa chỉ khác → nó tạo ALB riêng (group không khớp), xem mục 8.

### 5.2. Target Prometheus

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
```

Mở http://localhost:9090/targets (hoặc kiểm tra bằng API ở terminal khác):

```bash
curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.namespace=="envoy-gateway-system") | [.scrapePool, .health, .scrapeUrl] | @tsv'
```

Mong đợi các pool `podMonitor/monitoring/envoy-proxy/0`, `serviceMonitor/monitoring/envoy-gateway-controller/0`, `podMonitor/monitoring/envoy-ratelimit/0` đều `up`. Số target `envoy-proxy` = số Pod Envoy (2–N theo HPA).

Truy vấn thử:

```bash
curl -s localhost:9090/api/v1/query --data-urlencode 'query=sum by (envoy_response_code_class) (rate(envoy_http_downstream_rq_xx[5m]))' | jq '.data.result'
```

### 5.3. Grafana

1. Mở `https://grafana.gitlabonlinecom.click`, đăng nhập bằng tài khoản từ `./scripts/06-monitoring.sh password`.
2. **Dashboards → Envoy Gateway**: 5 dashboard

   | Dashboard | Xem gì |
   |---|---|
   | Envoy Global | RPS, mã lỗi, latency downstream toàn bộ Envoy |
   | Envoy Clusters | Theo upstream cluster: RPS, retry, timeout, circuit breaker, health |
   | Envoy Gateway Global | Control plane: xDS push, reconcile, status update, watchable |
   | Global Ratelimit | Envoy ratelimit service: over_limit, near_limit, Redis |
   | Envoy Proxy Resources | CPU/RAM của Pod Envoy |

3. Tạo traffic để dashboard có số liệu:

   ```bash
   ./tests/run-tests.sh
   ```

   ```bash
   for i in $(seq 1 200); do curl -s -o /dev/null https://portal.gitlabonlinecom.click/healthz; done
   ```

4. Các dashboard Kubernetes mặc định của kube-prometheus-stack (thư mục General) cũng được nạp.

## 6. Values chính

`helm/monitoring/kube-prometheus-stack-values.yaml`:

| Key | Giá trị | Lý do |
|---|---|---|
| `alertmanager.enabled` | `false` | Demo chưa cần cảnh báo; bật lại khi cấu hình receiver |
| `kubeControllerManager/kubeScheduler/kubeEtcd/kubeProxy.enabled` | `false` | EKS quản lý control plane, Prometheus không scrape được → tránh target `down` và alert giả |
| `prometheus.prometheusSpec.*SelectorNilUsesHelmValues` | `false` | Prometheus đọc **mọi** ServiceMonitor/PodMonitor/PrometheusRule trong cụm, không chỉ cái có label `release: monitoring` |
| `prometheus.prometheusSpec.retention / retentionSize` | `7d` / `8GB` | Giới hạn dung lượng |
| `grafana.admin.existingSecret` | `grafana-admin` | Mật khẩu không nằm trong values/Git |
| `grafana.sidecar.dashboards.searchNamespace` | `ALL` | Nạp ConfigMap dashboard ở mọi namespace |
| `grafana.sidecar.dashboards.folderAnnotation` | `grafana_folder` | Đặt dashboard vào thư mục theo annotation |
| `grafana.persistence.enabled` | `false` | Dashboard nạp từ ConfigMap; user/thay đổi trên UI mất khi Pod restart. Bật PVC nếu cần |

Lưu dữ liệu Prometheus bền vững (cần EBS CSI driver và StorageClass):

```bash
kubectl get storageclass
```

Đặt `export PROM_STORAGE_CLASS=gp3` trong `config/demo.env` rồi chạy lại `./scripts/06-monitoring.sh install`. Lưu ý: chuyển từ emptyDir sang PVC sẽ tạo lại StatefulSet Prometheus (mất dữ liệu cũ).

## 7. GitLab chưa dùng Ingress group

Nếu `detect` báo Ingress GitLab không có `alb.ingress.kubernetes.io/group.name`, ALB của GitLab đang là ALB "riêng" (implicit group của một Ingress) và không Ingress nào khác gia nhập được. Lựa chọn:

**A. Thêm group cho GitLab (khuyến nghị nếu chấp nhận một lần thay ALB).**

Thêm annotation vào values Helm của GitLab (không `kubectl annotate` trực tiếp, Helm sẽ ghi đè ở lần upgrade sau), ví dụ với chart GitLab:

```yaml
global:
  ingress:
    annotations:
      alb.ingress.kubernetes.io/group.name: gitlab
```

⚠️ Chuyển từ implicit group sang group có tên làm controller **tạo ALB mới** và xoá ALB cũ → DNS name của ALB thay đổi. Cần cập nhật bản ghi Route 53 của GitLab (nếu dùng external-dns thì tự cập nhật), và có vài phút gián đoạn. Làm trong giờ bảo trì. Sau đó chạy lại `./scripts/06-monitoring.sh detect`.

**B. Không đụng GitLab: Grafana có ALB riêng.** Đặt `ALB_GROUP_NAME=monitoring` và `GITLAB_INGRESS_NAMESPACE` trỏ tới namespace có Ingress ALB mẫu để chép annotation, hoặc sửa tay `helm/values/generated/monitoring-ingress.yaml` sau khi `detect`. Tốn thêm chi phí một ALB.

**C. Không public Grafana.** Bỏ Ingress, dùng port-forward:

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
```

## 8. Xử lý sự cố

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| Ingress Grafana không có ADDRESS | Controller lỗi reconcile group | `kubectl describe ingress -n monitoring monitoring-grafana` và `kubectl logs -n kube-system deploy/aws-load-balancer-controller \| grep -i error` |
| Event `conflicting ...` / `failed build model` | Annotation cấp ALB khác Ingress GitLab | So sánh annotation (mục 4.1), sửa values sinh ra rồi `install` lại. Cả group ngừng cập nhật tới khi sửa xong |
| Grafana ADDRESS khác GitLab | Sai `group.name` | Kiểm tra `ALB_GROUP_NAME` để trống hoặc trùng group GitLab |
| `https://grafana...` lỗi cert | Cert listener không phủ host | Kiểm tra `ACM_CERT_ARN`, `aws elbv2 describe-listener-certificates` |
| 502/504 từ ALB | Target group unhealthy | `aws elbv2 describe-target-health`; Security group của node/Pod phải cho ALB SG vào cổng 3000 (controller tự thêm nếu `manage-backend-security-group-rules` không tắt) |
| Grafana 404 / redirect sai | `root_url` sai | Kiểm tra `grafana.ini.server.root_url` trong values sinh ra |
| Target `envoy-proxy` không xuất hiện | Prometheus không chọn PodMonitor, hoặc label Pod khác | `kubectl get podmonitor -n monitoring`; `kubectl get pod -n envoy-gateway-system --show-labels`; kiểm tra `podMonitorSelectorNilUsesHelmValues: false` |
| Target `down`, `context deadline exceeded` | NetworkPolicy/SG chặn 19001 | Cho phép namespace `monitoring` vào cổng 19001 của `envoy-gateway-system` |
| Thư mục "Envoy Gateway" trống | Sidecar chưa nạp ConfigMap | `kubectl get cm -A -l grafana_dashboard=1`; `kubectl logs -n monitoring deploy/monitoring-grafana -c grafana-sc-dashboard` |
| Panel "No data" / lỗi datasource | Chưa có traffic hoặc chọn sai datasource | Chọn datasource `Prometheus` ở biến `$datasource` đầu dashboard; tạo traffic |
| Cảnh báo CRD Prometheus Operator đã có | Cụm đã có operator khác (vd từ GitLab) | `kubectl get deploy -A \| grep -i operator`. Không chạy hai operator cùng quản lý một loại CRD |

## 9. Gỡ cài

```bash
./scripts/99-cleanup.sh --monitoring
```

Script xoá bản ghi `grafana.<DOMAIN>`, gỡ `eg-monitoring` và `monitoring`, xoá namespace. Khi Ingress Grafana bị xoá, controller chỉ gỡ rule/target group của Grafana; **ALB của GitLab giữ nguyên** vì group vẫn còn Ingress GitLab.

CRD `monitoring.coreos.com` không bị Helm xoá. Nếu chắc chắn không còn ai dùng:

```bash
kubectl get crd -o name | grep monitoring.coreos.com
```

```bash
kubectl get crd -o name | grep monitoring.coreos.com | xargs kubectl delete
```
