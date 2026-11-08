#!/usr/bin/env bash
# Bước 5: tạo/cập nhật bản ghi Route 53 wildcard  *.<DOMAIN>  (Alias A) trỏ về NLB của Gateway.
# Chạy SAU "scripts/04-deploy.sh platform" (khi Gateway đã có địa chỉ NLB).
#
#   scripts/05-dns.sh
#
# HOSTED_ZONE_ID trong config/demo.env để trống thì script tự tìm public hosted zone theo tên DOMAIN.
source "$(dirname "$0")/lib.sh"
load_env
require_cmd aws kubectl jq

log "Lấy địa chỉ NLB của Gateway eg-gateway"
NLB_DNS=$(kubectl get gateway -n eg-gateway eg-gateway -o jsonpath='{.status.addresses[0].value}')
[[ -n "$NLB_DNS" ]] || die "Gateway chưa có địa chỉ. Kiểm tra: kubectl get gateway -n eg-gateway eg-gateway"
ok "NLB: $NLB_DNS"

NLB_ZONE=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?DNSName=='${NLB_DNS}'].CanonicalHostedZoneId" --output text)
[[ -n "$NLB_ZONE" && "$NLB_ZONE" != "None" ]] || die "Không tìm thấy NLB $NLB_DNS trong region $AWS_REGION"

ZONE_ID="${HOSTED_ZONE_ID:-}"
if [[ -z "$ZONE_ID" ]]; then
  log "Tìm public hosted zone của ${DOMAIN}"
  ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN}." \
    --query "HostedZones[?Name=='${DOMAIN}.' && Config.PrivateZone==\`false\`].Id | [0]" --output text | sed 's|/hostedzone/||')
  [[ -n "$ZONE_ID" && "$ZONE_ID" != "None" ]] || die "Không có public hosted zone ${DOMAIN} trong Route 53. Đặt HOSTED_ZONE_ID trong config/demo.env."
fi
ok "Hosted zone: $ZONE_ID"

RECORD="*.${DOMAIN}"
log "UPSERT ${RECORD} (Alias A) -> ${NLB_DNS}"
BATCH=$(jq -n --arg name "$RECORD" --arg zone "$NLB_ZONE" --arg dns "$NLB_DNS" '{
  Comment: "Envoy Gateway demo: wildcard -> NLB",
  Changes: [{ Action: "UPSERT", ResourceRecordSet: {
    Name: $name, Type: "A",
    AliasTarget: { HostedZoneId: $zone, DNSName: $dns, EvaluateTargetHealth: true } } }]
}')
CHANGE_ID=$(aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "$BATCH" \
  --query ChangeInfo.Id --output text)
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
ok "Route 53 đã cập nhật (${CHANGE_ID})"

for h in "portal.${DOMAIN}" "api.${DOMAIN}" "partner.${DOMAIN}"; do
  log "https://${h}"
done
warn "DNS có thể mất vài phút để lan truyền. Kiểm tra: curl -i https://portal.${DOMAIN}/healthz"
