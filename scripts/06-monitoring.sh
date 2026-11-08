#!/usr/bin/env bash
# Bước 6 (tuỳ chọn): Prometheus + Grafana. Grafana dùng CHUNG ALB với GitLab (cùng Ingress group).
#
#   scripts/06-monitoring.sh detect     # chỉ đọc: tìm Ingress/ALB của GitLab, sinh values Ingress cho Grafana
#   scripts/06-monitoring.sh install    # detect + cài kube-prometheus-stack + eg-monitoring + DNS
#   scripts/06-monitoring.sh dns        # tạo/cập nhật bản ghi Route 53 cho Grafana -> ALB
#   scripts/06-monitoring.sh password   # in tài khoản admin Grafana
#
# Biến tuỳ chọn (config/demo.env):
#   GRAFANA_HOST              mặc định grafana.<DOMAIN>
#   GITLAB_INGRESS_NAMESPACE  mặc định gitlab (namespace chứa Ingress ALB của GitLab)
#   ALB_GROUP_NAME            ép dùng group này thay vì tự tìm
#   PROM_STORAGE_CLASS        đặt (vd gp3) để Prometheus lưu dữ liệu trên EBS (cần EBS CSI driver)
source "$(dirname "$0")/lib.sh"
load_env
require_cmd kubectl helm jq aws openssl

MON_NS="${MON_NAMESPACE:-monitoring}"
GRAFANA_HOST="${GRAFANA_HOST:-grafana.${DOMAIN}}"
KPS_VERSION="${KPS_VERSION:-92.12.0}"
GITLAB_NS="${GITLAB_INGRESS_NAMESPACE:-gitlab}"
GEN="$REPO_ROOT/helm/values/generated"
ING_VALUES="$GEN/monitoring-ingress.yaml"
STORAGE_VALUES="$GEN/monitoring-storage.yaml"

# Annotation có hiệu lực ở cấp ALB/listener: mọi Ingress trong cùng group phải giống nhau (hoặc bỏ trống),
# nên chép nguyên từ Ingress của GitLab để không xung đột.
ALB_LEVEL_KEYS="scheme ip-address-type load-balancer-name security-groups manage-backend-security-group-rules subnets load-balancer-attributes ssl-policy wafv2-acl-arn waf-acl-id shield-advanced-protection tags inbound-cidrs listen-ports ssl-redirect customer-owned-ipv4-pool"

