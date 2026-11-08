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
  if ! kubectl wait --timeout=5m -n eg-gateway gateway/eg-gateway --for=condition=Programmed; then
    warn "Gateway chưa Programmed sau 5 phút. Thông tin chẩn đoán:"
    echo "--- Điều kiện của Gateway:"
    kubectl get gateway eg-gateway -n eg-gateway \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' || true
    echo "--- GatewayClass eg-demo:"
    kubectl get gatewayclass eg-demo \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' || true
    # Pod/Service của Envoy nằm trong namespace của controller (envoy-gateway-system)
    echo "--- Pod/Service Envoy (namespace envoy-gateway-system):"
    kubectl get pods,svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -o wide || true
    echo "--- Sự kiện của Service Envoy (tạo NLB):"
    kubectl describe svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway | sed -n '/Events:/,$p' || true
    echo "--- Lỗi gần đây của AWS Load Balancer Controller:"
    kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=200 2>/dev/null | grep -iE "error|fail" | tail -10 || true
    die "Xem docs/09-operations-troubleshooting.md mục 5"
  fi
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
  kubectl get backendtlspolicy -A 2>/dev/null || true
  log "Trạng thái chấp nhận của các policy (mong đợi: Accepted)"
  kubectl get securitypolicy,backendtrafficpolicy,backendtlspolicy -A \
    -o custom-columns='KIND:.kind,NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.ancestors[0].conditions[0].reason' 2>/dev/null || true
}

case "${1:-}" in
  eg) deploy_eg ;;
  platform) deploy_platform ;;
  apps) deploy_apps ;;
  all) deploy_eg; deploy_platform; deploy_apps ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac
