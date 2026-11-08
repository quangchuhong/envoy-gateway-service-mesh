# App v2: order-service + payment-service

Demo hai microservice gọi nhau, triển khai từng bước bằng `kubectl` + `helm` (không dùng script):

```
                              https://store.gitlabonlinecom.click/api/orders
 Client ──HTTPS──► NLB ──► Envoy Gateway ────────────► order-service ──────HTTP──────► payment-service
  (Bearer token Cognito)   (ns envoy-gateway-system)    (ns shop-order)    east-west     (ns shop-payment)
                           ① JWT: xác thực token        public            trong cụm     nội bộ, KHÔNG có route
                           ② AuthZ: group Cognito       qua HTTPRoute                   từ Internet
                           ③ sub → header x-jwt-sub
```

| Service | Namespace | Public? | API |
|---|---|---|---|
| order-service | `shop-order` | Có, qua Envoy Gateway | `GET /api/orders`, `GET /api/orders/<id>`, `POST /api/orders` |
| payment-service | `shop-payment` | Không | `POST /payments`, `GET /payments`, `GET /payments/<id>` (chỉ gọi được trong cụm) |

Luồng `POST /api/orders {"item":"book","amount":100}`:

1. Envoy kiểm tra access token Cognito, kiểm tra group (`developer`, `devops-admin` được tạo đơn), sinh `x-request-id`, chép claim `sub` vào header `x-jwt-sub`.
2. order-service tạo đơn (`customer` = `x-jwt-sub`), gọi `POST http://payment-service.shop-payment.svc.cluster.local:8080/payments`, chuyển tiếp `x-request-id`.
3. payment-service duyệt nếu `amount <= 1000` (201 `APPROVED`), ngược lại từ chối (402 `DECLINED`).
4. order-service trả `201 PAID`, `402 PAYMENT_DECLINED`, hoặc `502 PAYMENT_ERROR` nếu không gọi được payment-service.

Hai service viết bằng Python thuần (thư viện chuẩn), code nằm trong `demo-shop/app/` và được nạp vào ConfigMap, chạy trên image `python:3.12.8-alpine3.21`, không cần build image.

## Cấu trúc thư mục

```
app-v2/
├── README.md                          # guide này
└── demo-shop/                         # Helm chart
    ├── Chart.yaml
    ├── values.yaml
    ├── app/
    │   ├── order_service.py           # code order-service
    │   └── payment_service.py         # code payment-service
    └── templates/
        ├── _helpers.tpl               # khuôn chung: ServiceAccount + ConfigMap code + Deployment + Service
        ├── order-service.yaml         # order-service (ns shop-order)
        ├── payment-service.yaml       # payment-service (ns shop-payment)
        ├── httproute.yaml             # public /api/orders tại store.<domain>
        ├── securitypolicy.yaml        # JWT Cognito + phân quyền theo group
        ├── backendtrafficpolicy.yaml  # timeout, retry lỗi kết nối
        └── networkpolicy.yaml         # (tuỳ chọn) chặn east-west
```

### values.yaml

| Key | Mặc định | Ý nghĩa |
|---|---|---|
| `domain` / `hostPrefix` | `gitlabonlinecom.click` / `store` | Host public: `store.gitlabonlinecom.click` |
| `gateway.*` | `eg-gateway` / `eg-gateway` / `https` | Gateway và listener mà HTTPRoute gắn vào |
| `namespaces.order` / `namespaces.payment` | `shop-order` / `shop-payment` | Mỗi service một namespace |
| `image` | `python:3.12.8-alpine3.21` | Image chạy code Python |
| `order.replicas` / `order.paymentTimeoutSeconds` | `2` / `3` | Số Pod; thời gian order-service chờ payment-service |
| `payment.replicas` / `payment.approvalLimit` | `2` / `1000` | Số Pod; ngưỡng duyệt thanh toán |
| `cognito.issuer` | (bắt buộc đặt) | Issuer của User Pool Cognito |
| `authz.readGroups` | `viewer, developer, devops-admin` | Group được `GET` |
| `authz.writeGroups` | `developer, devops-admin` | Group được `POST` |
| `requestTimeout` | `10s` | Timeout Envoy → order-service |
| `networkPolicy.enabled` | `false` | Bật NetworkPolicy chặn east-west (mục 9) |

### Resource được tạo

| Resource | Namespace | Ghi chú |
|---|---|---|
| ServiceAccount, ConfigMap `*-code`, Deployment, Service `order-service` | shop-order | Pod chạy `python -u /app/order_service.py`, đọc code từ ConfigMap |
| ServiceAccount, ConfigMap `*-code`, Deployment, Service `payment-service` | shop-payment | Như trên |
| HTTPRoute `shop-api` | shop-order | `PathPrefix /api/orders` → `order-service:8080`. Không có rule cho payment |
| SecurityPolicy `shop-api-auth` | shop-order | JWT Cognito, chặn ID token, GET theo `readGroups`, POST theo `writeGroups`, còn lại 403 |
| BackendTrafficPolicy `shop-api-traffic` | shop-order | Timeout 10s; chỉ retry khi lỗi kết nối (không retry 5xx vì POST tạo đơn không idempotent) |
| NetworkPolicy (2) | shop-order, shop-payment | Chỉ khi `networkPolicy.enabled=true` |

Pod chạy non-root (UID 65534), root filesystem chỉ đọc, bỏ mọi Linux capability, không mount token ServiceAccount. Annotation `checksum/code` đổi khi sửa code, nên `helm upgrade` tự tạo lại Pod.

## 1. Chuẩn bị

Đã có từ các bước trước:

- Envoy Gateway và Gateway `eg-gateway` (namespace `eg-gateway`) đang `Programmed`.
- DNS `*.gitlabonlinecom.click` trỏ về NLB, cert ACM wildcard. Host `store.` dùng luôn, không cần tạo thêm.
- Cognito User Pool, client `demo-cli` và các user test (`config/cognito.env` từ bước 02).

Nạp biến môi trường vào terminal (chỉ đọc file cấu hình, không triển khai gì):

```bash
cd envoy-gateway-service-mesh
```

```bash
source config/demo.env && source config/cognito.env
```

```bash
echo "DOMAIN=$DOMAIN"; echo "ISSUER=$COGNITO_ISSUER"
```

Kiểm tra Gateway:

```bash
kubectl get gateway -n eg-gateway eg-gateway
```

## 2. Tạo namespace

```bash
kubectl create namespace shop-order
```

```bash
kubectl create namespace shop-payment
```

Chỉ `shop-order` được phép gắn HTTPRoute vào Gateway. Listener `https` chỉ nhận route từ namespace có label này:

```bash
kubectl label namespace shop-order gateway.demo.io/attach=true
```

`shop-payment` **không** gắn label, nên dù ai đó tạo HTTPRoute trong đó, Gateway cũng không nhận.

```bash
kubectl get namespace shop-order shop-payment --show-labels
```

## 3. Xem trước manifest với helm template

Kiểm tra chart:

```bash
helm lint app-v2/demo-shop --set cognito.issuer="$COGNITO_ISSUER"
```

Render ra file để đọc:

```bash
helm template demo-shop app-v2/demo-shop -n shop-order --set domain="$DOMAIN" --set cognito.issuer="$COGNITO_ISSUER" > /tmp/demo-shop.yaml
```

```bash
grep -E "^kind:|^  name:|^  namespace:" /tmp/demo-shop.yaml | paste - - -
```

Kết quả mong đợi: 11 resource (2 ServiceAccount, 2 ConfigMap, 2 Service, 2 Deployment, BackendTrafficPolicy, HTTPRoute, SecurityPolicy).

Cho API server kiểm tra schema (CRD, quyền) mà không tạo gì:

```bash
kubectl apply --dry-run=server -f /tmp/demo-shop.yaml
```

## 4. Triển khai

Chọn **một** trong hai cách.

### Cách A: helm upgrade --install (khuyến nghị)

Helm quản lý release: nâng cấp, xem lịch sử, rollback, gỡ bằng một lệnh.

```bash
helm upgrade --install demo-shop app-v2/demo-shop -n shop-order --set domain="$DOMAIN" --set cognito.issuer="$COGNITO_ISSUER" --wait
```

```bash
helm list -n shop-order
```

### Cách B: helm template + kubectl apply

Dùng Helm chỉ để sinh YAML, `kubectl` áp vào cụm (phù hợp khi muốn review file hoặc đưa vào GitOps):

```bash
kubectl apply -f /tmp/demo-shop.yaml
```

```bash
kubectl rollout status deploy/order-service -n shop-order
```

```bash
kubectl rollout status deploy/payment-service -n shop-payment
```

> Không trộn hai cách cho cùng resource: resource tạo bằng `kubectl apply` không thuộc release Helm, `helm install` sau đó sẽ báo lỗi "resource already exists".

## 5. Kiểm tra trạng thái

Pod và Service:

```bash
kubectl get pods,svc -n shop-order
```

```bash
kubectl get pods,svc -n shop-payment
```

Mỗi namespace có 2 Pod `Running` `1/1`.

```bash
kubectl logs -n shop-payment deploy/payment-service | head -3
```

Mong đợi dòng `listening on :8080, limit 1000`.

HTTPRoute được Gateway nhận:

```bash
kubectl get httproute -n shop-order shop-api -o custom-columns='NAME:.metadata.name,HOST:.spec.hostnames[0],ACCEPTED:.status.parents[0].conditions[?(@.type=="Accepted")].status,REFS:.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status'
```

Policy được chấp nhận:

```bash
kubectl get securitypolicy,backendtrafficpolicy -n shop-order -o custom-columns='KIND:.kind,NAME:.metadata.name,STATUS:.status.ancestors[0].conditions[0].reason'
```

Mong đợi `ACCEPTED=True`, `REFS=True`, policy `Accepted`.

## 6. Test gọi trực tiếp trong cụm (east-west)

Gọi thẳng payment-service từ một Pod tạm, **không qua gateway, không cần token**:

```bash
kubectl run curl-test -n shop-order --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- curl -s -X POST -H 'Content-Type: application/json' -d '{"order_id":"manual-1","amount":50}' http://payment-service.shop-payment.svc.cluster.local:8080/payments
```

Mong đợi JSON `"status": "APPROVED"`. Tức là **mọi Pod trong cụm đều gọi được payment-service** mà không bị kiểm tra gì. Mục 9 dùng NetworkPolicy để chặn việc này.

Gọi thẳng order-service, bỏ qua JWT của gateway:

```bash
kubectl run curl-test -n default --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- curl -s http://order-service.shop-order.svc.cluster.local:8080/api/orders
```

## 7. Lấy token Cognito

Access token của user `developer` (được đọc + tạo đơn) và `viewer` (chỉ đọc):

```bash
TOKEN_DEV=$(aws cognito-idp initiate-auth --region "$AWS_REGION" --client-id "$DEMO_CLI_CLIENT_ID" --auth-flow USER_PASSWORD_AUTH --auth-parameters "USERNAME=$USER_DEV_EMAIL,PASSWORD=$USER_DEV_PASSWORD" --query AuthenticationResult.AccessToken --output text)
```

```bash
TOKEN_VIEW=$(aws cognito-idp initiate-auth --region "$AWS_REGION" --client-id "$DEMO_CLI_CLIENT_ID" --auth-flow USER_PASSWORD_AUTH --auth-parameters "USERNAME=$USER_VIEWER_EMAIL,PASSWORD=$USER_VIEWER_PASSWORD" --query AuthenticationResult.AccessToken --output text)
```

ID token của developer (để thử bị chặn):

```bash
IDTOKEN_DEV=$(aws cognito-idp initiate-auth --region "$AWS_REGION" --client-id "$DEMO_CLI_CLIENT_ID" --auth-flow USER_PASSWORD_AUTH --auth-parameters "USERNAME=$USER_DEV_EMAIL,PASSWORD=$USER_DEV_PASSWORD" --query AuthenticationResult.IdToken --output text)
```

```bash
U=https://store.$DOMAIN
```

Token hết hạn sau 1 giờ, chạy lại các lệnh trên khi gặp 401.

## 8. Test qua Envoy Gateway

| # | Kịch bản | Mong đợi |
|---|---|---|
| T1 | Không có token | 401 |
| T2 | viewer `GET /api/orders` | 200 |
| T3 | viewer `POST /api/orders` | 403 (viewer không có quyền tạo đơn) |
| T4 | developer `POST` amount 100 | 201, `status: PAID`, `payment.status: APPROVED` |
| T5 | developer `POST` amount 5000 | 402, `status: PAYMENT_DECLINED` |
| T6 | developer `POST` body sai | 400 |
| T7 | `GET /api/orders/<id>` vừa tạo | 200, đúng đơn |
| T8 | `GET /api/payments` | 404 (payment-service không public) |
| T9 | Gửi giả header `x-jwt-sub: hacker` | `customer` vẫn là `sub` thật của token |
| T10 | Dùng ID token thay access token | 403 |
| T11 | Lần theo `x-request-id` | `request_id` của đơn = `payment.request_id` |

**T1** (mong đợi `401`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' $U/api/orders
```

**T2** (mong đợi `200`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN_VIEW" $U/api/orders
```

**T3** (mong đợi `403`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $TOKEN_VIEW" -H 'Content-Type: application/json' -d '{"item":"book","amount":100}' $U/api/orders
```

**T4**: tạo đơn được thanh toán, lưu id đơn vào biến `ORDER_ID`:

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN_DEV" -H 'Content-Type: application/json' -d '{"item":"book","amount":100}' -w '\nHTTP %{http_code}\n' $U/api/orders | tee /tmp/order.json
```

```bash
ORDER_ID=$(head -1 /tmp/order.json | jq -r .id); echo $ORDER_ID
```

Kết quả mẫu:

```json
{"id": "ord-7d53445b", "item": "book", "amount": 100.0, "customer": "<sub của user developer>", "status": "PAID",
 "request_id": "1f0c...", "payment": {"id": "pay-d4fabb37", "status": "APPROVED", "caller": "order-service", "request_id": "1f0c...", ...}}
HTTP 201
```

**T5**: số tiền vượt ngưỡng 1000 (mong đợi `PAYMENT_DECLINED DECLINED` và `HTTP 402`):

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN_DEV" -H 'Content-Type: application/json' -d '{"item":"tv","amount":5000}' -w '\nHTTP %{http_code}\n' $U/api/orders | head -1 | jq -r '.status + " " + .payment.status + " " + (.payment.reason // "")'
```

**T6** (mong đợi `400`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $TOKEN_DEV" -H 'Content-Type: application/json' -d '{"item":""}' $U/api/orders
```

**T7**:

```bash
curl -s -H "Authorization: Bearer $TOKEN_VIEW" $U/api/orders/$ORDER_ID | jq '{id, status, customer}'
```

**T8** (mong đợi `404`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN_DEV" $U/api/payments
```

**T9**: gửi kèm header giả `x-jwt-sub: hacker`, rồi so với `sub` thật của token:

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN_DEV" -H 'x-jwt-sub: hacker' -H 'Content-Type: application/json' -d '{"item":"pen","amount":5}' $U/api/orders | jq -r .customer
```

```bash
aws cognito-idp get-user --region "$AWS_REGION" --access-token "$TOKEN_DEV" --query "UserAttributes[?Name=='sub'].Value" --output text
```

Hai giá trị phải giống nhau và khác `hacker`. ClientTrafficPolicy của `eg-platform` xoá `x-jwt-sub` client gửi (`stripRequestHeaders`) trước khi bước JWT điền giá trị thật.

**T10** (mong đợi `403`, luật `reject-id-tokens`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $IDTOKEN_DEV" $U/api/orders
```

**T11**: lần theo một request qua cả hai service bằng `request_id`:

```bash
RID=$(head -1 /tmp/order.json | jq -r .request_id); echo $RID
```

```bash
kubectl logs -n shop-order -l app=order-service --prefix --tail=200 | grep "$RID"
```

```bash
kubectl logs -n shop-payment -l app=payment-service --prefix --tail=200 | grep "$RID"
```

```bash
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -c envoy --prefix --tail=500 | grep "$RID"
```

Cùng một id xuất hiện ở Envoy, order-service và payment-service, kèm tên Pod đã xử lý.

> Dữ liệu lưu trong RAM của từng Pod, mỗi service chạy 2 Pod. `GET /api/orders` có thể chỉ thấy một phần đơn (tuỳ request rơi vào Pod nào) và `GET /api/orders/<id>` đôi khi trả 404. Đây là giới hạn của demo, app thật dùng database chung. Muốn kết quả ổn định khi test thì giảm về 1 Pod: `--set order.replicas=1 --set payment.replicas=1`.

## 9. Chặn east-west bằng NetworkPolicy (tuỳ chọn)

Mục tiêu:

- payment-service **chỉ** nhận request từ Pod `order-service` trong namespace `shop-order`.
- order-service **chỉ** nhận request từ Pod Envoy proxy của Envoy Gateway.

### 9.1. Kiểm tra cụm hỗ trợ NetworkPolicy

EKS dùng Amazon VPC CNI. NetworkPolicy chỉ có tác dụng khi bật `enableNetworkPolicy` (VPC CNI ≥ 1.14):

```bash
kubectl get crd policyendpoints.networking.k8s.aws
```

```bash
kubectl get ds aws-node -n kube-system -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{" "}{.args}{"\n"}{end}'
```

Có CRD `policyendpoints` và container `aws-network-policy-agent` với `--enable-network-policy=true` là đã bật. Nếu chưa, bật trong EKS add-on `vpc-cni` (configuration `{"enableNetworkPolicy": "true"}`) trước khi tiếp tục. Chưa bật thì policy vẫn được tạo nhưng không chặn gì.

### 9.2. Bật

```bash
helm upgrade --install demo-shop app-v2/demo-shop -n shop-order --set domain="$DOMAIN" --set cognito.issuer="$COGNITO_ISSUER" --set networkPolicy.enabled=true --wait
```

(Cách B: thêm `--set networkPolicy.enabled=true` vào `helm template` ở mục 3, rồi `kubectl apply -f /tmp/demo-shop.yaml`.)

```bash
kubectl get networkpolicy -n shop-order; kubectl get networkpolicy -n shop-payment
```

### 9.3. Kiểm tra

Pod lạ gọi payment-service: **bị chặn**. Sau 5 giây curl hết thời gian chờ, không in JSON, kubectl báo `pod shop-order/curl-test terminated (Error)`:

```bash
kubectl run curl-test -n shop-order --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- curl -s -m 5 -X POST -d '{"order_id":"x","amount":1}' http://payment-service.shop-payment.svc.cluster.local:8080/payments
```

Pod lạ gọi thẳng order-service: **bị chặn** (cũng hết thời gian chờ):

```bash
kubectl run curl-test -n default --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- curl -s -m 5 http://order-service.shop-order.svc.cluster.local:8080/api/orders
```

Đi đúng đường (client → Envoy → order-service → payment-service): **vẫn chạy**, mong đợi `201` và `PAID`:

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN_DEV" -H 'Content-Type: application/json' -d '{"item":"book","amount":100}' -w '\nHTTP %{http_code}\n' $U/api/orders | head -1 | jq -r .status
```

NetworkPolicy chặn ở tầng IP/cổng (L3/L4), không phân biệt method/path và không mã hoá traffic. Muốn phân quyền L7 giữa service (vd order-service chỉ được `POST /payments`) và mTLS thì cần service mesh (Istio `AuthorizationPolicy`, xem `docs/10-next-steps-f5-istio.md`).

Tắt lại:

```bash
helm upgrade demo-shop app-v2/demo-shop -n shop-order --reuse-values --set networkPolicy.enabled=false --wait
```

## 10. Kịch bản lỗi và thay đổi cấu hình

**payment-service ngừng hoạt động**:

```bash
kubectl scale deploy/payment-service -n shop-payment --replicas=0
```

Mong đợi `PAYMENT_ERROR` + `HTTP 502`. Đơn vẫn được ghi, `payment.error` cho biết lý do (connection refused/timeout):

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN_DEV" -H 'Content-Type: application/json' -d '{"item":"book","amount":100}' -w '\nHTTP %{http_code}\n' $U/api/orders | head -1 | jq -r '.status + " " + .payment.error'
```

```bash
kubectl scale deploy/payment-service -n shop-payment --replicas=2
```

**Đổi ngưỡng duyệt thanh toán** lên 10000 (Deployment payment-service được tạo lại với biến môi trường mới):

```bash
helm upgrade demo-shop app-v2/demo-shop -n shop-order --reuse-values --set payment.approvalLimit=10000 --wait
```

**Sửa code**: sửa `app-v2/demo-shop/app/order_service.py` rồi chạy lại `helm upgrade` như trên. ConfigMap đổi nên annotation `checksum/code` đổi, Pod tự tạo lại.

**Lịch sử và rollback** (Cách A):

```bash
helm history demo-shop -n shop-order
```

```bash
helm rollback demo-shop 1 -n shop-order --wait
```

## 11. Xử lý sự cố

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| HTTPRoute `Accepted=False`, `NotAllowedByListeners` | Namespace `shop-order` thiếu label | `kubectl label namespace shop-order gateway.demo.io/attach=true` |
| Pod `CrashLoopBackOff` | Lỗi code Python | `kubectl logs -n shop-order deploy/order-service` |
| Pod `CreateContainerConfigError` | Thiếu ConfigMap code | `kubectl get cm -n shop-order`; cài lại chart |
| 401 dù có token | Token hết hạn, hoặc sai `cognito.issuer` | Lấy token mới; `kubectl get securitypolicy -n shop-order shop-api-auth -o yaml \| grep issuer` |
| 403 với user đúng group | Token là ID token, hoặc user chưa thuộc group | Dùng `AccessToken`; kiểm tra claim `cognito:groups` |
| `POST` trả 502 `PAYMENT_ERROR` | order-service không gọi được payment-service | `kubectl get pods,endpoints -n shop-payment`; nếu bật NetworkPolicy, kiểm tra label `app=order-service` |
| `POST` trả 504 | Timeout Envoy (10s) < thời gian xử lý | Tăng `requestTimeout` |
| 404 với `/api/orders` | Sai host (phải là `store.<domain>`) | `kubectl get httproute -n shop-order shop-api -o yaml` |
| Bật NetworkPolicy xong Pod `0/1 Ready` | Probe của kubelet bị chặn | Kiểm tra phiên bản VPC CNI/network policy agent; xem `kubectl describe pod` |

## 12. Gỡ

Cách A:

```bash
helm uninstall demo-shop -n shop-order
```

Cách B:

```bash
kubectl delete -f /tmp/demo-shop.yaml
```

Xoá namespace:

```bash
kubectl delete namespace shop-order shop-payment
```
