# 01 – Chuẩn bị

## 1. Công cụ trên máy triển khai

| Công cụ | Phiên bản tối thiểu | Dùng cho |
|---|---|---|
| `aws` CLI v2 | 2.22+ (có tham số `--managed-login-version` của Cognito) | Tạo Cognito, lấy token |
| `kubectl` | khớp ±1 minor với EKS | Làm việc với cụm |
| `helm` | 3.14+ (hỗ trợ OCI chart) | Cài toàn bộ |
| `jq`, `curl`, `openssl` | bất kỳ | Script và test |
| `kubeconform` | 0.6+ (tuỳ chọn) | `scripts/validate.sh` |
| `egctl` | trùng phiên bản Envoy Gateway (tuỳ chọn) | Debug cấu hình Envoy |

## 2. Cấu hình môi trường

```bash
cp config/demo.env.example config/demo.env
```

Sửa các biến trong `config/demo.env`:

| Biến | Ý nghĩa |
|---|---|
| `AWS_REGION`, `EKS_CLUSTER_NAME` | Region và tên cụm EKS hiện tại |
| `DOMAIN` | Domain cho demo, 3 app sẽ là `portal.`, `api.`, `partner.` + `DOMAIN` |
| `HOSTED_ZONE_ID` | Hosted zone Route 53 chứa `DOMAIN` |
| `ACM_CERT_ARN` | Cert ACM **cùng region**, nên là wildcard `*.DOMAIN` (ví dụ `*.demo.example.com`) |
| `COGNITO_DOMAIN_PREFIX` | Prefix cho Hosted UI, phải duy nhất trong region |

Trỏ `kubectl` vào cụm:

```bash
source config/demo.env
```

```bash
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
```

## 3. AWS Load Balancer Controller

Envoy Gateway tạo `Service type: LoadBalancer` với `loadBalancerClass: service.k8s.aws/nlb`. **AWS Load Balancer Controller** là thành phần tạo NLB từ Service đó. Kiểm tra:

```bash
kubectl get deployment -A -l app.kubernetes.io/name=aws-load-balancer-controller
```

Nếu chưa có, cài theo tài liệu AWS (cần IAM role cho ServiceAccount qua IRSA hoặc EKS Pod Identity):

```bash
helm repo add eks https://aws.github.io/eks-charts
```

```bash
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --set clusterName="$EKS_CLUSTER_NAME" --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller
```

Public subnet phải có tag `kubernetes.io/role/elb=1` để NLB internet-facing chọn đúng subnet.

## 4. Cert ACM

Yêu cầu cert wildcard cho domain demo (xác thực DNS qua Route 53):

```bash
aws acm request-certificate --region "$AWS_REGION" --domain-name "*.${DOMAIN}" --subject-alternative-names "${DOMAIN}" --validation-method DNS
```

Thêm bản ghi CNAME xác thực mà ACM yêu cầu vào Route 53, chờ trạng thái `ISSUED`, rồi đặt ARN vào `ACM_CERT_ARN`.

> **Không có ACM cert?** Để trống `ACM_CERT_ARN`. NLB khi đó chỉ chuyển TCP, Envoy terminate TLS bằng cert self-signed do chart sinh ra (chế độ `nlb-tcp`). Trình duyệt sẽ cảnh báo cert, và khi chạy test cần đặt `INSECURE_TLS=1`.

## 5. Kết nối ra Internet từ cụm

| Thành phần | Cần gọi tới | Để làm gì |
|---|---|---|
| Pod `envoy-gateway` (control plane) | `cognito-idp.<region>.amazonaws.com` | Đọc OIDC discovery |
| Pod Envoy Proxy (`eg-gateway`) | `cognito-idp.<region>.amazonaws.com`, `<prefix>.auth.<region>.amazoncognito.com` | Tải JWKS, đổi code lấy token, refresh token |

Node ở private subnet cần **NAT Gateway** (hoặc egress tương đương) cho các kết nối trên.

## 6. Tài nguyên cụm

| Thành phần | Request CPU / RAM (mặc định trong repo) |
|---|---|
| Envoy Gateway control plane | 2 × (100m / 256Mi) |
| Envoy Proxy | 2–6 × (250m / 256Mi), có HPA |
| Rate limit service | 1 × (do Envoy Gateway tạo) |
| Redis | 1 × (50m / 64Mi) |
| 3 app demo | khoảng 7 Pod × (20m / 32Mi) |

## 7. Chạy script kiểm tra

```bash
./scripts/01-check-prereqs.sh
```

Script kiểm tra công cụ, AWS credentials, kết nối cụm, AWS Load Balancer Controller, CRD Gateway API có sẵn hay không, và trạng thái cert ACM.
