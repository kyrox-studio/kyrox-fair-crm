#!/usr/bin/env bash
# Static asset performance for the Fair CRM nginx site. Adds only what is missing.
# - gzip for JS/CSS/JSON/SVG/3D models: /etc/nginx/conf.d/kyrox-gzip.conf (all sites)
# - cache: /assets/ one year (hashed names), index.html no-cache,
#   /models/ and /textures/ revalidated with ETag
# Rules live in nginx_performance.py. A failed nginx -t restores the previous files.
# Reload is left to the caller.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE="${NGINX_FAIR_CRM_SITE:-/etc/nginx/sites-available/fair-crm}"
NGINX_CONF="${NGINX_MAIN_CONF:-/etc/nginx/nginx.conf}"
GZIP_CONF="${NGINX_GZIP_CONF:-/etc/nginx/conf.d/kyrox-gzip.conf}"

[[ -f "$SITE" ]] || exit 0

SITE_BACKUP="$(mktemp)"
GZIP_BACKUP="$(mktemp)"
cp "$SITE" "$SITE_BACKUP"
HAD_GZIP=0
if [[ -f "$GZIP_CONF" ]]; then
  cp "$GZIP_CONF" "$GZIP_BACKUP"
  HAD_GZIP=1
fi

restore() {
  cp "$SITE_BACKUP" "$SITE"
  if [[ "$HAD_GZIP" == "1" ]]; then
    cp "$GZIP_BACKUP" "$GZIP_CONF"
  else
    rm -f "$GZIP_CONF"
  fi
}

if ! python3 "${SCRIPT_DIR}/nginx_performance.py" \
  --site "$SITE" --nginx-conf "$NGINX_CONF" --gzip-conf "$GZIP_CONF"; then
  restore
  echo "nginx performance patch failed; previous files restored" >&2
fi

if command -v nginx >/dev/null 2>&1; then
  if ! nginx -t >/dev/null 2>&1; then
    restore
    echo "nginx performance patch failed nginx -t; previous files restored" >&2
  fi
fi
rm -f "$SITE_BACKUP" "$GZIP_BACKUP"
