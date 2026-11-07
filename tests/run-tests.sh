#!/usr/bin/env bash
# Bộ test tự động cho Envoy Gateway demo (xem docs/08-testing.md).
#
#   tests/run-tests.sh            # chạy tất cả
#   tests/run-tests.sh gw         # chỉ nhóm GW (gateway chung)
#   tests/run-tests.sh portal     # chỉ nhóm POR
#   tests/run-tests.sh orders     # chỉ nhóm ORD
#   tests/run-tests.sh partner    # chỉ nhóm PAR
#
# Cần: curl, jq, aws (lấy token Cognito). Đọc cấu hình từ config/demo.env + config/cognito.env.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/demo.env"; source "$ROOT/config/cognito.env"
for c in curl jq aws; do command -v "$c" >/dev/null || { echo "Thiếu $c"; exit 2; }; done

PORTAL="portal.${DOMAIN}"; API="api.${DOMAIN}"; PARTNER="partner.${DOMAIN}"
CURL=(curl -sS --max-time 20)
[[ "${INSECURE_TLS:-0}" == "1" ]] && CURL+=(-k)
if [[ -n "${GATEWAY_IP:-}" ]]; then
  for h in "$PORTAL" "$API" "$PARTNER" "unknown.${DOMAIN}"; do CURL+=(--resolve "$h:443:$GATEWAY_IP" --resolve "$h:80:$GATEWAY_IP"); done
fi

PASS=0; FAIL=0; RESULTS=()
check() { # id, mô tả, kỳ vọng, thực tế
  if [[ "$3" == "$4" ]]; then PASS=$((PASS+1)); RESULTS+=("PASS|$1|$2|$4"); printf '\033[32mPASS\033[0m %-7s %s (=%s)\n' "$1" "$2" "$4"
  else FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1|$2|kỳ vọng $3, thực tế $4"); printf '\033[31mFAIL\033[0m %-7s %s (kỳ vọng %s, thực tế %s)\n' "$1" "$2" "$3" "$4"; fi
}
code() { "${CURL[@]}" -o /dev/null -w '%{http_code}' "$@"; }
# body + header vào file tạm, in status
req() { "${CURL[@]}" -D /tmp/eg-h.$$ -o /tmp/eg-b.$$ -w '%{http_code}' "$@"; }
hdr() { grep -i "^$1:" /tmp/eg-h.$$ | head -1 | cut -d: -f2- | tr -d ' \r'; }
body() { cat /tmp/eg-b.$$; }
echoed() { jq -r --arg h "$1" '.headers[$h][0] // "<none>"' /tmp/eg-b.$$ 2>/dev/null; }
trap 'rm -f /tmp/eg-h.$$ /tmp/eg-b.$$' EXIT

token_user() { aws cognito-idp initiate-auth --region "$AWS_REGION" --client-id "$DEMO_CLI_CLIENT_ID" \
  --auth-flow USER_PASSWORD_AUTH --auth-parameters "USERNAME=$1,PASSWORD=$2" \
  --query "AuthenticationResult.${3:-AccessToken}" --output text; }
token_m2m() { curl -sS -X POST "${COGNITO_DOMAIN_URL}/oauth2/token" -u "${M2M_CLIENT_ID}:${M2M_CLIENT_SECRET}" \
  --data-urlencode grant_type=client_credentials --data-urlencode "scope=orders-api/read orders-api/write" | jq -r .access_token; }

# =====================================================================================
test_gw() {
  echo; echo "== GW: Gateway dùng chung"
  local c loc
  c=$("${CURL[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "http://${PARTNER}/v1/test")
  check GW-01 "HTTP -> HTTPS redirect 301" "301 https://${PARTNER}/v1/test" "$c"
  check GW-02 "Health check listener /healthz" 200 "$(code "https://${PARTNER}/healthz")"
  check GW-03 "Host không có route -> 404" 404 "$(code "https://unknown.${DOMAIN}/")"
  c=$(req -H "x-api-key: ${PARTNER_GOLD_KEY}" "https://${PARTNER}/v1/reqid")
  [[ "$(echoed X-Request-Id)" != "<none>" ]] && loc=yes || loc=no
  check GW-04 "Envoy sinh X-Request-Id cho request" yes "$loc"
}

# =====================================================================================
test_portal() {
  echo; echo "== POR: App 1 - Portal (OIDC Cognito)"
  local out r
  out=$("${CURL[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "https://${PORTAL}/")
  check POR-01 "Chưa đăng nhập -> 302" 302 "${out%% *}"
  [[ "$out" == *"${COGNITO_DOMAIN_URL}/oauth2/authorize"* ]] && r=yes || r=no
  check POR-02 "Redirect tới Cognito Hosted UI /oauth2/authorize" yes "$r"
  [[ "$out" == *"redirect_uri="* && ( "$out" == *"${PORTAL}%2Foauth2%2Fcallback"* || "$out" == *"${PORTAL}/oauth2/callback"* ) ]] && r=yes || r=no
  check POR-03 "redirect_uri = https://${PORTAL}/oauth2/callback" yes "$r"
  check POR-04 "Request AJAX chưa đăng nhập -> 401 (denyRedirect)" 401 \
    "$(code -H 'X-Requested-With: XMLHttpRequest' "https://${PORTAL}/api/info")"
  check POR-05 "Cookie ID token giả -> không vào được (302/401)" yes \
    "$([[ $(code -H 'Cookie: PortalIdToken=abc.def.ghi' "https://${PORTAL}/") =~ ^(302|401)$ ]] && echo yes || echo no)"
  echo "      (POR-06..POR-12: test bằng trình duyệt - xem docs/08-testing.md)"
}

# =====================================================================================
test_orders() {
  echo; echo "== ORD: App 2 - Orders API (JWT Cognito)"
  local T_ADMIN T_DEV T_VIEW T_NOG T_ADMIN_ID T_M2M c i v2 ok503 n429 t0 t1
  T_ADMIN=$(token_user "$USER_ADMIN_EMAIL" "$USER_ADMIN_PASSWORD")
  T_ADMIN_ID=$(token_user "$USER_ADMIN_EMAIL" "$USER_ADMIN_PASSWORD" IdToken)
  T_DEV=$(token_user "$USER_DEV_EMAIL" "$USER_DEV_PASSWORD")
  T_VIEW=$(token_user "$USER_VIEWER_EMAIL" "$USER_VIEWER_PASSWORD")
  T_NOG=$(token_user "$USER_NOGROUP_EMAIL" "$USER_NOGROUP_PASSWORD")
  T_M2M=$(token_m2m)
  local U="https://${API}/orders"

  # --- Xác thực
  check ORD-01 "Không có token -> 401" 401 "$(code "$U")"
  check ORD-02 "Token sai chữ ký/định dạng -> 401" 401 "$(code -H 'Authorization: Bearer abc.def.ghi' "$U")"
  check ORD-03 "Dùng ID token thay access token -> 403" 403 "$(code -H "Authorization: Bearer $T_ADMIN_ID" "$U")"
  # --- Phân quyền theo group
  check ORD-04 "viewer GET -> 200" 200 "$(code -H "Authorization: Bearer $T_VIEW" "$U")"
  check ORD-05 "viewer POST -> 403" 403 "$(code -X POST -H "Authorization: Bearer $T_VIEW" "$U")"
  check ORD-06 "developer POST -> 200" 200 "$(code -X POST -H "Authorization: Bearer $T_DEV" -d '{"item":"x"}' "$U")"
  check ORD-07 "developer DELETE -> 403" 403 "$(code -X DELETE -H "Authorization: Bearer $T_DEV" "$U/1")"
  check ORD-08 "admin DELETE -> 200" 200 "$(code -X DELETE -H "Authorization: Bearer $T_ADMIN" "$U/1")"
  check ORD-09 "user không thuộc group nào GET -> 403" 403 "$(code -H "Authorization: Bearer $T_NOG" "$U")"
  # --- Phân quyền theo scope (máy)
  check ORD-10 "m2m (scope read) GET -> 200" 200 "$(code -H "Authorization: Bearer $T_M2M" "$U")"
  check ORD-11 "m2m (scope write) POST -> 200" 200 "$(code -X POST -H "Authorization: Bearer $T_M2M" "$U")"
  check ORD-12 "m2m DELETE (không có quyền) -> 403" 403 "$(code -X DELETE -H "Authorization: Bearer $T_M2M" "$U/1")"
  # --- URL rewrite + header + chống giả mạo header nội bộ
  req -H "Authorization: Bearer $T_ADMIN" -H 'X-Debug-Internal: secret' -H 'X-Jwt-Sub: hacker' "$U/123" >/dev/null
  check ORD-13 "URL rewrite /orders/123 -> /anything/orders/123" yes "$([[ $(jq -r .url /tmp/eg-b.$$) == *"/anything/orders/123" ]] && echo yes || echo no)"
  check ORD-14 "Gateway thêm header X-Gateway" envoy-gateway "$(echoed X-Gateway)"
  check ORD-15 "Gateway xoá header X-Debug-Internal" "<none>" "$(echoed X-Debug-Internal)"
  check ORD-16 "X-Jwt-Sub giả bị thay bằng sub thật" yes "$([[ $(echoed X-Jwt-Sub) != hacker && $(echoed X-Jwt-Sub) != "<none>" ]] && echo yes || echo no)"
  # --- Routing theo header + canary
  v2=0; for i in 1 2 3 4 5; do req -H "Authorization: Bearer $T_DEV" -H 'x-api-version: v2' "$U" >/dev/null; [[ "$(hdr x-backend-version)" == v2 ]] && v2=$((v2+1)); done
  check ORD-17 "Header x-api-version: v2 -> 5/5 vào v2" 5 "$v2"
  v2=0; for i in $(seq 1 15); do for t in "$T_ADMIN" "$T_DEV" "$T_VIEW"; do
    req -H "Authorization: Bearer $t" "$U" >/dev/null; [[ "$(hdr x-backend-version)" == v2 ]] && v2=$((v2+1)); done; done
  check ORD-18 "Canary 90/10: 45 request, v2 nằm trong khoảng 1..15 (thực tế $v2)" yes "$([[ $v2 -ge 1 && $v2 -le 15 ]] && echo yes || echo no)"
  # --- CORS
  req -X OPTIONS -H "Origin: https://${PORTAL}" -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: authorization' "$U" >/dev/null
  check ORD-19 "CORS preflight từ portal -> cho phép origin" "https://${PORTAL}" "$(hdr access-control-allow-origin)"
  req -X OPTIONS -H 'Origin: https://evil.example.org' -H 'Access-Control-Request-Method: POST' "$U" >/dev/null
  check ORD-20 "CORS preflight từ origin lạ -> không có Allow-Origin" "" "$(hdr access-control-allow-origin)"
  # --- Retry
  c=0; for i in $(seq 1 30); do [[ $(code -H "Authorization: Bearer $T_ADMIN" "https://${API}/orders/unstable") == 200 ]] && c=$((c+1)); done
  check ORD-21 "Retry: backend lỗi 50%, gateway retry 3 lần -> >=25/30 thành công (thực tế $c)" yes "$([[ $c -ge 25 ]] && echo yes || echo no)"
  # --- Timeout
  t0=$(date +%s); c=$(code -H "Authorization: Bearer $T_ADMIN" "https://${API}/orders/slow"); t1=$(date +%s)
  check ORD-22 "Timeout: backend chậm 5s, timeout 2s -> 504" 504 "$c"
  check ORD-23 "Timeout: trả lời trong < 4s (thực tế $((t1-t0))s)" yes "$([[ $((t1-t0)) -lt 4 ]] && echo yes || echo no)"
  # --- Circuit breaker
  for i in $(seq 1 15); do code -H "Authorization: Bearer $T_ADMIN" "https://${API}/orders/slow" > "/tmp/eg-cb.$$.$i" & done; wait
  ok503=$(cat /tmp/eg-cb.$$.* | grep -c 503); rm -f /tmp/eg-cb.$$.*
  check ORD-24 "Circuit breaker: 15 request song song -> có request bị 503 ngay (thực tế $ok503)" yes "$([[ $ok503 -ge 1 ]] && echo yes || echo no)"
  # --- Fault injection
  c=0; for i in $(seq 1 40); do [[ $(code -H "Authorization: Bearer $T_ADMIN" "https://${API}/orders/chaos/x") == 503 ]] && c=$((c+1)); done
  check ORD-25 "Fault injection 50%: 40 request, 503 trong khoảng 8..32 (thực tế $c)" yes "$([[ $c -ge 8 && $c -le 32 ]] && echo yes || echo no)"
  # --- Rate limit theo user (m2m: 30 request/phút)
  n429=0; for i in $(seq 1 35); do [[ $(code -H "Authorization: Bearer $T_M2M" "$U") == 429 ]] && n429=$((n429+1)); done
  check ORD-26 "Rate limit 30/phút/user: 35 request liên tiếp -> có 429 (thực tế $n429)" yes "$([[ $n429 -ge 1 ]] && echo yes || echo no)"
  check ORD-27 "User khác không bị ảnh hưởng bởi rate limit của m2m" 200 "$(code -H "Authorization: Bearer $T_VIEW" "$U")"
}

# =====================================================================================
test_partner() {
  echo; echo "== PAR: App 3 - Partner API (API key)"
  local U="https://${PARTNER}/v1/quote" n429 i c
  check PAR-01 "Không có API key -> 401" 401 "$(code "$U")"
  check PAR-02 "API key sai -> 401" 401 "$(code -H 'x-api-key: wrong-key' "$U")"
  c=$(req -H "x-api-key: ${PARTNER_SILVER_KEY}" "$U")
  check PAR-03 "silver GET -> 200" 200 "$c"
  check PAR-04 "Backend nhận X-Partner-Id = partner-silver" partner-silver "$(echoed X-Partner-Id)"
  check PAR-05 "API key bị xoá trước khi vào backend (sanitize)" "<none>" "$(echoed X-Api-Key)"
  check PAR-06 "silver POST (gói không có quyền ghi) -> 403" 403 "$(code -X POST -H "x-api-key: ${PARTNER_SILVER_KEY}" "$U")"
  check PAR-07 "gold POST -> 200" 200 "$(code -X POST -H "x-api-key: ${PARTNER_GOLD_KEY}" "$U")"
  req -H "x-api-key: ${PARTNER_SILVER_KEY}" -H 'X-Partner-Id: partner-gold' "$U" >/dev/null
  check PAR-08 "Giả mạo X-Partner-Id: partner-gold bằng key silver -> vẫn là silver" partner-silver "$(echoed X-Partner-Id)"
  check PAR-09 "Giả mạo X-Partner-Id + POST bằng key silver -> 403" 403 \
    "$(code -X POST -H "x-api-key: ${PARTNER_SILVER_KEY}" -H 'X-Partner-Id: partner-gold' "$U")"
  n429=0; for i in $(seq 1 8); do [[ $(code -H "x-api-key: ${PARTNER_SILVER_KEY}" "$U") == 429 ]] && n429=$((n429+1)); done
  check PAR-10 "silver rate limit 5/phút -> có 429 (thực tế $n429/8)" yes "$([[ $n429 -ge 1 ]] && echo yes || echo no)"
  n429=0; for i in $(seq 1 10); do [[ $(code -H "x-api-key: ${PARTNER_GOLD_KEY}" "$U") == 429 ]] && n429=$((n429+1)); done
  check PAR-11 "gold rate limit 100/phút -> 10 request không bị 429" 0 "$n429"
}

case "${1:-all}" in
  gw) test_gw ;; portal) test_portal ;; orders) test_orders ;; partner) test_partner ;;
  all) test_gw; test_portal; test_orders; test_partner ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac

echo; echo "========== KẾT QUẢ: $PASS PASS, $FAIL FAIL =========="
mkdir -p "$ROOT/tests/results"
{ echo "| Kết quả | Mã | Test case | Chi tiết |"; echo "|---|---|---|---|"
  for r in "${RESULTS[@]}"; do IFS='|' read -r s id d v <<< "$r"; echo "| $s | $id | $d | $v |"; done; } > "$ROOT/tests/results/last-run.md"
echo "Báo cáo: tests/results/last-run.md"
[[ $FAIL -eq 0 ]]
