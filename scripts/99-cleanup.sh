#!/usr/bin/env bash
# Gỡ demo (theo thứ tự ngược lại):
#   scripts/99-cleanup.sh --apps        # 3 app demo + namespace
#   scripts/99-cleanup.sh --platform    # Gateway (xoá NLB), EnvoyProxy, GatewayClass
#   scripts/99-cleanup.sh --eg          # Envoy Gateway + Redis (CRD giữ lại, xem docs/09)
#   scripts/99-cleanup.sh --cognito     # xoá User Pool Cognito + config/cognito.env
#   scripts/99-cleanup.sh --all
source "$(dirname "$0")/lib.sh"
load_env

clean_apps() {
  for r in demo-portal demo-orders demo-partner; do helm uninstall "$r" -n "$r" 2>/dev/null || true; done
  kubectl delete namespace demo-portal demo-orders demo-partner --ignore-not-found
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
  --apps) clean_apps ;;
  --platform) clean_platform ;;
  --eg) clean_eg ;;
  --cognito) clean_cognito ;;
  --all) clean_apps; clean_platform; clean_eg; clean_cognito ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac
