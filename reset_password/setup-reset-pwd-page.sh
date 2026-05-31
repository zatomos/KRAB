#!/bin/bash
set -e

# KRAB Reset password page setup
# Usage: sudo bash reset_password/setup-reset-page.sh <SUPABASE_URL> <SUPABASE_ANON_KEY>

SUPABASE_URL="${1}"
SUPABASE_ANON_KEY="${2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_ROOT="/var/www/krab"
NGINX_CONF="/etc/nginx/sites-available/krab"

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_ANON_KEY" ]; then
  echo "Usage: sudo bash scripts/setup-reset-page.sh <SUPABASE_URL> <SUPABASE_ANON_KEY>"
  exit 1
fi

echo "Installing nginx..."
apt-get install -y nginx > /dev/null

echo "Creating web root..."
mkdir -p "$WEB_ROOT"

echo "Writing reset-password.html..."
sed \
  -e "s|%%SUPABASE_URL%%|${SUPABASE_URL}|g" \
  -e "s|%%SUPABASE_ANON_KEY%%|${SUPABASE_ANON_KEY}|g" \
  "$SCRIPT_DIR/reset-password.html" > "$WEB_ROOT/reset-password.html"

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

if [ ! -f /etc/nginx/sites-enabled/krab ]; then
  ln -s "$NGINX_CONF" /etc/nginx/sites-enabled/krab
fi

if [ -f /etc/nginx/sites-enabled/default ]; then
  rm /etc/nginx/sites-enabled/default
fi

nginx -t
systemctl enable nginx
systemctl reload nginx

echo ""
echo "✅ Done! Reset page is live at http://localhost/reset-password.html"
echo ""
echo "Next steps:"
echo "  1. Make the page accessible to the internet: http://localhost:80"
echo "  2. Add the public URL to ADDITIONAL_REDIRECT_URLS in your Supabase .env"
echo "  3. Restart Supabase auth: docker compose up -d auth"