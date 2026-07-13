#!/bin/bash
set -euo pipefail

# KRAB reset-password page setup.
# Installs nginx, setups the reset-password page and recovery email template
# from GitHub, fills in your Supabase URL + anon key, serves them, and wires
# Supabase so password reset works end to end.

# Override the project dir with:
#   SUPABASE_DIR=/path/to/supabase-project sudo -E bash setup-reset-pwd-page.sh

SUPABASE_DIR="${SUPABASE_DIR:-$HOME/supabase-project}"
ENV_FILE="$SUPABASE_DIR/.env"
WEB_ROOT="/var/www/krab"
NGINX_CONF="/etc/nginx/sites-available/krab"
REPO_RAW="https://raw.githubusercontent.com/zatomos/KRAB/main/scripts/reset_password"

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi
[ -r /dev/tty ] || { echo "This script is interactive; run it in a terminal." >&2; exit 1; }

ask() { local p="$1" d="${2:-}" v; read -r -p "$p${d:+ [$d]}: " v < /dev/tty; printf '%s' "${v:-$d}"; }
env_default() { [ -f "$ENV_FILE" ] && grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true; }

# --- Gather answers interactively -----------------------------------------
def_api="$(env_default SUPABASE_PUBLIC_URL)"; [ -n "$def_api" ] || def_api="$(env_default API_EXTERNAL_URL)"
SUPABASE_URL="$(ask 'Supabase API URL clients use' "$def_api")"
[ -n "$SUPABASE_URL" ] || { echo "Supabase URL required" >&2; exit 1; }

PUBLIC_URL="$(ask 'Public URL where this host is served (e.g. https://krab.example.com)')"
[ -n "$PUBLIC_URL" ] || { echo "Public URL required" >&2; exit 1; }
PUBLIC_URL="${PUBLIC_URL%/}"                       # strip trailing slash

SUPABASE_ANON_KEY="$(ask 'Supabase anon key' "$(env_default ANON_KEY)")"
[ -n "$SUPABASE_ANON_KEY" ] || { echo "Anon key required" >&2; exit 1; }

# The template is fetched by the auth container, so serve it over the LAN IP.
def_ip="$(hostname -I 2>/dev/null | tr ' ' '\n' \
  | grep -E '^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))\.' | head -n1)"
TEMPLATE_HOST="$(ask 'LAN IP the auth container fetches the template from' "$def_ip")"
[ -n "$TEMPLATE_HOST" ] || { echo "Template host required" >&2; exit 1; }

RESET_PAGE_URL="$PUBLIC_URL/reset-password.html"
EMAIL_TEMPLATE_URL="http://${TEMPLATE_HOST}/recovery-email.html"

# --- 1. Serve the pages ----------------------------------------------------
echo "Installing nginx..."
apt-get install -y nginx curl > /dev/null

echo "Creating web root..."
mkdir -p "$WEB_ROOT"

echo "Downloading and writing reset-password.html..."
curl -fsSL "$REPO_RAW/reset-password.html" \
  | sed \
      -e "s|%%SUPABASE_URL%%|${SUPABASE_URL}|g" \
      -e "s|%%SUPABASE_ANON_KEY%%|${SUPABASE_ANON_KEY}|g" \
  > "$WEB_ROOT/reset-password.html"

echo "Downloading and writing recovery email template..."
curl -fsSL "$REPO_RAW/reset_password_email_template.html" \
  > "$WEB_ROOT/recovery-email.html"

echo "Writing nginx config..."
cat > "$NGINX_CONF" << 'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/krab;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

[ -f /etc/nginx/sites-enabled/krab ] || ln -s "$NGINX_CONF" /etc/nginx/sites-enabled/krab
[ -f /etc/nginx/sites-enabled/default ] && rm /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx
systemctl reload nginx

# --- 2. Wire Supabase ------------------------------------------------------
RESET_OVERRIDE="docker-compose.krab-reset.yml"
if [ ! -f "$ENV_FILE" ]; then
  echo ""
  echo "⚠️  No .env at $ENV_FILE, skipping Supabase config."
  echo "    Re-run with SUPABASE_DIR=/path/to/supabase-project, or set manually:"
  echo "      ADDITIONAL_REDIRECT_URLS must include $RESET_PAGE_URL"
  echo "      GOTRUE_MAILER_TEMPLATES_RECOVERY=$EMAIL_TEMPLATE_URL  (on the auth container)"
  echo "      GOTRUE_MAILER_SUBJECTS_RECOVERY=Reset your KRAB password"
  exit 0
fi

