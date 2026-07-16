#!/usr/bin/env bash
#
# One-shot KRAB backend bootstrap on a fresh host. Installs self-hosted Supabase if missing,
# configures it for KRAB, loads the schema, creates the storage buckets,
# stores this instance's Firebase config, and deploys the edge functions.
#
# Run:
#   curl -fsSL https://raw.githubusercontent.com/zatomos/KRAB/main/scripts/setup_backend.sh | bash

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

DB_CONTAINER="supabase-db"
# bucket:size-limit-in-bytes:allowed-mime-types.
BUCKETS=(
  "images:15728640:image/*"
  "group-icons:1048576:image/*"
  "profile-pictures:1048576:image/*"
  "image-thumbnails:1048576:image/*"
)

FN_SLUGS="
instance_config:instance-config
new_image_notify:image-notification
new_comment_notify:comment-notification
new_reaction_notify:reaction-notification
image_deleted_notify:image-deleted-notification
generate-thumbnail:thumbnail-generation
auth_pages:pages
"
AUTH_PAGE_FILES="reset_password.ts confirmed.ts recovery_email.ts confirmation_email.ts"

require_tty
[[ $EUID -eq 0 ]] && warn "Running as root: Supabase will be installed in /root. The optional setup scripts expect the same user, so stay consistent."

# --- 0. Install Supabase if missing -------------------------------------
resolve_supabase_dir
if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -e "$SUPABASE_DIR" ]]; then
    die "$SUPABASE_DIR exists but has no .env, so a previous install was interrupted.
  The installer will not write into an existing directory. Check there is nothing
  you want in there, then remove it and re-run:
    rm -rf $SUPABASE_DIR"
  fi
  log "Installing self-hosted Supabase into $SUPABASE_DIR"
  mkdir -p "$(dirname "$SUPABASE_DIR")" || die "Cannot create $(dirname "$SUPABASE_DIR")"
  ( cd "$(dirname "$SUPABASE_DIR")" \
      && curl -fsSL https://supabase.link/setup.sh | sh -s -- -y -p "$(basename "$SUPABASE_DIR")" ) \
    || die "Supabase install failed"
  [[ -f "$ENV_FILE" ]] || die "The installer finished but left no .env in $SUPABASE_DIR"
fi

# --- Gather answers interactively -----------------------------------------
ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
API_URL="$(ask 'API URL clients use' "http://${ip:-localhost}:8000")"
API_URL="${API_URL%/}"
DASH_USER="$(ask 'Studio dashboard username' "$(env_get DASHBOARD_USERNAME)")"
DASH_PASS="$(ask_secret_confirmed 'Studio dashboard password (empty = keep auto-generated)')"
log "Using API_URL=$API_URL"

# The notification triggers authenticate to the edge functions with the service
# role key.
SERVICE_ROLE_KEY="$(env_get SERVICE_ROLE_KEY)"
[[ -n "$SERVICE_ROLE_KEY" ]] || die "SERVICE_ROLE_KEY not found in $ENV_FILE"

SCHEMA_TMP="$(mktemp)"; trap 'rm -f "$SCHEMA_TMP"' EXIT
curl -fsSL "$REPO_RAW/supabase/schema.sql" -o "$SCHEMA_TMP" || die "Failed to download schema.sql"

# --- 1. Patch .env --------------------------------------------------------
log "Patching $ENV_FILE"
[[ -n "$(env_get ENABLE_EMAIL_AUTOCONFIRM)" ]] || set_env ENABLE_EMAIL_AUTOCONFIRM true
set_env FUNCTIONS_VERIFY_JWT false
set_env SUPABASE_PUBLIC_URL "$API_URL"
set_env API_EXTERNAL_URL "$API_URL"
if [[ -n "$DASH_USER" ]]; then set_env DASHBOARD_USERNAME "$DASH_USER"; fi
if [[ -n "$DASH_PASS" ]]; then set_env DASHBOARD_PASSWORD "$DASH_PASS"; fi

# --- 1b. Firebase Cloud Messaging for push -------------------------------
log "Configuring Firebase Cloud Messaging"
echo "  Create a Firebase project at https://console.firebase.google.com, add an"
echo "  Android app whose package matches your build (fr.zatomos.krab for the"
echo "  stock app), then download two files:"
echo "   - google-services.json  (Project settings > Your apps)"
echo "   - a service-account key (Project settings > Service accounts > Generate new private key)"

SHARED_DIR="$SUPABASE_DIR/volumes/functions/_shared"

# Ask until the answer is a readable file that parses as JSON and is the one
# being asked for.
prompt_json_path() {
  local prompt="$1" name="$2" needle="$3" deployed="$4" suffix="" path
  [[ -f "$deployed" ]] && suffix=" (blank to keep the current one)"
  while true; do
    path="$(ask "${prompt}${suffix}" '')"
    if [[ -z "$path" ]]; then
      [[ -n "$suffix" ]] && { JSON_PATH=""; return 0; }
      echo "  A path to your $name is required." >&2; continue
    fi
    path="${path/#\~/$HOME}"
    if [[ ! -f "$path" ]]; then echo "  No such file: $path" >&2; continue; fi
    if [[ ! -r "$path" ]]; then echo "  Not readable by $(id -un): $path" >&2; continue; fi
    if ! json_valid "$path"; then echo "  Not valid JSON: $path" >&2; continue; fi
    if ! grep -q "$needle" "$path"; then echo "  Valid JSON, but not a $name (no $needle): $path" >&2; continue; fi
    JSON_PATH="$path"; return 0
  done
}

prompt_json_path 'Path to google-services.json' 'google-services.json' 'mobilesdk_app_id' \
  "$SHARED_DIR/google-services.json"
GS_PATH="$JSON_PATH"
prompt_json_path 'Path to the service-account JSON' 'service-account JSON' 'private_key' \
  "$SHARED_DIR/service-account.json"
SA_PATH="$JSON_PATH"

# --- 1c. docker-compose override -----------------------------------------
# One override for everything KRAB changes.
OVERRIDE_FILE="$SUPABASE_DIR/docker-compose.override.yml"
cat > "$OVERRIDE_FILE" <<'YML'
# Added by KRAB setup_backend.sh. Do not edit; re-run the script to regenerate.
services:
  auth:
    environment:
      GOTRUE_SECURITY_REFRESH_TOKEN_REUSE_INTERVAL: "10"
      GOTRUE_SECURITY_REFRESH_TOKEN_ALGORITHM_VERSION: "2"
      GOTRUE_SECURITY_REFRESH_TOKEN_UPGRADE_PERCENTAGE: "100"
      GOTRUE_MAILER_TEMPLATES_RECOVERY: ${GOTRUE_MAILER_TEMPLATES_RECOVERY:-}
      GOTRUE_MAILER_SUBJECTS_RECOVERY: ${GOTRUE_MAILER_SUBJECTS_RECOVERY:-Reset your KRAB password}
      GOTRUE_MAILER_TEMPLATES_CONFIRMATION: ${GOTRUE_MAILER_TEMPLATES_CONFIRMATION:-}
      GOTRUE_MAILER_SUBJECTS_CONFIRMATION: ${GOTRUE_MAILER_SUBJECTS_CONFIRMATION:-Confirm your KRAB email}
  functions:
    environment:
      # The Firebase config is deployed as JSON files under _shared/ and imported
      # by the functions; these are only here for operators who would rather
      # inject it.
      GOOGLE_SERVICES_JSON: ${GOOGLE_SERVICES_JSON:-}
      FCM_SERVICE_ACCOUNT_JSON: ${FCM_SERVICE_ACCOUNT_JSON:-}
      # Optional: pin which Android app to serve when google-services.json holds
      # several (e.g. a rebranded fork). Defaults to the first client.
      FCM_PACKAGE_NAME: ${FCM_PACKAGE_NAME:-}
      SUPABASE_PUBLIC_URL: ${SUPABASE_PUBLIC_URL:-}
      PASSWORD_RESET_URL: ${PASSWORD_RESET_URL:-}
      EMAIL_CONFIRM_URL: ${EMAIL_CONFIRM_URL:-}
YML
echo "  wrote docker-compose.override.yml"

if grep -q '^COMPOSE_FILE=' "$ENV_FILE" \
   && ! grep '^COMPOSE_FILE=' "$ENV_FILE" | grep -q 'docker-compose.override.yml'; then
  sed -i 's#^COMPOSE_FILE=.*#&:docker-compose.override.yml#' "$ENV_FILE"
  echo "  wired docker-compose.override.yml into COMPOSE_FILE"
fi

# --- 2. Start the stack ---------------------------------------------------
log "Starting the stack"
compose up -d || die "docker compose up failed"

# --- 3. Wait for Postgres -------------------------------------------------
log "Waiting for $DB_CONTAINER..."
for i in $(seq 1 60); do
  if docker exec "$DB_CONTAINER" pg_isready -U postgres -d postgres >/dev/null 2>&1; then break; fi
  [[ $i -eq 60 ]] && die "$DB_CONTAINER not ready after 60s"
  sleep 1
done

psql_load()  { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres; }
psql_query() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres "$@"; }

# --- 3b. Wait for the storage service to create its schema -----------------
# storage.buckets/objects are created by the 'storage' container's migrations a
# few seconds after startup. Without them, the schema's storage RLS policies and
# the bucket seed have nothing to attach to.
log "Waiting for the storage schema..."
for i in $(seq 1 60); do
  if [[ "$(psql_query -tAc "select to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null" 2>/dev/null || true)" == "t" ]]; then break; fi
  [[ $i -eq 60 ]] && die "the storage schema never appeared, is the 'storage' container running? (docker compose logs storage)"
  sleep 2
done

# --- 3c. Let 'postgres' manage the storage schema -------------------------
log "Granting the storage role to postgres"
docker exec supabase-db psql -U supabase_admin -d postgres -q \
  -c "grant supabase_storage_admin to postgres;" 2>/dev/null \
  || warn "could not grant supabase_storage_admin to postgres; storage policies may fail"

# --- 4. Load schema -------------------------------------------------------
# The dump includes the storage schema, which already exists on a fresh
# Supabase, so "already exists" errors are expected and only those are ignored.
# The trigger URL and the service-role bearer are both substituted in.
log "Loading schema"
SCHEMA_LOG="$(mktemp)"
sed -e "s#your_supabase_url#${API_URL}#g" \
    -e "s#<SERVICE_ROLE_KEY>#${SERVICE_ROLE_KEY}#g" \
    "$SCHEMA_TMP" | psql_load > "$SCHEMA_LOG" 2>&1 || true
benign='already exists|multiple primary keys for table .* are not allowed|permission denied to change default privileges|grant options cannot be granted back to your own grantor'
real_errs="$(grep 'ERROR:' "$SCHEMA_LOG" | grep -vE "$benign" || true)"
if [[ -n "$real_errs" ]]; then
  warn "schema load reported $(printf '%s\n' "$real_errs" | wc -l) unexpected error(s):"
  printf '%s\n' "$real_errs" | sort | uniq -c | sort -rn | head -15 >&2
fi
rm -f "$SCHEMA_LOG"
[[ "$(psql_query -tAc "select to_regclass('public.\"Groups\"') is not null")" == "t" ]] \
  || die "Schema load failed: public.Groups not found"
log "Schema loaded (public.Groups present)"

want_pol="$(grep -oE '^CREATE POLICY "[^"]+" ON "?storage"?\."?objects"?' "$SCHEMA_TMP" \
  | sed 's/^CREATE POLICY "//; s/" ON.*//' | sort -u || true)"
if [[ -z "$want_pol" ]]; then
  warn "could not read the expected storage policies out of schema.sql; skipping that check"
else
  have_pol="$(psql_query -tAc "select policyname from pg_policies where schemaname = 'storage' and tablename = 'objects';" 2>/dev/null | sort -u || true)"
  missing_pol="$(comm -23 <(printf '%s\n' "$want_pol") <(printf '%s\n' "$have_pol") || true)"
  if [[ -n "$missing_pol" ]]; then
    die "$(printf '%s\n' "$missing_pol" | wc -l) of $(printf '%s\n' "$want_pol" | wc -l) storage policies are missing, so the app will not be able to upload or read photos:
$(printf '%s\n' "$missing_pol" | sed 's/^/  - /')
  Failed to grant storage admin to postgres. Check it by hand:
    docker exec supabase-db psql -U supabase_admin -d postgres -c 'grant supabase_storage_admin to postgres;'
  then re-run this script against a clean database (docker compose down -v)."
  fi
  log "Storage policies present ($(printf '%s\n' "$want_pol" | wc -l))"
fi

trg="$(psql_query -tAc "select count(distinct trigger_name) from information_schema.triggers where trigger_name in ('on-image-insert','on-comment-insert','on-reaction-insert','on-image-delete','on-image-insert-thumbnail');" 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$trg" == "5" ]] || warn "notification/thumbnail triggers missing ($trg/5), check supabase_functions/pg_net"

# --- 4b. Wire the new-user trigger ---------------------------------------
log "Wiring the new-user trigger"
psql_query -tAc "select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'handle_new_user';" 2>/dev/null | grep -q 1 \
  || die "public.handle_new_user() is missing from schema.sql; the app cannot create user profiles"

psql_query -q -c "
  drop trigger if exists on_auth_user_created on auth.users;
  create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();" \
  || die "could not create the on_auth_user_created trigger on auth.users"

# --- 5. Storage buckets ---------------------------------------------------
log "Creating storage buckets"
for spec in "${BUCKETS[@]}"; do
  b="${spec%%:*}"; rest="${spec#*:}"
  limit="${rest%%:*}"; mimes="${rest#*:}"
  mime_arr="ARRAY['${mimes//,/\',\'}']"
  psql_query -c "insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
               values ('$b','$b',false,$limit,$mime_arr)
               on conflict (id) do update
                 set file_size_limit = excluded.file_size_limit,
                     allowed_mime_types = excluded.allowed_mime_types;" >/dev/null
  echo "  bucket $b (max $((limit / 1048576))MB, $mimes)"
done

# --- 6. Deploy edge functions --------------------------------------------
log "Deploying edge functions"
fdir="$SUPABASE_DIR/volumes/functions"
deployed=1

# Shared helpers
mkdir -p "$fdir/_shared"
if fetch_to "$REPO_RAW/supabase/functions/_shared/fcm.ts" "$fdir/_shared/fcm.ts"; then
  echo "  _shared/fcm.ts"
else
  warn "failed to fetch _shared/fcm.ts"; deployed=0
fi

# The Firebase config, imported as JSON modules by instance_config and fcm.ts.
if [[ -n "$GS_PATH" ]]; then cp "$GS_PATH" "$fdir/_shared/google-services.json"; echo "  _shared/google-services.json"; fi
if [[ -n "$SA_PATH" ]]; then cp "$SA_PATH" "$fdir/_shared/service-account.json"; echo "  _shared/service-account.json"; fi

for pair in $FN_SLUGS; do
  src="${pair%%:*}"; slug="${pair##*:}"
  mkdir -p "$fdir/$slug"
  fetch_to "$REPO_RAW/supabase/functions/$src/index.ts" "$fdir/$slug/index.ts" \
    || { warn "failed to fetch $src/index.ts"; deployed=0; continue; }
  fetch_to "$REPO_RAW/supabase/functions/$src/deno.json" "$fdir/$slug/deno.json" || true
  echo "  $src -> $slug"
done

for page in $AUTH_PAGE_FILES; do
  fetch_to "$REPO_RAW/supabase/functions/auth_pages/$page" "$fdir/pages/$page" \
    || { warn "failed to fetch auth_pages/$page"; deployed=0; continue; }
  echo "  pages/$page"
done
if [[ $deployed -eq 1 ]]; then
  compose restart functions >/dev/null 2>&1 || warn "restart the 'functions' container manually"
fi

log "Done."

# --- Connection token -----------------------------------------------------
# What a user pastes into the app to reach this instance. Packs the API URL and
# the anon key into one string.
ANON_KEY="$(env_get ANON_KEY)"
if [[ -n "$ANON_KEY" ]]; then
  b64="$(printf '%s' "${API_URL}|${ANON_KEY}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  echo
  echo "Share this connection token with your users. They can paste it into the app"
  echo "to connect to this instance:"
  echo
  echo "  krab1:${b64}"
  echo
else
  warn "ANON_KEY not found in $ENV_FILE; could not build a connection token."
fi

cat <<EOF
Optional next steps (check README):
  Setup SMTP                # required by both of the below
  Setup password reset
  Setup email confirmation
EOF
