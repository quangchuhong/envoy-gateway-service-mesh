# 12. Định tuyến traffic theo URL Path, HTTP Method, HTTP Header

Hướng dẫn cấu hình rule định tuyến trong `HTTPRoute` (Gateway API) trên Envoy Gateway, kèm một app demo chạy được ngay: `https://shop.gitlabonlinecom.click` (chart `helm/charts/demo-routing`, namespace `demo-routing`). App này không cần đăng nhập, mỗi response cho biết request đã đi đâu:

| Response header | Ý nghĩa |
|---|---|
| `X-Routed-To` | Service backend đã nhận request |
| `X-Route-Rule` | Tên rule HTTPRoute đã khớp |

## 1. Mô hình

```
                             https://shop.gitlabonlinecom.click
                                         │
                                 Envoy (eg-gateway)
                                         │  chọn MỘT rule theo thứ tự ưu tiên (mục 2.3)
   ┌──────────────┬───────────────┬──────┴───────┬───────────────┬──────────────┬─────────────┐
 /about        /catalog        /catalog/       /users/<số>/    /orders          /products      / (còn lại)
 Exact         PathPrefix      internal        orders (regex)  theo METHOD      theo HEADER
   │              │               │               │            GET,HEAD│POST..│DELETE..       │
  web          catalog          admin        orders-read   orders-read │ orders-write │ 405    web
                                                                 + header x-client → mobile
                                                         /products: x-client/User-Agent → mobile,
                                                         x-beta+x-tenant / ?preview=1 → beta, còn lại → catalog
```

7 backend (`web`, `catalog`, `admin`, `orders-read`, `orders-write`, `mobile`, `beta`) đều là go-httpbin, mỗi cái 1 Pod. Chúng echo lại method, header và path dưới dạng JSON.

| File | Nội dung |
|---|---|
| `templates/route-path.yaml` | HTTPRoute `shop-path`: Exact, PathPrefix, prefix dài hơn, RegularExpression, catch-all |
| `templates/route-method.yaml` | HTTPRoute `shop-method`: GET/HEAD, POST/PUT/PATCH, path + method + header, 405 |
| `templates/route-header.yaml` | HTTPRoute `shop-header`: header Exact, header regex, AND nhiều header, query param |
| `templates/filters.yaml` | `HTTPRouteFilter`: rewrite path bằng regex, trả 405 trực tiếp |
| `templates/workload.yaml` | Deployment + Service cho 7 backend |

## 2. Kiến thức cần nắm

### 2.1. Cấu trúc một rule

```yaml
rules:
  - name: method-write-mobile        # tên rule (tuỳ chọn, hiện trong status/metrics)
    matches:                         # danh sách match: OR giữa các phần tử
      - path:                        # trong MỘT match: mọi điều kiện là AND
          type: PathPrefix
          value: /orders
        method: POST
        headers:
          - name: x-client
            value: mobile
        queryParams:
          - name: preview
            value: "1"
    filters: [...]                   # sửa request/response, rewrite, redirect...
    backendRefs: [...]               # Service đích (có thể nhiều, chia theo weight)
```

| Điều kiện | Kiểu | Ghi chú |
|---|---|---|
| `path` | `Exact`, `PathPrefix` (mặc định, value `/`), `RegularExpression` | Mỗi match có đúng 1 path |
| `method` | `GET`, `HEAD`, `POST`, `PUT`, `DELETE`, `CONNECT`, `OPTIONS`, `TRACE`, `PATCH` | Mỗi match có 1 method; nhiều method → nhiều match |
| `headers[]` | `Exact` (mặc định), `RegularExpression` | Tên header không phân biệt hoa thường; giá trị Exact **có** phân biệt |
| `queryParams[]` | `Exact` (mặc định), `RegularExpression` | Tên query param có phân biệt hoa thường |

Regex dùng cú pháp **RE2** (không có lookahead/backreference). Regex path khớp **toàn bộ** path.

### 2.2. Ba kiểu match path

| Kiểu | Value | Khớp | Không khớp |
|---|---|---|---|
| `Exact` | `/about` | `/about` | `/about/`, `/about/team` |
| `PathPrefix` | `/catalog` | `/catalog`, `/catalog/`, `/catalog/books` | `/catalogue` (prefix tính theo **segment**) |
| `RegularExpression` | `^/users/[0-9]+/orders$` | `/users/123/orders` | `/users/abc/orders`, `/users/1/orders/9` |

Query string (`?x=1`) không thuộc path nên không ảnh hưởng match path.

### 2.3. Thứ tự ưu tiên khi nhiều rule cùng khớp