set_env() {  # replace or add a KEY=VALUE line
  grep -v "^$1=" "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  echo "  set $1"
}

echo "Patching $ENV_FILE..."
# Append the reset URL to ADDITIONAL_REDIRECT_URLS without dropping existing entries
if grep -q '^ADDITIONAL_REDIRECT_URLS=' "$ENV_FILE"; then
  cur="$(grep '^ADDITIONAL_REDIRECT_URLS=' "$ENV_FILE" | cut -d= -f2-)"
  case ",$cur," in
    *",$RESET_PAGE_URL,"*) echo "  ADDITIONAL_REDIRECT_URLS already contains the reset URL" ;;
    *) set_env ADDITIONAL_REDIRECT_URLS "${cur:+$cur,}$RESET_PAGE_URL" ;;
  esac
else
  set_env ADDITIONAL_REDIRECT_URLS "$RESET_PAGE_URL"
fi

set_env PASSWORD_RESET_URL "$RESET_PAGE_URL"

# Drop any stale plain MAILER_TEMPLATES_* lines
sed -i '/^MAILER_TEMPLATES_RECOVERY=/d;/^MAILER_SUBJECTS_RECOVERY=/d' "$ENV_FILE"

echo "Writing $RESET_OVERRIDE (recovery template for the auth container)..."
cat > "$SUPABASE_DIR/$RESET_OVERRIDE" <<YML
# Added by KRAB reset-password setup. The stock compose does not map the plain
# MAILER_TEMPLATES_* vars, so set the GOTRUE_-prefixed ones directly. The URL is
# the host LAN IP so the auth container fetches the template locally (a public
# proxy round-trip here makes /recover hang and return 504).
services:
  auth:
    environment:
      GOTRUE_MAILER_TEMPLATES_RECOVERY: ${EMAIL_TEMPLATE_URL}
      GOTRUE_MAILER_SUBJECTS_RECOVERY: Reset your KRAB password
YML

# Make sure docker compose loads the override.
if grep -q '^COMPOSE_FILE=' "$ENV_FILE"; then
  cur="$(grep '^COMPOSE_FILE=' "$ENV_FILE" | cut -d= -f2-)"
  case ":$cur:" in
    *":$RESET_OVERRIDE:"*) echo "  COMPOSE_FILE already includes $RESET_OVERRIDE" ;;
    *) set_env COMPOSE_FILE "$cur:$RESET_OVERRIDE" ;;
  esac
else
  base="docker-compose.yml"
  [ -f "$SUPABASE_DIR/docker-compose.override.yml" ] && base="$base:docker-compose.override.yml"
  set_env COMPOSE_FILE "$base:$RESET_OVERRIDE"
fi

# --- SMTP for password-reset emails ---------------------------------------
# Sign-up auto-confirms, so SMTP is only needed for password-reset emails.
# Empty host skips it. SMTP_* ARE mapped to the auth container by the stock
# compose, so .env is the right place for them.
echo ""
SMTP_HOST="$(ask 'SMTP host for password-reset emails (empty to skip)')"
if [ -n "$SMTP_HOST" ]; then
  SMTP_PORT="$(ask 'SMTP port' 587)"
  SMTP_USER="$(ask 'SMTP user')"
  [ -n "$SMTP_USER" ] || { echo "SMTP user required" >&2; exit 1; }
  read -rs -p "SMTP password: " SMTP_PASS < /dev/tty; echo
  [ -n "$SMTP_PASS" ] || { echo "SMTP password required" >&2; exit 1; }
  SMTP_FROM="$(ask 'From email' "$SMTP_USER")"
  SMTP_SENDER_NAME="$(ask 'Sender name' KRAB)"
  set_env SMTP_HOST "$SMTP_HOST"
  set_env SMTP_PORT "$SMTP_PORT"
  set_env SMTP_USER "$SMTP_USER"
  set_env SMTP_PASS "$SMTP_PASS"
  set_env SMTP_ADMIN_EMAIL "$SMTP_FROM"
  set_env SMTP_SENDER_NAME "$SMTP_SENDER_NAME"
fi

echo "Applying to Supabase auth..."
( cd "$SUPABASE_DIR" && docker compose up -d auth )
( cd "$SUPABASE_DIR" && docker compose up -d functions )

echo ""
echo "✅ Done!"
echo "   reset page (public):    $RESET_PAGE_URL"
echo "   email template: $EMAIL_TEMPLATE_URL"
echo ""
echo "Last step: set the app's PASSWORD_RESET_URL=$RESET_PAGE_URL."
