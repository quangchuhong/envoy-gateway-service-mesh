#!/usr/bin/env bash
# Bước 1: kiểm tra công cụ, kết nối cụm EKS, AWS Load Balancer Controller, ACM cert.
source "$(dirname "$0")/lib.sh"
load_env

log "Kiểm tra công cụ"
require_cmd aws kubectl helm jq curl openssl
ok "aws $(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2), kubectl $(kubectl version --client -o json | jq -r .clientVersion.gitVersion), helm $(helm version --short)"

log "Kiểm tra AWS credentials"
aws sts get-caller-identity --query Arn --output text >/dev/null || die "AWS credentials không hợp lệ"
ok "AWS identity: $(aws sts get-caller-identity --query Arn --output text)"

log "Kiểm tra kết nối cụm EKS"
kubectl cluster-info >/dev/null 2>&1 || die "kubectl chưa trỏ tới cụm. Chạy: aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $AWS_REGION"
ok "Context: $(kubectl config current-context)"
ok "Kubernetes server: $(kubectl version -o json | jq -r .serverVersion.gitVersion)"

log "Kiểm tra AWS Load Balancer Controller (cần để tạo NLB)"
if kubectl get deployment -A -l app.kubernetes.io/name=aws-load-balancer-controller -o name 2>/dev/null | grep -q .; then
  ok "AWS Load Balancer Controller đã cài"
else
  warn "Không thấy AWS Load Balancer Controller. Xem docs/01-prerequisites.md mục 3."
fi

log "Kiểm tra subnet cho NLB internet-facing"
# Tên cụm lấy từ kubeconfig (aws eks update-kubeconfig đặt tên cluster là ARN .../cluster/<tên>)
ctx_cluster=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || true)
cluster="${ctx_cluster##*/}"; cluster="${cluster:-$EKS_CLUSTER_NAME}"
if [[ -n "${EKS_CLUSTER_NAME:-}" && "$cluster" != "$EKS_CLUSTER_NAME" ]]; then
  warn "EKS_CLUSTER_NAME=$EKS_CLUSTER_NAME khác cụm đang kết nối ($cluster). Nên sửa trong config/demo.env."
fi
vpc=$(aws eks describe-cluster --region "$AWS_REGION" --name "$cluster" \
  --query cluster.resourcesVpcConfig.vpcId --output text 2>/dev/null || true)
if [[ -z "$vpc" || "$vpc" == "None" ]]; then
  warn "Không đọc được VPC của cụm $cluster (thiếu quyền eks:DescribeCluster?)"
elif [[ -n "${NLB_SUBNETS:-}" ]]; then
  ok "VPC của cụm: $vpc; NLB dùng subnet chỉ định NLB_SUBNETS=$NLB_SUBNETS"
  # Route 0.0.0.0/0 của route table chính (main) - áp cho subnet không gắn route table riêng
  main_gw=$(aws ec2 describe-route-tables --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$vpc" "Name=association.main,Values=true" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" --output text 2>/dev/null || true)
  nlb_azs=""; bad=0
  for sn in $(echo "$NLB_SUBNETS" | tr ',' ' '); do
    info=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$sn" \
      --query 'Subnets[0].[VpcId,AvailabilityZone,CidrBlock]' --output text 2>/dev/null || true)
    sn_vpc=$(echo "$info" | awk '{print $1}'); sn_az=$(echo "$info" | awk '{print $2}'); sn_cidr=$(echo "$info" | awk '{print $3}')
    if [[ -z "$sn_vpc" || "$sn_vpc" == "None" ]]; then
      warn "  $sn: không tìm thấy subnet"; bad=1; continue
    fi
    if [[ "$sn_vpc" != "$vpc" ]]; then
      warn "  $sn: thuộc VPC $sn_vpc, không phải VPC của cụm ($vpc)"; bad=1; continue
    fi
    gw=$(aws ec2 describe-route-tables --region "$AWS_REGION" --filters "Name=association.subnet-id,Values=$sn" \
      --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" --output text 2>/dev/null || true)
    [[ -z "$gw" || "$gw" == "None" ]] && gw="$main_gw"
    case "$gw" in
      igw-*) ok "  $sn ($sn_az, $sn_cidr): public, route 0.0.0.0/0 -> $gw" ;;
      *)     warn "  $sn ($sn_az, $sn_cidr): KHÔNG có route tới Internet Gateway (route: ${gw:-không có}) -> private subnet"; bad=1 ;;
    esac
    case " $nlb_azs " in *" $sn_az "*) ;; *) nlb_azs="$nlb_azs $sn_az" ;; esac
  done
  [[ "$bad" -eq 0 ]] || die "NLB internet-facing cần public subnet thuộc VPC $vpc. Sửa NLB_SUBNETS trong config/demo.env (docs/01 mục 3.1)."
  n_az=$(echo $nlb_azs | wc -w | tr -d ' ')
  [[ "$n_az" -ge 2 ]] && ok "NLB trải trên $n_az AZ:$nlb_azs" || warn "NLB chỉ ở 1 AZ ($nlb_azs): không chịu lỗi AZ"
else
  # AWS Load Balancer Controller chọn subnet có tag kubernetes.io/role/elb (giá trị "1" hoặc rỗng)
  azs_raw=$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$vpc" "Name=tag-key,Values=kubernetes.io/role/elb" \
    --query 'Subnets[].AvailabilityZone' --output text 2>/dev/null || true)
  # Đếm số AZ khác nhau (không dùng grep trong pipeline: grep không khớp sẽ làm set -e dừng script)
  elb_azs=0
  for az in $(echo "$azs_raw" | tr '\t' ' ' | tr ' ' '\n' | sort -u); do
    [[ "$az" == "None" ]] || elb_azs=$((elb_azs + 1))
  done
  if [[ "${elb_azs:-0}" -ge 2 ]]; then
    ok "VPC $vpc có subnet tag kubernetes.io/role/elb ở $elb_azs AZ"
  elif [[ "${elb_azs:-0}" -eq 1 ]]; then
    warn "Chỉ 1 AZ có subnet tag kubernetes.io/role/elb: NLB vẫn tạo được nhưng không chịu lỗi AZ"
  else
    die "VPC $vpc KHÔNG có subnet nào tag kubernetes.io/role/elb -> NLB sẽ không được tạo.
       Cách 1: gắn tag cho public subnet (xem docs/01-prerequisites.md mục 3.1):
         aws ec2 create-tags --region $AWS_REGION --resources <subnet-public-1> <subnet-public-2> --tags Key=kubernetes.io/role/elb,Value=1
       Cách 2: chỉ định subnet: đặt NLB_SUBNETS=<subnet-1>,<subnet-2> trong config/demo.env rồi chạy lại 03-gen-values.sh"
  fi
fi

log "Kiểm tra CRD Gateway API đã tồn tại từ trước (tránh xung đột phiên bản)"
if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  warn "Cụm đã có Gateway API CRD (bundle-version: $(kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')). Xem docs/03 mục 'Cụm đã có Gateway API CRD'."
else
  ok "Chưa có Gateway API CRD, chart Envoy Gateway sẽ cài"
fi

if [[ -n "${ACM_CERT_ARN:-}" ]]; then
  log "Kiểm tra ACM cert: $ACM_CERT_ARN"
  # ARN dạng arn:aws:acm:<region>:<account>:certificate/<id>
  cert_region=$(cut -d: -f4 <<< "$ACM_CERT_ARN"); cert_account=$(cut -d: -f5 <<< "$ACM_CERT_ARN")
  my_account=$(aws sts get-caller-identity --query Account --output text)
  [[ "$cert_region" == "$AWS_REGION" ]] && ok "Cert cùng region $AWS_REGION" \
    || die "Cert ở region $cert_region, cụm ở $AWS_REGION. NLB chỉ dùng được cert ACM cùng region."
  [[ "$cert_account" == "$my_account" ]] && ok "Cert cùng account $my_account" \
    || die "Cert thuộc account $cert_account, đang dùng account $my_account. NLB chỉ dùng được cert cùng account."

  cert_json=$(aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$ACM_CERT_ARN" --output json 2>/dev/null) \
    || die "Không đọc được cert (sai ARN hoặc thiếu quyền acm:DescribeCertificate)"
  st=$(jq -r .Certificate.Status <<< "$cert_json")
  [[ "$st" == "ISSUED" ]] && ok "Cert trạng thái ISSUED" || die "Cert trạng thái $st (cần ISSUED)"
  ok "Cert hết hạn: $(jq -r .Certificate.NotAfter <<< "$cert_json")"

  # Mỗi hostname của app phải khớp một tên trong cert (khớp chính xác, hoặc wildcard "*." đúng 1 cấp)
  # (không dùng mapfile: bash 3.2 mặc định của macOS không có lệnh này)
  sans=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && sans+=("$name")
  done < <(jq -r '.Certificate.SubjectAlternativeNames[], .Certificate.DomainName' <<< "$cert_json" | sort -u)
  ok "Tên trong cert: ${sans[*]}"
  for h in "portal.${DOMAIN}" "api.${DOMAIN}" "partner.${DOMAIN}"; do
    covered=no
    for s in "${sans[@]}"; do
      if [[ "$s" == "$h" ]] || { [[ "$s" == \*.* ]] && [[ "${h#*.}" == "${s#\*.}" ]]; }; then covered=yes; break; fi
    done
    [[ "$covered" == yes ]] && ok "Cert phủ $h" || die "Cert KHÔNG phủ $h. Kiểm tra DOMAIN trong config/demo.env."
  done
fi

ok "Hoàn tất kiểm tra"
