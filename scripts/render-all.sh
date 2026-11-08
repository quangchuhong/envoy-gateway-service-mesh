#!/usr/bin/env bash
# Render toàn bộ chart ra YAML bằng "helm template" để review / commit vào repo GitOps / apply bằng kubectl.
#
#   scripts/render-all.sh            # dùng values trong helm/values/generated (cần chạy 03-gen-values.sh)
#   scripts/render-all.sh --example  # dùng values mặc định của chart (placeholder) - chỉ để xem cấu trúc
#
# Kết quả: rendered/<chart>.yaml (đã .gitignore)
# Apply thủ công theo đúng thứ tự:  kubectl apply -f rendered/eg-platform.yaml  (rồi tới các app)
source "$(dirname "$0")/lib.sh"
require_cmd helm
OUT="$REPO_ROOT/rendered"; mkdir -p "$OUT"
CHARTS="$REPO_ROOT/helm/charts"; VALUES="$REPO_ROOT/helm/values/generated"

example=false; [[ "${1:-}" == "--example" ]] && example=true
if ! $example; then load_env; fi

render() { # release chart namespace [extra args...]
  local rel=$1 chart=$2 ns=$3; shift 3
  local vf=(); if ! $example && [[ -f "$VALUES/$chart.yaml" ]]; then vf=(-f "$VALUES/$chart.yaml"); fi
  # ${vf[@]+"${vf[@]}"}: tránh lỗi "unbound variable" của bash 3.2 (macOS) khi mảng rỗng và có set -u
  helm template "$rel" "$CHARTS/$chart" -n "$ns" ${vf[@]+"${vf[@]}"} "$@" > "$OUT/$chart.yaml"
  ok "rendered/$chart.yaml"
}

render eg-redis eg-redis envoy-gateway-system
render eg-platform eg-platform eg-gateway
render demo-portal demo-portal demo-portal
render demo-orders demo-orders demo-orders
render demo-routing demo-routing demo-routing
if $example; then
  render demo-partner demo-partner demo-partner --set apiKeys.keys.partner-gold=EXAMPLE --set apiKeys.keys.partner-silver=EXAMPLE
else
  render demo-partner demo-partner demo-partner --set apiKeys.keys.partner-gold="$PARTNER_GOLD_KEY" --set apiKeys.keys.partner-silver="$PARTNER_SILVER_KEY"
  warn "rendered/demo-partner.yaml chứa API key thật - không commit"
fi
