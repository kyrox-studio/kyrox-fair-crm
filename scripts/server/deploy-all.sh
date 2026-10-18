#!/usr/bin/env bash
#
# Application deploy/update for KYROX Core + Fair Stand API + Fair CRM.
# One command brings up all three processes (core :8000, stand :8002, crm :8001).
# Fair Stand source is also pulled so CRM Vite can compile the configurator mount.
# Stand-only API refresh remains /opt/kyrox/kyrox-fair-stand/scripts/server/deploy.sh.
# Run after bootstrap-server.sh on fresh servers, or alone for updates.
#
# Safe deploy contract (backup/restore compatible):
#   - Git pull + dependency install + Playwright Chromium + frontend build + systemd/nginx reload
#   - nginx: missing gzip and static cache rules are added (apply-nginx-performance.sh); existing lines stay
#   - Alembic upgrade head on kyrox_core, fair_stand, and fair_crm (required after restore; non-destructive schema)
#   - Fair Stand catalog rows stay as stored. Deploy does not delete or reseed them.
#   - Backend restart via systemd (normal)
#   - ensure_database only CREATE DATABASE when missing (no drop/truncate/reset)
#   - Never runs pg_restore, restore jobs, or backup deletion
#   - Never touches backups/, data/restore_uploads/, or data/restore_logs/
#   - Never overwrites backend/.env or other .env files (copy-if-missing only)
#   - Preserves server .env keys such as ALLOW_RESTORE and TARGET_DATABASE_URL
#   - Does not clear system_backup_restore_jobs or other CRM data tables
#   - Does not run Fair Stand catalog reseed. That script deletes catalog rows.
#
# Usage (on server) — this is the normal update path:
#   sudo bash /opt/kyrox/kyrox-fair-crm/scripts/server/deploy-all.sh
#
# Domain/SSL one-time (or domain change) is separate:
#   sudo bash /opt/kyrox/kyrox-fair-crm/scripts/server/setup-domain-ssl.sh --domain fuar.kyrox.studio --email admin@fuar.kyrox.studio
#
# Optional environment overrides:
#   KYROX_CORE_DIR=/opt/kyrox/kyrox-core
#   FAIR_CRM_DIR=/opt/kyrox/kyrox-fair-crm
#   FAIR_STAND_DIR=/opt/kyrox/kyrox-fair-stand
#   KYROX_CORE_BRANCH=   boşsa origin varsayılan dalı
#   FAIR_CRM_BRANCH=     boşsa origin varsayılan dalı
#   FAIR_STAND_BRANCH=   boşsa origin varsayılan dalı
#   KYROX_CORE_REPO=https://github.com/kyrox-studio/kyrox-core.git
#   FAIR_STAND_REPO=https://github.com/kyrox-studio/kyrox-fair-stand.git
#   DEPLOY_SERVICE_USER=ubuntu
#   SKIP_FRONTEND_BUILD=1
#   SKIP_NODE=1
#   SKIP_CORE_DEV_SEED=1
#   SKIP_SYSTEMD=1
#   SKIP_NGINX_RELOAD=1
#   RUN_POST_CHECK=1
#   DEV_SEED_ENV_FILE=/etc/fair-crm/dev-seed.env
#   REQUIRED_NODEJS_VERSION=22.12.0
#
# Dev seed password:
#   Required file (no hardcoded default): /etc/fair-crm/dev-seed.env
#   Contents: DEV_USER_PASSWORD=<value>
#   Permissions: root:root, chmod 600
#   Password is never printed in deploy logs or the acceptance report.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KYROX_CORE_DIR="${KYROX_CORE_DIR:-${KYROX_ROOT}/kyrox-core}"
FAIR_CRM_DIR="${FAIR_CRM_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
FAIR_STAND_DIR="${FAIR_STAND_DIR:-${KYROX_ROOT}/kyrox-fair-stand}"
KYROX_CORE_REPO="${KYROX_CORE_REPO:-https://github.com/kyrox-studio/kyrox-core.git}"
FAIR_STAND_REPO="${FAIR_STAND_REPO:-https://github.com/kyrox-studio/kyrox-fair-stand.git}"
DEPLOY_SERVICE_USER="${DEPLOY_SERVICE_USER:-${SUDO_USER:-$(id -un)}}"

CORE_PORT="${CORE_PORT:-8000}"
FAIR_CRM_PORT="${FAIR_CRM_PORT:-8001}"
STAND_PORT="${STAND_PORT:-8002}"
CORE_HEALTH_PATH="${CORE_HEALTH_PATH:-/api/v1/health}"
FAIR_CRM_HEALTH_PATH="${FAIR_CRM_HEALTH_PATH:-/health}"
STAND_HEALTH_PATH="${STAND_HEALTH_PATH:-/health}"

PROTECTED_FAIR_CRM_PATHS=(
  "docker-compose.yml"
  "backend/.env"
  "frontend/.env"
  "frontend/.env.production"
  "backups"
  "data/restore_uploads"
  "data/restore_logs"
)
PROTECTED_KYROX_CORE_PATHS=(
  "backend/.env"
  ".env"
)
PROTECTED_FAIR_STAND_PATHS=(
  "backend/.env"
)

REPORT_CORE_STATUS="unknown"
REPORT_FAIR_STATUS="unknown"
REPORT_FRONTEND_BUILD="skipped"
REPORT_CORE_MIGRATION="not run"
REPORT_FAIR_MIGRATION="not run"
REPORT_STAND_MIGRATION="not run"
REPORT_CORE_HEALTH="000"
REPORT_FAIR_HEALTH="000"
REPORT_STAND_HEALTH="000"
REPORT_STAND_STATUS="unknown"
REPORT_CORE_HASH="n/a"
REPORT_FAIR_HASH="n/a"
REPORT_FAIR_STAND_HASH="n/a"
REPORT_FAIR_STAND_STATUS="unknown"
REPORT_FAIR_STAND_DEPS="not run"
REPORT_FAIR_STAND_SOURCE="not run"
REPORT_FAIR_STAND_BOOTSTRAP="not run"
REPORT_FAIR_STAND_SPA="not run"
REPORT_CORE_SEED="not run"
REPORT_NGINX="skipped"
REPORT_NGINX_TEST="skipped"
REPORT_POST_CHECK="skipped"
REPORT_LOGIN_SMOKE="not run"
REPORT_BACKUPS_SMOKE="not run"
REPORT_SAFE_DEPLOY_RESTORE="not run"
REPORT_PLAYWRIGHT_CHROMIUM="not run"
REPORT_FINAL_STATUS="unknown"

clone_or_update_repo() {
  local dir="$1"
  local repo_url="$2"
  local branch="$3"
  shift 3
  local -a protected=("$@")

  if [[ ! -d "$dir" ]]; then
    step "Clone repository into ${dir}"
    mkdir -p "$(dirname "$dir")"
    git clone --branch "$branch" "$repo_url" "$dir"
    return 0
  fi

  ensure_git_ff_pull "$dir" "$branch" "${protected[@]}"
}

setup_python_project() {
  local name="$1"
  local project_dir="$2"
  local venv_dir="$3"

  step "Python dependencies for ${name}"
  local requirements
  requirements="$(resolve_requirements_file "$project_dir" || die "requirements.txt not found under ${project_dir}")"
  ensure_python_venv "$venv_dir"
  pip_install_requirements "$venv_dir" "$requirements"
}

repair_local_postgres_password_if_needed() {
  local host_normalized="${PG_HOST,,}"
  local container="${POSTGRES_DOCKER_CONTAINER:-kyrox-db}"

  if [[ "$PG_USER" != "postgres" ]]; then
    return 1
  fi
  if [[ "$host_normalized" != "localhost" && "$host_normalized" != "127.0.0.1" && "$host_normalized" != "::1" ]]; then
    return 1
  fi
  if [[ -z "${PG_PASS}" ]] || ! command -v docker >/dev/null 2>&1; then
    return 1
  fi
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container"; then
    return 1
  fi

  local escaped_password="${PG_PASS//\'/\'\'}"
  warn "PostgreSQL TCP authentication failed; attempting safe local password resync for role postgres in ${container} (password not shown)"
  if ! docker exec "$container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
      -c "ALTER USER postgres WITH PASSWORD '${escaped_password}';" >/dev/null 2>&1; then
    return 1
  fi

  log "Local PostgreSQL role password resynced from application DATABASE_URL (password not shown)"
  return 0
}

verify_postgres_connectivity() {
  step "PostgreSQL connectivity"
  if PGPASSWORD="${PG_PASS}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    return 0
  fi

  if repair_local_postgres_password_if_needed && \
     PGPASSWORD="${PG_PASS}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    log "PostgreSQL connectivity restored after local password resync"
    return 0
  fi

  die "Cannot connect to PostgreSQL at ${PG_HOST}:${PG_PORT}; verify DATABASE_URL credentials and PostgreSQL role password"
}

run_core_dev_seed() {
  step "Seed Core dev identity for Fair CRM"
  local core_env="${KYROX_CORE_DIR}/backend/.env"
  local db_url
  db_url="$(read_env_key "$core_env" DATABASE_URL || read_env_key "$core_env" KYROX_CORE_DATABASE_URL || true)"
  [[ -n "$db_url" ]] || die "Cannot resolve Core DATABASE_URL for dev seed"

  if [[ "${SKIP_CORE_DEV_SEED:-0}" == "1" ]]; then
    REPORT_CORE_SEED="skipped (SKIP_CORE_DEV_SEED=1)"
    warn "Skipping Core dev seed"
    return 0
  fi

  require_dev_seed_env_file

  local seed_script="${FAIR_CRM_DIR}/scripts/seed_core_dev_identity.py"
  [[ -f "$seed_script" ]] || die "Fair CRM Core dev seed script missing: ${seed_script}"

  (
    env DATABASE_URL="$db_url" KYROX_CORE_DATABASE_URL="$db_url" \
      DEV_USER_PASSWORD="$DEV_USER_PASSWORD" \
      PYTHONPATH="${FAIR_CRM_DIR}/scripts:${FAIR_CRM_DIR}" \
      "${KYROX_CORE_DIR}/.venv/bin/python" "$seed_script"
  ) || die "Core dev identity seed failed"
  REPORT_CORE_SEED="success (idempotent)"
  print_core_seed_identity_report
}

manage_systemd_services() {
  if [[ "${SKIP_SYSTEMD:-0}" == "1" ]]; then
    warn "SKIP_SYSTEMD=1; leaving systemd units untouched"
    return 0
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  render_template "${SCRIPT_DIR}/systemd/kyrox-core.service" "${tmp_dir}/kyrox-core.service"
  render_template "${FAIR_STAND_DIR}/scripts/server/systemd/fair-stand.service" "${tmp_dir}/fair-stand.service"
  render_template "${SCRIPT_DIR}/systemd/fair-crm-backend.service" "${tmp_dir}/fair-crm-backend.service"
  render_template "${SCRIPT_DIR}/systemd/fair-crm-mail-worker.service" "${tmp_dir}/fair-crm-mail-worker.service"

  install_systemd_unit "${tmp_dir}/kyrox-core.service" "kyrox-core.service"
  install_systemd_unit "${tmp_dir}/fair-stand.service" "fair-stand.service"
  install_systemd_unit "${tmp_dir}/fair-crm-backend.service" "fair-crm-backend.service"
  install_systemd_unit "${tmp_dir}/fair-crm-mail-worker.service" "fair-crm-mail-worker.service"
  rm -rf "$tmp_dir"

  if [[ "${EUID}" -ne 0 ]]; then
    warn "Run with sudo to reload/restart systemd services"
    return 0
  fi

  step "Reload and restart systemd services (core, stand, crm)"
  systemctl daemon-reload
  systemctl enable kyrox-core fair-stand fair-crm-backend fair-crm-mail-worker
  systemctl restart kyrox-core
  sleep 2
  systemctl restart fair-stand
  sleep 2
  systemctl restart fair-crm-backend
  systemctl restart fair-crm-mail-worker

  REPORT_CORE_STATUS="$(systemctl is-active kyrox-core 2>/dev/null || echo unknown)"
  REPORT_STAND_STATUS="$(systemctl is-active fair-stand 2>/dev/null || echo unknown)"
  REPORT_FAIR_STATUS="$(systemctl is-active fair-crm-backend 2>/dev/null || echo unknown)"
}

build_frontend() {
  if [[ "${SKIP_FRONTEND_BUILD:-0}" == "1" ]]; then
    REPORT_FRONTEND_BUILD="skipped (SKIP_FRONTEND_BUILD=1)"
    return 0
  fi

  # Node runtime must meet package engines before npm install/build.
  if [[ "${SKIP_NODE:-0}" != "1" ]]; then
    ensure_nodejs
  else
    require_cmd node
    require_cmd npm
    local current
    current="$(get_installed_node_version)"
    if [[ -z "$current" ]] || ! node_version_meets_minimum "$current" "$REQUIRED_NODEJS_VERSION"; then
      die "SKIP_NODE=1 but Node.js ${current:-missing} does not meet >= ${REQUIRED_NODEJS_VERSION}"
    fi
  fi

  step "Frontend npm install + build"
  require_fair_stand_source_for_crm_build
  REPORT_FAIR_STAND_SOURCE="PASS"
  require_cmd npm
  (
    cd "${FAIR_CRM_DIR}/frontend"
    npm install
    npm run build
  )
  REPORT_FRONTEND_BUILD="success"

  if [[ ! -d "${FAIR_CRM_DIR}/frontend/dist" ]]; then
    REPORT_FRONTEND_BUILD="failed (dist missing)"
    die "Frontend build did not produce frontend/dist"
  fi
  log "Frontend build output: ${FAIR_CRM_DIR}/frontend/dist"
}

run_health_checks() {
  step "Health checks"
  local core_url="http://127.0.0.1:${CORE_PORT}${CORE_HEALTH_PATH}"
  local fair_url="http://127.0.0.1:${FAIR_CRM_PORT}${FAIR_CRM_HEALTH_PATH}"
  local stand_url="http://127.0.0.1:${STAND_PORT}${STAND_HEALTH_PATH}"
  local statuses

  if statuses="$(wait_for_http_health "$core_url" "$fair_url" "$stand_url" 60)"; then
    read -r REPORT_CORE_HEALTH REPORT_FAIR_HEALTH REPORT_STAND_HEALTH <<<"$statuses"
  else
    read -r REPORT_CORE_HEALTH REPORT_FAIR_HEALTH REPORT_STAND_HEALTH <<<"$statuses"
  fi

  if [[ "$REPORT_CORE_HEALTH" != "200" ]]; then
    local legacy_core_health
    legacy_core_health="$(http_status "http://127.0.0.1:${CORE_PORT}/health")"
    warn "Core health ${core_url} => ${REPORT_CORE_HEALTH}; /health => ${legacy_core_health}"
    die "Core health check failed (expected 200 at ${core_url})"
  fi
  if [[ "$REPORT_STAND_HEALTH" != "200" ]]; then
    die "Fair Stand health check failed (expected 200 at ${stand_url})"
  fi
  if [[ "$REPORT_FAIR_HEALTH" != "200" ]]; then
    die "Fair CRM health check failed (expected 200 at ${fair_url})"
  fi
}

run_fair_stand_catalog_bootstrap_deploy() {
  step "Fair Stand catalog bootstrap"
  if run_fair_stand_catalog_bootstrap_smoke "$STAND_PORT" "$CORE_PORT" "deploy"; then
    REPORT_FAIR_STAND_BOOTSTRAP="PASS (Stand :${STAND_PORT})"
  else
    REPORT_FAIR_STAND_BOOTSTRAP="FAIL"
    die "Fair Stand catalog bootstrap failed against 127.0.0.1:${STAND_PORT}"
  fi
}

run_fair_stand_spa_host_check() {
  local status="000"
  local domain=""
  local bootstrap_env="${SERVER_BOOTSTRAP_ENV_FILE:-/etc/fair-crm/server-bootstrap.env}"

  if [[ -f "$bootstrap_env" ]]; then
    domain="$(read_env_key "$bootstrap_env" FAIR_CRM_DOMAIN || true)"
  fi

  # Prefer the public Host header so nginx vhost + HTTPS redirects resolve.
  if [[ -n "$domain" ]]; then
    status="$(
      curl -s -o /dev/null -w "%{http_code}" \
        -H "Host: ${domain}" \
        --connect-timeout 5 --max-time 15 \
        "http://127.0.0.1/fair-stand" 2>/dev/null || echo "000"
    )"
    if [[ "$status" == "000" || "$status" -ge 400 ]]; then
      status="$(
        curl -sk -o /dev/null -w "%{http_code}" \
          -H "Host: ${domain}" \
          --connect-timeout 5 --max-time 15 \
          "https://127.0.0.1/fair-stand" 2>/dev/null || echo "000"
      )"
    fi
  else
    status="$(http_status "http://127.0.0.1/fair-stand")"
  fi

  REPORT_FAIR_STAND_SPA="HTTP ${status} (SPA host only, not configurator runtime)"
  if [[ "$status" =~ ^(200|301|302|303|307|308)$ ]]; then
    log "Fair Stand SPA host responded HTTP ${status} (not counted as configurator runtime)"
  else
    warn "Fair Stand SPA host HTTP ${status} at local /fair-stand (Host=${domain:-127.0.0.1})"
  fi
}

# Align /etc/fair-crm/server-bootstrap.env with the live nginx server_name so
# deploy-all + check-server stay consistent after domain cutovers (e.g. umaay -> fuar.kyrox.studio).
sync_bootstrap_domain_from_nginx() {
  local bootstrap_env="${SERVER_BOOTSTRAP_ENV_FILE:-/etc/fair-crm/server-bootstrap.env}"
  local nginx_site="/etc/nginx/sites-available/fair-crm"
  local nginx_domain=""
  local current_domain=""
  local current_email=""
  local current_ip=""
  local remote_pg_user remote_pg_port

  [[ "${EUID}" -eq 0 ]] || return 0
  [[ -f "$nginx_site" ]] || return 0

  nginx_domain="$(
    grep -E '^[[:space:]]*server_name[[:space:]]+' "$nginx_site" \
      | head -n 1 \
      | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/[[:space:]]*;.*$//; s/[[:space:]].*$//'
  )"
  [[ -n "$nginx_domain" ]] || return 0

  if [[ -f "$bootstrap_env" ]]; then
    current_domain="$(read_env_key "$bootstrap_env" FAIR_CRM_DOMAIN || true)"
    current_email="$(read_env_key "$bootstrap_env" LETSENCRYPT_EMAIL || true)"
    current_ip="$(read_env_key "$bootstrap_env" SERVER_PUBLIC_IP || true)"
    remote_pg_user="$(read_env_key "$bootstrap_env" REMOTE_PG_USER || printf '%s' "faircrm_remote")"
    remote_pg_port="$(read_env_key "$bootstrap_env" REMOTE_PG_PORT || printf '%s' "15432")"
  else
    remote_pg_user="faircrm_remote"
    remote_pg_port="15432"
  fi

  if [[ "$current_domain" == "$nginx_domain" ]]; then
    log "Bootstrap domain already matches nginx (${nginx_domain})"
    return 0
  fi

  step "Sync bootstrap domain from nginx (${current_domain:-<empty>} -> ${nginx_domain})"
  [[ -n "$current_email" ]] || current_email="admin@${nginx_domain}"
  [[ -n "$current_ip" ]] || current_ip="$(
    curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true
  )"

  run_root mkdir -p "$(dirname "$bootstrap_env")"
  {
    printf 'FAIR_CRM_DOMAIN=%s\n' "$nginx_domain"
    printf 'SERVER_PUBLIC_IP=%s\n' "$current_ip"
    printf 'LETSENCRYPT_EMAIL=%s\n' "$current_email"
    printf 'REMOTE_PG_USER=%s\n' "$remote_pg_user"
    printf 'REMOTE_PG_PORT=%s\n' "$remote_pg_port"
  } | run_root tee "$bootstrap_env" >/dev/null
  run_root chown root:root "$bootstrap_env"
  run_root chmod 600 "$bootstrap_env"
  log "Updated ${bootstrap_env}: FAIR_CRM_DOMAIN=${nginx_domain}"
}

install_fair_stand_dependencies() {
  if [[ "${SKIP_NODE:-0}" != "1" ]]; then
    ensure_nodejs
  else
    require_cmd node
    require_cmd npm
  fi

  step "Fair Stand npm ci"
  [[ -f "${FAIR_STAND_DIR}/package.json" ]] || die "Fair Stand package.json missing: ${FAIR_STAND_DIR}/package.json"
  (
    cd "$FAIR_STAND_DIR"
    npm ci
  )
  if [[ ! -d "${FAIR_STAND_DIR}/node_modules" ]]; then
    REPORT_FAIR_STAND_DEPS="FAIL"
    die "Fair Stand npm ci did not produce node_modules"
  fi
  REPORT_FAIR_STAND_DEPS="PASS"
}

report_pass_fail() {
  local value="$1"
  case "$value" in
    PASS|passed*|success*|ok|200|reloaded) printf '%s' "PASS" ;;
    skipped*|"not run") printf '%s' "$value" ;;
    *) printf '%s' "FAIL" ;;
  esac
}

run_login_smoke_deploy() {
  step "Login smoke test (Core auth)"
  if run_login_smoke_test "$CORE_PORT" "deploy"; then
    REPORT_LOGIN_SMOKE="passed (HTTP 200, access_token present)"
    echo "[OK] Login smoke test passed"
  else
    REPORT_LOGIN_SMOKE="failed"
    die "Login smoke test failed"
  fi
}

run_admin_backups_smoke_deploy() {
  step "Admin backups API smoke test (dev owner)"
  if run_admin_backups_smoke_test "$FAIR_CRM_PORT" "$CORE_PORT" "deploy"; then
    REPORT_BACKUPS_SMOKE="passed (HTTP 200)"
    echo "[OK] Admin backups API smoke test passed"
  else
    REPORT_BACKUPS_SMOKE="failed"
    die "Admin backups API smoke test failed (expected HTTP 200 at /api/v1/admin/backups)"
  fi
}

maybe_run_post_check() {
  if [[ "${RUN_POST_CHECK:-1}" != "1" ]]; then
    REPORT_POST_CHECK="skipped (RUN_POST_CHECK=0)"
    return 0
  fi
  step "Post-deploy health audit (check-server.sh)"
  if [[ "${EUID}" -ne 0 ]]; then
    REPORT_POST_CHECK="skipped (requires sudo)"
    warn "Skipping post-deploy check; run sudo bash ${FAIR_CRM_DIR}/scripts/server/check-server.sh manually"
    return 0
  fi
  if SKIP_PUBLIC_CHECKS=1 bash "${FAIR_CRM_DIR}/scripts/server/check-server.sh"; then
    REPORT_POST_CHECK="passed"
  else
    REPORT_POST_CHECK="failed"
    die "Post-deploy check-server.sh reported failures"
  fi
}

