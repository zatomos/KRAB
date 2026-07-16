#!/usr/bin/env bash
#
# Turns on signup email verification. Needs SMTP.
#
# Run:
#   curl -fsSL https://raw.githubusercontent.com/zatomos/KRAB/main/scripts/setup_email_confirmation.sh | bash
# Use --off to turn email verification back off.

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

require_env_file

if [[ "${1:-}" == "--off" ]]; then
  log "Turning email confirmation off"
  set_env ENABLE_EMAIL_AUTOCONFIRM true
  compose_up auth
  echo
  echo "✅ Sign-ups auto-confirm again."
  exit 0
fi

require_smtp "Email confirmation"

API_URL="$(public_api_url)"
CONFIRMED_PAGE_URL="$API_URL/functions/v1/pages/confirmed"
TEMPLATE_URL="$KONG_INTERNAL_URL/functions/v1/pages/confirmation-email"

log "Patching $ENV_FILE"
set_env ENABLE_EMAIL_AUTOCONFIRM false
env_list_add ADDITIONAL_REDIRECT_URLS "$CONFIRMED_PAGE_URL"
set_env EMAIL_CONFIRM_URL "$CONFIRMED_PAGE_URL"
set_env GOTRUE_MAILER_TEMPLATES_CONFIRMATION "$TEMPLATE_URL"
set_env GOTRUE_MAILER_SUBJECTS_CONFIRMATION "Confirm your KRAB email"

compose_up auth functions

log "Checking the landing page"
if curl -fsS -o /dev/null "$CONFIRMED_PAGE_URL" 2>/dev/null; then
  echo "  landing page OK"
else
  warn "could not fetch $CONFIRMED_PAGE_URL: check 'docker compose logs functions'"
fi

cat <<EOF

✅ New signups must confirm their email before logging in.
   landing page:   $CONFIRMED_PAGE_URL
   mail template:  $TEMPLATE_URL

Existing accounts are unaffected. To turn this back off:
  bash setup_email_confirmation.sh --off
EOF
