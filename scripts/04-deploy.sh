#!/usr/bin/env bash
# Triển khai toàn bộ theo đúng thứ tự trong docs (chạy từng phần hoặc tất cả):
#
#   scripts/04-deploy.sh eg         # Redis + Envoy Gateway (control plane)
#   scripts/04-deploy.sh platform   # GatewayClass, EnvoyProxy, Gateway (tạo NLB), ClientTrafficPolicy
#   scripts/04-deploy.sh apps       # 3 app demo (portal, orders, partner)
#   scripts/04-deploy.sh all
source "$(dirname "$0")/lib.sh"
load_env
require_cmd kubectl helm
VALUES="$REPO_ROOT/helm/values/generated"
CHARTS="$REPO_ROOT/helm/charts"

deploy_eg() {
  log "Cài Redis (backend rate limit)"
  helm upgrade --install eg-redis "$CHARTS/eg-redis" -n envoy-gateway-system --create-namespace --wait

  log "Cài Envoy Gateway $EG_VERSION"
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version "$EG_VERSION" \
    -n envoy-gateway-system -f "$REPO_ROOT/helm/envoy-gateway/values.yaml" --wait --timeout 5m
  kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
  ok "Envoy Gateway sẵn sàng"
}

deploy_platform() {
  [[ -f "$VALUES/eg-platform.yaml" ]] || die "Chưa có values. Chạy scripts/03-gen-values.sh"
  log "Cài eg-platform"
  helm upgrade --install eg-platform "$CHARTS/eg-platform" -n eg-gateway --create-namespace \
    -f "$VALUES/eg-platform.yaml" --wait
  kubectl wait --timeout=5m -n eg-gateway gateway/eg-gateway --for=condition=Programmed
  ok "Gateway đã Programmed"
  kubectl get gateway -n eg-gateway eg-gateway
  log "Bước tiếp theo: tạo DNS *.${DOMAIN} -> NLB bằng scripts/05-dns.sh"
}

deploy_apps() {
  for ns in demo-portal demo-orders demo-partner; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
    # Label cho phép namespace gắn HTTPRoute vào Gateway (allowedRoutes selector)
    kubectl label namespace "$ns" gateway.demo.io/attach=true --overwrite
  done

  log "Secret OIDC client cho portal"
  kubectl create secret generic portal-oidc-client -n demo-portal \
    --from-literal=client-secret="$PORTAL_CLIENT_SECRET" --dry-run=client -o yaml | kubectl apply -f -

  log "Cài App 1 - demo-portal"
  helm upgrade --install demo-portal "$CHARTS/demo-portal" -n demo-portal -f "$VALUES/demo-portal.yaml" --wait
  log "Cài App 2 - demo-orders"
  helm upgrade --install demo-orders "$CHARTS/demo-orders" -n demo-orders -f "$VALUES/demo-orders.yaml" --wait
  log "Cài App 3 - demo-partner"
  helm upgrade --install demo-partner "$CHARTS/demo-partner" -n demo-partner -f "$VALUES/demo-partner.yaml" \
    --set apiKeys.keys.partner-gold="$PARTNER_GOLD_KEY" \
    --set apiKeys.keys.partner-silver="$PARTNER_SILVER_KEY" --wait

  log "Trạng thái route và policy"
  kubectl get httproute -A
  kubectl get securitypolicy,backendtrafficpolicy -A
}

case "${1:-}" in
  eg) deploy_eg ;;
  platform) deploy_platform ;;
  apps) deploy_apps ;;
  all) deploy_eg; deploy_platform; deploy_apps ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac
