#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SITE_ROOT="${SITE_ROOT:-/var/www/mysite}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/mysite}"
NGINX_INCLUDE="/etc/nginx/snippets/mastertents-routes.conf"
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
[ -f "$NGINX_SITE" ] || fail "Nginx site configuration not found: $NGINX_SITE"

log "Pulling the latest $BRANCH branch"
git -C "$REPO_DIR" pull --ff-only origin "$BRANCH"

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
printf 'Test: curl -I https://mastertentsandshades.com/about/\n'
