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

Script chạy được trên **macOS** (bash 3.2 mặc định của Apple) lẫn Linux (bash 4/5). Không cần cài bash mới; chỉ cần `jq`:

```bash
brew install jq
```

## 2. Cấu hình môi trường

```bash
cp config/demo.env.example config/demo.env
```

File mẫu đã điền sẵn giá trị của môi trường hiện tại. Chỉ cần kiểm tra lại, đặc biệt là `EKS_CLUSTER_NAME`:

| Biến | Giá trị trong file mẫu | Ý nghĩa |
|---|---|---|
| `AWS_REGION` | `ap-southeast-1` | Region của cụm EKS, cert ACM và Cognito |
| `EKS_CLUSTER_NAME` | `devops-tools` | **Sửa thành tên cụm EKS thật của bạn** |
| `DOMAIN` | `gitlabonlinecom.click` | 3 app sẽ là `portal.`, `api.`, `partner.gitlabonlinecom.click` |
| `HOSTED_ZONE_ID` | để trống | Hosted zone Route 53 của `DOMAIN`. Để trống thì `scripts/05-dns.sh` tự tìm public hosted zone theo tên domain |
| `ACM_CERT_ARN` | `arn:aws:acm:ap-southeast-1:609320954321:certificate/569f4470-6ac3-4ef2-be6e-7eb012397305` | Cert `*.gitlabonlinecom.click` đã import vào ACM. Để trống thì chuyển sang chế độ `nlb-tcp` (Envoy dùng cert self-signed) |
| `COGNITO_DOMAIN_PREFIX` | `gitlabonlinecom-eg-demo` | Prefix Hosted UI: `https://gitlabonlinecom-eg-demo.auth.ap-southeast-1.amazoncognito.com`. Phải duy nhất trong region; nếu bị trùng thì đổi tên khác |
| `COGNITO_POOL_NAME` | `eg-demo-users` | Tên User Pool |
| `EG_VERSION` | `v1.9.3` | Phiên bản Envoy Gateway |
| `NLB_SUBNETS` | trống | Danh sách subnet đặt NLB, cách nhau dấu phẩy. Để trống thì dùng subnet có tag `kubernetes.io/role/elb` (mục 3.1) |
| `GATEWAY_IP`, `INSECURE_TLS` | trống, `0` | Chỉ dùng khi chạy test (xem docs/08) |

AWS CLI phải dùng credentials của account **609320954321** (account chứa cert ACM và cụm EKS):

```bash
aws sts get-caller-identity --query Account --output text
```

Kết quả mong đợi: `609320954321`.

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

### 3.1 Subnet cho NLB internet-facing

AWS Load Balancer Controller chỉ đặt NLB **internet-facing** vào các **public subnet** (có route `0.0.0.0/0` tới Internet Gateway) mang tag `kubernetes.io/role/elb`. Không có subnet nào mang tag này thì NLB **không được tạo**: Service của Envoy đứng ở `EXTERNAL-IP <pending>`, Gateway báo `Programmed=False AddressNotAssigned`, và log của controller báo:

```
unable to resolve at least one subnet (0 match VPC and tags: [kubernetes.io/role/elb])
```

`scripts/01-check-prereqs.sh` kiểm tra điều kiện này. Có hai cách xử lý; chọn **một** trong hai.

**Cách 1 (khuyến nghị): gắn tag cho các public subnet của VPC**

Lấy VPC của cụm (tên cụm lấy từ kubeconfig):

```bash
CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' | awk -F/ '{print $NF}')
```

```bash
VPC=$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)
```

Liệt kê subnet kèm loại public/private. Subnet public là subnet có route `0.0.0.0/0` tới `igw-...`, qua route table riêng hoặc route table chính (main) của VPC:

```bash
MAIN_IGW=$(aws ec2 describe-route-tables --region "$AWS_REGION" --filters Name=vpc-id,Values="$VPC" Name=association.main,Values=true --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" --output text)
```

