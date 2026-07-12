#!/usr/bin/env bash
#
# One-shot KRAB backend bootstrap on a fresh host. Installs self-hosted Supabase if missing,
# configures it for KRAB, loads the schema, creates the storage buckets,
# and deploys the notification edge functions.
#
# Run:
#   curl -fsSL https://raw.githubusercontent.com/zatomos/KRAB/main/scripts/setup_backend.sh | bash

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -uo pipefail

SUPABASE_DIR="$HOME/supabase-project"
DB_CONTAINER="supabase-db"
REPO_RAW="https://raw.githubusercontent.com/zatomos/KRAB/main"
# bucket:size-limit-in-bytes:allowed-mime-types.
BUCKETS=(
  "images:15728640:image/*"
  "group-icons:1048576:image/*"
  "profile-pictures:1048576:image/*"
  "image-thumbnails:1048576:image/*"
)
FN_SLUGS="new_image_notify:image-notification new_comment_notify:comment-notification new_reaction_notify:reaction-notification image_deleted_notify:image-deleted-notification generate-thumbnail:thumbnail-generation"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ -r /dev/tty ]] || die "This script is interactive; run it in a terminal."
ask() { local p="$1" d="${2:-}" v; read -r -p "$p${d:+ [$d]}: " v < /dev/tty; printf '%s' "${v:-$d}"; }

# --- 0. Install Supabase if missing -------------------------------------
if [[ ! -d "$SUPABASE_DIR" ]]; then
  log "Installing self-hosted Supabase into $HOME"
  ( cd "$HOME" && curl -fsSL https://supabase.link/setup.sh | sh -s -- -y ) \
    || die "Supabase install failed"
fi
ENV_FILE="$SUPABASE_DIR/.env"
[[ -f "$ENV_FILE" ]] || die "No .env in $SUPABASE_DIR"

# --- Gather answers interactively -----------------------------------------
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
API_URL="$(ask 'API URL clients use' "http://${ip:-localhost}:8000")"
DASH_USER="$(ask 'Studio dashboard username' "$(grep -E '^DASHBOARD_USERNAME=' "$ENV_FILE" | cut -d= -f2-)")"
read -rs -p "Studio dashboard password (empty = keep auto-generated): " DASH_PASS < /dev/tty; echo
log "Using API_URL=$API_URL"

# The notification triggers authenticate to the edge functions with the service
# role key.
SERVICE_ROLE_KEY="$(grep -E '^SERVICE_ROLE_KEY=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r"')"
[[ -n "$SERVICE_ROLE_KEY" ]] || die "SERVICE_ROLE_KEY not found in $ENV_FILE"

SCHEMA_TMP="$(mktemp)"; trap 'rm -f "$SCHEMA_TMP"' EXIT
curl -fsSL "$REPO_RAW/supabase/schema.sql" -o "$SCHEMA_TMP" || die "Failed to download schema.sql"

# --- 1. Patch .env --------------------------------------------------------
log "Patching $ENV_FILE"
set_env() {  # plain KEY=VALUE (safe: no backslash interpretation)
  grep -v "^$1=" "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  echo "  set $1"
}
set_env ENABLE_EMAIL_AUTOCONFIRM true
set_env FUNCTIONS_VERIFY_JWT false
set_env SUPABASE_PUBLIC_URL "$API_URL"
set_env API_EXTERNAL_URL "$API_URL"
set_env DASHBOARD_USERNAME "$DASH_USER"
[[ -n "$DASH_PASS" ]] && set_env DASHBOARD_PASSWORD "$DASH_PASS"

# --- 1b. docker-compose override: auth refresh-token config + Firebase --
OVERRIDE_FILE="$SUPABASE_DIR/docker-compose.override.yml"
cat > "$OVERRIDE_FILE" <<'YML'
# Added by KRAB setup_backend.sh. Do not edit; re-run the script to regenerate.
services:
  auth:
    environment:
      GOTRUE_SECURITY_REFRESH_TOKEN_REUSE_INTERVAL: "10"
      GOTRUE_SECURITY_REFRESH_TOKEN_ALGORITHM_VERSION: "2"
      GOTRUE_SECURITY_REFRESH_TOKEN_UPGRADE_PERCENTAGE: "100"
YML
echo "  wrote auth refresh-token config to docker-compose.override.yml"

# Firebase service account for the push edge functions (optional).
printf '\nPaste the Firebase service-account JSON, then Ctrl-D (Ctrl-D alone to skip).\n> '
sa_json="$(cat /dev/tty)"
if [[ -n "${sa_json//[[:space:]]/}" ]]; then
  if command -v jq >/dev/null 2>&1; then sa_json="$(printf '%s' "$sa_json" | jq -c .)" || die "Invalid JSON"
  else sa_json="$(printf '%s' "$sa_json" | tr -d '\n')"; fi
  grep -v '^GOOGLE_SERVICE_ACCOUNT=' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  printf "GOOGLE_SERVICE_ACCOUNT='%s'\n" "$sa_json" >> "$ENV_FILE"
  echo "  set GOOGLE_SERVICE_ACCOUNT"
fi

# If a service account is present (just pasted, or kept from a previous run),
# expose it to the edge-functions container via the same override.
if grep -q '^GOOGLE_SERVICE_ACCOUNT=' "$ENV_FILE"; then
  cat >> "$OVERRIDE_FILE" <<'YML'
  functions:
    environment:
      GOOGLE_SERVICE_ACCOUNT: ${GOOGLE_SERVICE_ACCOUNT}
YML
  echo "  added functions env to docker-compose.override.yml"
fi

if grep -q '^COMPOSE_FILE=' "$ENV_FILE" \
   && ! grep '^COMPOSE_FILE=' "$ENV_FILE" | grep -q 'docker-compose.override.yml'; then
  sed -i 's#^COMPOSE_FILE=.*#&:docker-compose.override.yml#' "$ENV_FILE"
  echo "  wired docker-compose.override.yml into COMPOSE_FILE"
fi

# --- 2. Start the stack ---------------------------------------------------
log "Starting the stack"
( cd "$SUPABASE_DIR" && docker compose up -d ) || die "docker compose up failed"

# --- 3. Wait for Postgres -------------------------------------------------
log "Waiting for $DB_CONTAINER..."
for i in $(seq 1 60); do
  docker exec "$DB_CONTAINER" pg_isready -U postgres -d postgres >/dev/null 2>&1 && break
  [[ $i -eq 60 ]] && die "$DB_CONTAINER not ready after 60s"
  sleep 1
done
psql_run() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres "$@"; }

