#!/usr/bin/env bash
# Hàm dùng chung cho các script. Dùng: source "$(dirname "$0")/lib.sh"
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

load_env() {
  [[ -f "$CONFIG_DIR/demo.env" ]] || die "Chưa có config/demo.env (cp config/demo.env.example config/demo.env)"
  # shellcheck disable=SC1091
  source "$CONFIG_DIR/demo.env"
  if [[ -f "$CONFIG_DIR/cognito.env" ]]; then
    # shellcheck disable=SC1091
    source "$CONFIG_DIR/cognito.env"
  fi
}

require_cmd() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "Thiếu công cụ: $c"; done
}