```bash
for sn in $(aws ec2 describe-subnets --region "$AWS_REGION" --filters Name=vpc-id,Values="$VPC" --query 'Subnets[].SubnetId' --output text); do gw=$(aws ec2 describe-route-tables --region "$AWS_REGION" --filters Name=association.subnet-id,Values="$sn" --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" --output text); [ "$gw" = "None" ] && gw="$MAIN_IGW (main)"; az=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$sn" --query 'Subnets[0].AvailabilityZone' --output text); echo "$sn $az $gw"; done
```

Dòng có `igw-...` là **public subnet**. Gắn tag cho các public subnet đó (nên mỗi AZ một subnet):

```bash
aws ec2 create-tags --region "$AWS_REGION" --resources subnet-xxxx subnet-yyyy subnet-zzzz --tags Key=kubernetes.io/role/elb,Value=1
```

> Cụm chạy trong **default VPC** (dải `172.31.0.0/16`) thì mọi subnet mặc định đều là public. Tag này chỉ dùng để AWS Load Balancer Controller **tự chọn** subnet cho Load Balancer internet-facing; nó không thay đổi route hay bảo mật của subnet, và các Load Balancer đang có không bị ảnh hưởng.

**Môi trường hiện tại dùng cách 2** với 3 subnet của cụm EKS `eks-cluster-ver1` (VPC `vpc-0a7f2229b36e6ceb5`):

```
NLB_SUBNETS=subnet-01e7b81b2c34fbaae,subnet-0729b4d3570c85035,subnet-063d005e791e4932f
```

Giá trị này đã có sẵn trong `config/demo.env.example` và là giá trị mặc định `envoyProxy.service.nlb.subnets` của chart `eg-platform`. `01-check-prereqs.sh` kiểm tra từng subnet: thuộc VPC của cụm và có route `0.0.0.0/0` tới Internet Gateway (public). Nếu có subnet private, script dừng và báo subnet nào; khi đó thay bằng public subnet cùng AZ, hoặc dùng cách 1.

**Cách 2: chỉ định subnet trực tiếp, không gắn tag**

Dùng khi VPC dùng chung và bạn không được sửa tag. Đặt trong `config/demo.env`:

```bash
export NLB_SUBNETS=subnet-xxxx,subnet-yyyy,subnet-zzzz
```

Chạy lại `./scripts/03-gen-values.sh`. Chart sẽ thêm annotation `service.beta.kubernetes.io/aws-load-balancer-subnets` cho Service của Envoy.

**Sau khi xử lý**, áp dụng lại để AWS Load Balancer Controller tạo NLB:

```bash
./scripts/04-deploy.sh platform
```

Controller tự thử lại định kỳ, nhưng khoảng cách giữa các lần thử tăng dần (tới hàng chục phút). Chạy lại lệnh trên giúp có NLB ngay.

## 4. Cert ACM

**Môi trường hiện tại đã có cert**, không cần tạo mới:

| | |
|---|---|
| ARN | `arn:aws:acm:ap-southeast-1:609320954321:certificate/569f4470-6ac3-4ef2-be6e-7eb012397305` |
| Domain | `*.gitlabonlinecom.click` |
| Account / region | `609320954321` / `ap-southeast-1` |

ARN đã được đặt sẵn trong `config/demo.env.example` (`ACM_CERT_ARN`) và làm giá trị mặc định của chart `eg-platform`. Xem thông tin cert:

```bash
aws acm describe-certificate --region ap-southeast-1 --certificate-arn arn:aws:acm:ap-southeast-1:609320954321:certificate/569f4470-6ac3-4ef2-be6e-7eb012397305 --query 'Certificate.{Status:Status,Domain:DomainName,SANs:SubjectAlternativeNames,NotAfter:NotAfter,Type:Type}'
```

Điều kiện để NLB dùng được cert, đều được `scripts/01-check-prereqs.sh` kiểm tra tự động:

- Trạng thái `ISSUED`.
- Cùng **region** với cụm EKS (`ap-southeast-1`).
- Cùng **account** với cụm EKS (`609320954321`). NLB không dùng được cert ACM của account khác.
- Phủ đủ 3 hostname: `portal.`, `api.`, `partner.gitlabonlinecom.click`. Wildcard `*.gitlabonlinecom.click` chỉ phủ **một cấp** subdomain, nên không dùng được cho tên dạng `a.b.gitlabonlinecom.click`.

> Cert **mua ngoài rồi import vào ACM** sẽ **không tự gia hạn** như cert do ACM cấp. Nhớ import lại cert mới (dùng `aws acm import-certificate --certificate-arn <ARN cũ>` để giữ nguyên ARN) trước ngày hết hạn. Khi giữ nguyên ARN, NLB tự dùng cert mới mà không cần cài lại chart. Script kiểm tra in ra ngày hết hạn của cert.

Môi trường khác, nếu cần tạo cert mới do ACM cấp (xác thực DNS qua Route 53):

```bash
aws acm request-certificate --region "$AWS_REGION" --domain-name "*.${DOMAIN}" --subject-alternative-names "${DOMAIN}" --validation-method DNS
```

Thêm bản ghi CNAME xác thực mà ACM yêu cầu vào Route 53, chờ trạng thái `ISSUED`, rồi đặt ARN vào `ACM_CERT_ARN`.

> **Không có ACM cert?** Để trống `ACM_CERT_ARN`. NLB khi đó chỉ chuyển TCP, Envoy terminate TLS bằng cert self-signed do chart sinh ra (chế độ `nlb-tcp`). Trình duyệt sẽ cảnh báo cert, và khi chạy test cần đặt `INSECURE_TLS=1`.

## 5. Kết nối ra Internet từ cụm

| Thành phần | Cần gọi tới | Để làm gì |
|---|---|---|
| Pod `envoy-gateway` (control plane) | `cognito-idp.ap-southeast-1.amazonaws.com` | Đọc OIDC discovery |
| Pod Envoy Proxy (`envoy-gateway-system`) | `cognito-idp.ap-southeast-1.amazonaws.com`, `gitlabonlinecom-eg-demo.auth.ap-southeast-1.amazoncognito.com` | Tải JWKS, đổi code lấy token, refresh token |

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

| Hạng mục | Script kiểm tra | Khi lỗi |
|---|---|---|
| Công cụ | `aws`, `kubectl`, `helm`, `jq`, `curl`, `openssl` có sẵn | Dừng |
| AWS credentials | `aws sts get-caller-identity` chạy được | Dừng |
| Kết nối cụm | `kubectl cluster-info` chạy được | Dừng, gợi ý lệnh `update-kubeconfig` |
| AWS Load Balancer Controller | Có Deployment `aws-load-balancer-controller` | Cảnh báo |
| CRD Gateway API | Đã có sẵn trên cụm hay chưa (tránh xung đột phiên bản) | Cảnh báo |
| Cert ACM – region | Region trong ARN = `AWS_REGION` | Dừng |
| Cert ACM – account | Account trong ARN = account đang dùng | Dừng |
| Cert ACM – trạng thái | `ISSUED`; in ra ngày hết hạn | Dừng |
| Cert ACM – tên miền | Cert phủ `portal.`, `api.`, `partner.gitlabonlinecom.click` | Dừng |

Kết quả mong đợi với môi trường hiện tại (rút gọn):

```
[ OK ] Cert cùng region ap-southeast-1
[ OK ] Cert cùng account 609320954321
[ OK ] Cert trạng thái ISSUED
[ OK ] Tên trong cert: *.gitlabonlinecom.click ...
[ OK ] Cert phủ portal.gitlabonlinecom.click
[ OK ] Cert phủ api.gitlabonlinecom.click
[ OK ] Cert phủ partner.gitlabonlinecom.click
[ OK ] Hoàn tất kiểm tra
```