# --- 3b. Wait for the storage service to create its schema -----------------
# storage.buckets/objects are created by the 'storage' container's migrations a
# few seconds after startup. Without them, the schema's storage RLS policies and
# the bucket seed have nothing to attach to.
log "Waiting for storage schema (storage.buckets)..."
for i in $(seq 1 60); do
  [[ "$(psql_run -tAc "select to_regclass('storage.buckets') is not null" 2>/dev/null)" == "t" ]] && break
  [[ $i -eq 60 ]] && die "storage.buckets never appeared, is the 'storage' container running?"
  sleep 2
done

# --- 4. Load schema -------------------------------------------------------
# The dump includes the storage schema, which already exists on a fresh
# Supabase, so "already exists" notices are expected. The trigger URL and the
# service-role bearer are both substituted in
log "Loading schema (storage 'already exists' notices are expected)"
sed -e "s#your_supabase_url#${API_URL}#g" \
    -e "s#<SERVICE_ROLE_KEY>#${SERVICE_ROLE_KEY}#g" \
    "$SCHEMA_TMP" | psql_run >/dev/null 2>&1 || true
[[ "$(psql_run -tAc "select to_regclass('public.\"Groups\"') is not null")" == "t" ]] \
  || die "Schema load failed: public.Groups not found"
log "Schema loaded (public.Groups present)"

trg="$(psql_run -tAc "select count(distinct trigger_name) from information_schema.triggers where trigger_name in ('on-image-insert','on-comment-insert','on-reaction-insert','on-image-delete','on-image-insert-thumbnail');" | tr -d '[:space:]')"
[[ "$trg" == "5" ]] || echo "  WARN: notification/thumbnail triggers missing ($trg/5), check supabase_functions/pg_net"

# --- 5. Storage buckets ---------------------------------------------------
log "Creating storage buckets"
for spec in "${BUCKETS[@]}"; do
  b="${spec%%:*}"; rest="${spec#*:}"
  limit="${rest%%:*}"; mimes="${rest#*:}"
  mime_arr="ARRAY['${mimes//,/\',\'}']"
  psql_run -c "insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
               values ('$b','$b',false,$limit,$mime_arr)
               on conflict (id) do update
                 set file_size_limit = excluded.file_size_limit,
                     allowed_mime_types = excluded.allowed_mime_types;" >/dev/null
  echo "  bucket $b (max $((limit / 1048576))MB, $mimes)"
done

# --- 6. Deploy edge functions --------------------------------------------
# Self-hosted edge runtime serves each subdir of volumes/functions at
# /functions/v1/<slug>. Download the notification functions under their slugs.
log "Deploying edge functions"
fdir="$SUPABASE_DIR/volumes/functions"
deployed=1

# Shared helpers
mkdir -p "$fdir/_shared"
curl -fsSL "$REPO_RAW/supabase/functions/_shared/fcm.ts" -o "$fdir/_shared/fcm.ts" \
  || { echo "  WARN: failed to fetch _shared/fcm.ts"; deployed=0; }
echo "  _shared/fcm.ts"

for pair in $FN_SLUGS; do
  src="${pair%%:*}"; slug="${pair##*:}"
  mkdir -p "$fdir/$slug"
  curl -fsSL "$REPO_RAW/supabase/functions/$src/index.ts" -o "$fdir/$slug/index.ts" \
    || { echo "  WARN: failed to fetch $src/index.ts"; deployed=0; continue; }
  curl -fsSL "$REPO_RAW/supabase/functions/$src/deno.json" -o "$fdir/$slug/deno.json" 2>/dev/null || true
  echo "  $src -> $slug"
done
[[ $deployed -eq 1 ]] && { ( cd "$SUPABASE_DIR" && docker compose restart functions ) >/dev/null 2>&1 \
  || echo "  WARN: restart the 'functions' container manually"; }

log "Done."
echo "Optional: enable password reset with scripts/reset_password/setup-reset-pwd-page.sh"
