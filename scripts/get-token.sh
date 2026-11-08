#!/usr/bin/env bash
# Lấy token từ AWS Cognito để gọi API demo.
#
#   scripts/get-token.sh user admin|dev|viewer|nogroup [access|id]   # token của user (mặc định access)
#   scripts/get-token.sh m2m [scope...]                              # token máy (Client Credentials)
#   scripts/get-token.sh decode <jwt>                                # xem claims (không verify)
source "$(dirname "$0")/lib.sh"
load_env
require_cmd aws curl jq

decode() {
  local p; p=$(echo "$1" | cut -d. -f2 | tr '_-' '/+')
  while (( ${#p} % 4 )); do p="${p}="; done
  # openssl thay cho "base64 -d": macOS cũ dùng "base64 -D", Linux dùng "-d"
  echo "$p" | openssl base64 -d -A 2>/dev/null | jq .
}

case "${1:-}" in
  user)
    who=$(echo "${2:?admin|dev|viewer|nogroup}" | tr '[:lower:]' '[:upper:]'); kind="${3:-access}"
    email_var="USER_${who}_EMAIL"; pw_var="USER_${who}_PASSWORD"
    [[ -n "${!email_var:-}" ]] || die "Không có user '$2' trong config/cognito.env"
    field=$([[ "$kind" == "id" ]] && echo IdToken || echo AccessToken)
    aws cognito-idp initiate-auth --region "$AWS_REGION" \
      --client-id "$DEMO_CLI_CLIENT_ID" --auth-flow USER_PASSWORD_AUTH \
      --auth-parameters "USERNAME=${!email_var},PASSWORD=${!pw_var}" \
      --query "AuthenticationResult.${field}" --output text
    ;;
  m2m)
    shift; scope="${*:-orders-api/read orders-api/write}"
    curl -sS -X POST "${COGNITO_DOMAIN_URL}/oauth2/token" \
      -u "${M2M_CLIENT_ID}:${M2M_CLIENT_SECRET}" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode grant_type=client_credentials \
      --data-urlencode "scope=${scope}" | jq -r .access_token
    ;;
  decode)
    decode "${2:?jwt}"
    ;;
  *)
    sed -n '2,7p' "$0"; exit 1;;
esac
