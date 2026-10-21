#!/usr/bin/env bash
# ============================================================================
#  Deploy this repo as token.memebull.com on the SAME server as memebull.com.
#
#  Unlike installer.sh (which assumes a server of its own), this only adds a
#  separate nginx site + Let's Encrypt certificate for the subdomain. It does
#  not touch the memebull.com site, the firewall or nginx's default site.
#
#  First install and every later update:
#    sudo bash deploy-token-subdomain.sh
# ============================================================================
set -euo pipefail

DOMAIN="token.memebull.com"
REPO_URL="https://github.com/demigod412/tkkkb.git"
BRANCH="main"
WEBROOT="/var/www/token-memebull"
ACME_ROOT="/var/www/letsencrypt"
SITE_CONF="/etc/nginx/sites-available/token-memebull"

info() { echo -e "\e[36m\e[1m==>\e[0m $*"; }
ok()   { echo -e "\e[32m✓\e[0m $*"; }
fail() { echo -e "\e[31m✗ $*\e[0m"; exit 1; }

[[ $EUID -eq 0 ]] || fail "Run with sudo: sudo bash deploy-token-subdomain.sh"
command -v nginx >/dev/null || fail "nginx is not installed on this server."
command -v certbot >/dev/null || { info "Installing certbot..."; apt-get update -qq; apt-get install -y -qq certbot; }
command -v git >/dev/null || { apt-get update -qq; apt-get install -y -qq git; }

# --- 1. DNS must already point at this server, or the certificate request fails
SERVER_IP="$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]' || true)"
DNS_IP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)"
if [[ -z "$DNS_IP" ]]; then
  fail "$DOMAIN has no DNS record yet. Add an A record: token -> ${SERVER_IP:-your server IP}, wait a few minutes, then rerun."
fi
if [[ -n "$SERVER_IP" && "$DNS_IP" != "$SERVER_IP" ]]; then
  fail "$DOMAIN points to $DNS_IP but this server is $SERVER_IP. Fix the A record (and if it's in Cloudflare, set it to 'DNS only' / grey cloud), then rerun."
fi
ok "DNS: $DOMAIN -> $DNS_IP"

# --- 2. Site files
if [[ -d "$WEBROOT/.git" ]]; then
  info "Updating site files in $WEBROOT"
  git -C "$WEBROOT" fetch --quiet origin "$BRANCH"
  git -C "$WEBROOT" reset --hard --quiet "origin/$BRANCH"
else
  info "Cloning $REPO_URL into $WEBROOT"
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$WEBROOT"
fi
chmod -R a+rX "$WEBROOT"
ok "Site files at $(git -C "$WEBROOT" log --oneline -1)"

# --- 3. nginx site
mkdir -p "$ACME_ROOT"
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

site_body() {
cat <<EOF
    root $WEBROOT;
    index index.html;
    charset utf-8;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml text/plain;

    # Never serve git data or the deploy scripts
    location ~ /\.(?!well-known) { deny all; }
    location ~* \.(sh|md)\$ { deny all; }

    location ~* \.(jpg|jpeg|png|webp|gif|svg|ico|mp4|pdf|woff2?)\$ {
        expires 7d;
        access_log off;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
EOF
}

write_http_only() {
cat > "$SITE_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; default_type text/plain; }
$(site_body)
}
EOF
}

write_https() {
cat > "$SITE_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; default_type text/plain; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

$(site_body)
}
EOF
}

reload_nginx() {
  nginx -t -q || fail "nginx config test failed; nothing was reloaded. Check: sudo nginx -t"
  systemctl reload nginx
}

if [[ ! -f "$CERT_DIR/fullchain.pem" ]]; then
  info "Serving $DOMAIN over HTTP so Let's Encrypt can verify it"
  write_http_only
  ln -sf "$SITE_CONF" /etc/nginx/sites-enabled/token-memebull
  reload_nginx

  info "Requesting HTTPS certificate for $DOMAIN"
  EMAIL_ARGS=(--register-unsafely-without-email)
  if [[ ! -d /etc/letsencrypt/accounts ]]; then
    read -r -p "Email for certificate expiry notices (blank to skip): " CERT_EMAIL || true
    [[ -n "${CERT_EMAIL:-}" ]] && EMAIL_ARGS=(-m "$CERT_EMAIL")
  else
    EMAIL_ARGS=()
  fi
  certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" \
    --non-interactive --agree-tos "${EMAIL_ARGS[@]}" \
    --deploy-hook "systemctl reload nginx" \
    || fail "Certificate request failed. $DOMAIN stays on HTTP until this succeeds; rerun the script after fixing the error above."
fi

write_https
ln -sf "$SITE_CONF" /etc/nginx/sites-enabled/token-memebull
reload_nginx
ok "Live: https://$DOMAIN"
