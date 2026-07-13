#!/bin/bash
set -euo pipefail

# KRAB email-confirmation setup.
# Turns on signup email verification: serves a email confirmed landing page
# and the confirmation email template, then wires Supabase to require
# confirmation and send the email.
#
# Requires SMTP to be configured.
#
# Override the project dir with:
#   SUPABASE_DIR=/path/to/supabase-project sudo -E bash setup-email-confirmation.sh

SUPABASE_DIR="${SUPABASE_DIR:-$HOME/supabase-project}"
ENV_FILE="$SUPABASE_DIR/.env"
WEB_ROOT="/var/www/krab"
NGINX_CONF="/etc/nginx/sites-available/krab"
REPO_RAW="https://raw.githubusercontent.com/zatomos/KRAB/main/scripts/email_confirmation"

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi
[ -r /dev/tty ] || { echo "Run the script in a terminal." >&2; exit 1; }

ask() { local p="$1" d="${2:-}" v; read -r -p "$p${d:+ [$d]}: " v < /dev/tty; printf '%s' "${v:-$d}"; }
env_default() { [ -f "$ENV_FILE" ] && grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true; }

# --- Gather answers interactively -----------------------------------------
PUBLIC_URL="$(ask 'Public URL where this host is served (e.g. https://krab.example.com)')"
[ -n "$PUBLIC_URL" ] || { echo "Public URL required" >&2; exit 1; }
PUBLIC_URL="${PUBLIC_URL%/}"

# The template is fetched by the auth container, so serve it over the LAN IP.
def_ip="$(hostname -I 2>/dev/null | tr ' ' '\n' \
  | grep -E '^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))\.' | head -n1)"
TEMPLATE_HOST="$(ask 'LAN IP the auth container fetches the template from' "$def_ip")"
[ -n "$TEMPLATE_HOST" ] || { echo "Template host required" >&2; exit 1; }

CONFIRMED_PAGE_URL="$PUBLIC_URL/confirmed.html"
EMAIL_TEMPLATE_URL="http://${TEMPLATE_HOST}/confirmation-email.html"

# --- 1. Serve the pages ----------------------------------------------------
echo "Installing nginx..."
apt-get install -y nginx curl > /dev/null

echo "Creating web root..."
mkdir -p "$WEB_ROOT"

echo "Downloading and writing confirmed.html..."
curl -fsSL "$REPO_RAW/confirmed.html" > "$WEB_ROOT/confirmed.html"

echo "Downloading and writing confirmation email template..."
curl -fsSL "$REPO_RAW/confirmation_email_template.html" \
  > "$WEB_ROOT/confirmation-email.html"

if [ ! -f "$NGINX_CONF" ]; then
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
fi
systemctl reload nginx

# --- 2. Wire Supabase ------------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
  echo ""
  echo "⚠️  No .env at $ENV_FILE, skipping Supabase config."
  echo "    Re-run with SUPABASE_DIR=/path/to/supabase-project, or set manually on auth:"
  echo "      GOTRUE_MAILER_AUTOCONFIRM=false"
  echo "      GOTRUE_MAILER_TEMPLATES_CONFIRMATION=$EMAIL_TEMPLATE_URL"
  echo "      GOTRUE_MAILER_SUBJECTS_CONFIRMATION=Confirm your KRAB email"
  echo "      ADDITIONAL_REDIRECT_URLS must include $CONFIRMED_PAGE_URL"
  exit 0
fi

set_env() {  # replace or add a KEY=VALUE line
  grep -v "^$1=" "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  echo "  set $1"
}

# Confirmation requires SMTP; refuse to enable it without one.
if [ -z "$(env_default SMTP_HOST)" ]; then
  echo ""
  echo "⚠️  No SMTP_HOST in $ENV_FILE. Email confirmation needs SMTP to deliver the"
  echo "    link, otherwise new users can never log in. Configure SMTP first (the"
  echo "    reset-password setup does this) and re-run. Aborting."
  exit 1
fi

echo "Patching $ENV_FILE..."
# Append the confirmed page to ADDITIONAL_REDIRECT_URLS without dropping entries.
if grep -q '^ADDITIONAL_REDIRECT_URLS=' "$ENV_FILE"; then
  cur="$(grep '^ADDITIONAL_REDIRECT_URLS=' "$ENV_FILE" | cut -d= -f2-)"
  case ",$cur," in
    *",$CONFIRMED_PAGE_URL,"*) echo "  ADDITIONAL_REDIRECT_URLS already contains the confirmed URL" ;;
    *) set_env ADDITIONAL_REDIRECT_URLS "${cur:+$cur,}$CONFIRMED_PAGE_URL" ;;
  esac
else
  set_env ADDITIONAL_REDIRECT_URLS "$CONFIRMED_PAGE_URL"
fi

set_env EMAIL_CONFIRM_URL "$CONFIRMED_PAGE_URL"

CONFIRM_OVERRIDE="docker-compose.krab-confirm.yml"
echo "Writing $CONFIRM_OVERRIDE (confirmation settings for the auth container)..."
cat > "$SUPABASE_DIR/$CONFIRM_OVERRIDE" <<YML
# Added by KRAB email-confirmation setup. The stock compose does not map the
# plain MAILER_* vars, so set the GOTRUE_-prefixed ones directly. The template
# URL is the host LAN IP so the auth container fetches it locally.
services:
  auth:
    environment:
      GOTRUE_MAILER_AUTOCONFIRM: "false"
      GOTRUE_MAILER_TEMPLATES_CONFIRMATION: ${EMAIL_TEMPLATE_URL}
      GOTRUE_MAILER_SUBJECTS_CONFIRMATION: Confirm your KRAB email
YML

# Make sure docker compose loads the override.
if grep -q '^COMPOSE_FILE=' "$ENV_FILE"; then
  cur="$(grep '^COMPOSE_FILE=' "$ENV_FILE" | cut -d= -f2-)"
  case ":$cur:" in
    *":$CONFIRM_OVERRIDE:"*) echo "  COMPOSE_FILE already includes $CONFIRM_OVERRIDE" ;;
    *) set_env COMPOSE_FILE "$cur:$CONFIRM_OVERRIDE" ;;
  esac
else
  base="docker-compose.yml"
  [ -f "$SUPABASE_DIR/docker-compose.override.yml" ] && base="$base:docker-compose.override.yml"
  set_env COMPOSE_FILE "$base:$CONFIRM_OVERRIDE"
fi

echo "Applying to Supabase auth..."
( cd "$SUPABASE_DIR" && docker compose up -d auth )
( cd "$SUPABASE_DIR" && docker compose up -d functions )

echo ""
echo "✅ Done! New signups must confirm their email before logging in."
echo "   confirmed page (public): $CONFIRMED_PAGE_URL"
echo "   email template:          $EMAIL_TEMPLATE_URL"
echo ""
echo "To turn confirmation back off, remove $CONFIRM_OVERRIDE from COMPOSE_FILE"
echo "in $ENV_FILE (or set GOTRUE_MAILER_AUTOCONFIRM=true) and re-run 'docker compose up -d auth'."
