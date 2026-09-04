#!/usr/bin/env bash
# ============================================================================
#  Meme Bull — AWS Lightsail (Ubuntu) installer
#  Sets up nginx to serve the static site (landing page + PDF viewer +
#  whitepaper/roadmap PDFs), tuned for sitting behind Cloudflare.
#
#  Usage:
#    sudo ./installer.sh
#
#  This script is interactive — it will ask for everything it needs.
#  Re-running it is safe; it will overwrite its own config files but will
#  ask before touching your site files.
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Pretty output helpers
# ---------------------------------------------------------------------------
C_RESET="\e[0m"; C_BOLD="\e[1m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"; C_RED="\e[31m"; C_BLUE="\e[36m"
info()  { echo -e "${C_BLUE}${C_BOLD}==>${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}✓${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}!${C_RESET} $*"; }
fail()  { echo -e "${C_RED}✗ $*${C_RESET}"; exit 1; }

ask() { # ask "Question" "default"  -> echoes the answer
  local q="$1" def="${2:-}" ans
  if [[ -n "$def" ]]; then
    read -r -p "$(echo -e "${C_BOLD}?${C_RESET} ${q} [${def}]: ")" ans || true
    echo "${ans:-$def}"
  else
    read -r -p "$(echo -e "${C_BOLD}?${C_RESET} ${q}: ")" ans || true
    echo "$ans"
  fi
}

ask_yn() { # ask_yn "Question" "y|n" -> returns 0 for yes, 1 for no
  local q="$1" def="${2:-y}" ans
  while true; do
    read -r -p "$(echo -e "${C_BOLD}?${C_RESET} ${q} [$( [[ $def == y ]] && echo Y/n || echo y/N )]: ")" ans || true
    ans="${ans:-$def}"
    case "$ans" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Must be root
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  fail "Please run this with sudo: sudo ./installer.sh"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo -e "${C_BOLD}Meme Bull — Lightsail site installer${C_RESET}"
echo "This will install nginx, deploy your site files, and configure it to"
echo "run cleanly behind Cloudflare (you said Cloudflare is handling SSL/DNS)."
echo ""

# ---------------------------------------------------------------------------
# 1. Gather info
# ---------------------------------------------------------------------------
DOMAIN="$(ask "Your domain (e.g. memebull.com, no https://)" "")"
[[ -n "$DOMAIN" ]] || fail "A domain is required."

if ask_yn "Also serve www.${DOMAIN}?" "y"; then
  SERVER_NAMES="${DOMAIN} www.${DOMAIN}"
else
  SERVER_NAMES="${DOMAIN}"
fi

DEFAULT_SRC="$SCRIPT_DIR"
echo ""
info "How should I get your website files onto this server?"
echo "   1) Clone them from a GitHub repo (recommended)"
echo "   2) Use a folder that's already on this server"
SRC_MODE="$(ask "Choice (1/2)" "1")"

CLONE_DIR=""
if [[ "$SRC_MODE" == "1" ]]; then
  REPO_URL="$(ask "GitHub repo URL (e.g. https://github.com/youruser/yourrepo.git)" "")"
  [[ -n "$REPO_URL" ]] || fail "A repo URL is required."
  BRANCH="$(ask "Branch to deploy" "main")"

  GIT_CLONE_URL="$REPO_URL"
  if ask_yn "Is this a private repo?" "n"; then
    read -r -s -p "$(echo -e "${C_BOLD}?${C_RESET} GitHub Personal Access Token (input hidden): ")" GH_TOKEN
    echo ""
    [[ -n "$GH_TOKEN" ]] || fail "A token is required for a private repo."
    # Embed the token only in the URL used for this clone/pull — never printed or logged,
    # and the origin remote is reset back to the plain URL right after.
    GIT_CLONE_URL="$(echo "$REPO_URL" | sed -E "s#https://#https://${GH_TOKEN}@#")"
  fi

  REPO_NAME="$(basename "$REPO_URL" .git)"
  CLONE_DIR="$(ask "Local folder to clone into" "/opt/${REPO_NAME}")"

  # git is needed for this path specifically
  command -v git >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1 || true; apt-get install -y git; }

  if [[ -d "$CLONE_DIR/.git" ]]; then
    info "That folder already looks like a git checkout."
    if ask_yn "Pull the latest changes instead of re-cloning?" "y"; then
      git -C "$CLONE_DIR" remote set-url origin "$GIT_CLONE_URL"
      git -C "$CLONE_DIR" fetch --all --quiet
      git -C "$CLONE_DIR" checkout "$BRANCH" --quiet
      git -C "$CLONE_DIR" pull --quiet origin "$BRANCH"
      git -C "$CLONE_DIR" remote set-url origin "$REPO_URL"
      ok "Repo updated to the latest $BRANCH."
    else
      ask_yn "Delete it and re-clone fresh?" "n" || fail "Pick a different folder and re-run."
      rm -rf "$CLONE_DIR"
      git clone --branch "$BRANCH" --single-branch "$GIT_CLONE_URL" "$CLONE_DIR" --quiet
      git -C "$CLONE_DIR" remote set-url origin "$REPO_URL"
      ok "Repo cloned."
    fi
  elif [[ -d "$CLONE_DIR" ]]; then
    fail "$CLONE_DIR exists and isn't a git checkout — pick another path."
  else
    info "Cloning ${REPO_URL} (branch: ${BRANCH})..."
    git clone --branch "$BRANCH" --single-branch "$GIT_CLONE_URL" "$CLONE_DIR" --quiet
    git -C "$CLONE_DIR" remote set-url origin "$REPO_URL"
    ok "Repo cloned to $CLONE_DIR."
  fi
  unset GH_TOKEN GIT_CLONE_URL

  SUBDIR="$(ask "Subfolder inside the repo containing the site files (blank = repo root)" "")"
  if [[ -n "$SUBDIR" ]]; then
    SRC_DIR="${CLONE_DIR}/${SUBDIR}"
  else
    SRC_DIR="$CLONE_DIR"
  fi
else
  SRC_DIR="$(ask "Folder containing your site files (index/viewer/pdfs/images)" "$DEFAULT_SRC")"
fi
[[ -d "$SRC_DIR" ]] || fail "That folder doesn't exist: $SRC_DIR"

# Figure out the homepage file
HOMEPAGE=""
if [[ -f "$SRC_DIR/index.html" ]]; then
  HOMEPAGE="index.html"
elif [[ -f "$SRC_DIR/memebull-landing-page.html" ]]; then
  HOMEPAGE="memebull-landing-page.html"
  warn "Found memebull-landing-page.html but no index.html — it will be copied to index.html too."
else
  HOMEPAGE="$(ask "Filename of your main landing page inside $SRC_DIR" "memebull-landing-page.html")"
  [[ -f "$SRC_DIR/$HOMEPAGE" ]] || fail "Couldn't find $SRC_DIR/$HOMEPAGE"
fi

WEBROOT="/var/www/${DOMAIN}"

echo ""
info "Cloudflare SSL mode — pick what matches your Cloudflare SSL/TLS setting:"
echo "   1) Flexible     — origin serves plain HTTP only, Cloudflare does HTTPS to visitors"
echo "   2) Full         — origin serves HTTPS with a self-signed cert (script generates it)"
echo "   3) Full (strict)— origin serves HTTPS with a real Cloudflare Origin Certificate"
echo "                      (recommended — free, valid 15 years, issued from your CF dashboard)"
SSL_MODE="$(ask "Choice (1/2/3)" "3")"

PASTED_CERT=""
PASTED_KEY=""
if [[ "$SSL_MODE" == "3" ]]; then
  echo ""
  info "Paste your Cloudflare Origin Certificate (from CF dashboard → SSL/TLS → Origin Server →"
  echo "  Create Certificate). Paste the full '-----BEGIN CERTIFICATE-----' block, then a line"
  echo "  with just: END"
  while IFS= read -r line; do
    [[ "$line" == "END" ]] && break
    PASTED_CERT+="${line}"$'\n'
  done
  echo ""
  info "Now paste the matching Private Key, then a line with just: END"
  while IFS= read -r line; do
    [[ "$line" == "END" ]] && break
    PASTED_KEY+="${line}"$'\n'
  done
  [[ -n "$PASTED_CERT" && -n "$PASTED_KEY" ]] || fail "Certificate or key came through empty — re-run and paste both blocks fully."
  ok "Got the certificate and key — will install them during setup."
fi

RESTRICT_TO_CF="$(ask_yn "Restrict ports 80/443 so only Cloudflare's IPs can reach this server? (recommended)" "y" && echo y || echo n)"
SETUP_UFW="$(ask_yn "Enable and configure the UFW firewall on this server?" "y" && echo y || echo n)"
SETUP_FAIL2BAN="$(ask_yn "Install fail2ban to protect SSH from brute-force attempts?" "y" && echo y || echo n)"
SETUP_UNATTENDED="$(ask_yn "Enable unattended automatic security updates?" "y" && echo y || echo n)"
SETUP_SWAP="$(ask_yn "Add a swap file? (recommended on small Lightsail instances, e.g. 512MB-1GB RAM)" "y" && echo y || echo n)"
if [[ "$SETUP_SWAP" == "y" ]]; then
  SWAP_SIZE="$(ask "Swap size" "1G")"
fi

echo ""
ok "Got everything I need. Starting install — this takes a few minutes."
echo ""

# ---------------------------------------------------------------------------
# 2. Base packages
# ---------------------------------------------------------------------------
info "Updating package lists and installing base packages (nginx, curl, rsync, openssl)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || warn "apt-get update reported errors from one or more repos — continuing, since the packages we need may still be available."
apt-get install -y nginx curl rsync openssl ca-certificates git
ok "Base packages installed."

# ---------------------------------------------------------------------------
# 3. Swap file
# ---------------------------------------------------------------------------
if [[ "$SETUP_SWAP" == "y" ]]; then
  if swapon --show | grep -q '/swapfile'; then
    ok "Swap file already exists, skipping."
  else
    info "Creating a ${SWAP_SIZE} swap file..."
    fallocate -l "$SWAP_SIZE" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    ok "Swap file ready."
  fi
fi

# ---------------------------------------------------------------------------
# 4. Deploy site files
# ---------------------------------------------------------------------------
info "Deploying site files to ${WEBROOT}..."
mkdir -p "$WEBROOT"
if [[ -n "$(ls -A "$WEBROOT" 2>/dev/null || true)" ]]; then
  warn "$WEBROOT already has files in it."
  if ! ask_yn "Overwrite/update with the files from $SRC_DIR?" "y"; then
    fail "Aborted — nothing was changed in $WEBROOT."
  fi
fi
rsync -a \
  --exclude 'installer.sh' \
  --exclude '.git' \
  --exclude '.github' \
  --exclude '.gitignore' \
  --exclude 'README.md' \
  --exclude 'LICENSE' \
  "$SRC_DIR"/ "$WEBROOT"/
if [[ "$HOMEPAGE" != "index.html" ]]; then
  cp "$WEBROOT/$HOMEPAGE" "$WEBROOT/index.html"
fi
chown -R www-data:www-data "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} \;
find "$WEBROOT" -type f -exec chmod 644 {} \;
ok "Site files deployed to $WEBROOT (homepage: index.html)."

# ---------------------------------------------------------------------------
# 5. Cloudflare IP ranges (for real-IP + optional firewall lockdown)
# ---------------------------------------------------------------------------
info "Fetching current Cloudflare IP ranges..."
CF_CONF="/etc/nginx/cloudflare-ips.conf"

# Fallback list used only if the live fetch below fails (e.g. no internet access
# at install time). Cloudflare's ranges rarely change, but if this script is more
# than a year or two old when you run it, double check https://www.cloudflare.com/ips/
FALLBACK_CF_V4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
FALLBACK_CF_V6="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"

CF_V4="$(curl -fsSL https://www.cloudflare.com/ips-v4 || true)"
CF_V6="$(curl -fsSL https://www.cloudflare.com/ips-v6 || true)"

if [[ -z "$CF_V4" ]]; then
  warn "Couldn't fetch live Cloudflare IPv4 ranges (no internet access from this shell right now?) — using a built-in fallback list."
  CF_V4="$FALLBACK_CF_V4"
fi
if [[ -z "$CF_V6" ]]; then
  warn "Couldn't fetch live Cloudflare IPv6 ranges — using a built-in fallback list."
  CF_V6="$FALLBACK_CF_V6"
fi

{
  echo "# Auto-generated by Meme Bull installer — Cloudflare IP ranges"
  for ip in $CF_V4; do echo "set_real_ip_from ${ip};"; done
  for ip in $CF_V6; do echo "set_real_ip_from ${ip};"; done
  echo "real_ip_header CF-Connecting-IP;"
} > "$CF_CONF"
ok "Cloudflare IP ranges saved to $CF_CONF."

# ---------------------------------------------------------------------------
# 6. SSL setup
# ---------------------------------------------------------------------------
SSL_CERT=""
SSL_KEY=""
ENABLE_443="n"

if [[ "$SSL_MODE" == "2" ]]; then
  ENABLE_443="y"
  info "Generating a self-signed certificate for Cloudflare 'Full' mode..."
  mkdir -p /etc/ssl/memebull
  openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
    -keyout /etc/ssl/memebull/origin.key \
    -out /etc/ssl/memebull/origin.pem \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  SSL_CERT="/etc/ssl/memebull/origin.pem"
  SSL_KEY="/etc/ssl/memebull/origin.key"
  ok "Self-signed certificate created."

elif [[ "$SSL_MODE" == "3" ]]; then
  ENABLE_443="y"
  info "Installing the Cloudflare Origin Certificate you pasted earlier..."
  mkdir -p /etc/ssl/memebull
  printf '%s' "$PASTED_CERT" > /etc/ssl/memebull/origin.pem
  printf '%s' "$PASTED_KEY" > /etc/ssl/memebull/origin.key
  chmod 600 /etc/ssl/memebull/origin.key
  SSL_CERT="/etc/ssl/memebull/origin.pem"
  SSL_KEY="/etc/ssl/memebull/origin.key"
  ok "Cloudflare Origin Certificate installed."
else
  info "Flexible mode selected — origin will serve plain HTTP only (Cloudflare handles HTTPS to visitors)."
fi

# ---------------------------------------------------------------------------
# 7. nginx server block
# ---------------------------------------------------------------------------
info "Writing nginx config..."
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}.conf"

IPV6_LISTEN80=""
IPV6_LISTEN443=""
if [[ -f /proc/net/if_inet6 ]]; then
  IPV6_LISTEN80="    listen [::]:80;"
  IPV6_LISTEN443="    listen [::]:443 ssl;"
else
  warn "No IPv6 support detected on this host — nginx will listen on IPv4 only."
fi

{
cat <<NGINXEOF
# Meme Bull — ${DOMAIN}
# Generated by installer.sh — safe to hand-edit, re-running the installer
# will overwrite this file though.

server {
    listen 80;
${IPV6_LISTEN80}
    server_name ${SERVER_NAMES};

    include ${CF_CONF};

    root ${WEBROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~* \.pdf\$ {
        add_header Content-Disposition "inline";
        add_header Cache-Control "public, max-age=86400";
    }

    location ~* \.(jpg|jpeg|png|gif|svg|ico|webp)\$ {
        add_header Cache-Control "public, max-age=604800";
    }

    location ~* \.(css|js)\$ {
        add_header Cache-Control "public, max-age=86400";
    }

    gzip on;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1024;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log  /var/log/nginx/${DOMAIN}.error.log;
}
NGINXEOF

if [[ "$ENABLE_443" == "y" ]]; then
cat <<NGINXEOF

server {
    listen 443 ssl;
${IPV6_LISTEN443}
    server_name ${SERVER_NAMES};

    include ${CF_CONF};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;

    root ${WEBROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~* \.pdf\$ {
        add_header Content-Disposition "inline";
        add_header Cache-Control "public, max-age=86400";
    }

    location ~* \.(jpg|jpeg|png|gif|svg|ico|webp)\$ {
        add_header Cache-Control "public, max-age=604800";
    }

    location ~* \.(css|js)\$ {
        add_header Cache-Control "public, max-age=86400";
    }

    gzip on;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1024;

    access_log /var/log/nginx/${DOMAIN}.ssl.access.log;
    error_log  /var/log/nginx/${DOMAIN}.ssl.error.log;
}
NGINXEOF
fi
} > "$NGINX_CONF"

ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
rm -f /etc/nginx/sites-enabled/default

nginx -t || fail "nginx config test failed — check $NGINX_CONF"
systemctl enable nginx >/dev/null 2>&1
systemctl reload nginx || systemctl restart nginx
ok "nginx configured and running."

# ---------------------------------------------------------------------------
# 8. UFW firewall
# ---------------------------------------------------------------------------
if [[ "$SETUP_UFW" == "y" ]]; then
  info "Configuring UFW..."
  apt-get install -y ufw
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp
  if [[ "$RESTRICT_TO_CF" == "y" ]]; then
    info "Restricting 80/443 to Cloudflare IP ranges only..."
    for ip in $(curl -fsSL https://www.cloudflare.com/ips-v4); do
      ufw allow from "$ip" to any port 80 proto tcp >/dev/null 2>&1
      ufw allow from "$ip" to any port 443 proto tcp >/dev/null 2>&1
    done
    for ip in $(curl -fsSL https://www.cloudflare.com/ips-v6); do
      ufw allow from "$ip" to any port 80 proto tcp >/dev/null 2>&1
      ufw allow from "$ip" to any port 443 proto tcp >/dev/null 2>&1
    done
  else
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
  fi
  ufw --force enable
  ok "UFW enabled. (Remember: Lightsail also has its own network firewall — see the reminder below.)"
fi

# ---------------------------------------------------------------------------
# 9. fail2ban
# ---------------------------------------------------------------------------
if [[ "$SETUP_FAIL2BAN" == "y" ]]; then
  info "Installing fail2ban..."
  apt-get install -y fail2ban
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
  ok "fail2ban active (default sshd jail)."
fi

# ---------------------------------------------------------------------------
# 10. Unattended upgrades
# ---------------------------------------------------------------------------
if [[ "$SETUP_UNATTENDED" == "y" ]]; then
  info "Enabling unattended security upgrades..."
  apt-get install -y unattended-upgrades
  dpkg-reconfigure -f noninteractive unattended-upgrades
  ok "Automatic security updates enabled."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
IP_ADDR="$(curl -fsSL https://checkip.amazonaws.com || hostname -I | awk '{print $1}')"

echo ""
echo -e "${C_GREEN}${C_BOLD}All done.${C_RESET}"
echo ""
echo "Site deployed to: ${WEBROOT}"
echo "This server's public IP: ${IP_ADDR}"
echo ""
echo -e "${C_BOLD}Still to do, in Cloudflare and Lightsail dashboards:${C_RESET}"
echo " 1) Lightsail → Networking tab → open ports 80 and 443 (TCP) if not already open."
echo " 2) Cloudflare → DNS → A record for ${DOMAIN} (and www) → ${IP_ADDR} → proxy ON (orange cloud)."
case "$SSL_MODE" in
  1) echo " 3) Cloudflare → SSL/TLS → set mode to: Flexible" ;;
  2) echo " 3) Cloudflare → SSL/TLS → set mode to: Full" ;;
  3) echo " 3) Cloudflare → SSL/TLS → set mode to: Full (strict)" ;;
esac
echo " 4) Cloudflare → SSL/TLS → Edge Certificates → turn on 'Always Use HTTPS'."
echo " 5) Test: http://${DOMAIN} and https://${DOMAIN} once DNS has propagated."
echo ""
echo "Re-run this script any time to redeploy updated site files or change settings."
