# KRAB script helpers

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- Interaction ----------------------------------------------------------
require_tty() {
  [[ -r /dev/tty ]] || die "This script is interactive; run it in a terminal."
}

ask() {
  local prompt="$1" default="${2:-}" reply
  read -r -p "$prompt${default:+ [$default]}: " reply < /dev/tty
  printf '%s' "${reply:-$default}"
}

# Ask until the answer is non-empty.
ask_required() {
  local prompt="$1" default="${2:-}" value
  while true; do
    value="$(ask "$prompt" "$default")"
    [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }
    printf '  Required.\n' >&2
  done
}

# Ask for a value that has no safe default
ask_with_example() {
  local label="$1" example="$2" stored="${3:-}"
  if [[ -n "$stored" ]]; then
    ask_required "$label" "$stored"
  else
    ask_required "$label (e.g. $example)"
  fi
}

ask_secret() {
  local prompt="$1" reply
  read -rs -p "$prompt: " reply < /dev/tty
  echo >&2
  printf '%s' "$reply"
}

# Ask for a secret twice and keep asking until both entries match.
ask_secret_confirmed() {
  local prompt="$1" first second
  while true; do
    first="$(ask_secret "$prompt")"
    [[ -z "$first" ]] && return 0
    second="$(ask_secret "Repeat it")"
    [[ "$first" == "$second" ]] && { printf '%s' "$first"; return 0; }
    printf '  They do not match, try again.\n' >&2
  done
}

# Ask for a secret, and only offer to keep an existing one when there is one to
# keep.
ask_secret_or_keep() {
  local label="$1" current="${2:-}" suffix="" value
  [[ -n "$current" ]] && suffix=" (blank to keep the current one)"
  while true; do
    value="$(ask_secret_confirmed "${label}${suffix}")"
    [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }
    [[ -n "$current" ]] && return 0
    printf '  %s is required.\n' "$label" >&2
  done
}

confirm() {
  local reply
  reply="$(ask "$1 [y/N]")"
  [[ "$reply" =~ ^[Yy] ]]
}

# True if the file parses as JSON.
json_valid() {
  local file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$file" >/dev/null 2>&1
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" >/dev/null 2>&1
    return
  fi
  # No parser on the box: at least reject what is obviously not a JSON object.
  [[ "$(tr -d '[:space:]' < "$file" | head -c 1)" == "{" ]]
}

# --- Locating the Supabase project ----------------------------------------
resolve_supabase_dir() {
  SUPABASE_DIR="${SUPABASE_DIR:-$HOME/supabase-project}"
  ENV_FILE="$SUPABASE_DIR/.env"
}

require_env_file() {
  resolve_supabase_dir
  if [[ ! -f "$ENV_FILE" ]]; then
    printf 'ERROR: no Supabase .env at %s\n' "$ENV_FILE" >&2
    if [[ $EUID -eq 0 ]]; then
      printf '  You are running as root, so $HOME is /root. These scripts expect to run\n' >&2
      printf '  as the same unprivileged user that ran setup_backend.sh; re-run without sudo.\n' >&2
    else
      printf '  Run setup_backend.sh first, or point this script at the project:\n' >&2
      printf '    SUPABASE_DIR=/path/to/supabase-project bash %s\n' "${0##*/}" >&2
    fi
    exit 1
  fi
  [[ -w "$ENV_FILE" ]] || die "$ENV_FILE is not writable by $(id -un). If a previous run was done with sudo, fix it with: sudo chown $(id -un) $ENV_FILE"
}

# --- .env read/write ------------------------------------------------------
env_escape() {
  local v="$1"
  if [[ "$v" == *[[:space:]\#\"\'\\\$]* ]]; then
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//\$/\$\$}"
    printf '"%s"' "$v"
  else
    printf '%s' "$v"
  fi
}

env_unescape() {
  local v="$1"
  if [[ ${#v} -ge 2 && "$v" == \"*\" ]]; then
    v="${v:1:${#v}-2}"
    v="${v//\$\$/\$}"
    v="${v//\\\"/\"}"
    v="${v//\\\\/\\}"
  fi
  printf '%s' "$v"
}

# Value of KEY in .env, or empty.
env_get() {
  local raw
  [[ -f "${ENV_FILE:-}" ]] || return 0
  raw="$(grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  raw="${raw%$'\r'}"
  env_unescape "$raw"
}

# Replace or append KEY=VALUE.
set_env() {
  local key="$1" val tmp
  val="$(env_escape "$2")"
  [[ -f "$ENV_FILE" ]] || die "no .env at $ENV_FILE"
  tmp="$(mktemp)"
  grep -v "^${key}=" "$ENV_FILE" > "$tmp" || true
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
  printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  echo "  set $key"
}

# Append an entry to a comma-separated .env list, keeping what is already there.
env_list_add() {
  local key="$1" entry="$2" cur
  cur="$(env_get "$key")"
  case ",$cur," in
    *",$entry,"*) echo "  $key already contains $entry" ; return 0 ;;
  esac
  set_env "$key" "${cur:+$cur,}$entry"
}

# --- Docker ---------------------------------------------------------------
compose() { ( cd "$SUPABASE_DIR" && docker compose "$@" ); }

compose_up() {
  log "Applying to ${*}"
  compose up -d "$@" || die "docker compose up -d $* failed"
}

# --- Downloads ------------------------------------------------------------
fetch_to() {
  local url="$1" dest="$2" tmp
  tmp="$(mktemp)"
  if curl -fsL "$url" -o "$tmp"; then
    mv "$tmp" "$dest"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# --- SMTP -----------------------------------------------------------------
smtp_is_stock() { [[ "$(env_get SMTP_HOST)" == 'supabase-mail' ]]; }

# The stored value, or empty while the block is still Supabase's placeholder.
smtp_get() {
  smtp_is_stock && return 0
  env_get "$1"
}

smtp_configured() {
  smtp_is_stock && return 1
  [[ -n "$(env_get SMTP_HOST)" ]]
}

require_smtp() {
  smtp_configured && return 0
  printf 'ERROR: no SMTP_HOST in %s\n' "$ENV_FILE" >&2
  printf '  %s needs SMTP to deliver its email. Configure it first.' >&2
  exit 1
}

# --- Internal service URLs ------------------------------------------------
KONG_INTERNAL_URL="http://kong:8000"

# The public origin clients use.
public_api_url() {
  local u
  u="$(env_get SUPABASE_PUBLIC_URL)"
  [[ -n "$u" ]] || u="$(env_get API_EXTERNAL_URL)"
  [[ -n "$u" ]] || die "neither SUPABASE_PUBLIC_URL nor API_EXTERNAL_URL is set in $ENV_FILE; re-run setup_backend.sh"
  printf '%s' "${u%/}"
}
