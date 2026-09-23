#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SITE_ROOT="${SITE_ROOT:-/var/www/mysite}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/mysite}"
NGINX_INCLUDE="/etc/nginx/snippets/mastertents-routes.conf"
NGINX_REDIRECT="${NGINX_REDIRECT:-/etc/nginx/conf.d/mastertentsandshades-redirect.conf}"
APEX_HOST="mastertentsandshades.com"
CANONICAL_HOST="www.mastertentsandshades.com"
BRANCH="${DEPLOY_BRANCH:-main}"

log() {
    printf '\n[deploy] %s\n' "$1"
}

fail() {
    printf '\n[deploy] ERROR: %s\n' "$1" >&2
    exit 1
}

[ "$(id -u)" -ne 0 ] || fail "Run this script as the normal deploy user, not root. It uses sudo when required."
command -v git >/dev/null || fail "git is not installed."
command -v rsync >/dev/null || fail "rsync is not installed."
command -v nginx >/dev/null || fail "nginx is not installed."
[ -d "$REPO_DIR/.git" ] || fail "$REPO_DIR is not a Git repository."
[ -f "$REPO_DIR/generate-nginx-routes.sh" ] || fail "generate-nginx-routes.sh is missing."

log "Pulling the latest $BRANCH branch"
git -C "$REPO_DIR" pull --ff-only origin "$BRANCH"

if [ ! -f "$NGINX_SITE" ]; then
    log "Finding the active Nginx site configuration"
    NGINX_SITE="$(sudo nginx -T 2>/dev/null | awk '
        /^# configuration file / {
            file = $0
            sub(/^# configuration file /, "", file)
            sub(/:$/, "", file)
        }
        /server_name[[:space:]]+(www\.)?mastertentsandshades\.com/ && file != "" {
            print file
            exit
        }
    ')"
fi

[ -n "$NGINX_SITE" ] && [ -f "$NGINX_SITE" ] || fail "Nginx site configuration not found. Set NGINX_SITE to its path and run again."
backup="${NGINX_SITE}.backup.$(date +%Y%m%d%H%M%S)"
sudo cp -a "$NGINX_SITE" "$backup"
tmp="$(mktemp)"
awk -v apex_host="$APEX_HOST" -v canonical_host="$CANONICAL_HOST" '
    /^[[:space:]]*server_name[[:space:]]/ {
        line = $0
        sub(/^[[:space:]]*/, "", line)
        if (line == "server_name " apex_host ";" ||
            line == "server_name " apex_host " " canonical_host ";" ||
            line == "server_name " canonical_host " " apex_host ";") {
            match($0, /^[[:space:]]*/)
            print substr($0, 1, RLENGTH) "server_name " canonical_host ";"
            next
        }
    }
    { print }
' "$NGINX_SITE" > "$tmp" || {
    rm -f "$tmp"
    fail "Could not update the Nginx content hostname. Nginx config was not changed."
}
sudo install -m 0644 "$tmp" "$NGINX_SITE"
rm -f "$tmp"

SSL_CERTIFICATE="$(sudo awk '/^[[:space:]]*ssl_certificate[[:space:]]/ && $0 !~ /ssl_certificate_key/ { print; exit }' "$NGINX_SITE")"
SSL_CERTIFICATE_KEY="$(sudo awk '/^[[:space:]]*ssl_certificate_key[[:space:]]/ { print; exit }' "$NGINX_SITE")"
[ -n "$SSL_CERTIFICATE" ] && [ -n "$SSL_CERTIFICATE_KEY" ] || fail "Could not find SSL certificate directives in $NGINX_SITE."

log "Generating non-www redirects"
sudo mkdir -p "$(dirname "$NGINX_REDIRECT")"
sudo tee "$NGINX_REDIRECT" >/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $APEX_HOST;

    return 301 https://$CANONICAL_HOST\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $APEX_HOST;

    $SSL_CERTIFICATE
    $SSL_CERTIFICATE_KEY

    return 301 https://$CANONICAL_HOST\$request_uri;
}
EOF

log "Publishing website files to $SITE_ROOT"
sudo mkdir -p "$SITE_ROOT" /etc/nginx/snippets
sudo rsync -a --delete \
    --exclude='.git/' \
    --exclude='dev_server.py' \
    "$REPO_DIR/" "$SITE_ROOT/"

log "Generating clean URL routes"
sudo bash "$SITE_ROOT/generate-nginx-routes.sh" "$SITE_ROOT" \
    | sudo tee "$NGINX_INCLUDE" >/dev/null

log "Ensuring the route include is present in the HTTPS server block"
INCLUDE_LINE="include $NGINX_INCLUDE;"
if ! sudo grep -Fq "$INCLUDE_LINE" "$NGINX_SITE"; then
    backup="${NGINX_SITE}.backup.$(date +%Y%m%d%H%M%S)"
    sudo cp -a "$NGINX_SITE" "$backup"
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT

    awk -v include_line="$INCLUDE_LINE" '
        /root[[:space:]]+\/var\/www\/mysite;/ && !added {
            print "    " include_line
            added = 1
        }
        { print }
        END {
            if (!added) exit 42
        }
    ' "$NGINX_SITE" > "$tmp" || {
        rm -f "$tmp"
        fail "Could not find root /var/www/mysite; in the Nginx config. Nginx config was not changed."
    }

    sudo install -m 0644 "$tmp" "$NGINX_SITE"
    rm -f "$tmp"
    trap - EXIT
    log "Added $INCLUDE_LINE"
else
    log "Nginx route include already present"
fi

if ! sudo grep -Fq "$INCLUDE_LINE" "$NGINX_SITE"; then
    fail "The Nginx route include is not present after installation."
fi

log "Validating Nginx configuration"
sudo nginx -t

log "Reloading Nginx"
sudo systemctl reload nginx

log "Deployment completed successfully"
printf 'Test redirect: curl -I https://%s/about/\n' "$APEX_HOST"
printf 'Test canonical: curl -I https://%s/about/\n' "$CANONICAL_HOST"
