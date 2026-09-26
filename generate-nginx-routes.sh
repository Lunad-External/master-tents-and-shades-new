#!/usr/bin/env bash
set -eu

site_root=${1:?Usage: generate-nginx-routes.sh /var/www/mysite}

components='Header.dc.html Footer.dc.html BlogPost.dc.html InfoPage.dc.html ProductPage.dc.html'

# Known crawler/bot user agents. These get served the pre-rendered static
# snapshot at /prerendered/<slug>.html instead of the live .dc.html, so they
# see full content without executing JS. Real visitors never match this and
# always get the normal client-rendered page — unchanged from today.
bot_ua_pattern='googlebot|bingbot|yandex|duckduckbot|baiduspider|facebookexternalhit|twitterbot|linkedinbot|slackbot|discordbot|whatsapp|telegrambot|applebot|semrushbot|ahrefsbot|mj12bot|rogerbot|screaming frog|embedly|quora link preview|pinterestbot|redditbot|w3c_validator'

cat <<'EOF'
location ~ ^/[a-z0-9-]+/(support\.js|img/.*|assets/.*|(Header|Footer|BlogPost|InfoPage|ProductPage)\.dc\.html)$ {
  rewrite ^/[^/]+/(.*)$ /$1 last;
}

EOF

if [ -f "$site_root/index.html" ]; then
  cat <<EOF
location = / {
    set \$dc_file "/index.html";
    if (\$http_user_agent ~* "${bot_ua_pattern}") {
        set \$dc_file "/prerendered/home.html";
    }
    try_files \$dc_file "/index.html" =404;
}

EOF
fi

find "$site_root" -maxdepth 1 -type f -name '*.dc.html' -printf '%f\n' | sort | while IFS= read -r filename; do
  case " $components " in
    *" $filename "*) continue ;;
  esac

  name=${filename%.dc.html}
  slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')

  cat <<EOF
location = "/${filename}" {
    return 301 /${slug}/;
}

location = /${slug}/ {
    set \$dc_file "/${filename}";
    if (\$http_user_agent ~* "${bot_ua_pattern}") {
        set \$dc_file "/prerendered/${slug}.html";
    }
    try_files \$dc_file "/${filename}" =404;
}

EOF
done
