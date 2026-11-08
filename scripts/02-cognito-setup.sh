#!/usr/bin/env bash
# Bước 2: tạo AWS Cognito cho demo bằng AWS CLI (chưa dùng Terraform).
#
# Tạo ra:
#   - User Pool (đăng nhập bằng email, chỉ admin tạo user, MFA TOTP tuỳ chọn)
#   - Hosted UI domain: https://<COGNITO_DOMAIN_PREFIX>.auth.<region>.amazoncognito.com
#   - Group: devops-admin, developer, viewer         -> claim "cognito:groups"
#   - Resource server "orders-api" với scope read, write
#   - App client:
#       portal-web  : Authorization Code + secret     -> App 1 (OIDC tại Envoy Gateway)
#       demo-cli    : USER_PASSWORD_AUTH, không secret -> lấy token user để TEST App 2
#       orders-m2m  : Client Credentials + secret     -> client máy gọi App 2
#   - 4 user test: admin / dev / viewer / nogroup (mật khẩu ngẫu nhiên)
#
# Kết quả ghi vào config/cognito.env (đã .gitignore).
source "$(dirname "$0")/lib.sh"
load_env
require_cmd aws jq openssl

OUT="$CONFIG_DIR/cognito.env"
[[ -f "$OUT" ]] && die "$OUT đã tồn tại (Cognito đã được tạo). Muốn tạo lại: chạy scripts/99-cleanup.sh --cognito trước."

R="--region $AWS_REGION"
TOKEN_UNITS="AccessToken=minutes,IdToken=minutes,RefreshToken=hours"

log "Tạo User Pool $COGNITO_POOL_NAME"
POOL_ID=$(aws cognito-idp create-user-pool $R \
  --pool-name "$COGNITO_POOL_NAME" \
  --username-attributes email \
  --auto-verified-attributes email \
  --username-configuration CaseSensitive=false \
  --admin-create-user-config AllowAdminCreateUserOnly=true \
  --policies 'PasswordPolicy={MinimumLength=12,RequireUppercase=true,RequireLowercase=true,RequireNumbers=true,RequireSymbols=true,TemporaryPasswordValidityDays=3}' \
  --account-recovery-setting 'RecoveryMechanisms=[{Priority=1,Name=verified_email}]' \
  --query UserPool.Id --output text)
ok "User Pool: $POOL_ID"
# Ghi ngay ID pool: nếu các bước sau lỗi, scripts/99-cleanup.sh --cognito vẫn xoá được pool này.
# File sẽ được ghi đầy đủ ở cuối script.
{ echo "# Đang tạo dở bởi scripts/02-cognito-setup.sh"; echo "export COGNITO_USER_POOL_ID=$POOL_ID"; } > "$OUT"
chmod 600 "$OUT"

# Demo: MFA OPTIONAL để script test lấy được token bằng mật khẩu.
# Production: đặt --mfa-configuration ON (bắt buộc MFA).
aws cognito-idp set-user-pool-mfa-config $R --user-pool-id "$POOL_ID" \
  --software-token-mfa-configuration Enabled=true --mfa-configuration OPTIONAL >/dev/null
ok "MFA: OPTIONAL (TOTP)"

log "Tạo Hosted UI domain"
aws cognito-idp create-user-pool-domain $R --user-pool-id "$POOL_ID" \
  --domain "$COGNITO_DOMAIN_PREFIX" --managed-login-version 1 >/dev/null
COGNITO_DOMAIN_URL="https://${COGNITO_DOMAIN_PREFIX}.auth.${AWS_REGION}.amazoncognito.com"
ok "Hosted UI: $COGNITO_DOMAIN_URL"

log "Tạo group"
for g in devops-admin developer viewer; do
  aws cognito-idp create-group $R --user-pool-id "$POOL_ID" --group-name "$g" >/dev/null
  ok "group $g"
done

log "Tạo resource server orders-api (scope read, write)"
aws cognito-idp create-resource-server $R --user-pool-id "$POOL_ID" \
  --identifier orders-api --name "Orders API" \
  --scopes ScopeName=read,ScopeDescription=Read-orders ScopeName=write,ScopeDescription=Write-orders >/dev/null
ok "resource server orders-api"

