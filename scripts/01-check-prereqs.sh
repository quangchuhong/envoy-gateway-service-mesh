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
  mapfile -t sans < <(jq -r '.Certificate.SubjectAlternativeNames[], .Certificate.DomainName' <<< "$cert_json" | sort -u)
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