detect() {
  log "Tìm Ingress ALB của GitLab (namespace $GITLAB_NS)"
  local all gl group
  all=$(kubectl get ingress -A -o json)
  # Ingress dùng ALB: ingressClassName=alb hoặc annotation kubernetes.io/ingress.class=alb
  gl=$(echo "$all" | jq -c --arg ns "$GITLAB_NS" '[.items[]
        | select(.metadata.namespace==$ns)
        | select(.spec.ingressClassName=="alb" or .metadata.annotations["kubernetes.io/ingress.class"]=="alb")][0] // empty')
  [[ -n "$gl" ]] || die "Không thấy Ingress ALB nào trong namespace $GITLAB_NS. Đặt GITLAB_INGRESS_NAMESPACE đúng namespace của GitLab."
  ok "Ingress GitLab: $(echo "$gl" | jq -r '.metadata.namespace + "/" + .metadata.name') hosts: $(echo "$gl" | jq -r '[.spec.rules[]?.host] | join(", ")')"

  group="${ALB_GROUP_NAME:-$(echo "$gl" | jq -r '.metadata.annotations["alb.ingress.kubernetes.io/group.name"] // empty')}"
  if [[ -z "$group" ]]; then
    die "Ingress GitLab KHÔNG thuộc Ingress group nào (không có annotation alb.ingress.kubernetes.io/group.name).
       ALB chỉ dùng chung được giữa các Ingress cùng group. Xem docs/11-monitoring.md mục 'GitLab chưa dùng Ingress group'."
  fi
  ok "ALB group: $group"
  echo "$all" | jq -r --arg g "$group" '.items[] | select(.metadata.annotations["alb.ingress.kubernetes.io/group.name"]==$g)
     | "       - " + .metadata.namespace + "/" + .metadata.name + "  " + ([.spec.rules[]?.host] | join(","))'
  local alb; alb=$(echo "$gl" | jq -r '.status.loadBalancer.ingress[0].hostname // empty')
  [[ -n "$alb" ]] && ok "ALB hiện tại: $alb"

  # Chép annotation cấp ALB từ Ingress GitLab, thêm annotation riêng cho Grafana
  local keys_json cert
  keys_json=$(printf '%s\n' $ALB_LEVEL_KEYS | jq -R . | jq -s .)
  cert="${ACM_CERT_ARN:-$(echo "$gl" | jq -r '.metadata.annotations["alb.ingress.kubernetes.io/certificate-arn"] // empty')}"
  mkdir -p "$GEN"
  echo "$gl" | jq --argjson keys "$keys_json" --arg group "$group" --arg host "$GRAFANA_HOST" --arg cert "$cert" '
    (.metadata.annotations // {}) as $a
    | ([ $keys[] | "alb.ingress.kubernetes.io/" + . | select($a[.] != null) | {key: ., value: $a[.]} ] | from_entries) as $copied
    | {
        grafana: {
          ingress: {
            enabled: true,
            ingressClassName: "alb",
            annotations: ($copied + {
              "alb.ingress.kubernetes.io/group.name": $group,
              "alb.ingress.kubernetes.io/target-type": "ip",
              "alb.ingress.kubernetes.io/healthcheck-path": "/api/health",
              "alb.ingress.kubernetes.io/success-codes": "200"
            } + (if $cert != "" then {"alb.ingress.kubernetes.io/certificate-arn": $cert} else {} end)),
            hosts: [$host],
            path: "/",
            pathType: "Prefix"
          },
          "grafana.ini": { server: { root_url: ("https://" + $host) } }
        }
      }' > "$ING_VALUES"
  ok "Đã sinh $ING_VALUES (Grafana: https://$GRAFANA_HOST)"
  jq -r '.grafana.ingress.annotations | to_entries[] | "       " + .key + ": " + .value' "$ING_VALUES"
  if [[ -z "$cert" ]]; then
    warn "Không có cert: ACM_CERT_ARN trống và Ingress GitLab không có certificate-arn. HTTPS cho $GRAFANA_HOST sẽ lỗi."
  fi
}

install() {
  detect

  if kubectl get crd prometheuses.monitoring.coreos.com >/dev/null 2>&1 && ! helm status monitoring -n "$MON_NS" >/dev/null 2>&1; then
    warn "Cụm đã có CRD của Prometheus Operator từ nguồn khác. Kiểm tra không có Prometheus Operator thứ hai: kubectl get deploy -A | grep -i operator"
  fi

  local extra=()
  if [[ -n "${PROM_STORAGE_CLASS:-}" ]]; then
    jq -n --arg sc "$PROM_STORAGE_CLASS" '{prometheus:{prometheusSpec:{storageSpec:{volumeClaimTemplate:{spec:{
      storageClassName:$sc, accessModes:["ReadWriteOnce"], resources:{requests:{storage:"20Gi"}}}}}}}}' > "$STORAGE_VALUES"
    extra=(-f "$STORAGE_VALUES"); ok "Prometheus lưu dữ liệu trên PVC 20Gi, storageClass $PROM_STORAGE_CLASS"
  fi

  kubectl create namespace "$MON_NS" --dry-run=client -o yaml | kubectl apply -f -
  if ! kubectl get secret grafana-admin -n "$MON_NS" >/dev/null 2>&1; then
    kubectl create secret generic grafana-admin -n "$MON_NS" \
      --from-literal=admin-user=admin \
      --from-literal=admin-password="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
    ok "Đã tạo Secret grafana-admin (mật khẩu ngẫu nhiên)"
  fi

  log "Cài kube-prometheus-stack $KPS_VERSION (Prometheus Operator, Prometheus, Grafana)"
  helm upgrade --install monitoring oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
    --version "$KPS_VERSION" -n "$MON_NS" \
    -f "$REPO_ROOT/helm/monitoring/kube-prometheus-stack-values.yaml" -f "$ING_VALUES" ${extra[@]+"${extra[@]}"} \
    --wait --timeout 10m

  log "Cài eg-monitoring (PodMonitor/ServiceMonitor Envoy Gateway + dashboard)"
  helm upgrade --install eg-monitoring "$REPO_ROOT/helm/charts/eg-monitoring" -n "$MON_NS" --wait

  log "Chờ ALB nhận rule của Grafana"
  local i alb=""
  for i in $(seq 1 30); do
    alb=$(kubectl get ingress -n "$MON_NS" monitoring-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [[ -n "$alb" ]] && break; sleep 10
  done
  [[ -n "$alb" ]] || die "Ingress Grafana chưa có địa chỉ ALB. Xem: kubectl describe ingress -n $MON_NS monitoring-grafana"
  ok "Ingress Grafana gắn vào ALB: $alb"

  dns
  password
  ok "Mở https://$GRAFANA_HOST (thư mục dashboard 'Envoy Gateway')"
}

dns() {
  local alb zone alb_zone change
  alb=$(kubectl get ingress -n "$MON_NS" monitoring-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  [[ -n "$alb" ]] || die "Ingress Grafana chưa có địa chỉ ALB"
  alb_zone=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?DNSName=='${alb}'].CanonicalHostedZoneId" --output text)
  [[ -n "$alb_zone" && "$alb_zone" != "None" ]] || die "Không tìm thấy ALB $alb trong region $AWS_REGION"
  zone="${HOSTED_ZONE_ID:-$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN}." \
    --query "HostedZones[?Name=='${DOMAIN}.' && Config.PrivateZone==\`false\`].Id | [0]" --output text | sed 's|/hostedzone/||')}"
  [[ -n "$zone" && "$zone" != "None" ]] || die "Không tìm thấy hosted zone ${DOMAIN}"
  # Bản ghi cụ thể grafana.<domain> được ưu tiên hơn wildcard *.<domain> (đang trỏ về NLB của Envoy Gateway)
  change=$(aws route53 change-resource-record-sets --hosted-zone-id "$zone" --change-batch "$(jq -n \
    --arg n "$GRAFANA_HOST" --arg z "$alb_zone" --arg d "$alb" \
    '{Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:$n,Type:"A",AliasTarget:{HostedZoneId:$z,DNSName:$d,EvaluateTargetHealth:true}}}]}')" \
    --query ChangeInfo.Id --output text)
  aws route53 wait resource-record-sets-changed --id "$change"
  ok "DNS: $GRAFANA_HOST -> $alb"
}

password() {
  local u p
  u=$(kubectl get secret grafana-admin -n "$MON_NS" -o jsonpath='{.data.admin-user}' | openssl base64 -d -A)
  p=$(kubectl get secret grafana-admin -n "$MON_NS" -o jsonpath='{.data.admin-password}' | openssl base64 -d -A)
  ok "Grafana: user=$u  password=$p"
}

case "${1:-}" in
  detect) detect ;;
  install) install ;;
  dns) dns ;;
  password) password ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
