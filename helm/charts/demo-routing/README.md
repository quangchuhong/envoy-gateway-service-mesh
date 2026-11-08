# Chart `demo-routing`

Demo các kiểu định tuyến của `HTTPRoute` trên Envoy Gateway: theo **URL Path**, **HTTP Method**, **HTTP Header** và query param. Host `https://shop.<domain>`, không cần đăng nhập. Hướng dẫn đầy đủ: [docs/12-traffic-routing.md](../../../docs/12-traffic-routing.md).

```bash
./scripts/04-deploy.sh routing
```

```bash
./tests/run-tests.sh routing
```

## Cấu trúc

```
demo-routing/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── _helpers.tpl        # parentRefs/hostnames chung, filter chung của rule, backendRef
    ├── workload.yaml       # Deployment + Service cho từng backend trong .Values.services
    ├── filters.yaml        # HTTPRouteFilter: to-anything (rewrite regex), method-not-allowed (405)
    ├── route-path.yaml     # HTTPRoute shop-path
    ├── route-method.yaml   # HTTPRoute shop-method
    └── route-header.yaml   # HTTPRoute shop-header
```

## values.yaml

| Key | Mặc định | Ý nghĩa |
|---|---|---|
| `domain` / `hostPrefix` | `gitlabonlinecom.click` / `shop` | Host của route: `shop.gitlabonlinecom.click` |
| `gateway.name/namespace/sectionName` | `eg-gateway` / `eg-gateway` / `https` | Listener mà route gắn vào |
| `image` | `mccutchen/go-httpbin:2.25.0` | Backend echo (cùng image App 2, 3) |
| `services` | `web, catalog, admin, orders-read, orders-write, mobile, beta` | Mỗi tên là một Deployment + Service cổng 8080. Tên được dùng trong `route-*.yaml` |
| `replicas` | `1` | Số Pod mỗi backend |
| `resources` | 10m CPU / 16Mi | Tài nguyên mỗi Pod |

## _helpers.tpl

| Helper | Sinh ra |
|---|---|
| `routing.routeSpecHead` | `parentRefs` (eg-gateway, listener https) + `hostnames` |
| `routing.ruleFilters "<rule>"` | `ExtensionRef` tới `to-anything` + `ResponseHeaderModifier` đặt `X-Route-Rule: <rule>` |
| `routing.backend "<svc>"` | `backendRef` tới Service `<svc>:8080` + `ResponseHeaderModifier` đặt `X-Routed-To: <svc>` |

Hai header response cho biết rule nào khớp và backend nào nhận. Bộ test RT-01…RT-24 dựa vào chúng.

## filters.yaml

| HTTPRouteFilter | Dùng cho | Chi tiết |
|---|---|---|
| `to-anything` | mọi rule có backend | `urlRewrite.path.type: ReplaceRegexMatch`, `^/` → `/anything/`. go-httpbin chỉ echo ở `/anything/*`; regex rewrite dùng được với mọi kiểu match (URLRewrite chuẩn `ReplacePrefixMatch` chỉ đi với `PathPrefix`) |
| `method-not-allowed` | rule `method-not-allowed` | `directResponse`: 405, body JSON, header `Allow`. Rule không có `backendRefs` |

## route-path.yaml (`shop-path`)

| Rule | Match | Backend |
|---|---|---|
| `path-exact` | `Exact /about` | web |
| `path-prefix` | `PathPrefix /catalog` | catalog |
| `path-prefix-longer` | `PathPrefix /catalog/internal` | admin |
| `path-regex` | `RegularExpression ^/users/[0-9]+/orders$` | orders-read |
| `default` | `PathPrefix /` (catch-all cho cả host) | web |

## route-method.yaml (`shop-method`)

| Rule | Match (path `/orders`) | Backend |
|---|---|---|
| `method-read` | `GET` hoặc `HEAD` (2 match = OR) | orders-read |
| `method-write` | `POST`, `PUT`, `PATCH` (3 match) | orders-write |
| `method-write-mobile` | `POST` + header `x-client: mobile` | mobile |
| `method-not-allowed` | không điều kiện method (DELETE, OPTIONS…) | 405 trực tiếp |

## route-header.yaml (`shop-header`)

| Rule | Match (path `/products`) | Backend |
|---|---|---|
| `header-exact` | `x-client: mobile` | mobile |
| `header-regex` | `user-agent` ~ `.*(iPhone\|Android).*` | mobile |
| `header-and` | `x-beta: true` **và** `x-tenant: internal` | beta |
| `query-param` | `?preview=1` | beta |
| `header-default` | không điều kiện | catalog |

## Thêm rule

1. Thêm backend mới (nếu cần) vào `services` trong values.
2. Thêm rule vào file route phù hợp, dùng `routing.ruleFilters` và `routing.backend`.
3. `helm template demo-routing helm/charts/demo-routing -n demo-routing` để xem kết quả, `./scripts/validate.sh` để kiểm tra schema.
4. `helm upgrade --install demo-routing helm/charts/demo-routing -n demo-routing --wait`.