print_final_report() {
  local core_health_label fair_health_label stand_health_label login_label frontend_label nginx_label post_label
  core_health_label="$(report_pass_fail "$REPORT_CORE_HEALTH")"
  fair_health_label="$(report_pass_fail "$REPORT_FAIR_HEALTH")"
  stand_health_label="$(report_pass_fail "$REPORT_STAND_HEALTH")"
  login_label="$(report_pass_fail "$REPORT_LOGIN_SMOKE")"
  frontend_label="$(report_pass_fail "$REPORT_FRONTEND_BUILD")"
  nginx_label="$(report_pass_fail "$REPORT_NGINX")"
  post_label="$(report_pass_fail "$REPORT_POST_CHECK")"

  if [[ "$REPORT_FRONTEND_BUILD" == "success" && "$REPORT_FAIR_STAND_BOOTSTRAP" == PASS* ]]; then
    REPORT_FINAL_STATUS="deploy complete"
  elif [[ "${DEPLOY_FAILED_STEP:-none}" != "none" ]]; then
    REPORT_FINAL_STATUS="BROKEN"
  else
    REPORT_FINAL_STATUS="see details"
  fi

  echo ""
  echo "========== DEPLOY ACCEPTANCE REPORT =========="
  echo "Failed step: ${DEPLOY_FAILED_STEP:-none}"
  echo "Status: ${REPORT_FINAL_STATUS}"
  echo ""
  echo "Git commits:"
  echo "kyrox-core=${REPORT_CORE_HASH}"
  echo "fair-crm=${REPORT_FAIR_HASH}"
  echo "fair-stand=${REPORT_FAIR_STAND_HASH}"
  echo ""
  echo "Core health: ${core_health_label}"
  echo "Fair Stand health: ${stand_health_label}"
  echo "Fair CRM health: ${fair_health_label}"
  echo "Login smoke: ${login_label}"
  echo "Core migration: $(report_pass_fail "$REPORT_CORE_MIGRATION")"
  echo "Fair CRM migration: $(report_pass_fail "$REPORT_FAIR_MIGRATION")"
  echo "Fair Stand migration: $(report_pass_fail "$REPORT_STAND_MIGRATION")"
  echo "Fair CRM frontend build: ${frontend_label}"
  echo "Fair Stand source integration: ${REPORT_FAIR_STAND_SOURCE}"
  echo "Fair Stand npm ci: ${REPORT_FAIR_STAND_DEPS}"
  echo "Fair Stand catalog bootstrap: ${REPORT_FAIR_STAND_BOOTSTRAP}"
  echo "Fair Stand SPA host: ${REPORT_FAIR_STAND_SPA}"
  echo "Nginx: ${nginx_label}"
  echo "Post-check: ${post_label}"
  echo ""
  echo "1. Scripts:"
  echo "   scripts/server/bootstrap-server.sh"
  echo "   scripts/server/deploy-all.sh"
  echo "   scripts/server/check-server.sh"
  echo ""
  echo "2. Core seed: ${REPORT_CORE_SEED}"
  echo "   script: ${FAIR_CRM_DIR}/scripts/seed_core_dev_identity.py"
  echo "   python: ${KYROX_CORE_DIR}/.venv/bin/python"
  echo "   email: ${DEV_LOGIN_EMAIL}"
  echo "   password: (from ${DEV_SEED_ENV_FILE}; not shown)"
  echo "   org id: ${DEV_LOGIN_ORG_ID}"
  echo "   role: owner/admin; permissions: all fair_crm.*"
  echo ""
  echo "3. systemd:"
  print_systemd_service_summary "$SCRIPT_DIR" | sed 's/^/   /'
  echo ""
  echo "4. nginx:"
  echo "   /              -> ${FAIR_CRM_DIR}/frontend/dist"
  echo "   /api/          -> 127.0.0.1:8001"
  echo "   /api/v1/fair-stand/ -> 127.0.0.1:${STAND_PORT}"
  echo "   /kyrox-core/   -> 127.0.0.1:8000"
  echo "   /fair-stand    -> Fair CRM SPA route (same dist)"
  echo "   nginx -t: ${REPORT_NGINX_TEST}; reload: ${REPORT_NGINX}"
  echo ""
  echo "5. Health: Core ${REPORT_CORE_HEALTH}, Fair Stand ${REPORT_STAND_HEALTH}, Fair CRM ${REPORT_FAIR_HEALTH}"
  echo "6. Login smoke: ${REPORT_LOGIN_SMOKE}"
  echo "7. Admin backups API: ${REPORT_BACKUPS_SMOKE}"
  echo "8. Frontend build: ${REPORT_FRONTEND_BUILD}"
  echo "9. Playwright Chromium: ${REPORT_PLAYWRIGHT_CHROMIUM}"
  echo "10. Migrations: Core ${REPORT_CORE_MIGRATION}, Fair Stand ${REPORT_STAND_MIGRATION}, Fair CRM ${REPORT_FAIR_MIGRATION}"
  echo "11. Git commits: kyrox-core=${REPORT_CORE_HASH} (${KYROX_CORE_BRANCH}), fair-crm=${REPORT_FAIR_HASH} (${FAIR_CRM_BRANCH}), fair-stand=${REPORT_FAIR_STAND_HASH} (${FAIR_STAND_BRANCH})"
  echo "12. Safe deploy restore: ${REPORT_SAFE_DEPLOY_RESTORE}"
  echo "13. Post-deploy check: ${REPORT_POST_CHECK}"
  echo "14. Push: not run by deploy script (manual git push if needed)"
  echo ""
  echo "Core API: http://127.0.0.1:${CORE_PORT}"
  echo "Fair Stand API: http://127.0.0.1:${STAND_PORT}"
  echo "Fair CRM API: http://127.0.0.1:${FAIR_CRM_PORT}"
  echo "=============================================="
}

