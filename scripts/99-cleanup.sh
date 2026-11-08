#!/usr/bin/env bash
# Gỡ demo (theo thứ tự ngược lại):
#   scripts/99-cleanup.sh --monitoring  # Prometheus/Grafana + bản ghi grafana.<DOMAIN> (ALB GitLab giữ nguyên)
#   scripts/99-cleanup.sh --dns         # xoá bản ghi Route 53 *.<DOMAIN> do scripts/05-dns.sh tạo
#   scripts/99-cleanup.sh --apps        # 3 app demo + demo-routing + namespace
#   scripts/99-cleanup.sh --platform    # Gateway (xoá NLB), EnvoyProxy, GatewayClass
#   scripts/99-cleanup.sh --eg          # Envoy Gateway + Redis (CRD giữ lại, xem docs/09)
#   scripts/99-cleanup.sh --cognito     # xoá User Pool Cognito + config/cognito.env
#   scripts/99-cleanup.sh --all
source "$(dirname "$0")/lib.sh"
load_env

clean_dns() {
  local zone="${HOSTED_ZONE_ID:-}" rr
  if [[ -z "$zone" ]]; then
    zone=$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN}." \
      --query "HostedZones[?Name=='${DOMAIN}.' && Config.PrivateZone==\`false\`].Id | [0]" --output text | sed 's|/hostedzone/||')
  fi
  [[ -n "$zone" && "$zone" != "None" ]] || { warn "Không tìm thấy hosted zone ${DOMAIN}"; return; }
  # Route 53 lưu ký tự "*" dưới dạng "\052"
  rr=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone" --output json \
    | jq -c --arg d "${DOMAIN}." '[.ResourceRecordSets[] | select(.Type=="A" and (.Name=="\\052."+$d or .Name=="*."+$d))][0] // empty')
  [[ -n "$rr" ]] || { warn "Không có bản ghi *.${DOMAIN}"; return; }
  aws route53 change-resource-record-sets --hosted-zone-id "$zone" \
    --change-batch "$(jq -n --argjson rr "$rr" '{Changes:[{Action:"DELETE",ResourceRecordSet:$rr}]}')" >/dev/null
  ok "Đã xoá bản ghi *.${DOMAIN} trong hosted zone $zone"
}
clean_monitoring() {
  local ns="${MON_NAMESPACE:-monitoring}" host="${GRAFANA_HOST:-grafana.${DOMAIN}}" zone="${HOSTED_ZONE_ID:-}" rr
  if [[ -z "$zone" ]]; then
    zone=$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN}." \
      --query "HostedZones[?Name=='${DOMAIN}.' && Config.PrivateZone==\`false\`].Id | [0]" --output text | sed 's|/hostedzone/||')
  fi
  if [[ -n "$zone" && "$zone" != "None" ]]; then
    rr=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone" --output json \
      | jq -c --arg n "${host}." '[.ResourceRecordSets[] | select(.Type=="A" and .Name==$n)][0] // empty')
    if [[ -n "$rr" ]]; then
      aws route53 change-resource-record-sets --hosted-zone-id "$zone" \
        --change-batch "$(jq -n --argjson rr "$rr" '{Changes:[{Action:"DELETE",ResourceRecordSet:$rr}]}')" >/dev/null
      ok "Đã xoá bản ghi $host"
    fi
  fi
  # Xoá Ingress Grafana trước: AWS LB Controller chỉ gỡ rule của Grafana, ALB của GitLab giữ nguyên
  helm uninstall eg-monitoring -n "$ns" 2>/dev/null || true
  helm uninstall monitoring -n "$ns" 2>/dev/null || true
  kubectl delete namespace "$ns" --ignore-not-found
  ok "Đã gỡ monitoring. CRD monitoring.coreos.com giữ lại (xem docs/11 mục Gỡ cài)"
}
clean_apps() {
  for r in demo-portal demo-orders demo-partner demo-routing; do helm uninstall "$r" -n "$r" 2>/dev/null || true; done
  kubectl delete namespace demo-portal demo-orders demo-partner demo-routing --ignore-not-found
  ok "Đã gỡ app"
}
clean_platform() {
  helm uninstall eg-platform -n eg-gateway 2>/dev/null || true
  kubectl delete namespace eg-gateway --ignore-not-found
  ok "Đã gỡ platform (NLB sẽ bị xoá bởi AWS Load Balancer Controller)"
}
clean_eg() {
  helm uninstall eg -n envoy-gateway-system 2>/dev/null || true
  helm uninstall eg-redis -n envoy-gateway-system 2>/dev/null || true
  kubectl delete namespace envoy-gateway-system --ignore-not-found
  ok "Đã gỡ Envoy Gateway"
}
clean_cognito() {
  [[ -n "${COGNITO_USER_POOL_ID:-}" ]] || { warn "Không có config/cognito.env"; return; }
  aws cognito-idp delete-user-pool-domain --region "$AWS_REGION" --user-pool-id "$COGNITO_USER_POOL_ID" --domain "$COGNITO_DOMAIN_PREFIX" || true
  aws cognito-idp delete-user-pool --region "$AWS_REGION" --user-pool-id "$COGNITO_USER_POOL_ID"
  rm -f "$CONFIG_DIR/cognito.env"
  ok "Đã xoá Cognito User Pool $COGNITO_USER_POOL_ID"
}

case "${1:-}" in
  --monitoring) clean_monitoring ;;
  --dns) clean_dns ;;
  --apps) clean_apps ;;
  --platform) clean_platform ;;
  --eg) clean_eg ;;
  --cognito) clean_cognito ;;
  --all) clean_monitoring; clean_dns; clean_apps; clean_platform; clean_eg; clean_cognito ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
