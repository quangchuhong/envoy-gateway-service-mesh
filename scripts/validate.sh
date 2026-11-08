#!/usr/bin/env bash
# Kiểm tra chart TRƯỚC khi cài (không cần cụm):
#   1. helm lint từng chart
#   2. helm template (values mẫu) + kubeconform với schema CRD của Envoy Gateway / Gateway API
#      (nếu máy có kubeconform; CRD lấy từ chart gateway-helm đúng phiên bản)
source "$(dirname "$0")/lib.sh"
require_cmd helm python3
EG_VERSION="${EG_VERSION:-v1.9.3}"
CHARTS="$REPO_ROOT/helm/charts"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

log "helm lint"
for c in eg-redis eg-platform demo-portal demo-orders demo-routing eg-monitoring; do helm lint "$CHARTS/$c" >/dev/null && ok "lint $c"; done
helm lint "$CHARTS/demo-partner" --set apiKeys.keys.partner-gold=x --set apiKeys.keys.partner-silver=y >/dev/null && ok "lint demo-partner"

log "helm template"
"$REPO_ROOT/scripts/render-all.sh" --example >/dev/null
ok "render OK"

if ! command -v kubeconform >/dev/null 2>&1; then
  warn "Không có kubeconform - bỏ qua kiểm tra schema (cài: go install github.com/yannh/kubeconform/cmd/kubeconform@v0.6.7)"
  exit 0
fi

log "Lấy CRD từ gateway-helm $EG_VERSION"
helm pull oci://docker.io/envoyproxy/gateway-helm --version "$EG_VERSION" --untar -d "$TMP" >/dev/null
mkdir -p "$TMP/schemas"
python3 - "$TMP/schemas" "$TMP"/gateway-helm/charts/crds/crds/gatewayapi-crds.yaml "$TMP"/gateway-helm/charts/crds/crds/generated/*.yaml <<'EOF'
import sys, os, json, yaml
out = sys.argv[1]
def strict(s):
    if isinstance(s, dict):
        if s.get("type") == "object" and "properties" in s and "additionalProperties" not in s and not s.get("x-kubernetes-preserve-unknown-fields"):
            s["additionalProperties"] = False
        for v in s.values(): strict(v)
    elif isinstance(s, list):
        for v in s: strict(v)
for f in sys.argv[2:]:
    for d in yaml.safe_load_all(open(f)):
        if not d or d.get("kind") != "CustomResourceDefinition": continue
        g = d["spec"]["group"]; k = d["spec"]["names"]["kind"].lower()
        for v in d["spec"]["versions"]:
            sch = v["schema"]["openAPIV3Schema"]; strict(sch)
            sch.setdefault("properties", {})["metadata"] = {"type": "object"}
            os.makedirs(f"{out}/{g}", exist_ok=True)
            json.dump(sch, open(f"{out}/{g}/{k}_{v['name']}.json", "w"))
EOF
kubeconform -strict -summary -schema-location default \
  -schema-location "$TMP/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  "$REPO_ROOT"/rendered/*.yaml
