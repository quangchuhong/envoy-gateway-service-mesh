# Chart `eg-platform` – Cửa vào dùng chung (Gateway + data plane Envoy)

Chart này dựng **hạ tầng dùng chung** cho mọi app: lớp Gateway, cấu hình các Pod Envoy Proxy, Load Balancer (NLB) phía trước, TLS và các chính sách áp cho mọi request đi vào. **Platform team** quản lý chart này; các team app chỉ gắn `HTTPRoute` của mình vào Gateway mà chart tạo ra.

Tài liệu giải thích **từng khối trong `values.yaml`**: template nào dùng, sinh ra resource gì, và Envoy Gateway xử lý ra sao.

| | |
|---|---|
| Namespace | `eg-gateway` |
| Yêu cầu trước | Đã cài Envoy Gateway (chart `gateway-helm`, xem `helm/envoy-gateway/README.md`) và AWS Load Balancer Controller |
| Kết quả | Một Gateway `eg-gateway` có NLB, sẵn sàng nhận `HTTPRoute` từ các namespace app |

---

## 1. Cấu trúc chart

```
eg-platform/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── _helpers.tpl                # label chung + hàm sinh annotation cho NLB
    ├── gatewayclass.yaml           # GatewayClass eg-demo → trỏ tới EnvoyProxy
    ├── envoyproxy.yaml             # EnvoyProxy: Deployment/Service/HPA/PDB/log của Envoy
    ├── gateway.yaml                # Gateway eg-gateway: listener http:80 và https:443
    ├── http-redirect.yaml          # HTTPRoute: HTTP → HTTPS (301)
    ├── clienttrafficpolicy.yaml    # Chính sách phía client → Envoy cho toàn Gateway
    └── tls-secret.yaml             # Secret TLS self-signed cho listener HTTPS
```

| Template | Kind | Tên | Phạm vi |
|---|---|---|---|
| `gatewayclass.yaml` | `GatewayClass` | `eg-demo` | Cluster |
| `envoyproxy.yaml` | `EnvoyProxy` | `eg-demo-proxy` | `eg-gateway` |
| `gateway.yaml` | `Gateway` | `eg-gateway` | `eg-gateway` |
| `http-redirect.yaml` | `HTTPRoute` | `http-to-https-redirect` | `eg-gateway` |
| `clienttrafficpolicy.yaml` | `ClientTrafficPolicy` | `eg-gateway-client` | `eg-gateway` |
| `tls-secret.yaml` | `Secret` (`kubernetes.io/tls`) | `eg-gateway-tls` | `eg-gateway` |

### Resource do Envoy Gateway **tự tạo** (không nằm trong chart)

Khi thấy `Gateway eg-gateway`, controller Envoy Gateway tự tạo các resource sau trong namespace `eg-gateway`, theo cấu hình của `EnvoyProxy`:

| Resource | Tên (dạng) | Nguồn cấu hình |
|---|---|---|
| `Deployment` các Pod Envoy | `envoy-eg-gateway-eg-gateway-<hash>` | `envoyProxy.replicas`, `resources`, rải theo AZ |
| `Service` type LoadBalancer → **NLB** | `envoy-eg-gateway-eg-gateway-<hash>` | `envoyProxy.service.*` |
| `HorizontalPodAutoscaler` | cùng tên | `envoyProxy.hpa.*` |
| `PodDisruptionBudget` | cùng tên | `envoyProxy.pdb.*` |
| `ServiceAccount`, `ConfigMap` | cùng tên | – |

Các resource này có label `gateway.envoyproxy.io/owning-gateway-name=eg-gateway`:

```bash
kubectl get deploy,svc,hpa,pdb -n eg-gateway -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway
```

> Không sửa trực tiếp các resource tự tạo này: controller sẽ ghi đè lại. Mọi thay đổi phải đi qua `values.yaml` → `EnvoyProxy`.

## 2. Quan hệ giữa các resource

```
GatewayClass eg-demo
   │  controllerName: gateway.envoyproxy.io/gatewayclass-controller   (do Envoy Gateway quản lý)
   │  parametersRef ───────────────► EnvoyProxy eg-demo-proxy
   │                                   (Pod, Service NLB, HPA, PDB, drain, access log)
   ▼
Gateway eg-gateway  ◄──── ClientTrafficPolicy eg-gateway-client (targetRef: Gateway)
   ├── listener "http"  :80   ◄── HTTPRoute http-to-https-redirect  (cùng namespace)
   └── listener "https" :443  ◄── HTTPRoute của app, từ namespace có label gateway.demo.io/attach=true
         └── TLS: Secret eg-gateway-tls
```

Luồng một request:

```
User ─HTTPS─► NLB (cert ACM) ─TLS─► Pod Envoy :10443
                                     │ ClientTrafficPolicy: xác định IP client, xoá header nội bộ,
                                     │ trả /healthz, sinh X-Request-Id, kiểm tra timeout
                                     ▼
                              chọn HTTPRoute theo Host header → policy của app → backend
```

---

## 3. Giải thích từng khối trong `values.yaml`

### 3.1 Domain

```yaml
domain: gitlabonlinecom.click
```

Chỉ dùng ở `tls-secret.yaml` để đặt tên miền trong cert self-signed (`CN=*.gitlabonlinecom.click`, SAN `*.gitlabonlinecom.click` và `gitlabonlinecom.click`). Hostname của từng app do chart app quyết định, không phải chart này.

### 3.2 GatewayClass

```yaml
gatewayClass:
  name: eg-demo
```

`gatewayclass.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: {{ .Values.gatewayClass.name }}
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: {{ .Values.envoyProxy.name }}
    namespace: {{ .Release.Namespace }}
```

| Trường | Ý nghĩa |
|---|---|
| `controllerName` | Phải trùng `config.envoyGateway.gateway.controllerName` trong values của chart Envoy Gateway. Đây là cách Envoy Gateway biết GatewayClass nào thuộc về mình |
| `parametersRef` | Mọi Gateway thuộc lớp `eg-demo` dùng cấu hình data plane trong `EnvoyProxy eg-demo-proxy` |

GatewayClass là resource **cấp cluster**. Muốn có một lớp Gateway khác (ví dụ Gateway nội bộ chỉ dùng NLB internal), tạo GatewayClass thứ hai trỏ tới một `EnvoyProxy` khác.

### 3.3 Gateway

```yaml
gateway:
  name: eg-gateway
  attachNamespaceLabel:
    key: gateway.demo.io/attach
    value: "true"
```

`gateway.yaml`:

```yaml
spec:
  gatewayClassName: {{ .Values.gatewayClass.name }}
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same                       # chỉ route trong namespace eg-gateway (route redirect)
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: {{ .Values.tls.secretName }}
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              {{ $lbl.key }}: {{ $lbl.value | quote }}   # gateway.demo.io/attach: "true"
        kinds:
          - kind: HTTPRoute
```

| Trường | Ý nghĩa |
|---|---|
| `gateway.name` | Tên Gateway. Các chart app tham chiếu tên này trong `parentRefs` (`gateway.name` trong values của app) |
| Listener `http` + `from: Same` | Chỉ route redirect của platform gắn được vào cổng 80. App không thể vô tình phục vụ nội dung qua HTTP không mã hoá |
| Listener `https` + `tls.mode: Terminate` | Envoy giải mã TLS bằng Secret `tls.secretName`, rồi đọc HTTP để định tuyến |
| `allowedRoutes.namespaces.from: Selector` | Chỉ namespace có label `gateway.demo.io/attach=true` mới gắn được HTTPRoute. Đây là cách **platform team kiểm soát** ai được dùng cửa chung |
| `kinds: HTTPRoute` | Listener HTTPS chỉ nhận HTTPRoute (không nhận GRPCRoute, TCPRoute...) |

Cho phép một namespace mới gắn route:

```bash
kubectl label namespace <ns> gateway.demo.io/attach=true
```

#### Vì sao listener HTTPS **không** đặt `hostname`?

Gateway API cho phép đặt `hostname: "*.gitlabonlinecom.click"` trên listener. Repo cố ý **không** đặt. Khi listener có hostname, Envoy chọn cấu hình TLS theo **SNI** trong bản tin bắt tay TLS. NLB (và F5 sau này) khi re-encrypt tới Envoy **có thể không gửi SNI**, nên kết nối sẽ bị từ chối. Bỏ hostname thì Envoy nhận mọi kết nối TLS, và việc phân biệt app được làm ở `HTTPRoute.spec.hostnames` (dựa vào header `Host`).

#### Cổng thật trong container

Envoy Gateway không cho Envoy mở cổng < 1024 (cần quyền root). Nó dịch cổng lên **+10000**: listener 443 chạy ở container port **10443**, listener 80 ở **10080**. Service vẫn mở 80/443 ra ngoài và trỏ vào 10080/10443. Cần nhớ điều này khi cấu hình Security Group, hoặc khi F5 trỏ thẳng vào Pod IP.

### 3.4 Chuyển HTTP sang HTTPS

`http-redirect.yaml` (không có values riêng):

```yaml
spec:
  parentRefs:
    - name: {{ .Values.gateway.name }}
      sectionName: http                 # chỉ gắn vào listener port 80
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

Route này không có `hostnames` và `matches`, nên áp cho **mọi** host và mọi path trên cổng 80: `http://partner.gitlabonlinecom.click/v1/x` → `301` → `https://partner.gitlabonlinecom.click/v1/x`.

### 3.5 TLS

```yaml
tls:
  secretName: eg-gateway-tls
  create: true
  validityDays: 3650
```

`tls-secret.yaml`:

```yaml
{{- if .Values.tls.create }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace .Values.tls.secretName -}}
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
data:
{{- if and $existing $existing.data }}
  tls.crt: {{ index $existing.data "tls.crt" }}        # đã có → giữ nguyên cert cũ
  tls.key: {{ index $existing.data "tls.key" }}
{{- else }}
{{- $cn := printf "*.%s" .Values.domain -}}
{{- $cert := genSelfSignedCert $cn nil (list $cn .Values.domain) (int .Values.tls.validityDays) }}
  tls.crt: {{ $cert.Cert | b64enc }}                   # chưa có → sinh cert mới
  tls.key: {{ $cert.Key | b64enc }}
{{- end }}
{{- end }}
```

| Khoá | Ý nghĩa |
|---|---|
| `secretName` | Secret mà listener HTTPS dùng. Luôn cần, kể cả khi `create: false` |
| `create: true` | Chart tự sinh cert self-signed bằng hàm `genSelfSignedCert` của Helm |
| `validityDays` | Hạn của cert self-signed (mặc định 10 năm) |

**Vì sao dùng `lookup`?** `genSelfSignedCert` sinh cert **mới** mỗi lần render. Nếu không có `lookup`, mỗi lần `helm upgrade` cert đổi một lần. `lookup` đọc Secret đang có trên cluster: nếu đã tồn tại thì dùng lại.

> `helm template` không kết nối cluster, nên `lookup` luôn trả về rỗng và mỗi lần render ra một cert khác. Đây là hành vi bình thường. Nếu triển khai theo kiểu GitOps (render rồi apply), nên đặt `create: false` và quản lý Secret riêng.

**Cert self-signed có an toàn không?** Còn tuỳ chế độ (xem mục 3.7):

| Chế độ | Người dùng thấy cert nào | Cert trong Secret này dùng cho |
|---|---|---|
| `nlb-tls` (có `acmCertArn`) | Cert **ACM** public, hợp lệ | Chỉ đoạn NLB → Envoy, bên trong VPC. NLB không kiểm tra cert của target nên self-signed là đủ |
| `nlb-tcp` (không có ACM) | Chính cert trong Secret này | Đoạn người dùng → Envoy. Self-signed sẽ bị trình duyệt cảnh báo; cần thay bằng cert thật |

Dùng cert thật (ví dụ do cert-manager cấp) cho chế độ `nlb-tcp`:

```bash
helm upgrade eg-platform helm/charts/eg-platform -n eg-gateway -f helm/values/generated/eg-platform.yaml --set tls.create=false --set tls.secretName=wildcard-demo-tls
```

### 3.6 Data plane: Pod Envoy

```yaml
envoyProxy:
  name: eg-demo-proxy
  replicas: 2
  hpa:
    enabled: true
    minReplicas: 2
    maxReplicas: 6
    cpuUtilization: 70
  pdb:
    minAvailable: 1
  resources:
    requests: { cpu: 250m, memory: 256Mi }
    limits: { memory: 1Gi }
```

`envoyproxy.yaml`, phần `provider.kubernetes`:

```yaml
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        replicas: {{ $p.replicas }}
        container:
          resources: {{ $p.resources }}
        pod:
          topologySpreadConstraints:              # rải Pod Envoy đều qua các AZ
            - maxSkew: 1
              topologyKey: topology.kubernetes.io/zone
              whenUnsatisfiable: ScheduleAnyway
              labelSelector:
                matchLabels:
                  gateway.envoyproxy.io/owning-gateway-name: {{ .Values.gateway.name }}
      {{- if $p.hpa.enabled }}
      envoyHpa:
        minReplicas: {{ $p.hpa.minReplicas }}
        maxReplicas: {{ $p.hpa.maxReplicas }}
        metrics:
          - type: Resource
            resource:
              name: cpu
              target:
                type: Utilization
                averageUtilization: {{ $p.hpa.cpuUtilization }}
      {{- end }}
      envoyPDB:
        minAvailable: {{ $p.pdb.minAvailable }}
```

| Khoá | Ý nghĩa |
|---|---|
| `name` | Tên resource `EnvoyProxy`, được GatewayClass tham chiếu |
| `replicas` | Số Pod Envoy ban đầu. Khi bật HPA, HPA sẽ điều chỉnh số này |
| `hpa.*` | Tự scale Pod Envoy theo CPU: giữ trung bình khoảng 70%, từ 2 đến 6 Pod |
| `pdb.minAvailable: 1` | Khi drain node hoặc nâng cấp cluster, luôn còn ít nhất 1 Pod Envoy chạy |
| `resources` | Request đủ để HPA tính % CPU. Không đặt giới hạn CPU để tránh Envoy bị throttle làm tăng độ trễ |
| `topologySpreadConstraints` (cố định) | Rải Pod qua các AZ. Mất một AZ thì Gateway vẫn chạy. `ScheduleAnyway` cho phép xếp lệch khi không đủ node thay vì treo Pod |

> Nên giữ `hpa.minReplicas` ≥ 2 và lớn hơn `pdb.minAvailable`, nếu không việc drain node có thể bị chặn.

### 3.7 Service và NLB

```yaml
envoyProxy:
  service:
    type: LoadBalancer
    loadBalancerClass: service.k8s.aws/nlb
    externalTrafficPolicy: Cluster
    nlb:
      enabled: true
      scheme: internet-facing
      # cert *.gitlabonlinecom.click đã import vào ACM (account 609320954321)
      acmCertArn: "arn:aws:acm:ap-southeast-1:609320954321:certificate/569f4470-6ac3-4ef2-be6e-7eb012397305"
      sslPolicy: ELBSecurityPolicy-TLS13-1-2-2021-06
      preserveClientIP: true
      deregistrationDelaySeconds: 30
      sourceRanges: []
    annotations: {}
```

#### Annotation NLB được sinh ở `_helpers.tpl`

```yaml
{{- define "eg-platform.serviceAnnotations" -}}
{{- $s := .Values.envoyProxy.service -}}
{{- if and (eq $s.type "LoadBalancer") $s.nlb.enabled }}
service.beta.kubernetes.io/aws-load-balancer-type: external
service.beta.kubernetes.io/aws-load-balancer-scheme: {{ $s.nlb.scheme }}
service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: preserve_client_ip.enabled={{ $s.nlb.preserveClientIP }},deregistration_delay.timeout_seconds={{ $s.nlb.deregistrationDelaySeconds }}
{{- if $s.nlb.acmCertArn }}
service.beta.kubernetes.io/aws-load-balancer-ssl-cert: {{ $s.nlb.acmCertArn | quote }}
service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
service.beta.kubernetes.io/aws-load-balancer-backend-protocol: ssl
service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy: {{ $s.nlb.sslPolicy }}
{{- end }}
{{- end }}
{{- end -}}
```

`envoyproxy.yaml` gộp annotation này với `service.annotations` của người dùng:

```yaml
envoyService:
  type: {{ $p.service.type }}
  {{- if and (eq $p.service.type "LoadBalancer") $p.service.loadBalancerClass }}
  loadBalancerClass: {{ $p.service.loadBalancerClass }}
  {{- end }}
  {{- if ne $p.service.type "ClusterIP" }}
  externalTrafficPolicy: {{ $p.service.externalTrafficPolicy }}
  {{- end }}
  {{- $ann := include "eg-platform.serviceAnnotations" . | fromYaml | default dict }}
  {{- $ann = merge (deepCopy ($p.service.annotations | default dict)) $ann }}
  annotations: {{ $ann }}
  {{- with $p.service.nlb.sourceRanges }}
  loadBalancerSourceRanges: {{ . }}
  {{- end }}
```

Hàm `merge` ưu tiên giá trị của **đối số đầu** (annotation người dùng). Vì vậy `service.annotations` có thể ghi đè bất kỳ annotation nào chart sinh ra.

**Vì sao sinh annotation trong template thay vì ghi sẵn trong `values.yaml`?** Helm **gộp** map khi ghi đè values: nếu `values.yaml` chứa sẵn annotation `ssl-cert`, file ghi đè không xoá được nó (chỉ thêm hoặc sửa được). Sinh trong template thì annotation TLS chỉ xuất hiện khi `acmCertArn` có giá trị.

| Khoá | Annotation / trường | Ý nghĩa |
|---|---|---|
| `type: LoadBalancer` | `envoyService.type` | Yêu cầu tạo Load Balancer |
| `loadBalancerClass: service.k8s.aws/nlb` | `envoyService.loadBalancerClass` | Chỉ định **AWS Load Balancer Controller** xử lý (không dùng controller cũ có sẵn trong Kubernetes) |
| `nlb.enabled` | Bật/tắt toàn bộ annotation NLB | Tắt khi chuyển sang F5 |
| `nlb.scheme` | `aws-load-balancer-scheme` | `internet-facing` (public) hoặc `internal` (chỉ trong VPC) |
| (cố định) | `aws-load-balancer-nlb-target-type: ip` | NLB gửi thẳng tới **IP Pod** Envoy, không qua NodePort |
| (cố định) | `cross_zone.enabled=true` | Chia đều tải sang Pod ở mọi AZ |
| `nlb.preserveClientIP` | `preserve_client_ip.enabled` | Envoy thấy **IP thật** của người dùng. Rate limit theo IP và IP allowlist cần điều này |
| `nlb.deregistrationDelaySeconds` | `deregistration_delay.timeout_seconds` | Khi Pod Envoy bị xoá, NLB ngừng gửi kết nối mới nhưng chờ 30s cho kết nối cũ xong. Khớp với `shutdown.drainTimeout` |
| `nlb.acmCertArn` | `ssl-cert`, `ssl-ports`, `backend-protocol: ssl` | **Có giá trị** → chế độ `nlb-tls`: NLB giải mã TLS bằng cert ACM ở cổng 443, rồi **mã hoá lại** (ssl) khi gửi tới Envoy |
| `nlb.sslPolicy` | `ssl-negotiation-policy` | Chính sách TLS phía người dùng: chỉ TLS 1.2 và 1.3 |
| `nlb.sourceRanges` | `loadBalancerSourceRanges` | Chỉ IP trong danh sách được vào NLB. Nên đặt IP văn phòng hoặc VPN khi demo |
| `externalTrafficPolicy` | `envoyService.externalTrafficPolicy` | Với target type `ip` không ảnh hưởng. Có ý nghĩa khi chuyển sang `NodePort` (mục 4) |
| `annotations` | Thêm vào hoặc ghi đè | Ví dụ gắn tag cho NLB: `service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags` |

Hai chế độ TLS:

| | `nlb-tls` (có `acmCertArn`) | `nlb-tcp` (`acmCertArn: ""`) |
|---|---|---|
| NLB cổng 443 | Listener **TLS**, cert ACM | Listener **TCP**, chuyển nguyên gói tin |
| Người dùng thấy cert | ACM (hợp lệ) | Cert trong `tls.secretName` |
| NLB → Envoy | TLS (re-encrypt) | TLS của người dùng đi thẳng tới Envoy |
| Giống mô hình F5 | ✅ | ❌ |

Cổng 80 luôn là TCP, Envoy nhận và redirect sang HTTPS.

### 3.8 Drain khi tắt Pod

```yaml
envoyProxy:
  shutdown:
    drainTimeout: 30s
    minDrainDuration: 5s
```

Render ra `EnvoyProxy.spec.shutdown`. Khi Pod Envoy bị xoá (rollout, scale-in, drain node):

1. Pod báo **not ready**, NLB bắt đầu rút Pod khỏi target group (`deregistration_delay` 30s).
2. Envoy ngừng nhận kết nối mới nhưng vẫn phục vụ request đang chạy, **tối thiểu** `minDrainDuration` (5s) và **tối đa** `drainTimeout` (30s).
3. Hết thời gian thì Envoy tắt.

Nhờ vậy rollout Envoy **không làm rớt request**. Nếu có request dài hơn 30s (upload lớn, stream), tăng cả `drainTimeout` và `nlb.deregistrationDelaySeconds` lên cùng giá trị.

### 3.9 Access log

```yaml
envoyProxy:
  accessLog: true
```

Bật khối `telemetry.accessLog` trong `EnvoyProxy`: mỗi request ghi một dòng JSON ra stdout của container `envoy`.

```yaml
telemetry:
  accessLog:
    settings:
      - format:
          type: JSON
          json:
            start_time: "%START_TIME%"
            method: "%REQ(:METHOD)%"
            authority: "%REQ(:AUTHORITY)%"
            path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"   # path gốc, trước khi URL rewrite
            response_code: "%RESPONSE_CODE%"
            response_flags: "%RESPONSE_FLAGS%"           # lý do lỗi: RL, UO, UT, NR...
            duration_ms: "%DURATION%"
            client_ip: "%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%"
            x_forwarded_for: "%REQ(X-FORWARDED-FOR)%"
            request_id: "%REQ(X-REQUEST-ID)%"
            route_name: "%ROUTE_NAME%"
            upstream_host: "%UPSTREAM_HOST%"             # Pod backend thực sự nhận request
            upstream_cluster: "%UPSTREAM_CLUSTER%"
            user_sub: "%REQ(X-JWT-SUB)%"                 # user/client từ JWT (App 1, 2)
            client_id: "%REQ(X-JWT-CLIENT-ID)%"
            partner_id: "%REQ(X-PARTNER-ID)%"            # đối tác từ API key (App 3)
            user_agent: "%REQ(USER-AGENT)%"
        sinks:
          - type: File
            file:
              path: /dev/stdout
```

`user_sub`, `client_id`, `partner_id` đọc từ header do bước xác thực của các app gắn vào. Nhờ vậy log trả lời được câu hỏi **ai** đã gọi, không chỉ **IP nào**. Log ra stdout nên agent thu log của cluster (Fluent Bit → CloudWatch/OpenSearch/Loki) tự thu được.

Xem log:

```bash
kubectl logs -n eg-gateway -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -c envoy --tail=20
```

### 3.10 ClientTrafficPolicy

```yaml
clientTraffic:
  clientIPDetection: direct
  xffTrustedHops: 1
  healthCheckPath: /healthz
  requestReceivedTimeout: 30s
  idleTimeout: 300s
  stripRequestHeaders:
    - x-jwt-sub
    - x-jwt-client-id
    - x-user-email
    - x-partner-id
```

`clienttrafficpolicy.yaml`:

```yaml
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: {{ .Values.gateway.name }}            # áp cho mọi listener, mọi app
  {{- if eq $c.clientIPDetection "xff" }}
  clientIPDetection:
    xForwardedFor:
      numTrustedHops: {{ $c.xffTrustedHops }}
  {{- end }}
  healthCheck:
    path: {{ $c.healthCheckPath }}
  timeout:
    http:
      requestReceivedTimeout: {{ $c.requestReceivedTimeout }}
      idleTimeout: {{ $c.idleTimeout }}
  headers:
    requestID: PreserveOrGenerate
    earlyRequestHeaders:
      remove: {{ $c.stripRequestHeaders }}
  tls:
    minVersion: "1.2"
```

`ClientTrafficPolicy` cấu hình đoạn **client → Envoy** (listener). Nó gắn vào **Gateway** nên áp cho cả 3 app.

| Khoá values / trường | Ý nghĩa |
|---|---|
| `clientIPDetection: direct` | Không render khối `clientIPDetection`: Envoy lấy IP từ kết nối TCP. Đúng khi NLB giữ IP client (`preserveClientIP: true`) |
| `clientIPDetection: xff` + `xffTrustedHops` | Lấy IP từ `X-Forwarded-For`, tin `xffTrustedHops` proxy đứng trước. Dùng khi có **F5** (1 hop), hoặc F5 + CloudFront (2 hop) |
| `healthCheckPath` | Envoy tự trả `200` cho `GET /healthz` ở mọi host, không đi vào app. Dùng cho monitor của NLB/F5 hoặc kiểm tra thủ công |
| `requestReceivedTimeout` | Thời gian tối đa để nhận **xong** request từ client. Chặn client gửi chậm cố tình giữ kết nối (kiểu slowloris) |
| `idleTimeout` | Kết nối không có hoạt động sau 300s thì bị đóng |
| `requestID: PreserveOrGenerate` (cố định) | Giữ `X-Request-Id` nếu client gửi, nếu không thì sinh mới. Header này đi tới backend và vào access log, dùng để truy vết một request xuyên hệ thống |
| `stripRequestHeaders` | Danh sách header bị **xoá ngay khi request vào**, trước mọi bước xử lý khác |
| `tls.minVersion: "1.2"` (cố định) | Listener HTTPS của Envoy không chấp nhận TLS 1.0, 1.1 |

#### Vì sao phải xoá các header trong `stripRequestHeaders`?

Các header này mang **danh tính** mà backend và rate limit tin tưởng:

| Header | Do ai gắn | Dùng cho |
|---|---|---|
| `x-jwt-sub`, `x-jwt-client-id`, `x-user-email` | Bước JWT (App 1, 2), từ claim trong token đã verify | Backend biết user; rate limit theo user (App 2) |
| `x-partner-id` | Bước API key (App 3) | Phân quyền theo gói, rate limit theo gói |

Nếu không xoá, một client có thể tự gửi `x-partner-id: partner-gold` để được quyền của đối tác khác. `earlyRequestHeaders` chạy **trước** mọi filter, nên header giả bị xoá trước; sau đó Envoy chỉ gắn lại giá trị lấy từ token hoặc API key thật.

Khi thêm app mới dùng header danh tính khác (ví dụ `x-tenant-id`), **phải thêm header đó vào danh sách này**.

---

## 4. Chuyển sang F5 (giai đoạn sau)

Không cần sửa template, chỉ đổi values. Ví dụ file `eg-platform-f5.yaml` khi dùng **F5 CIS** (F5 trỏ thẳng vào Pod IP):

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

Kết quả render:

```yaml
# EnvoyProxy: không còn NLB, không còn annotation AWS
envoyService:
  type: ClusterIP

# ClientTrafficPolicy: tin 1 hop X-Forwarded-For do F5 chèn
clientIPDetection:
  xForwardedFor:
    numTrustedHops: 1
```

Nếu F5 trỏ tới **NodePort** thay vì Pod IP: đặt `type: NodePort` và `externalTrafficPolicy: Local` (node chỉ chuyển traffic vào Pod Envoy trên chính node đó, tránh thêm một hop qua node khác).

Phía F5: pool trỏ tới Pod IP cổng **10443** (CIS) hoặc `<node>:<nodePort>`; monitor `GET /ready` cổng **19003** (readiness của Envoy) hoặc `GET /healthz` qua cổng HTTPS. Chi tiết trong `docs/10-next-steps-f5-istio.md`.

## 5. Cài đặt và ghi đè values

File values sinh tự động `helm/values/generated/eg-platform.yaml`:

```yaml
domain: gitlabonlinecom.click
envoyProxy:
  service:
    nlb:
      acmCertArn: "arn:aws:acm:ap-southeast-1:609320954321:certificate/569f4470-6ac3-4ef2-be6e-7eb012397305"
```

Cài:

```bash
helm upgrade --install eg-platform helm/charts/eg-platform -n eg-gateway --create-namespace -f helm/values/generated/eg-platform.yaml --wait
```

Ví dụ giới hạn IP truy cập và tăng số Pod Envoy:

```bash
helm upgrade eg-platform helm/charts/eg-platform -n eg-gateway -f helm/values/generated/eg-platform.yaml --set 'envoyProxy.service.nlb.sourceRanges={203.0.113.0/24}' --set envoyProxy.hpa.minReplicas=3
```

Xem trước:

```bash
helm template eg-platform helm/charts/eg-platform -n eg-gateway -f helm/values/generated/eg-platform.yaml
```

> Một số thay đổi ở Service khiến AWS Load Balancer Controller **tạo NLB mới** (ví dụ đổi `scheme` từ `internet-facing` sang `internal`). DNS của NLB sẽ đổi, nên phải cập nhật bản ghi Route 53.

## 6. Kiểm tra sau khi cài

Gateway phải `PROGRAMMED=True` và có `ADDRESS` (DNS name của NLB):

```bash
kubectl get gateway -n eg-gateway eg-gateway
```

```bash
kubectl get gatewayclass eg-demo
```

Kết quả mong đợi: `ACCEPTED=True`.

```bash
kubectl get clienttrafficpolicy -n eg-gateway eg-gateway-client -o jsonpath='{.status.ancestors[0].conditions[0].reason}{"\n"}'
```

Kết quả mong đợi: `Accepted`.

Pod, Service, HPA, PDB do Envoy Gateway tạo:

```bash
kubectl get deploy,svc,hpa,pdb,pod -n eg-gateway -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -o wide
```

Annotation NLB đã được đặt đúng:

```bash
kubectl get svc -n eg-gateway -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -o jsonpath='{.items[0].metadata.annotations}' | jq
```

Gọi thử health check và redirect (khi đã có DNS):

```bash
curl -i "https://portal.${DOMAIN}/healthz"
```

```bash
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "http://portal.${DOMAIN}/"
```

Chạy nhóm test của Gateway: `tests/run-tests.sh gw` (GW-01 đến GW-04).

## 7. Lỗi thường gặp khi sửa values

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| GatewayClass `ACCEPTED=False` | `controllerName` không khớp cấu hình của Envoy Gateway, hoặc `EnvoyProxy` sai | `kubectl describe gatewayclass eg-demo` |
| Gateway không có `ADDRESS` | Chưa có AWS Load Balancer Controller, subnet thiếu tag `kubernetes.io/role/elb=1`, hoặc IAM thiếu quyền | `kubectl describe svc -n eg-gateway`; log của `aws-load-balancer-controller` |
| Trình duyệt báo cert không hợp lệ | Đang ở chế độ `nlb-tcp` với cert self-signed | Đặt `nlb.acmCertArn`, hoặc dùng cert thật với `tls.create=false` |
| `curl` báo lỗi TLS khi có ACM | Cert ACM không phủ hostname (ví dụ cert `gitlabonlinecom.click` nhưng gọi `portal.gitlabonlinecom.click`) | Dùng cert wildcard `*.gitlabonlinecom.click` |
| Route của app báo `NotAllowedByListeners` | Namespace app thiếu label `gateway.demo.io/attach=true` | Gắn label cho namespace |
| Rate limit theo IP chặn tất cả mọi người cùng lúc | Envoy thấy cùng một IP cho mọi request (`preserveClientIP: false`, hoặc có proxy phía trước mà vẫn để `direct`) | Bật `preserveClientIP`, hoặc đổi `clientIPDetection: xff` |
| Header danh tính bị giả mạo được | Header mới chưa có trong `stripRequestHeaders` | Thêm vào danh sách |
| Request bị `5xx` khi rollout Envoy | Thời gian drain ngắn hơn thời gian xử lý request | Tăng `shutdown.drainTimeout` và `nlb.deregistrationDelaySeconds` |