log_deploy_safety_contract() {
  step "Deploy safety contract (backup/restore compatible)"
  log "Will run: git pull of each repo's origin default branch (core/crm/fair-stand), pip/npm install, Fair Stand pip + npm ci, Playwright Chromium install, alembic upgrade head (three DBs), systemd restart core then stand then crm"
  log "Will restore safe deploy scripts/templates before fair-crm git pull when locally modified"
  log "Will not: drop/truncate DB, delete or reseed Fair Stand catalog rows, pg_restore, touch backups/ or restore data dirs, overwrite .env"
}

main() {
  log_deploy_safety_contract

  step "Preflight commands"
  require_linux
  require_cmd git
  require_cmd python3
  require_cmd curl
  require_cmd psql
  resolve_deploy_service_user
  assert_db_url_resolvers

  step "Verify target directories"
  mkdir -p "$(dirname "$KYROX_CORE_DIR")" "$(dirname "$FAIR_CRM_DIR")" "$(dirname "$FAIR_STAND_DIR")"
  KYROX_CORE_BRANCH="$(branch_or_origin_default "${KYROX_CORE_BRANCH:-}" "$KYROX_CORE_REPO")"
  if [[ -d "${FAIR_CRM_DIR}/.git" ]]; then
    FAIR_CRM_BRANCH="$(branch_or_origin_default "${FAIR_CRM_BRANCH:-}" "$FAIR_CRM_DIR")"
  else
    FAIR_CRM_BRANCH="${FAIR_CRM_BRANCH:-}"
  fi
  FAIR_STAND_BRANCH="$(branch_or_origin_default "${FAIR_STAND_BRANCH:-}" "$FAIR_STAND_REPO")"
  log "KYROX_CORE_DIR=${KYROX_CORE_DIR} (branch ${KYROX_CORE_BRANCH})"
  log "FAIR_CRM_DIR=${FAIR_CRM_DIR} (branch ${FAIR_CRM_BRANCH})"
  log "FAIR_STAND_DIR=${FAIR_STAND_DIR} (branch ${FAIR_STAND_BRANCH})"
  log "DEPLOY_SERVICE_USER=${DEPLOY_SERVICE_USER}"

  clone_or_update_repo "$KYROX_CORE_DIR" "$KYROX_CORE_REPO" "$KYROX_CORE_BRANCH" "${PROTECTED_KYROX_CORE_PATHS[@]}"

  ensure_core_backend_env "$KYROX_CORE_DIR" || die "Cannot create Core backend .env at ${KYROX_CORE_DIR}/backend/.env"

  if [[ -d "${FAIR_CRM_DIR}/.git" ]]; then
    restore_safe_fair_crm_deploy_files "$FAIR_CRM_DIR"
    clone_or_update_repo "$FAIR_CRM_DIR" "$(git -C "$FAIR_CRM_DIR" remote get-url origin)" "$FAIR_CRM_BRANCH" "${PROTECTED_FAIR_CRM_PATHS[@]}"
  else
    warn "Fair CRM repo not initialized at ${FAIR_CRM_DIR}; using working tree without git pull"
  fi

  clone_or_update_repo "$FAIR_STAND_DIR" "$FAIR_STAND_REPO" "$FAIR_STAND_BRANCH" "${PROTECTED_FAIR_STAND_PATHS[@]}"
  REPORT_FAIR_STAND_STATUS="updated (${FAIR_STAND_BRANCH})"

  REPORT_CORE_HASH="$(git_short_hash "$KYROX_CORE_DIR")"
  REPORT_FAIR_HASH="$(git_short_hash "$FAIR_CRM_DIR")"
  REPORT_FAIR_STAND_HASH="$(git_short_hash "$FAIR_STAND_DIR")"

  setup_python_project "kyrox-core" "$KYROX_CORE_DIR" "${KYROX_CORE_DIR}/.venv"
  setup_python_project "fair-crm" "$FAIR_CRM_DIR" "${FAIR_CRM_DIR}/backend/.venv"
  setup_python_project "fair-stand" "$FAIR_STAND_DIR" "${FAIR_STAND_DIR}/backend/.venv"
  install_fair_stand_dependencies

  # After Fair CRM pip install; before systemd restart / health checks.
  REPORT_PLAYWRIGHT_CHROMIUM="failed"
  install_playwright_chromium "$FAIR_CRM_DIR"
  REPORT_PLAYWRIGHT_CHROMIUM="success (idempotent)"

  ensure_postgres_container "$FAIR_CRM_DIR"
  resolve_postgres_connection "$FAIR_CRM_DIR" "$KYROX_CORE_DIR"
  verify_postgres_connectivity

  ensure_database "kyrox_core"
  ensure_database "fair_crm"
  ensure_database "fair_stand"
  ensure_fair_stand_backend_env "$FAIR_STAND_DIR" "$KYROX_CORE_DIR"
  ensure_fair_crm_peer_database_urls
  ensure_repo_data_dirs "$FAIR_CRM_DIR"

  validate_env_files_required

  local core_db_url fair_db_url
  core_db_url="$(resolve_core_db_url)"
  fair_db_url="$(resolve_fair_db_url)"

  if run_alembic_upgrade "$KYROX_CORE_DIR" "${KYROX_CORE_DIR}/.venv/bin/python" "alembic.ini" "$core_db_url"; then
    REPORT_CORE_MIGRATION="success"
  else
    REPORT_CORE_MIGRATION="failed"
    die "kyrox-core alembic upgrade failed"
  fi

  assert_core_migration_meets_seed_minimum \
    "$KYROX_CORE_DIR" "${KYROX_CORE_DIR}/.venv/bin/python" "$core_db_url"

  run_core_dev_seed

  if run_alembic_upgrade "$FAIR_CRM_DIR" "${FAIR_CRM_DIR}/backend/.venv/bin/python" "alembic.ini" "$fair_db_url"; then
    REPORT_FAIR_MIGRATION="success"
  else
    REPORT_FAIR_MIGRATION="failed"
    die "fair-crm alembic upgrade failed"
  fi

  if run_alembic_upgrade "${FAIR_STAND_DIR}/backend" "${FAIR_STAND_DIR}/backend/.venv/bin/python" "alembic.ini" ""; then
    REPORT_STAND_MIGRATION="success"
  else
    REPORT_STAND_MIGRATION="failed"
    die "fair-stand alembic upgrade failed"
  fi

  log "Fair Stand catalog rows left untouched"

  manage_systemd_services
  build_frontend

  if [[ "${SKIP_NGINX_RELOAD:-0}" != "1" ]]; then
    step "Reload nginx"
    if command -v nginx >/dev/null 2>&1; then
      bash "${SCRIPT_DIR}/apply-nginx-upload-limit.sh"
      bash "${SCRIPT_DIR}/apply-nginx-performance.sh"
      if run_root nginx -t >/dev/null 2>&1; then
        REPORT_NGINX_TEST="ok"
        run_root systemctl reload nginx
        REPORT_NGINX="reloaded"
      else
        REPORT_NGINX_TEST="failed"
        die "nginx -t failed before reload"
      fi
    else
      REPORT_NGINX_TEST="skipped (nginx not installed)"
    fi
  fi

  run_health_checks
  run_login_smoke_deploy
  run_admin_backups_smoke_deploy
  run_fair_stand_catalog_bootstrap_deploy
  sync_bootstrap_domain_from_nginx
  run_fair_stand_spa_host_check
  maybe_run_post_check
  print_final_report
}

trap 'if [[ $? -ne 0 ]]; then echo ""; print_final_report; fi' EXIT

main "$@"
