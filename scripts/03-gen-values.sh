#!/usr/bin/env bash
# Bước 3: sinh file values cho các chart từ config/demo.env + config/cognito.env
# Kết quả: helm/values/generated/*.yaml (đã .gitignore, có thông tin môi trường)
source "$(dirname "$0")/lib.sh"
load_env
[[ -n "${COGNITO_ISSUER:-}" ]] || die "Thiếu config/cognito.env. Chạy scripts/02-cognito-setup.sh trước."

OUT_DIR="$REPO_ROOT/helm/values/generated"
mkdir -p "$OUT_DIR"

# ---- eg-platform
cat > "$OUT_DIR/eg-platform.yaml" <<EOF
domain: ${DOMAIN}
envoyProxy:
  service:
    nlb:
      # có ARN -> NLB terminate TLS bằng cert ACM; trống -> NLB TCP, Envoy dùng cert self-signed
      acmCertArn: "${ACM_CERT_ARN:-}"
EOF
if [[ -n "${ACM_CERT_ARN:-}" ]]; then
  ok "eg-platform.yaml (chế độ nlb-tls, cert ACM)"
else
  warn "eg-platform.yaml (chế độ nlb-tcp: Envoy dùng cert self-signed, trình duyệt sẽ cảnh báo)"
fi

# ---- demo-portal
cat > "$OUT_DIR/demo-portal.yaml" <<EOF
domain: ${DOMAIN}
cognito:
  issuer: "${COGNITO_ISSUER}"
  clientId: "${PORTAL_CLIENT_ID}"
  authorizationEndpoint: "${COGNITO_DOMAIN_URL}/oauth2/authorize"
  tokenEndpoint: "${COGNITO_DOMAIN_URL}/oauth2/token"
EOF
ok "demo-portal.yaml"

# ---- demo-orders
cat > "$OUT_DIR/demo-orders.yaml" <<EOF
domain: ${DOMAIN}
cognito:
  issuer: "${COGNITO_ISSUER}"
EOF
ok "demo-orders.yaml"

# ---- demo-partner (API key KHÔNG ghi vào file, truyền bằng --set lúc cài)
cat > "$OUT_DIR/demo-partner.yaml" <<EOF
domain: ${DOMAIN}
EOF
ok "demo-partner.yaml"

ok "Đã sinh values tại $OUT_DIR"