Envoy chỉ chọn **một** rule. Envoy Gateway gộp mọi HTTPRoute gắn vào cùng hostname rồi sắp xếp theo:

1. Kiểu path: `Exact` > `RegularExpression` > `PathPrefix`
2. Cùng kiểu: path dài hơn thắng (`/catalog/internal` > `/catalog` > `/`)
3. Có `method` thắng không có `method`
4. Nhiều điều kiện `headers` hơn thắng
5. Nhiều điều kiện `queryParams` hơn thắng
6. Vẫn hoà: HTTPRoute tạo trước thắng, rồi theo tên `namespace/name`, rồi theo thứ tự rule trong file

Hệ quả thực tế:

- Header không "vượt" được path: request `/catalog/internal/x` có header `x-client: mobile` vẫn vào `admin` (path dài hơn được xét trước).
- Header thắng query param: `/products?preview=1` + `x-client: mobile` → `mobile` (RT-24).
- Gateway API chuẩn chỉ quy định Exact > Prefix; vị trí của regex là lựa chọn của Envoy Gateway. Tránh viết regex chồng lấn với prefix của rule khác.

Thứ tự thật trong Envoy của app demo (xuất bằng `egctl`, mục 5.3):

```
path=/about                                         shop-path   path-exact
regex=^/users/[0-9]+/orders$                        shop-path   path-regex
prefix=/catalog/internal                            shop-path   path-prefix-longer
prefix=/products  x-beta=true x-tenant=internal     shop-header header-and
prefix=/products  x-client=mobile                   shop-header header-exact
prefix=/products  user-agent~.*(iPhone|Android).*   shop-header header-regex
prefix=/products  ?preview=1                        shop-header query-param
prefix=/products                                    shop-header header-default
prefix=/catalog                                     shop-path   path-prefix
prefix=/orders    :method=POST x-client=mobile      shop-method method-write-mobile
prefix=/orders    :method=GET | HEAD                shop-method method-read
prefix=/orders    :method=POST | PUT | PATCH        shop-method method-write
prefix=/orders                                      shop-method method-not-allowed (405)
prefix=/                                            shop-path   default
```

### 2.4. Rewrite path và trả lời trực tiếp

- **Rewrite**: backend thường không có tiền tố như `/catalog`. `URLRewrite` chuẩn (`ReplacePrefixMatch`) chỉ dùng với match `PathPrefix`, `ReplaceFullPath` thay toàn bộ path. Demo dùng `HTTPRouteFilter` của Envoy Gateway kiểu `ReplaceRegexMatch` (`^/` → `/anything/`), áp được cho mọi kiểu match, kể cả regex.
- **Direct response**: rule không có `backendRefs`, chỉ có filter `HTTPRouteFilter.directResponse` → Envoy tự trả lời (ở đây 405 + header `Allow`), không gọi backend.
- Không có rule nào khớp → Envoy trả **404**. Rule khớp nhưng backend không tồn tại hoặc không có Pod → **500/503**.

## 3. Cài đặt

Đã có Gateway (bước 04) và DNS wildcard `*.gitlabonlinecom.click` (bước 05), cert ACM wildcard phủ luôn `shop.`.

```bash
git pull origin claude/eloquent-cerf-0p58lc
```

```bash
./scripts/03-gen-values.sh
```

```bash
./scripts/04-deploy.sh routing
```

Kết quả mong đợi: 3 HTTPRoute `ACCEPTED=True`, `REFS=True`.

```
NAME          ACCEPTED   REFS
shop-header   True       True
shop-method   True       True
shop-path     True       True
```

Cài thủ công (tương đương):

```bash
kubectl create namespace demo-routing
```

```bash
kubectl label namespace demo-routing gateway.demo.io/attach=true
```

```bash
helm upgrade --install demo-routing helm/charts/demo-routing -n demo-routing --wait
```

> Label `gateway.demo.io/attach=true` bắt buộc: listener `https` của `eg-gateway` chỉ nhận HTTPRoute từ namespace có label này (`allowedRoutes.namespaces.selector`). Thiếu label → route `Accepted=False`, reason `NotAllowedByListeners`.

## 4. Test

### 4.1. Bộ test tự động (24 case)

```bash
./tests/run-tests.sh routing
```

| Mã | Request | Mong đợi (`X-Routed-To` / `X-Route-Rule`) |
|---|---|---|
| RT-01 | `GET /about` | web / path-exact |
| RT-02 | `GET /about/team` | web / default (Exact không khớp) |
| RT-03 | `GET /catalog/books` | catalog / path-prefix |
| RT-04 | `GET /catalogue` | web / default (prefix theo segment) |
| RT-05 | `GET /catalog/internal/stock` | admin / path-prefix-longer |
| RT-06 | `GET /users/123/orders` | orders-read / path-regex |
| RT-07 | `GET /users/abc/orders` | web / default |
| RT-08 | `GET /catalog/books` | backend nhận path `/anything/catalog/books` |
| RT-09 | `GET /orders` | orders-read / method-read |
| RT-10 | `HEAD /orders/1` | orders-read / method-read |
| RT-11 | `POST /orders` | orders-write / method-write |
| RT-12 | `PATCH /orders/1` | orders-write / method-write |
| RT-13 | `DELETE /orders/1` | **405**, `Allow: GET, HEAD, POST, PUT, PATCH` |
| RT-14 | `POST /orders` + `x-client: mobile` | mobile / method-write-mobile |
| RT-15 | `GET /products` | catalog / header-default |
| RT-16 | `x-client: mobile` | mobile / header-exact |
| RT-17 | `X-CLIENT: mobile` | mobile (tên header không phân biệt hoa thường) |
| RT-18 | `x-client: Mobile` | catalog (giá trị phân biệt hoa thường) |
| RT-19 | `User-Agent: ...iPhone...` | mobile / header-regex |
| RT-20 | chỉ `x-beta: true` | catalog (AND cần đủ 2 header) |
| RT-21 | `x-beta: true` + `x-tenant: internal` | beta / header-and |
| RT-22 | 3 header `x-client`, `x-beta`, `x-tenant` | beta (2 header khớp thắng 1 header) |
| RT-23 | `/products?preview=1` | beta / query-param |
| RT-24 | `?preview=1` + `x-client: mobile` | mobile (header thắng query) |

Nhóm `routing` không nằm trong `./tests/run-tests.sh` (all) để không đổi kết quả 48 test cũ.

### 4.2. Test tay bằng curl

Xem backend và rule đã khớp:

```bash
curl -s -o /dev/null -D - https://shop.gitlabonlinecom.click/catalog/internal/stock | grep -i "x-route"
```

Theo method:

```bash
for m in GET POST PUT PATCH DELETE OPTIONS; do printf '%-8s ' "$m"; curl -s -o /dev/null -X "$m" -w '%{http_code} ' -D - https://shop.gitlabonlinecom.click/orders | grep -i "x-routed-to\|x-route-rule" | tr -d '\r' | tr '\n' ' '; echo; done
```

Theo header:

```bash
curl -s -o /dev/null -D - -H 'x-client: mobile' https://shop.gitlabonlinecom.click/products | grep -i "x-route"
```

```bash
curl -s -o /dev/null -D - -A 'Mozilla/5.0 (Linux; Android 14)' https://shop.gitlabonlinecom.click/products | grep -i "x-route"
```

Xem backend nhận gì (method, path sau rewrite, header):

```bash
curl -s -X POST -H 'x-client: mobile' -d '{"item":1}' https://shop.gitlabonlinecom.click/orders | jq '{method, url, headers: .headers["X-Client"]}'
```

## 5. Tự viết rule mới

### 5.1. Quy trình

1. Chọn HTTPRoute (hoặc tạo mới) gắn vào cùng `parentRefs` + `hostnames`.
2. Viết rule, đặt `name` rõ ràng.
3. Kiểm tra không cần cụm: `helm lint`, `helm template`, rồi `./scripts/validate.sh`.
4. Cài: `helm upgrade --install ...`.
5. Kiểm tra status route (mục 6) và test bằng curl.

### 5.2. Mẫu rule hay dùng

**Tách API version theo path** (`/v1/*` → orders-v1, `/v2/*` → orders-v2, backend không có tiền tố):

```yaml
- name: api-v2
  matches:
    - path: { type: PathPrefix, value: /v2 }
  filters:
    - type: URLRewrite
      urlRewrite:
        path: { type: ReplacePrefixMatch, replacePrefixMatch: / }
  backendRefs:
    - { name: orders-v2, port: 8080 }
```

**Chỉ cho phép đọc** (GET/HEAD vào backend, method khác 405) — xem `route-method.yaml`.

**Chọn phiên bản theo header, còn lại chia canary theo weight** — đã dùng ở App 2 (`helm/charts/demo-orders/templates/httproutes.yaml`, header `x-api-version: v2`):

```yaml
- name: version-by-header
  matches:
    - path: { type: PathPrefix, value: /orders }
      headers:
        - { name: x-api-version, value: v2 }
  backendRefs:
    - { name: orders-api-v2, port: 8080 }
- name: canary-by-weight
  matches:
    - path: { type: PathPrefix, value: /orders }
  backendRefs:
    - { name: orders-api-v1, port: 8080, weight: 90 }
    - { name: orders-api-v2, port: 8080, weight: 10 }
```

**Định tuyến theo cookie** (header `Cookie` là một chuỗi, dùng regex):

```yaml
headers:
  - name: cookie
    type: RegularExpression
    value: "(^|.*; )beta=1(;.*|$)"
```

**Nhiều host khác nhau, cùng path**: tách HTTPRoute theo `hostnames`, mỗi host một route.

### 5.3. Định tuyến theo claim JWT (group Cognito)

Muốn user group `devops-admin` vào backend riêng: SecurityPolicy JWT chép claim ra header rồi **tính lại route** (`recomputeRoute: true`), vì Envoy chọn route trước khi filter JWT chạy.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
spec:
  targetRefs:
    - { group: gateway.networking.k8s.io, kind: HTTPRoute, name: shop-admin }
  jwt:
    providers:
      - name: cognito
        issuer: https://cognito-idp.ap-southeast-1.amazonaws.com/<USER_POOL_ID>
        remoteJWKS:
          uri: https://cognito-idp.ap-southeast-1.amazonaws.com/<USER_POOL_ID>/.well-known/jwks.json
        claimToHeaders:
          - { claim: "cognito:groups", header: x-user-groups }
        recomputeRoute: true
```

Rule tương ứng: `headers: [{ name: x-user-groups, type: RegularExpression, value: ".*devops-admin.*" }]`.

Bảo mật: client có thể tự gửi header `x-user-groups` để giả mạo. Thêm header này vào `clientTraffic.stripRequestHeaders` trong `helm/charts/eg-platform/values.yaml` (giống `x-jwt-sub`, `x-partner-id` đang dùng). ClientTrafficPolicy xoá nó ngay khi request vào Envoy, trước khi chọn route và trước filter JWT, nên header chỉ còn giá trị lấy từ token đã xác thực. Đồng thời bắt buộc JWT trên route (không có token → 401).

## 6. Kiểm tra và xử lý sự cố

Status của route:

```bash
kubectl get httproute -n demo-routing -o custom-columns='NAME:.metadata.name,ACCEPTED:.status.parents[0].conditions[?(@.type=="Accepted")].reason,REFS:.status.parents[0].conditions[?(@.type=="ResolvedRefs")].reason'
```

Thứ tự route thật trong Envoy (cần `egctl` cùng phiên bản v1.9.3):

```bash
egctl config envoy-proxy route -n envoy-gateway-system "$(kubectl get pod -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -o jsonpath='{.items[0].metadata.name}')" -o json | jq -r '.. | .virtualHosts? // empty | .[] | select(.domains[] | test("shop")) | .routes[] | .name'
```

Access log (route nào xử lý request):

```bash
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -c envoy --tail=200 | grep shop. | tail -5
```

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| Route `Accepted=False` `NotAllowedByListeners` | Namespace thiếu label `gateway.demo.io/attach=true` | `kubectl label namespace demo-routing gateway.demo.io/attach=true` |
| `ResolvedRefs=False` `BackendNotFound` | Sai tên/port Service trong `backendRefs` | `kubectl get svc -n demo-routing` |
| `ResolvedRefs=False` với `ExtensionRef` | `HTTPRouteFilter` sai tên hoặc khác namespace | Filter phải cùng namespace với HTTPRoute |
| 404 | Không rule nào khớp (sai host, path, method) | Kiểm tra `hostnames`; nhớ PathPrefix theo segment |
| Vào nhầm backend | Rule khác có độ ưu tiên cao hơn | Xem thứ tự ở mục 2.3 / `egctl config envoy-proxy route` |
| Header match không ăn | Giá trị khác hoa thường, hoặc header bị proxy phía trước (F5/CDN) xoá | Dùng `RegularExpression` `(?i)mobile`; kiểm tra header backend nhận bằng `jq .headers` |
| 500 `no healthy upstream` / 503 | Service không có Pod Ready | `kubectl get pods -n demo-routing` |
| Regex bị từ chối | Cú pháp không phải RE2 (lookahead `(?=`...) | Viết lại bằng RE2 |

## 7. Gỡ

```bash
helm uninstall demo-routing -n demo-routing
```

```bash
kubectl delete namespace demo-routing
```

(`./scripts/99-cleanup.sh --apps` cũng gỡ demo-routing.)
