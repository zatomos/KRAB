#!/usr/bin/env bash
#
# Enables password reset. Needs SMTP.
#
# Run:
#   curl -fsSL https://raw.githubusercontent.com/zatomos/KRAB/main/scripts/setup_password_reset.sh | bash

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

require_env_file
require_smtp "Password reset"

API_URL="$(public_api_url)"
RESET_PAGE_URL="$API_URL/functions/v1/pages/reset-password"
TEMPLATE_URL="$KONG_INTERNAL_URL/functions/v1/pages/recovery-email"

log "Patching $ENV_FILE"
env_list_add ADDITIONAL_REDIRECT_URLS "$RESET_PAGE_URL"
set_env PASSWORD_RESET_URL "$RESET_PAGE_URL"
set_env GOTRUE_MAILER_TEMPLATES_RECOVERY "$TEMPLATE_URL"
set_env GOTRUE_MAILER_SUBJECTS_RECOVERY "Reset your KRAB password"

compose_up auth functions

log "Checking the reset page"
if body="$(curl -fsS "$RESET_PAGE_URL" 2>/dev/null)"; then
  case "$body" in
    *"%%SUPABASE_ANON_KEY%%"*|*"SUPABASE_ANON_KEY = ''"*|*"SUPABASE_URL = ''"*)
      warn "the page is served but its config was not filled in; check 'docker compose logs functions'" ;;
    *)
      echo "  reset page OK" ;;
  esac
else
  warn "could not fetch $RESET_PAGE_URL: check 'docker compose logs functions'"
fi

cat <<EOF

✅ Password reset enabled.
   reset page:     $RESET_PAGE_URL
   mail template:  $TEMPLATE_URL
EOF
