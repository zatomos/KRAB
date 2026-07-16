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
_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || true)"
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

SMTP_HOST="$(ask_with_example 'SMTP host' 'smtp.provider.example.com' "$(smtp_get SMTP_HOST)")"
port_default="$(smtp_get SMTP_PORT)"; [[ -n "$port_default" ]] || port_default=587
SMTP_PORT="$(ask 'SMTP port' "$port_default")"
SMTP_USER="$(ask_with_example 'SMTP user' 'your-email@provider.com' "$(smtp_get SMTP_USER)")"

SMTP_PASS="$(ask_secret_or_keep 'SMTP password' "$(smtp_get SMTP_PASS)")"
[[ -n "$SMTP_PASS" ]] || echo "  keeping the stored password"

from_default="$(smtp_get SMTP_ADMIN_EMAIL)"; [[ -n "$from_default" ]] || from_default="$SMTP_USER"
SMTP_FROM="$(ask_required 'From email' "$from_default")"
sender_default="$(smtp_get SMTP_SENDER_NAME)"; [[ -n "$sender_default" ]] || sender_default=KRAB
SMTP_SENDER_NAME="$(ask_required 'Sender name' "$sender_default")"

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

You can now run the password reset and email confirmation setup scripts (check README).
EOF