log "Tạo app client portal-web (Authorization Code, có secret)"
read -r PORTAL_CLIENT_ID PORTAL_CLIENT_SECRET < <(aws cognito-idp create-user-pool-client $R --user-pool-id "$POOL_ID" \
  --client-name portal-web --generate-secret \
  --allowed-o-auth-flows code --allowed-o-auth-flows-user-pool-client \
  --allowed-o-auth-scopes openid email profile \
  --supported-identity-providers COGNITO \
  --callback-urls "https://portal.${DOMAIN}/oauth2/callback" \
  --logout-urls "https://portal.${DOMAIN}/" \
  --explicit-auth-flows ALLOW_REFRESH_TOKEN_AUTH \
  --prevent-user-existence-errors ENABLED --enable-token-revocation \
  --access-token-validity 30 --id-token-validity 30 --refresh-token-validity 12 \
  --token-validity-units "$TOKEN_UNITS" \
  --query 'UserPoolClient.[ClientId,ClientSecret]' --output text)
ok "portal-web: $PORTAL_CLIENT_ID"

log "Tạo app client demo-cli (USER_PASSWORD_AUTH, dùng cho test)"
DEMO_CLI_CLIENT_ID=$(aws cognito-idp create-user-pool-client $R --user-pool-id "$POOL_ID" \
  --client-name demo-cli --no-generate-secret \
  --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --prevent-user-existence-errors ENABLED \
  --access-token-validity 30 --id-token-validity 30 --refresh-token-validity 12 \
  --token-validity-units "$TOKEN_UNITS" \
  --query UserPoolClient.ClientId --output text)
ok "demo-cli: $DEMO_CLI_CLIENT_ID"

log "Tạo app client orders-m2m (Client Credentials, có secret)"
read -r M2M_CLIENT_ID M2M_CLIENT_SECRET < <(aws cognito-idp create-user-pool-client $R --user-pool-id "$POOL_ID" \
  --client-name orders-m2m --generate-secret \
  --allowed-o-auth-flows client_credentials --allowed-o-auth-flows-user-pool-client \
  --allowed-o-auth-scopes orders-api/read orders-api/write \
  --supported-identity-providers COGNITO \
  --access-token-validity 60 --token-validity-units AccessToken=minutes \
  --query 'UserPoolClient.[ClientId,ClientSecret]' --output text)
ok "orders-m2m: $M2M_CLIENT_ID"

log "Tạo user test"
gen_pw() { echo "Eg$(openssl rand -hex 8)#1"; }
# user -> group (dùng hàm thay cho "declare -A": bash 3.2 mặc định của macOS không có mảng kết hợp)
user_group() {
  case "$1" in
    admin) echo devops-admin ;;
    dev) echo developer ;;
    viewer) echo viewer ;;
    *) echo "" ;;
  esac
}
{
  echo "# Sinh bởi scripts/02-cognito-setup.sh - KHÔNG commit"
  echo "export COGNITO_USER_POOL_ID=$POOL_ID"
  echo "export COGNITO_ISSUER=https://cognito-idp.${AWS_REGION}.amazonaws.com/${POOL_ID}"
  echo "export COGNITO_DOMAIN_URL=$COGNITO_DOMAIN_URL"
  echo "export PORTAL_CLIENT_ID=$PORTAL_CLIENT_ID"
  echo "export PORTAL_CLIENT_SECRET=$PORTAL_CLIENT_SECRET"
  echo "export DEMO_CLI_CLIENT_ID=$DEMO_CLI_CLIENT_ID"
  echo "export M2M_CLIENT_ID=$M2M_CLIENT_ID"
  echo "export M2M_CLIENT_SECRET=$M2M_CLIENT_SECRET"
} > "$OUT"
chmod 600 "$OUT"

for u in admin dev viewer nogroup; do
  email="eg-demo-${u}@example.com"; pw=$(gen_pw); up=$(echo "$u" | tr '[:lower:]' '[:upper:]'); grp=$(user_group "$u")
  aws cognito-idp admin-create-user $R --user-pool-id "$POOL_ID" --username "$email" \
    --user-attributes Name=email,Value="$email" Name=email_verified,Value=true \
    --message-action SUPPRESS >/dev/null
  aws cognito-idp admin-set-user-password $R --user-pool-id "$POOL_ID" --username "$email" \
    --password "$pw" --permanent
  if [[ -n "$grp" ]]; then
    aws cognito-idp admin-add-user-to-group $R --user-pool-id "$POOL_ID" --username "$email" --group-name "$grp"
  fi
  echo "export USER_${up}_EMAIL=$email" >> "$OUT"
  echo "export USER_${up}_PASSWORD='$pw'" >> "$OUT"
  ok "user $email (group: ${grp:-<không có>})"
done

# Tạo API key cho App 3 (partner) - lưu cùng file để dùng lại khi cài chart và khi test
{
  echo "export PARTNER_GOLD_KEY=$(openssl rand -hex 24)"
  echo "export PARTNER_SILVER_KEY=$(openssl rand -hex 24)"
} >> "$OUT"
ok "Đã sinh API key partner-gold / partner-silver"

ok "Xong. Thông tin lưu tại $OUT"
