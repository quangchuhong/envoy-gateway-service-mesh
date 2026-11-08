# Chart `eg-monitoring`

Dạy Prometheus (do kube-prometheus-stack cài) thu thập metrics của Envoy Gateway và nạp 5 dashboard chính thức của Envoy Gateway v1.9.3 vào Grafana. Chart **không** cài Prometheus/Grafana; cài sau release `monitoring` (xem [docs/11-monitoring.md](../../../docs/11-monitoring.md)).

```bash
helm upgrade --install eg-monitoring helm/charts/eg-monitoring -n monitoring --wait
```

## Cấu trúc

```
eg-monitoring/
├── Chart.yaml
├── values.yaml
├── dashboards/                 # JSON dashboard (nguồn: gateway-addons-helm v1.9.3)
│   ├── envoy-global.json
│   ├── envoy-clusters.json
│   ├── envoy-gateway-global.json
│   ├── global-ratelimit.json
│   └── resources-monitor.json
└── templates/
    ├── monitors.yaml           # PodMonitor / ServiceMonitor
    └── dashboards.yaml         # ConfigMap cho mỗi file dashboards/*.json
```

## values.yaml

| Key | Mặc định | Ý nghĩa |
|---|---|---|
| `envoyGatewayNamespace` | `envoy-gateway-system` | Namespace chứa control plane **và** Pod Envoy Proxy (chế độ ControllerNamespace mặc định) |
| `scrapeInterval` | `30s` | Chu kỳ scrape cho mọi monitor |
| `monitors.envoyProxy` | `true` | PodMonitor `envoy-proxy` |
| `monitors.controlPlane` | `true` | ServiceMonitor `envoy-gateway-controller` |
| `monitors.rateLimit` | `true` | PodMonitor `envoy-ratelimit` (tắt nếu không dùng Global Rate Limit) |
| `dashboards.enabled` | `true` | Tạo ConfigMap dashboard |
| `dashboards.folder` | `Envoy Gateway` | Thư mục Grafana (annotation `grafana_folder`) |

## templates/monitors.yaml

| Resource | Chọn đối tượng | Endpoint |
|---|---|---|
| `PodMonitor envoy-proxy` | Pod có `app.kubernetes.io/name=envoy`, `app.kubernetes.io/component=proxy`, `app.kubernetes.io/managed-by=envoy-gateway` | cổng tên `metrics` (19001), `/stats/prometheus` |
| `ServiceMonitor envoy-gateway-controller` | Service có `control-plane=envoy-gateway` | cổng tên `metrics` (19001), `/metrics` |
| `PodMonitor envoy-ratelimit` | Pod có `app.kubernetes.io/name=envoy-ratelimit`, `component=ratelimit`, `managed-by=envoy-gateway` | cổng tên `metrics` (19001), `/metrics` |

Label lấy từ mã nguồn Envoy Gateway v1.9.3 (Envoy Gateway tự gắn cho Deployment nó tạo), nên không phụ thuộc tên Gateway: thêm Gateway mới cũng tự được scrape. Monitor đặt ở namespace `monitoring` và dùng `namespaceSelector.matchNames` để chọn `envoy-gateway-system`.

Prometheus chỉ đọc các monitor này vì values kube-prometheus-stack đặt `podMonitorSelectorNilUsesHelmValues: false` và `serviceMonitorSelectorNilUsesHelmValues: false` (nếu không, cần thêm label `release: monitoring`).

Kiểm tra label trên cụm:

```bash
kubectl get pod,svc -n envoy-gateway-system --show-labels
```

## templates/dashboards.yaml

Lặp qua `dashboards/*.json` bằng `.Files.Glob`, mỗi file thành ConfigMap `eg-dashboard-<tên>` có:

- label `grafana_dashboard: "1"`: sidecar `grafana-sc-dashboard` tự phát hiện (`searchNamespace: ALL`).
- annotation `grafana_folder: Envoy Gateway`: sidecar ghi file vào thư mục con, provider `foldersFromFilesStructure: true` biến thành thư mục Grafana.

Datasource trong JSON là biến `$datasource` (bản gốc có 3 chỗ gắn cứng uid `PBFA97CFB590B2093`, đã thay), nên chạy được với datasource Prometheus do kube-prometheus-stack tạo.

Thêm dashboard: chép file JSON vào `dashboards/`, dùng `${datasource}` cho datasource, rồi `helm upgrade`.

## Kiểm tra

```bash
helm template eg-monitoring helm/charts/eg-monitoring -n monitoring | grep -E "^kind|^  name"
```

```bash
kubectl get podmonitor,servicemonitor,cm -n monitoring -l app.kubernetes.io/part-of=eg-monitoring
```
