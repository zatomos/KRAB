#!/usr/bin/env bash
#
# SMTP for outgoing KRAB mail.
#
# Run:
#   curl -fsSL https://raw.githubusercontent.com/zatomos/KRAB/main/scripts/setup_smtp.sh | bash

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

REPO_REF="${REPO_REF:-main}"
REPO_RAW="https://raw.githubusercontent.com/zatomos/KRAB/$REPO_REF"
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ -n "$_dir" && -r "$_dir/lib.sh" ]] && head -n1 "$_dir/lib.sh" | grep -q 'KRAB script helpers'; then
  source "$_dir/lib.sh"
else
  _lib="$(mktemp)"
  curl -fsSL "$REPO_RAW/scripts/lib.sh" -o "$_lib" || { echo "ERROR: could not fetch scripts/lib.sh" >&2; exit 1; }
  source "$_lib"
  rm -f "$_lib"
fi

require_tty
require_env_file

log "SMTP settings"
echo "  Use an app-specific password from your provider, not your account password."

SMTP_HOST="$(ask 'SMTP host' "$(env_get SMTP_HOST)")"
[[ -n "$SMTP_HOST" ]] || die "SMTP host required"
SMTP_PORT="$(ask 'SMTP port' "$(env_get SMTP_PORT)")"
[[ -n "$SMTP_PORT" ]] || SMTP_PORT=587
SMTP_USER="$(ask 'SMTP user' "$(env_get SMTP_USER)")"
[[ -n "$SMTP_USER" ]] || die "SMTP user required"

SMTP_PASS="$(ask_secret 'SMTP password (empty = keep current)')"
if [[ -z "$SMTP_PASS" ]]; then
  [[ -n "$(env_get SMTP_PASS)" ]] || die "SMTP password required"
  echo "  keeping the stored password"
fi

from_default="$(env_get SMTP_ADMIN_EMAIL)"; [[ -n "$from_default" ]] || from_default="$SMTP_USER"
SMTP_FROM="$(ask 'From email' "$from_default")"
SMTP_SENDER_NAME="$(ask 'Sender name' "$(env_get SMTP_SENDER_NAME)")"
[[ -n "$SMTP_SENDER_NAME" ]] || SMTP_SENDER_NAME=KRAB

log "Patching $ENV_FILE"
set_env SMTP_HOST "$SMTP_HOST"
set_env SMTP_PORT "$SMTP_PORT"
set_env SMTP_USER "$SMTP_USER"
[[ -n "$SMTP_PASS" ]] && set_env SMTP_PASS "$SMTP_PASS"
set_env SMTP_ADMIN_EMAIL "$SMTP_FROM"
set_env SMTP_SENDER_NAME "$SMTP_SENDER_NAME"

compose_up auth

cat <<EOF

✅ SMTP configured ($SMTP_USER via $SMTP_HOST:$SMTP_PORT).

You can run these next:
  scripts/setup_password_reset.sh
  scripts/setup_email_confirmation.sh
EOF
