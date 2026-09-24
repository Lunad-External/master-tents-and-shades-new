#!/usr/bin/env bash
set -eu

site_root=${1:?Usage: generate-nginx-routes.sh /var/www/mysite}

components='Header.dc.html Footer.dc.html BlogPost.dc.html InfoPage.dc.html ProductPage.dc.html'

cat <<'EOF'
location ~ ^/[a-z0-9-]+/(support\.js|img/.*|assets/.*|(Header|Footer|BlogPost|InfoPage|ProductPage)\.dc\.html)$ {
  rewrite ^/[^/]+/(.*)$ /$1 last;
}

EOF

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
    try_files "/${filename}" =404;
}

EOF
done
