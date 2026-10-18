#!/usr/bin/env bash
# Shared helpers for server bootstrap, deploy, and health-check scripts.

set -euo pipefail

DEPLOY_STEP=""
DEPLOY_FAILED_STEP=""
DEPLOY_LOG_PREFIX="[server]"

CHECK_FAIL_COUNT=0
CHECK_WARN_COUNT=0
CHECK_PASS_COUNT=0
CHECK_STRICT="${CHECK_STRICT:-0}"
CHECK_QUIET="${CHECK_QUIET:-0}"

DEV_LOGIN_EMAIL="${DEV_LOGIN_EMAIL:-dev@example.com}"
DEV_LOGIN_PASSWORD="${DEV_LOGIN_PASSWORD:-}"
DEV_LOGIN_ORG_ID="${DEV_LOGIN_ORG_ID:-00000000-0000-4000-8000-000000000010}"
DEV_SEED_ENV_FILE="${DEV_SEED_ENV_FILE:-/etc/fair-crm/dev-seed.env}"

MIN_CORE_SEED_MIGRATION_REVISION="${MIN_CORE_SEED_MIGRATION_REVISION:-20260701_0031}"
# Boş dal = origin HEAD (GitHub varsayılan dal). main diye sabitlenmez.
EXPECTED_FAIR_CRM_BRANCH="${EXPECTED_FAIR_CRM_BRANCH:-${FAIR_CRM_BRANCH:-}}"
EXPECTED_KYROX_CORE_BRANCH="${EXPECTED_KYROX_CORE_BRANCH:-${KYROX_CORE_BRANCH:-}}"
# Kyrox projeleri tek kök altında, GitHub repo adlarıyla: ${KYROX_ROOT}/kyrox-fair-crm, kyrox-fair-stand, kyrox-core.
KYROX_ROOT="${KYROX_ROOT:-/opt/kyrox}"
FAIR_STAND_DIR="${FAIR_STAND_DIR:-${KYROX_ROOT}/kyrox-fair-stand}"
FAIR_STAND_REPO="${FAIR_STAND_REPO:-https://github.com/kyrox-studio/kyrox-fair-stand.git}"
EXPECTED_FAIR_STAND_BRANCH="${EXPECTED_FAIR_STAND_BRANCH:-${FAIR_STAND_BRANCH:-}}"

# Frontend engine requirements (vite / tooling) need Node 22.12+.
REQUIRED_NODEJS_VERSION="${REQUIRED_NODEJS_VERSION:-22.12.0}"
NODEJS_MAJOR_CHANNEL="${NODEJS_MAJOR_CHANNEL:-22}"

log() {
  echo "${DEPLOY_LOG_PREFIX} $*"
}

warn() {
  echo "${DEPLOY_LOG_PREFIX} WARN: $*" >&2
}

die() {
  DEPLOY_FAILED_STEP="${DEPLOY_STEP:-unknown}"
  echo "${DEPLOY_LOG_PREFIX} ERROR at step '${DEPLOY_FAILED_STEP}': $*" >&2
  exit 1
}

step() {
  DEPLOY_STEP="$1"
  if [[ "${CHECK_QUIET:-0}" != "1" ]]; then
    log "==> $1"
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
}

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "This script supports Linux servers only"
}

require_root_or_sudo() {
  if [[ "${EUID}" -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      die "Run as root or install sudo"
    fi
    if ! sudo -n true 2>/dev/null; then
      warn "Some steps need sudo; you may be prompted for a password"
    fi
  fi
}

run_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

check_reset_counters() {
  CHECK_FAIL_COUNT=0
  CHECK_WARN_COUNT=0
  CHECK_PASS_COUNT=0
}

check_pass() {
  local label="$1"
  CHECK_PASS_COUNT=$((CHECK_PASS_COUNT + 1))
  echo "[OK] ${label}"
}

check_fail() {
  local label="$1"
  CHECK_FAIL_COUNT=$((CHECK_FAIL_COUNT + 1))
  echo "[FAIL] ${label}" >&2
}

check_warn_item() {
  local label="$1"
  CHECK_WARN_COUNT=$((CHECK_WARN_COUNT + 1))
  echo "[WARN] ${label}" >&2
}

check_compute_final_status() {
  if [[ "${CHECK_FAIL_COUNT}" -gt 0 ]]; then
    printf '%s' "BROKEN"
  elif [[ "${CHECK_WARN_COUNT}" -gt 0 ]]; then
    printf '%s' "DEGRADED"
  else
    printf '%s' "HEALTHY"
  fi
}

check_finalize_exit() {
  local final
  final="$(check_compute_final_status)"
  echo ""
  echo "Final: ${final}"
  if [[ "${CHECK_FAIL_COUNT}" -gt 0 ]]; then
    return 1
  fi
  if [[ "${CHECK_STRICT}" == "1" && "${CHECK_WARN_COUNT}" -gt 0 ]]; then
    return 1
  fi
  return 0
}

read_env_key() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 1
  local line
  line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 1
  local value="${line#*=}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

# Non-reversible short fingerprint for safe password identity checks (never log plaintext).
dev_password_fingerprint() {
  local password="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$password" | sha256sum | awk '{print substr($1,1,12)}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$password" | shasum -a 256 | awk '{print substr($1,1,12)}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$password" | openssl dgst -sha256 | awk '{print substr($NF,1,12)}'
  else
    printf '%s' "unavailable"
  fi
}

dev_password_meta_log() {
  local source="$1"
  local password="$2"
  local length="${#password}"
  local fingerprint
  fingerprint="$(dev_password_fingerprint "$password")"
  log "DEV_USER_PASSWORD from ${source} (length=${length} fingerprint=${fingerprint}; value not shown)"
}

dev_seed_password_missing_help() {
  cat <<EOF
DEV_USER_PASSWORD is required for Core dev identity seed and login smoke tests.
There is no hardcoded default password.

Create a root-only env file on the server:

  sudo mkdir -p /etc/fair-crm
  echo 'DEV_USER_PASSWORD=<set-a-strong-dev-password>' | sudo tee ${DEV_SEED_ENV_FILE} >/dev/null
  sudo chown root:root ${DEV_SEED_ENV_FILE}
  sudo chmod 600 ${DEV_SEED_ENV_FILE}

Or export DEV_USER_PASSWORD in the environment (local development).
EOF
}

# Load DEV_USER_PASSWORD from /etc/fair-crm/dev-seed.env (required on deploy).
# Never prints the password value. Does not fall back to a hardcoded default.
require_dev_seed_env_file() {
  local seed_env="${DEV_SEED_ENV_FILE}"
  if [[ ! -f "$seed_env" ]]; then
    die "Dev seed password file missing: ${seed_env}

$(dev_seed_password_missing_help)"
  fi

  local password
  password="$(read_env_key "$seed_env" DEV_USER_PASSWORD || true)"
  if [[ -z "$password" ]]; then
    die "DEV_USER_PASSWORD is missing or empty in ${seed_env}

$(dev_seed_password_missing_help)"
  fi

  export DEV_USER_PASSWORD="$password"
  export DEV_LOGIN_PASSWORD="$password"
  dev_password_meta_log "$seed_env" "$password"
  export DEV_PASSWORD_META_LOGGED=1
}

# Resolve password for smoke tests: env override, else seed env file.
# Never falls back to a hardcoded default.
require_dev_login_password() {
  local password=""
  local source=""
  if [[ -n "${DEV_USER_PASSWORD:-}" ]]; then
    password="$DEV_USER_PASSWORD"
    source="env:DEV_USER_PASSWORD"
  elif [[ -n "${DEV_LOGIN_PASSWORD:-}" ]]; then
    password="$DEV_LOGIN_PASSWORD"
    source="env:DEV_LOGIN_PASSWORD"
  elif [[ -f "${DEV_SEED_ENV_FILE}" ]]; then
    password="$(read_env_key "$DEV_SEED_ENV_FILE" DEV_USER_PASSWORD || true)"
    source="${DEV_SEED_ENV_FILE}"
  fi

  if [[ -z "$password" ]]; then
    die "DEV_USER_PASSWORD is not set and seed env file is missing or empty: ${DEV_SEED_ENV_FILE}

$(dev_seed_password_missing_help)"
  fi

  export DEV_USER_PASSWORD="$password"
  export DEV_LOGIN_PASSWORD="$password"
  if [[ -z "${DEV_PASSWORD_META_LOGGED:-}" ]]; then
    dev_password_meta_log "${source:-unknown}" "$password"
    export DEV_PASSWORD_META_LOGGED=1
  fi
}

parse_database_url() {
  local url="${1//+psycopg2/}"
  python3 - "$url" <<'PY'
import sys
from urllib.parse import urlparse

raw = sys.argv[1]
parsed = urlparse(raw)
user = parsed.username or "postgres"
password = parsed.password or ""
host = parsed.hostname or "127.0.0.1"
port = parsed.port or 5432
db = (parsed.path or "/postgres").lstrip("/") or "postgres"
print(f"PG_USER={user}")
print(f"PG_PASS={password}")
print(f"PG_HOST={host}")
print(f"PG_PORT={port}")
print(f"PG_DB={db}")
PY
}

http_status() {
  local url="$1"
  curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 15 "$url" 2>/dev/null || echo "000"
}

git_short_hash() {
  local dir="$1"
  if [[ -d "${dir}/.git" ]]; then
    git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "unknown"
  else
    echo "n/a"
  fi
}

git_head_sha() {
  local dir="$1"
  if [[ -d "${dir}/.git" ]]; then
    git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown"
  else
    echo "n/a"
  fi
}

print_integrated_git_commits() {
  echo "kyrox-core=$(git_short_hash "${KYROX_CORE_DIR:-${KYROX_ROOT}/kyrox-core}")"
  echo "fair-crm=$(git_short_hash "${FAIR_CRM_DIR:-${KYROX_ROOT}/kyrox-fair-crm}")"
  echo "fair-stand=$(git_short_hash "${FAIR_STAND_DIR:-${KYROX_ROOT}/kyrox-fair-stand}")"
}

is_port_listening() {
  local port="$1"
  local host="${2:-127.0.0.1}"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :${port}" 2>/dev/null | grep -q ":${port} " && return 0
  fi
  if command -v nc >/dev/null 2>&1; then
    nc -z "$host" "$port" >/dev/null 2>&1 && return 0
  fi
  return 1
}

read_origin_default_branch() {
  local target="$1"
  local line branch
  if [[ -d "${target}/.git" ]]; then
    line="$(git -C "$target" ls-remote --symref origin HEAD 2>/dev/null | head -n 1 || true)"
  else
    line="$(git ls-remote --symref "$target" HEAD 2>/dev/null | head -n 1 || true)"
  fi
  [[ "$line" == ref:* ]] || return 1
  branch="${line#ref: }"
  branch="${branch%%[[:space:]]*}"
  branch="${branch#refs/heads/}"
  [[ -n "$branch" && "$branch" != "HEAD" ]] || return 1
  printf '%s\n' "$branch"
}

branch_or_origin_default() {
  local explicit="$1"
  local target="$2"
  local resolved
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  resolved="$(read_origin_default_branch "$target")" || die "origin default branch could not be resolved for ${target}"
  printf '%s\n' "$resolved"
}

ensure_git_ff_pull() {
  local dir="$1"
  local branch="$2"
  shift 2
  local -a protected_paths=("$@")

  step "Git update in ${dir} (branch ${branch})"
  [[ -d "${dir}/.git" ]] || die "Not a git repository: ${dir}"

  local dirty
  dirty="$(git -C "$dir" status --porcelain 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      local path="${line:3}"
      local allowed=0
      for protected in "${protected_paths[@]}"; do
        if [[ "$path" == "$protected" || "$path" == "${protected}/"* ]]; then
          allowed=1
          break
        fi
      done
      if [[ "$allowed" -eq 0 ]]; then
        die "Repository ${dir} has local changes in '${path}'. Commit/stash before deploy."
      fi
      warn "Preserving local server config change: ${dir}/${path}"
    done <<< "$dirty"
  fi

  git -C "$dir" fetch origin
  if git -C "$dir" show-ref --verify --quiet "refs/heads/${branch}"; then
    git -C "$dir" checkout "${branch}"
  elif git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
    git -C "$dir" checkout -B "${branch}" "origin/${branch}"
  else
    die "Branch '${branch}' not found in ${dir}"
  fi
  git -C "$dir" pull --ff-only origin "${branch}"
}

FAIR_CRM_SAFE_DEPLOY_RESTORE_PATHS=(
  "scripts/server/bootstrap-server.sh"
  "scripts/server/deploy-all.sh"
  "scripts/server/check-server.sh"
  "scripts/server/systemd"
  "scripts/server/nginx"
)

FAIR_CRM_SERVER_EXECUTABLE_SCRIPTS=(
  "scripts/server/bootstrap-server.sh"
  "scripts/server/deploy-all.sh"
  "scripts/server/check-server.sh"
  "scripts/server/run-restore-job.sh"
)

ensure_fair_crm_server_scripts_executable() {
  local dir="$1"
  local rel script_path
  for rel in "${FAIR_CRM_SERVER_EXECUTABLE_SCRIPTS[@]}"; do
    script_path="${dir}/${rel}"
    if [[ -f "$script_path" ]]; then
      chmod +x "$script_path"
    fi
  done
}

restore_safe_fair_crm_deploy_files() {
  local dir="$1"
  REPORT_SAFE_DEPLOY_RESTORE="${REPORT_SAFE_DEPLOY_RESTORE:-not run}"

  [[ -d "${dir}/.git" ]] || return 0

  step "Restore safe deploy files before git pull"
  local dirty
  dirty="$(
    git -C "$dir" status --porcelain -- "${FAIR_CRM_SAFE_DEPLOY_RESTORE_PATHS[@]}" 2>/dev/null || true
  )"
  if [[ -z "$dirty" ]]; then
    REPORT_SAFE_DEPLOY_RESTORE="none needed"
    log "No safe deploy file changes to restore"
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      log "Restoring safe deploy path: ${line:3}"
    done <<< "$dirty"

    if git -C "$dir" checkout HEAD -- "${FAIR_CRM_SAFE_DEPLOY_RESTORE_PATHS[@]}" 2>/dev/null; then
      :
    elif git -C "$dir" restore --source=HEAD --worktree --staged -- "${FAIR_CRM_SAFE_DEPLOY_RESTORE_PATHS[@]}" 2>/dev/null; then
      :
    else
      die "Failed to restore safe deploy files in ${dir}"
    fi

    REPORT_SAFE_DEPLOY_RESTORE="safe deploy files restored before git pull"
    log "${REPORT_SAFE_DEPLOY_RESTORE}"
  fi

  ensure_fair_crm_server_scripts_executable "$dir"
}

# Bash has already parsed deploy-all.sh main() and sourced this file before the
# fair-crm git pull, so the old deploy logic would keep running after an update.
# These files are fingerprinted before the pull; when they change, deploy-all.sh
# restarts itself once with the new version (KYROX_DEPLOY_REEXECED guards a loop).
FAIR_CRM_DEPLOY_SELF_FILES=(
  "scripts/server/deploy-all.sh"
  "scripts/server/lib/common.sh"
)

deploy_scripts_fingerprint() {
  local dir="$1"
  local rel
  for rel in "${FAIR_CRM_DEPLOY_SELF_FILES[@]}"; do
    if [[ -f "${dir}/${rel}" ]]; then
      printf '%s %s\n' "$(sha256sum "${dir}/${rel}" | cut -d' ' -f1)" "$rel"
    else
      printf 'missing %s\n' "$rel"
    fi
  done
}

reexec_deploy_if_scripts_changed() {
  local dir="$1"
  local before="$2"
  local script="$3"
  shift 3

  local after
  after="$(deploy_scripts_fingerprint "$dir")"
  [[ "$after" != "$before" ]] || return 0

  if [[ "${KYROX_DEPLOY_REEXECED:-0}" == "1" ]]; then
    warn "Deploy scripts changed again after restart; continuing with the running version"
    return 0
  fi

  step "Deploy scripts updated by git pull; restarting with the new version"
  export KYROX_DEPLOY_REEXECED=1
  # exec replaces this process; the EXIT trap does not fire, so no partial report.
  exec bash "$script" "$@"
}

copy_env_if_missing() {
  local example="$1"
  local target="$2"
  if [[ -f "$target" ]]; then
    log "Preserving existing env: ${target}"
    return 0
  fi
  if [[ ! -f "$example" ]]; then
    warn "Env example missing: ${example}"
    return 0
  fi
  cp "$example" "$target"
  warn "Created ${target} from example — review secrets and URLs before production use"
}

replace_or_append_env_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  python3 - "$file" "$key" "$value" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
found = False
out = []
prefix = f"{key}="
for line in lines:
    stripped = line.strip()
    if stripped.startswith(prefix):
        out.append(f"{key}={value}")
        found = True
    else:
        out.append(line)
if not found:
    out.append(f"{key}={value}")
path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}

ensure_fair_crm_peer_database_urls() {
  local fair_env="${FAIR_CRM_DIR}/backend/.env"
  [[ -f "$fair_env" ]] || return 0

  if [[ -z "$(read_env_key "$fair_env" KYROX_CORE_DATABASE_URL || true)" ]]; then
    replace_or_append_env_key "$fair_env" "KYROX_CORE_DATABASE_URL" "$(resolve_core_db_url)"
  fi
  if [[ -z "$(read_env_key "$fair_env" FAIR_STAND_DATABASE_URL || true)" ]]; then
    replace_or_append_env_key "$fair_env" "FAIR_STAND_DATABASE_URL" "$(resolve_stand_db_url)"
  fi
  if [[ -z "$(read_env_key "$fair_env" KYROX_CORE_REPO_PATH || true)" ]]; then
    replace_or_append_env_key "$fair_env" "KYROX_CORE_REPO_PATH" "${KYROX_CORE_DIR}"
  fi
  if [[ -z "$(read_env_key "$fair_env" FAIR_STAND_REPO_PATH || true)" ]]; then
    replace_or_append_env_key "$fair_env" "FAIR_STAND_REPO_PATH" "${FAIR_STAND_DIR}"
  fi
}

ensure_fair_stand_backend_env() {
  local stand_dir="${1:-${FAIR_STAND_DIR}}"
  local core_dir="${2:-${KYROX_CORE_DIR}}"
  local target="${stand_dir}/backend/.env"
  local example="${stand_dir}/backend/.env.example"
  local created=0

  [[ -d "$stand_dir" ]] || die "Fair Stand checkout missing: ${stand_dir}"
  mkdir -p "${stand_dir}/backend"

  if [[ -f "$target" ]]; then
    log "Preserving existing Fair Stand env: ${target}"
  else
    [[ -f "$example" ]] || die "Fair Stand env example missing: ${example}"
    cp "$example" "$target"
    created=1
    warn "Created ${target} from example"
  fi

  local core_jwt db_url current_jwt
  core_jwt="$(read_env_key "${core_dir}/backend/.env" JWT_SECRET_KEY || true)"
  [[ -n "$core_jwt" ]] || die "JWT_SECRET_KEY missing in ${core_dir}/backend/.env"
  db_url="postgresql+psycopg2://${PG_USER}:${PG_PASS}@${PG_HOST}:${PG_PORT}/fair_stand"
  current_jwt="$(read_env_key "$target" JWT_SECRET_KEY || true)"

  if [[ -z "$current_jwt" || "$current_jwt" == "dev-insecure-change-me-use-env-in-production-32b" ]]; then
    replace_or_append_env_key "$target" "JWT_SECRET_KEY" "$core_jwt"
  fi
  if [[ -z "$(read_env_key "$target" FAIR_STAND_DATABASE_URL || true)" || "$created" == "1" ]]; then
    replace_or_append_env_key "$target" "FAIR_STAND_DATABASE_URL" "$db_url"
  fi
  if [[ -z "$(read_env_key "$target" KYROX_CORE_BASE_URL || true)" ]]; then
    replace_or_append_env_key "$target" "KYROX_CORE_BASE_URL" "http://127.0.0.1:8000"
  fi
  if [[ "$created" == "1" ]]; then
    replace_or_append_env_key "$target" "APP_ENV" "production"
    replace_or_append_env_key "$target" "FAIR_STAND_DEV_BYPASS_CORE" "false"
  fi
}

ensure_core_backend_env() {
  local core_dir="${1:-${KYROX_CORE_DIR}}"
  local backend_env="${core_dir}/backend/.env"
  local backend_example="${core_dir}/backend/.env.example"
  local root_env="${core_dir}/.env"
  local root_example="${core_dir}/.env.example"

  if [[ -f "$backend_env" ]]; then
    log "Preserving existing Core env: ${backend_env}"
    return 0
  fi

  if [[ ! -d "$core_dir" ]]; then
    warn "Core checkout not present at ${core_dir}; cannot create backend/.env"
    return 1
  fi

  mkdir -p "${core_dir}/backend"

  if [[ -f "$backend_example" ]]; then
    cp "$backend_example" "$backend_env"
    warn "Created ${backend_env} from backend/.env.example"
    return 0
  fi

  if [[ -f "$root_env" ]]; then
    cp "$root_env" "$backend_env"
    warn "Created ${backend_env} from legacy ${root_env}"
    return 0
  fi

  if [[ -f "$root_example" ]]; then
    cp "$root_example" "$backend_env"
    warn "Created ${backend_env} from ${root_example}"
    return 0
  fi

  warn "Core env example missing; expected ${backend_example} or ${root_example}"
  return 1
}

write_frontend_production_env_if_missing() {
  local fair_dir="$1"
  local target="${fair_dir}/frontend/.env.production"
  if [[ -f "$target" ]]; then
    log "Preserving existing frontend env: ${target}"
    return 0
  fi

  cat >"$target" <<EOF
# Empty: same-origin /api/v1/... and /kyrox-core/... via Nginx proxies
VITE_API_BASE_URL=
VITE_CORE_BASE_URL=
VITE_APP_ENV=production
VITE_DEV_BYPASS_ENABLED=false
VITE_ORGANIZATION_ID=00000000-0000-4000-8000-000000000010
EOF
  warn "Created ${target} with same-origin API/Core bases (Nginx proxies /api and /kyrox-core)"
}

validate_env_files_required() {
  step "Validate Core, Fair CRM, and Fair Stand .env files"
  local core_env="${KYROX_CORE_DIR}/backend/.env"
  local fair_env="${FAIR_CRM_DIR}/backend/.env"
  local stand_env="${FAIR_STAND_DIR}/backend/.env"

  [[ -f "$core_env" ]] || die "Missing Core env file: ${core_env}"
  [[ -f "$fair_env" ]] || die "Missing Fair CRM env file: ${fair_env}"
  [[ -f "$stand_env" ]] || die "Missing Fair Stand env file: ${stand_env}"

  local core_jwt fair_jwt stand_jwt fair_core_url stand_core_url
  core_jwt="$(read_env_key "$core_env" JWT_SECRET_KEY || true)"
  fair_jwt="$(read_env_key "$fair_env" JWT_SECRET_KEY || true)"
  stand_jwt="$(read_env_key "$stand_env" JWT_SECRET_KEY || true)"
  fair_core_url="$(read_env_key "$fair_env" KYROX_CORE_BASE_URL || true)"
  stand_core_url="$(read_env_key "$stand_env" KYROX_CORE_BASE_URL || true)"

  [[ -n "$core_jwt" ]] || die "JWT_SECRET_KEY missing in ${core_env}"
  [[ -n "$fair_jwt" ]] || die "JWT_SECRET_KEY missing in ${fair_env}"
  [[ -n "$stand_jwt" ]] || die "JWT_SECRET_KEY missing in ${stand_env}"
  [[ "$core_jwt" == "$fair_jwt" ]] || die "JWT_SECRET_KEY mismatch between Core and Fair CRM .env files"
  [[ "$core_jwt" == "$stand_jwt" ]] || die "JWT_SECRET_KEY mismatch between Core and Fair Stand .env files"

  if [[ -n "$fair_core_url" && "$fair_core_url" != "http://127.0.0.1:8000" && "$fair_core_url" != "http://localhost:8000" ]]; then
    warn "Fair CRM KYROX_CORE_BASE_URL=${fair_core_url} (expected http://127.0.0.1:8000 on single-host deploy)"
  else
    log "Fair CRM KYROX_CORE_BASE_URL OK (${fair_core_url:-http://127.0.0.1:8000})"
  fi
  if [[ -n "$stand_core_url" && "$stand_core_url" != "http://127.0.0.1:8000" && "$stand_core_url" != "http://localhost:8000" ]]; then
    warn "Fair Stand KYROX_CORE_BASE_URL=${stand_core_url} (expected http://127.0.0.1:8000 on single-host deploy)"
  else
    log "Fair Stand KYROX_CORE_BASE_URL OK (${stand_core_url:-http://127.0.0.1:8000})"
  fi
}

validate_env_files_check() {
  local core_env="${KYROX_CORE_DIR}/backend/.env"
  local fair_env="${FAIR_CRM_DIR}/backend/.env"
  local stand_env="${FAIR_STAND_DIR}/backend/.env"

  if [[ ! -f "$core_env" ]]; then
    check_fail "Core .env present"
    return 0
  fi
  check_pass "Core .env present"

  if [[ ! -f "$fair_env" ]]; then
    check_fail "Fair CRM .env present"
    return 0
  fi
  check_pass "Fair CRM .env present"

  if [[ ! -f "$stand_env" ]]; then
    check_fail "Fair Stand .env present"
    return 0
  fi
  check_pass "Fair Stand .env present"

  local core_jwt fair_jwt stand_jwt fair_core_url
  core_jwt="$(read_env_key "$core_env" JWT_SECRET_KEY || true)"
  fair_jwt="$(read_env_key "$fair_env" JWT_SECRET_KEY || true)"
  stand_jwt="$(read_env_key "$stand_env" JWT_SECRET_KEY || true)"
  fair_core_url="$(read_env_key "$fair_env" KYROX_CORE_BASE_URL || true)"

  if [[ -z "$core_jwt" || -z "$fair_jwt" || -z "$stand_jwt" ]]; then
    check_fail "JWT_SECRET_KEY configured in Core, Fair CRM, and Fair Stand .env files"
  elif [[ "$core_jwt" != "$fair_jwt" ]]; then
    check_fail "JWT_SECRET_KEY match between Core and Fair CRM"
  elif [[ "$core_jwt" != "$stand_jwt" ]]; then
    check_fail "JWT_SECRET_KEY match between Core and Fair Stand"
  else
    check_pass "JWT_SECRET_KEY match between Core, Fair CRM, and Fair Stand"
  fi

  if [[ -z "$fair_core_url" || "$fair_core_url" == "http://127.0.0.1:8000" || "$fair_core_url" == "http://localhost:8000" ]]; then
    check_pass "Fair CRM KYROX_CORE_BASE_URL=http://127.0.0.1:8000"
  else
    check_warn_item "Fair CRM KYROX_CORE_BASE_URL is ${fair_core_url} (expected http://127.0.0.1:8000)"
  fi
}

ensure_python_venv() {
  local venv_dir="$1"
  if [[ ! -d "${venv_dir}/bin" ]]; then
    log "Creating venv at ${venv_dir}"
    python3 -m venv "${venv_dir}"
  fi
}

pip_install_requirements() {
  local venv_dir="$1"
  local requirements_file="$2"
  [[ -f "$requirements_file" ]] || die "requirements.txt not found: ${requirements_file}"
  "${venv_dir}/bin/pip" install --upgrade pip wheel
  "${venv_dir}/bin/pip" install -r "$requirements_file"
}

install_playwright_chromium() {
  local fair_crm_dir="${1:-${FAIR_CRM_DIR}}"
  local venv_python="${fair_crm_dir}/backend/.venv/bin/python"

  step "Install Playwright Chromium (browser + OS deps)"
  [[ -x "$venv_python" ]] || die "Fair CRM venv missing: ${venv_python}"

  # Idempotent: re-running succeeds when Chromium and deps are already present.
  if ! "$venv_python" -m playwright install --with-deps chromium; then
    die "Playwright Chromium install failed (${venv_python} -m playwright install --with-deps chromium)"
  fi
}

check_playwright_chromium() {
  local fair_crm_dir="${1:-${FAIR_CRM_DIR}}"
  local venv_python="${fair_crm_dir}/backend/.venv/bin/python"
  local label="Playwright Chromium headless launch"
  local err_file detail

  if [[ ! -x "$venv_python" ]]; then
    check_fail "${label} (venv missing: ${venv_python})"
    return 0
  fi

  err_file="$(mktemp)"
  if "$venv_python" - <<'PY' >"${err_file}" 2>&1
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    page.set_content("<title>FAIR CRM Playwright Check</title>")
    assert page.title() == "FAIR CRM Playwright Check"
    browser.close()
PY
  then
    rm -f "$err_file"
    check_pass "${label}"
    return 0
  fi

  # Prefer the actionable Playwright/import error line over a full traceback prefix.
  detail="$(
    grep -E 'BrowserType\.|Executable doesn|ModuleNotFoundError|ImportError|Error:|No module named' "$err_file" \
      | tail -n 1 \
      || true
  )"
  if [[ -z "$detail" ]]; then
    detail="$(tr '\n' ' ' <"$err_file" | sed 's/[[:space:]]\+/ /g')"
  fi
  detail="$(printf '%s' "$detail" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  detail="${detail:0:300}"
  rm -f "$err_file"
  check_fail "${label} (${detail:-unknown error})"
}

resolve_requirements_file() {
  local project_dir="$1"
  if [[ -f "${project_dir}/requirements.txt" ]]; then
    printf '%s\n' "${project_dir}/requirements.txt"
    return 0
  fi
  if [[ -f "${project_dir}/backend/requirements.txt" ]]; then
    printf '%s\n' "${project_dir}/backend/requirements.txt"
    return 0
  fi
  return 1
}

alembic_pythonpath() {
  local project_root="$1"
  if [[ -d "${project_root}/backend" ]]; then
    printf '%s\n' "${project_root}/backend"
  else
    printf '%s\n' "${project_root}"
  fi
}

run_alembic_upgrade() {
  local project_root="$1"
  local venv_python="$2"
  local alembic_ini="${3:-alembic.ini}"
  local database_url="${4:-}"
  local pythonpath
  pythonpath="$(alembic_pythonpath "$project_root")"

  step "Alembic upgrade head in ${project_root}"
  if [[ -f "${project_root}/${alembic_ini}" ]]; then
    local -a env_args=()
    if [[ -n "$database_url" ]]; then
      env_args+=(DATABASE_URL="$database_url")
    fi
    (
      cd "$project_root"
      env "${env_args[@]}" PYTHONPATH="$pythonpath" \
        "$venv_python" -m alembic -c "$alembic_ini" upgrade head
    )
    return $?
  fi

  log "No ${alembic_ini} in ${project_root}; running programmatic alembic"
  (
    cd "$project_root"
    env PYTHONPATH="${project_root}/backend" \
      "$venv_python" - <<'PY'
from alembic.config import Config
from alembic import command
from pathlib import Path

root = Path.cwd()
cfg = Config()
cfg.set_main_option("script_location", str(root / "backend" / "alembic"))
cfg.set_main_option("prepend_sys_path", str(root / "backend"))
command.upgrade(cfg, "head")
PY
  )
}

alembic_revision_snapshot() {
  local project_root="$1"
  local venv_python="$2"
  local database_url="$3"
  local mode="$4"

  if [[ ! -x "$venv_python" ]]; then
    printf '%s\n' "missing-venv"
    return 0
  fi

  local alembic_cfg_dir="$project_root"
  local pythonpath
  pythonpath="$(alembic_pythonpath "$project_root")"
  if [[ ! -f "${project_root}/alembic.ini" && -f "${project_root}/backend/alembic.ini" ]]; then
    alembic_cfg_dir="${project_root}/backend"
    pythonpath="${project_root}/backend"
  fi
  local alembic_ini="${alembic_cfg_dir}/alembic.ini"
  local -a env_args=(PYTHONPATH="$pythonpath")
  if [[ -n "$database_url" ]]; then
    env_args+=(DATABASE_URL="$database_url")
  fi

  if [[ -f "$alembic_ini" ]]; then
    (
      cd "$alembic_cfg_dir"
      env "${env_args[@]}" "$venv_python" -m alembic -c alembic.ini "$mode" 2>/dev/null || true
    )
    return 0
  fi

  (
    cd "$project_root"
    env "${env_args[@]}" "$venv_python" - <<PY
from alembic.config import Config
from alembic import command
from pathlib import Path

root = Path.cwd()
cfg = Config()
cfg.set_main_option("script_location", str(root / "backend" / "alembic"))
cfg.set_main_option("prepend_sys_path", str(root / "backend"))
command.${mode}(cfg)
PY
  ) 2>/dev/null || true
}

alembic_pick_revision() {
  tr -d '\r' | grep -oE '[0-9]{8}_[0-9]{4}[^ ]*|[0-9]{4}(_[0-9]{4})?' | tail -n 1
}

alembic_revision_meets_minimum() {
  local current="$1"
  local minimum="$2"
  [[ -n "$current" && -n "$minimum" ]] || return 1
  [[ "$current" == "$minimum" || "$current" > "$minimum" ]]
}

assert_core_migration_meets_seed_minimum() {
  local project_root="$1"
  local venv_python="$2"
  local database_url="$3"
  local minimum="${4:-$MIN_CORE_SEED_MIGRATION_REVISION}"

  step "Verify Core migration meets seed minimum (${minimum})"
  local current
  current="$(alembic_revision_snapshot "$project_root" "$venv_python" "$database_url" "current" | alembic_pick_revision)"
  [[ -n "$current" ]] || die "Cannot read Core alembic current revision after upgrade"

  if alembic_revision_meets_minimum "$current" "$minimum"; then
    log "Core migration OK: ${current} (required >= ${minimum})"
    return 0
  fi

  die "Core migration ${current} is below required ${minimum} for dev seed. Update kyrox-core main to include migration ${minimum} and re-run deploy."
}

check_core_migration_meets_seed_minimum() {
  local project_root="$1"
  local venv_python="$2"
  local database_url="$3"
  local minimum="${4:-$MIN_CORE_SEED_MIGRATION_REVISION}"
  local current

  current="$(alembic_revision_snapshot "$project_root" "$venv_python" "$database_url" "current" | alembic_pick_revision)"
  if [[ -z "$current" ]]; then
    check_fail "Core migration meets seed minimum ${minimum}"
    return 0
  fi

  if alembic_revision_meets_minimum "$current" "$minimum"; then
    check_pass "Core migration meets seed minimum (${current} >= ${minimum})"
  else
    check_fail "Core migration meets seed minimum (current=${current}, required>=${minimum})"
  fi
}

check_git_branch() {
  local label="$1"
  local dir="$2"
  local expected_branch="$3"

  if [[ ! -d "${dir}/.git" ]]; then
    check_fail "${label} git branch ${expected_branch:-origin-default}"
    return 0
  fi

  if [[ -z "$expected_branch" ]]; then
    expected_branch="$(read_origin_default_branch "$dir" || true)"
    if [[ -z "$expected_branch" ]]; then
      check_fail "${label} git branch origin-default (unresolved)"
      return 0
    fi
  fi

  local current_branch
  current_branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$current_branch" == "$expected_branch" ]]; then
    check_pass "${label} git branch ${expected_branch}"
  else
    check_fail "${label} git branch ${expected_branch} (current=${current_branch:-unknown})"
  fi
}

check_fair_crm_server_scripts_executable() {
  local dir="$1"
  local rel script_path
  local -a missing=() not_exec=()

  for rel in "${FAIR_CRM_SERVER_EXECUTABLE_SCRIPTS[@]}"; do
    script_path="${dir}/${rel}"
    if [[ ! -f "$script_path" ]]; then
      missing+=("$rel")
    elif [[ ! -x "$script_path" ]]; then
      not_exec+=("$rel")
    fi
  done

  if ((${#missing[@]} == 0 && ${#not_exec[@]} == 0)); then
    check_pass "Server deploy scripts executable"
    return 0
  fi

  if ((${#missing[@]} > 0)); then
    check_fail "Server deploy scripts executable (missing: ${missing[*]})"
  fi
  if ((${#not_exec[@]} > 0)); then
    check_fail "Server deploy scripts executable (not executable: ${not_exec[*]})"
  fi
}

fetch_dev_access_token() {
  local core_port="${1:-8000}"
  local url="http://127.0.0.1:${core_port}/api/v1/auth/login"
  local tmp_body tmp_payload tmp_curl_err
  local http_code curl_rc=0 body_preview parse_detail parse_rc=0
  local attempt max_attempts=5

  require_dev_login_password

  tmp_body="$(mktemp -t dev-access-token-body.XXXXXX)"
  tmp_payload="$(mktemp -t dev-access-token-payload.XXXXXX)"
  tmp_curl_err="$(mktemp -t dev-access-token-curl.XXXXXX)"

  export DEV_LOGIN_EMAIL DEV_LOGIN_PASSWORD
  python3 -c 'import json, os, sys; json.dump({"email": os.environ["DEV_LOGIN_EMAIL"], "password": os.environ["DEV_LOGIN_PASSWORD"]}, sys.stdout)' \
    >"$tmp_payload"

  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    : >"$tmp_body"
    : >"$tmp_curl_err"
    curl_rc=0
    http_code="$(
      curl -sS -o "$tmp_body" -w '%{http_code}' -X POST "$url" \
        -H "Content-Type: application/json" \
        --data-binary "@${tmp_payload}" \
        --connect-timeout 10 --max-time 30 2>"$tmp_curl_err"
    )" || curl_rc=$?

    if [[ "$curl_rc" -ne 0 || -z "$http_code" || "$http_code" == "000" || "$http_code" != "200" || ! -s "$tmp_body" ]]; then
      if [[ "$attempt" -lt "$max_attempts" ]]; then
        sleep 2
        continue
      fi
      rm -f "$tmp_body" "$tmp_payload" "$tmp_curl_err"
      return 1
    fi

    parse_rc=0
    parse_detail="$(
      python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
token = data.get("access_token")
if not token:
    raise SystemExit(1)
print(token)
' "$tmp_body" 2>&1
    )" || parse_rc=$?

    if [[ "$parse_rc" -eq 0 && -n "$parse_detail" ]]; then
      printf '%s' "$parse_detail"
      rm -f "$tmp_body" "$tmp_payload" "$tmp_curl_err"
      return 0
    fi

    if [[ "$attempt" -lt "$max_attempts" ]]; then
      sleep 2
      continue
    fi
  done

  rm -f "$tmp_body" "$tmp_payload" "$tmp_curl_err"
  return 1
}

run_admin_backups_smoke_test() {
  local fair_port="${1:-8001}"
  local core_port="${2:-8000}"
  local fail_mode="${3:-check}"
  local token http_code body_preview
  local url="http://127.0.0.1:${fair_port}/api/v1/admin/backups"
  local tmp_body tmp_curl_err

  token="$(fetch_dev_access_token "$core_port" 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    if [[ "$fail_mode" != "deploy" ]]; then
      check_fail "Admin backups API authorized (could not obtain dev access token)"
    fi
    return 1
  fi

  tmp_body="$(mktemp -t admin-backups-body.XXXXXX)"
  tmp_curl_err="$(mktemp -t admin-backups-curl.XXXXXX)"
  http_code="$(
    curl -sS -o "$tmp_body" -w '%{http_code}' -X GET "$url" \
      -H "Authorization: Bearer ${token}" \
      -H "X-Organization-Id: ${DEV_LOGIN_ORG_ID}" \
      --connect-timeout 10 --max-time 30 2>"$tmp_curl_err"
  )" || http_code="000"

  body_preview="$(tr -d '\n\r' <"$tmp_body" 2>/dev/null | head -c 300)"
  [[ -n "$body_preview" ]] || body_preview="empty"
  rm -f "$tmp_body" "$tmp_curl_err"

  if [[ "$http_code" == "200" ]]; then
    if [[ "$fail_mode" != "deploy" ]]; then
      check_pass "Admin backups API authorized (HTTP 200)"
    fi
    return 0
  fi

  if [[ "$fail_mode" != "deploy" ]]; then
    check_fail "Admin backups API authorized (HTTP ${http_code:-000}, body=${body_preview})"
  fi
  return 1
}

require_fair_stand_source_for_crm_build() {
  local mount="${FAIR_STAND_DIR}/src/mountFairStand.js"
  if [[ ! -f "$mount" ]]; then
    die "Production Fair CRM frontend build requires ${mount}; Vite CI fallback is not accepted on the server"
  fi
  log "Fair Stand source for CRM build: ${mount}"
}

check_fair_stand_repo() {
  local dir="${1:-$FAIR_STAND_DIR}"
  local expected_branch="${2:-$EXPECTED_FAIR_STAND_BRANCH}"

  if [[ -d "${dir}/.git" ]]; then
    check_pass "Fair Stand repo present (${dir})"
  else
    check_fail "Fair Stand repo present (${dir})"
    return 0
  fi

  check_git_branch "fair-stand" "$dir" "$expected_branch"

  local dirty
  dirty="$(git -C "$dir" status --porcelain 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    check_fail "Fair Stand repo clean/deployment-compatible"
  else
    check_pass "Fair Stand repo clean/deployment-compatible"
  fi

  if [[ -f "${dir}/package.json" ]]; then
    check_pass "Fair Stand package.json present"
  else
    check_fail "Fair Stand package.json present"
  fi

  if [[ -f "${dir}/src/mountFairStand.js" ]]; then
    check_pass "Fair Stand source integration (src/mountFairStand.js)"
  else
    check_fail "Fair Stand source integration (src/mountFairStand.js)"
  fi

  if [[ -f "${dir}/package-lock.json" && -d "${dir}/node_modules" ]]; then
    check_pass "Fair Stand dependency install"
  else
    check_fail "Fair Stand dependency install (npm ci / node_modules)"
  fi

  if [[ -x "${dir}/backend/.venv/bin/python" ]]; then
    check_pass "Fair Stand virtualenv present"
  else
    check_fail "Fair Stand virtualenv present"
  fi

  local sha
  sha="$(git_head_sha "$dir")"
  if [[ -n "$sha" && "$sha" != "n/a" && "$sha" != "unknown" ]]; then
    check_pass "Fair Stand commit ${sha}"
  else
    check_fail "Fair Stand commit readable"
  fi
}

check_fair_stand_spa_host() {
  local url="http://127.0.0.1/fair-stand"
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
        "$url" 2>/dev/null || echo "000"
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
    status="$(http_status "$url")"
  fi

  if [[ "$status" =~ ^(200|301|302|303|307|308)$ ]]; then
    check_pass "Fair Stand SPA host HTTP ${status} (index/host only; Host=${domain:-127.0.0.1})"
  else
    check_warn_item "Fair Stand SPA host HTTP ${status} at ${url} (Host=${domain:-127.0.0.1})"
  fi
}

run_fair_stand_catalog_bootstrap_smoke() {
  local fair_port="${1:-8001}"
  local core_port="${2:-8000}"
  local fail_mode="${3:-check}"
  local token http_code parse_rc=0 parse_detail=""
  local url="http://127.0.0.1:${fair_port}/api/v1/fair-stand/catalog/bootstrap"
  local tmp_body tmp_curl_err

  token="$(fetch_dev_access_token "$core_port" 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    if [[ "$fail_mode" != "deploy" ]]; then
      check_fail "Fair Stand catalog bootstrap (could not obtain dev access token)"
    fi
    return 1
  fi

  tmp_body="$(mktemp -t fair-stand-bootstrap-body.XXXXXX)"
  tmp_curl_err="$(mktemp -t fair-stand-bootstrap-curl.XXXXXX)"
  http_code="$(
    curl -sS -o "$tmp_body" -w '%{http_code}' -X GET "$url" \
      -H "Authorization: Bearer ${token}" \
      -H "X-Organization-Id: ${DEV_LOGIN_ORG_ID}" \
      --connect-timeout 10 --max-time 30 2>"$tmp_curl_err"
  )" || http_code="000"

  if [[ "$http_code" != "200" ]]; then
    local body_preview
    body_preview="$(tr -d '\n\r' <"$tmp_body" 2>/dev/null | head -c 300)"
    rm -f "$tmp_body" "$tmp_curl_err"
    if [[ "$fail_mode" != "deploy" ]]; then
      check_fail "Fair Stand catalog bootstrap (HTTP ${http_code:-000}, body=${body_preview:-empty})"
    fi
    return 1
  fi

  parse_detail="$(
    python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
missing = [key for key in ("categories", "items", "previewKinds") if not isinstance(data.get(key), list)]
if missing:
    raise SystemExit("missing_or_not_array=" + ",".join(missing))
print("ok")
' "$tmp_body" 2>&1
  )" || parse_rc=$?

  rm -f "$tmp_body" "$tmp_curl_err"

  if [[ "$parse_rc" -ne 0 ]]; then
    if [[ "$fail_mode" != "deploy" ]]; then
      check_fail "Fair Stand catalog bootstrap payload (${parse_detail:-invalid json})"
    fi
    return 1
  fi

  if [[ "$fail_mode" != "deploy" ]]; then
    check_pass "Fair Stand catalog bootstrap (HTTP 200, categories/items/previewKinds arrays)"
  fi
  return 0
}

check_alembic_at_head() {
  local label="$1"
  local project_root="$2"
  local venv_python="$3"
  local database_url="$4"

  if [[ ! -d "$project_root" ]]; then
    check_warn_item "migration:${label}" "project directory missing"
    return 0
  fi

  local current heads
  current="$(alembic_revision_snapshot "$project_root" "$venv_python" "$database_url" "current" | alembic_pick_revision)"
  heads="$(alembic_revision_snapshot "$project_root" "$venv_python" "" "heads" | alembic_pick_revision)"

  if [[ -z "$current" || "$current" == "missing-venv" ]]; then
    check_fail "${label} migration at head (could not read alembic current)"
    return 0
  fi
  if [[ -z "$heads" ]]; then
    check_warn_item "${label} migration heads readable"
    return 0
  fi

  if [[ "$current" == "$heads" ]]; then
    check_pass "${label} migration at head (${current})"
  else
    check_fail "${label} migration at head (current=${current}, head=${heads})"
  fi
}

escape_sed_replacement() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//|/\\|}"
  value="${value//&/\\&}"
  printf '%s' "$value"
}

resolve_deploy_service_user() {
  local user="${DEPLOY_SERVICE_USER:-}"

  if [[ -z "$user" && -n "${SUDO_USER:-}" ]]; then
    user="$SUDO_USER"
  fi
  if [[ -z "$user" && -n "${SUDO_UID:-}" ]]; then
    user="$(getent passwd "$SUDO_UID" 2>/dev/null | cut -d: -f1 || true)"
  fi
  if [[ -z "$user" ]]; then
    user="$(id -un 2>/dev/null || true)"
  fi

  [[ -n "$user" ]] || die "Cannot resolve DEPLOY_SERVICE_USER for systemd units"
  if ! getent passwd "$user" >/dev/null 2>&1; then
    die "DEPLOY_SERVICE_USER '${user}' does not exist on this system"
  fi

  DEPLOY_SERVICE_USER="$user"
}

normalize_template_output() {
  local file="$1"
  if grep -q $'\r' "$file" 2>/dev/null; then
    tr -d '\r' <"$file" >"${file}.tmp"
    mv "${file}.tmp" "$file"
  fi
}

render_template() {
  local template="$1"
  local output="$2"
  local service_user core_dir fair_dir stand_dir
  local -a tokens=(
    DEPLOY_SERVICE_USER
    KYROX_CORE_DIR
    FAIR_CRM_DIR
    FAIR_STAND_DIR
  )
  local token value escaped pattern

  [[ -f "$template" ]] || die "Template missing: ${template}"

  resolve_deploy_service_user
  core_dir="${KYROX_CORE_DIR:-${KYROX_ROOT}/kyrox-core}"
  fair_dir="${FAIR_CRM_DIR:-${KYROX_ROOT}/kyrox-fair-crm}"
  stand_dir="${FAIR_STAND_DIR:-${KYROX_ROOT}/kyrox-fair-stand}"
  service_user="$DEPLOY_SERVICE_USER"

  [[ -n "$core_dir" && -n "$fair_dir" && -n "$stand_dir" ]] \
    || die "Template render requires KYROX_CORE_DIR, FAIR_CRM_DIR and FAIR_STAND_DIR"

  cp "$template" "$output"

  for token in "${tokens[@]}"; do
    case "$token" in
      DEPLOY_SERVICE_USER) value="$service_user" ;;
      KYROX_CORE_DIR) value="$core_dir" ;;
      FAIR_CRM_DIR) value="$fair_dir" ;;
      FAIR_STAND_DIR) value="$stand_dir" ;;
      *) die "Unknown template token: ${token}" ;;
    esac
    escaped="$(escape_sed_replacement "$value")"
    for pattern in "__${token}__" "@${token}@"; do
      sed -i "s|${pattern}|${escaped}|g" "$output"
    done
  done

  normalize_template_output "$output"
}

assert_rendered_systemd_unit() {
  local unit_file="$1"
  local label="${2:-systemd unit}"

  [[ -f "$unit_file" ]] || die "${label} missing after render: ${unit_file}"

  if grep -Eq '@(DEPLOY_SERVICE_USER|KYROX_CORE_DIR|FAIR_CRM_DIR|FAIR_STAND_DIR)@|__(DEPLOY_SERVICE_USER|KYROX_CORE_DIR|FAIR_CRM_DIR|FAIR_STAND_DIR)__' "$unit_file"; then
    die "${label} has unreplaced template placeholders"
  fi

  local unit_user unit_group
  unit_user="$(grep -E '^User=' "$unit_file" | head -n1 | cut -d= -f2- || true)"
  unit_group="$(grep -E '^Group=' "$unit_file" | head -n1 | cut -d= -f2- || true)"
  [[ -n "$unit_user" ]] || die "${label} is missing User="
  [[ -n "$unit_group" ]] || die "${label} is missing Group="
  getent passwd "$unit_user" >/dev/null 2>&1 || die "${label} User=${unit_user} is not a valid system user"
  getent group "$unit_group" >/dev/null 2>&1 || die "${label} Group=${unit_group} is not a valid system group"

  if command -v systemd-analyze >/dev/null 2>&1; then
    local verify_out verify_rc=0
    verify_out="$(systemd-analyze verify "$unit_file" 2>&1)" || verify_rc=$?
    if [[ "$verify_rc" -ne 0 ]]; then
      die "${label} failed systemd-analyze verify: ${verify_out}"
    fi
  fi
}

install_systemd_unit() {
  local rendered_unit="$1"
  local service_name="$2"
  local dest="/etc/systemd/system/${service_name}"
  step "Install systemd unit ${service_name}"
  [[ -f "$rendered_unit" ]] || die "Rendered systemd unit missing: ${rendered_unit}"
  assert_rendered_systemd_unit "$rendered_unit" "${service_name}"
  if [[ "${EUID}" -ne 0 ]]; then
    warn "Not running as root; skipping systemd install for ${service_name}"
    return 0
  fi
  cp "$rendered_unit" "$dest"
  chmod 644 "$dest"
}

check_systemd_service() {
  local service="$1"
  local label="$2"
  if ! command -v systemctl >/dev/null 2>&1; then
    check_warn_item "${label} service active"
    return 0
  fi
  if ! systemctl list-unit-files "${service}" >/dev/null 2>&1; then
    check_fail "${label} service active"
    return 0
  fi
  local active enabled
  active="$(systemctl is-active "${service}" 2>/dev/null || echo unknown)"
  enabled="$(systemctl is-enabled "${service}" 2>/dev/null || echo unknown)"
  if [[ "$active" == "active" && "$enabled" == "enabled" ]]; then
    check_pass "${label} service active"
  elif [[ "$active" == "active" ]]; then
    check_warn_item "${label} service enabled (enabled=${enabled})"
  else
    check_fail "${label} service active (active=${active}, enabled=${enabled})"
  fi
}

parse_compose_postgres() {
  local compose_file="$1"
  COMPOSE_PG_USER="postgres"
  COMPOSE_PG_PASS="postgres"
  COMPOSE_PG_PORT="5432"
  COMPOSE_PG_CONTAINER=""

  [[ -f "$compose_file" ]] || return 0

  local user_line pass_line port_line container_line
  user_line="$(grep -E 'POSTGRES_USER:' "$compose_file" | head -n 1 || true)"
  pass_line="$(grep -E 'POSTGRES_PASSWORD:' "$compose_file" | head -n 1 || true)"
  port_line="$(grep -E '^[[:space:]]*-[[:space:]]*"(127\.0\.0\.1:)?[0-9]+:5432"' "$compose_file" | head -n 1 || true)"
  container_line="$(grep -E 'container_name:' "$compose_file" | head -n 1 || true)"

  if [[ -n "$user_line" ]]; then
    COMPOSE_PG_USER="$(echo "$user_line" | sed -E 's/.*POSTGRES_USER:[[:space:]]*//; s/[[:space:]]+$//')"
  fi
  if [[ -n "$pass_line" ]]; then
    COMPOSE_PG_PASS="$(echo "$pass_line" | sed -E 's/.*POSTGRES_PASSWORD:[[:space:]]*//; s/[[:space:]]+$//')"
  fi
  if [[ -n "$port_line" ]]; then
    COMPOSE_PG_PORT="$(echo "$port_line" | sed -E 's/.*"(127\.0\.0\.1:)?([0-9]+):5432".*/\2/')"
  fi
  if [[ -n "$container_line" ]]; then
    COMPOSE_PG_CONTAINER="$(echo "$container_line" | sed -E 's/.*container_name:[[:space:]]*//; s/[[:space:]]+$//')"
  fi
}

ensure_compose_localhost_postgres_bind() {
  local fair_dir="$1"
  local compose_file="${fair_dir}/docker-compose.yml"
  [[ -f "$compose_file" ]] || return 1

  if grep -qE '^[[:space:]]*-[[:space:]]*"127\.0\.0\.1:5432:5432"' "$compose_file"; then
    log "Postgres compose port already bound to 127.0.0.1:5432"
    return 1
  fi

  if grep -qE '^[[:space:]]*-[[:space:]]*"(5432:5432|0\.0\.0\.0:5432:5432)"' "$compose_file"; then
    step "Patch docker-compose Postgres port to 127.0.0.1:5432 (localhost only)"
    sed -i.bak -E 's/"5432:5432"/"127.0.0.1:5432:5432"/; s/"0\.0\.0\.0:5432:5432"/"127.0.0.1:5432:5432"/' "$compose_file"
    rm -f "${compose_file}.bak"
    log "Updated ${compose_file} Postgres binding to 127.0.0.1:5432"
    return 0
  fi

  warn "Postgres port mapping in ${compose_file} is custom; expected 127.0.0.1:5432:5432"
  return 1
}

ensure_postgres_container() {
  local fair_dir="$1"
  local compose_file="${fair_dir}/docker-compose.yml"
  if [[ ! -f "$compose_file" ]]; then
    warn "No docker-compose.yml at ${compose_file}; assuming external PostgreSQL"
    return 0
  fi
  require_cmd docker
  local recreate=0
  if ensure_compose_localhost_postgres_bind "$fair_dir"; then
    recreate=1
  fi
  step "Ensure Postgres container is up (docker compose; local compose file preserved)"
  (
    cd "$fair_dir"
    if [[ "$recreate" -eq 1 ]]; then
      docker compose up -d postgres --force-recreate
    else
      docker compose up -d postgres
    fi
  )
}

check_docker_postgres() {
  local fair_dir="$1"
  local compose_file="${fair_dir}/docker-compose.yml"
  if [[ ! -f "$compose_file" ]]; then
    check_warn_item "PostgreSQL container running (external DB assumed)"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    check_fail "Docker installed"
    return 0
  fi
  check_pass "Docker installed"

  if ! run_root systemctl is-active docker >/dev/null 2>&1; then
    check_fail "Docker service active"
    return 0
  fi
  check_pass "Docker service active"

  parse_compose_postgres "$compose_file"
  local container="${COMPOSE_PG_CONTAINER:-kyrox-db}"
  if docker ps --format '{{.Names}}' | grep -qx "$container"; then
    check_pass "PostgreSQL container running"
  else
    check_fail "PostgreSQL container running"
  fi
}

psql_admin_exec() {
  local sql="$1"
  PGPASSWORD="${PG_PASS}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -v ON_ERROR_STOP=1 -c "$sql"
}

database_exists() {
  local db_name="$1"
  local count
  count="$(PGPASSWORD="${PG_PASS}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -tAc \
    "SELECT COUNT(*) FROM pg_database WHERE datname='${db_name}'" 2>/dev/null || echo 0)"
  [[ "${count}" == "1" ]]
}

ensure_database() {
  local db_name="$1"
  if database_exists "$db_name"; then
    log "Database exists: ${db_name} (no drop/truncate/reset)"
  else
    log "Creating database: ${db_name}"
    psql_admin_exec "CREATE DATABASE \"${db_name}\";"
  fi
}

ensure_repo_data_dirs() {
  local fair_dir="$1"
  step "Ensure backup/restore data directories exist (create only; never delete contents)"
  local dir
  for dir in \
    "${fair_dir}/backups" \
    "${fair_dir}/data/restore_uploads" \
    "${fair_dir}/data/restore_logs"; do
    if [[ -d "$dir" ]]; then
      log "Preserving existing data directory: ${dir}"
    else
      mkdir -p "$dir"
      warn "Created empty data directory: ${dir}"
    fi
  done
}

check_database_exists() {
  local db_name="$1"
  if database_exists "$db_name"; then
    check_pass "${db_name} DB exists"
  else
    check_fail "${db_name} DB exists"
  fi
}

resolve_postgres_connection() {
  local fair_dir="$1"
  local core_dir="$2"
  step "Resolve PostgreSQL connection settings"
  parse_compose_postgres "${fair_dir}/docker-compose.yml"

  PG_HOST="127.0.0.1"
  PG_PORT="${COMPOSE_PG_PORT}"
  PG_USER="${COMPOSE_PG_USER}"
  PG_PASS="${COMPOSE_PG_PASS}"

  local fair_env="${fair_dir}/backend/.env"
  local core_env="${core_dir}/backend/.env"
  local fair_db_url core_db_url

  if [[ -f "$fair_env" ]]; then
    fair_db_url="$(read_env_key "$fair_env" DATABASE_URL || read_env_key "$fair_env" FAIR_CRM_DATABASE_URL || true)"
  fi
  if [[ -f "$core_env" ]]; then
    core_db_url="$(read_env_key "$core_env" DATABASE_URL || read_env_key "$core_env" KYROX_CORE_DATABASE_URL || true)"
  fi

  if [[ -n "${fair_db_url:-}" ]]; then
    eval "$(parse_database_url "$fair_db_url")"
    log "Postgres settings from Fair CRM .env (host=${PG_HOST} port=${PG_PORT} user=${PG_USER})"
  elif [[ -n "${core_db_url:-}" ]]; then
    eval "$(parse_database_url "$core_db_url")"
    log "Postgres settings from Core .env (host=${PG_HOST} port=${PG_PORT} user=${PG_USER})"
  else
    log "Postgres settings from docker-compose defaults (host=${PG_HOST} port=${PG_PORT} user=${PG_USER})"
  fi
}

check_postgres_connectivity() {
  if PGPASSWORD="${PG_PASS}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    check_pass "PostgreSQL reachable at ${PG_HOST}:${PG_PORT}"
  else
    check_fail "PostgreSQL reachable at ${PG_HOST}:${PG_PORT}"
  fi
}

install_apt_packages() {
  step "Install OS packages (apt)"
  require_cmd apt-get
  run_root apt-get update -qq
  run_root apt-get install -y -qq \
    ca-certificates curl git gnupg \
    nginx postgresql-client ufw \
    python3 python3-pip python3-venv
}

ensure_nodejs() {
  step "Ensure Node.js >= ${REQUIRED_NODEJS_VERSION}"
  local current
  current="$(get_installed_node_version)"
  if [[ -n "$current" ]] && node_version_meets_minimum "$current" "$REQUIRED_NODEJS_VERSION"; then
    log "Node.js ${current} already satisfies >= ${REQUIRED_NODEJS_VERSION} (npm $(npm --version 2>/dev/null || echo '?'))"
    return 0
  fi

  if [[ -n "$current" ]]; then
    log "Node.js ${current} is below required ${REQUIRED_NODEJS_VERSION}; installing Node.js ${NODEJS_MAJOR_CHANNEL}.x"
  else
    log "Node.js not found; installing Node.js ${NODEJS_MAJOR_CHANNEL}.x"
  fi

  install_nodejs_from_nodesource
  hash -r 2>/dev/null || true

  current="$(get_installed_node_version)"
  if [[ -z "$current" ]] || ! node_version_meets_minimum "$current" "$REQUIRED_NODEJS_VERSION"; then
    die "Node.js >= ${REQUIRED_NODEJS_VERSION} required after install; found: ${current:-missing}"
  fi
  require_cmd npm
  log "Node.js ${current}, npm $(npm --version)"
}

# Normalize versions like "v22.12.0", "22.12.0-rc.1" -> "22.12.0"
normalize_node_version() {
  local v="${1:-}"
  v="${v#v}"
  v="${v%%[-+]*}"
  printf '%s' "$v"
}

# Return 0 when current >= required (sort -V).
node_version_meets_minimum() {
  local current required
  current="$(normalize_node_version "${1:-}")"
  required="$(normalize_node_version "${2:-$REQUIRED_NODEJS_VERSION}")"
  [[ -n "$current" && -n "$required" ]] || return 1
  [[ "$(printf '%s\n' "$required" "$current" | sort -V | head -n1)" == "$required" ]]
}

get_installed_node_version() {
  if ! command -v node >/dev/null 2>&1; then
    return 0
  fi
  node --version 2>/dev/null || true
}

install_nodejs_from_nodesource() {
  require_cmd apt-get
  require_cmd curl
  require_cmd gpg

  run_root mkdir -p /etc/apt/keyrings
  # Non-interactive, idempotent NodeSource apt repo for Node 22.x
  run_root bash -c "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor --batch --yes -o /etc/apt/keyrings/nodesource.gpg
    chmod a+r /etc/apt/keyrings/nodesource.gpg
    printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' \
      '${NODEJS_MAJOR_CHANNEL}' > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq
    apt-get install -y -qq nodejs
  "
}

check_nodejs_runtime() {
  local current
  current="$(get_installed_node_version)"
  if [[ -z "$current" ]]; then
    check_fail "Node.js version (required >=${REQUIRED_NODEJS_VERSION})"
  elif node_version_meets_minimum "$current" "$REQUIRED_NODEJS_VERSION"; then
    check_pass "Node.js version ${current} (required >=${REQUIRED_NODEJS_VERSION})"
  else
    check_fail "Node.js version ${current} (required >=${REQUIRED_NODEJS_VERSION})"
  fi

  if command -v npm >/dev/null 2>&1; then
    check_pass "npm installed ($(npm --version 2>/dev/null || echo unknown))"
  else
    check_fail "npm installed"
  fi
}

ensure_docker() {
  step "Ensure Docker Engine + compose plugin"
  if ! command -v docker >/dev/null 2>&1; then
    require_cmd apt-get
    run_root apt-get update -qq
    run_root apt-get install -y -qq docker.io docker-compose-v2 \
      || run_root apt-get install -y -qq docker.io docker-compose-plugin
  fi
  run_root systemctl enable docker
  run_root systemctl start docker
  if id -nG "${DEPLOY_SERVICE_USER}" 2>/dev/null | grep -qw docker; then
    log "User ${DEPLOY_SERVICE_USER} already in docker group"
  else
    run_root usermod -aG docker "${DEPLOY_SERVICE_USER}"
    warn "Added ${DEPLOY_SERVICE_USER} to docker group — re-login required for non-root docker"
  fi
}

ensure_ufw_firewall() {
  step "Configure UFW firewall (SSH + HTTP public; API/DB local only)"
  if ! command -v ufw >/dev/null 2>&1; then
    require_cmd apt-get
    run_root apt-get install -y -qq ufw
  fi
  run_root ufw allow OpenSSH
  run_root ufw allow 80/tcp comment 'Fair CRM nginx'
  if ufw status 2>/dev/null | grep -q "Status: inactive"; then
    run_root ufw --force enable
  fi
  log "UFW rules: OpenSSH + 80/tcp (8000/8001/5432 not opened)"
}

check_firewall_rules() {
  if ! command -v ufw >/dev/null 2>&1; then
    check_warn_item "UFW installed"
    return 0
  fi
  local status
  status="$(ufw status 2>/dev/null || true)"
  if grep -q "Status: active" <<<"$status"; then
    check_pass "UFW active"
  else
    check_warn_item "UFW active"
  fi

  if grep -E '(22/tcp|OpenSSH).*ALLOW|22.*ALLOW' <<<"$status" >/dev/null; then
    check_pass "22 allowed"
  else
    check_warn_item "22 allowed"
  fi

  if grep -E '80/tcp.*ALLOW|80.*ALLOW' <<<"$status" >/dev/null; then
    check_pass "80 allowed"
  else
    check_warn_item "80 allowed"
  fi

  if grep -E '443/tcp.*ALLOW|443.*ALLOW' <<<"$status" >/dev/null; then
    check_pass "443 allowed"
  else
    check_warn_item "443 not configured"
  fi

  local port
  for port in 5432 8000 8001 8002; do
    if grep -E "${port}/tcp" <<<"$status" | grep -q ALLOW; then
      check_fail "${port} not publicly exposed"
    else
      check_pass "${port} not publicly exposed"
    fi
  done
}

check_required_commands() {
  local cmd
  for cmd in git python3 curl psql docker nginx node npm; do
    if command -v "$cmd" >/dev/null 2>&1; then
      check_pass "${cmd} installed"
    else
      if [[ "$cmd" == "git" || "$cmd" == "python3" || "$cmd" == "curl" || "$cmd" == "psql" ]]; then
        check_fail "${cmd} installed"
      else
        check_warn_item "${cmd} installed"
      fi
    fi
  done
}

get_port_listeners() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p "$" { print $4 }'
    return 0
  fi
  return 1
}

check_port_binding_local_only() {
  local port="$1"
  local label="$2"
  local listeners
  listeners="$(get_port_listeners "$port" | paste -sd ',' - || true)"

  if [[ -z "$listeners" ]]; then
    check_fail "${label} binding 127.0.0.1:${port}"
    return 0
  fi

  if grep -qE '(0\.0\.0\.0|\[::\]):'"${port}" <<<"$listeners"; then
    if [[ "$label" == "PostgreSQL" ]]; then
      check_warn_item "${label} binding publicly exposed (${listeners}) — prefer 127.0.0.1:${port} in docker-compose"
    else
      check_fail "${label} binding publicly exposed (${listeners})"
    fi
  elif grep -q "127.0.0.1:${port}" <<<"$listeners"; then
    check_pass "${label} binding 127.0.0.1:${port}"
  else
    check_warn_item "${label} binding (${listeners})"
  fi
}

check_port_binding_public() {
  local port="$1"
  local label="$2"
  local listeners
  listeners="$(get_port_listeners "$port" | paste -sd ',' - || true)"

  if [[ -z "$listeners" ]]; then
    check_fail "${label} public ${port}"
    return 0
  fi

  if grep -qE '(0\.0\.0\.0|\[::\]):'"${port}" <<<"$listeners" || grep -q ":${port}" <<<"$listeners"; then
    check_pass "${label} public ${port} (${listeners})"
  else
    check_warn_item "${label} public ${port} (${listeners})"
  fi
}

check_postgres_port_binding() {
  local port="${COMPOSE_PG_PORT:-5432}"
  local listeners
  listeners="$(get_port_listeners "$port" | paste -sd ',' - || true)"

  if [[ -z "$listeners" ]]; then
    check_fail "PostgreSQL bound to 127.0.0.1:${port}"
    check_fail "5432 not publicly exposed"
    return 0
  fi

  if grep -q "127.0.0.1:${port}" <<<"$listeners"; then
    check_pass "PostgreSQL bound to 127.0.0.1:${port}"
    check_pass "5432 not publicly exposed"
    return 0
  fi

  if grep -qE '(0\.0\.0\.0|\[::\]):'"${port}" <<<"$listeners"; then
    check_warn_item "PostgreSQL bound to 127.0.0.1:${port} (currently ${listeners})"
    check_fail "5432 not publicly exposed"
    return 0
  fi

  check_warn_item "PostgreSQL bound to 127.0.0.1:${port} (listeners: ${listeners})"
  check_warn_item "5432 not publicly exposed"
}

check_port_bindings() {
  parse_compose_postgres "${FAIR_CRM_DIR}/docker-compose.yml"
  check_postgres_port_binding
  check_port_binding_local_only "8000" "KYROX Core"
  check_port_binding_local_only "8001" "Fair CRM"
  check_port_binding_local_only "8002" "Fair Stand"
  check_port_binding_public "80" "Nginx"
  if get_port_listeners "443" | grep -q .; then
    check_port_binding_public "443" "Nginx HTTPS"
  else
    check_warn_item "Nginx HTTPS 443 not listening"
  fi
}

install_nginx_site() {
  local template="$1"
  local site_name="${2:-fair-crm}"
  local available="/etc/nginx/sites-available/${site_name}"
  local enabled="/etc/nginx/sites-enabled/${site_name}"
  local rendered
  rendered="$(mktemp)"

  step "Install nginx site ${site_name}"
  [[ -f "$template" ]] || die "nginx template missing: ${template}"
  render_template "$template" "$rendered"

  if [[ -f "$available" ]] && ! cmp -s "$rendered" "$available"; then
    warn "Preserving existing nginx config: ${available}"
    rm -f "$rendered"
  else
    run_root cp "$rendered" "$available"
    run_root chmod 644 "$available"
    log "Installed nginx site: ${available}"
    rm -f "$rendered"
  fi

  if [[ ! -e "$enabled" ]]; then
    run_root ln -sf "$available" "$enabled"
  fi

  run_root nginx -t
  run_root systemctl enable nginx
  run_root systemctl reload nginx
}

reload_nginx_if_installed() {
  if command -v nginx >/dev/null 2>&1 && [[ -d /etc/nginx/sites-enabled ]]; then
    step "Reload nginx"
    run_root nginx -t
    run_root systemctl reload nginx
  fi
}

check_nginx_site() {
  if ! command -v nginx >/dev/null 2>&1; then
    check_fail "nginx installed"
    return 0
  fi
  check_pass "nginx installed"

  local nginx_test_output nginx_test_rc=0
  nginx_test_output="$(run_root nginx -t 2>&1)" || nginx_test_rc=$?
  if [[ "$nginx_test_rc" -eq 0 ]]; then
    check_pass "nginx -t syntax OK"
  else
    check_fail "nginx -t failed"
  fi

  if [[ -f /etc/nginx/sites-enabled/fair-crm || -L /etc/nginx/sites-enabled/fair-crm ]]; then
    check_pass "nginx fair-crm site enabled"
  else
    check_warn_item "nginx fair-crm site enabled"
  fi

  if run_root systemctl is-active nginx >/dev/null 2>&1; then
    check_pass "nginx service active"
  else
    check_fail "nginx service active"
  fi

  local site="/etc/nginx/sites-available/fair-crm"
  if [[ -f "$site" ]] && grep -q '127.0.0.1:8002' "$site" && grep -q '/api/v1/fair-stand/' "$site"; then
    check_pass "nginx /api/v1/fair-stand/ -> 127.0.0.1:8002"
  else
    check_fail "nginx /api/v1/fair-stand/ -> 127.0.0.1:8002"
  fi

  # Static asset performance: missing rules are added by deploy-all.sh
  # (apply-nginx-performance.sh), so a gap here is a warning, not a failure.
  local perf_py="${FAIR_CRM_DIR:-${KYROX_ROOT}/kyrox-fair-crm}/scripts/server/nginx_performance.py"
  if [[ -f "$site" && -f "$perf_py" ]] && python3 "$perf_py" --site "$site" --check-site >/dev/null 2>&1; then
    check_pass "nginx static cache rules (/assets/ 1y, index.html no-cache, models/textures revalidate)"
  else
    check_warn_item "nginx static cache rules missing (run deploy-all.sh)"
  fi
  if run_root nginx -T 2>/dev/null | grep -Eq '^[[:space:]]*gzip_types[^#]*application/javascript'; then
    check_pass "nginx gzip covers JS/CSS/JSON"
  else
    check_warn_item "nginx gzip does not cover JS (run deploy-all.sh)"
  fi
}

wait_for_http_health() {
  local core_url="$1"
  local fair_url="$2"
  local stand_url="$3"
  local timeout="${4:-60}"
  local core_status="000"
  local fair_status="000"
  local stand_status="000"
  local deadline=$((SECONDS + timeout))

  while (( SECONDS < deadline )); do
    core_status="$(http_status "$core_url")"
    fair_status="$(http_status "$fair_url")"
    stand_status="$(http_status "$stand_url")"
    if [[ "$core_status" == "200" && "$fair_status" == "200" && "$stand_status" == "200" ]]; then
      printf '%s %s %s' "$core_status" "$fair_status" "$stand_status"
      return 0
    fi
    sleep 2
  done
  printf '%s %s %s' "$core_status" "$fair_status" "$stand_status"
  return 1
}

check_http_endpoints() {
  local core_url="$1"
  local fair_url="$2"
  local stand_url="${3:-}"

  local core_status fair_status stand_status
  core_status="$(http_status "$core_url")"
  fair_status="$(http_status "$fair_url")"

  if [[ "$core_status" == "200" ]]; then
    check_pass "Core health ${core_status}"
  else
    check_fail "Core health ${core_status}"
  fi

  if [[ "$fair_status" == "200" ]]; then
    check_pass "Fair CRM health ${fair_status}"
  else
    check_fail "Fair CRM health ${fair_status}"
  fi

  if [[ -n "$stand_url" ]]; then
    stand_status="$(http_status "$stand_url")"
    if [[ "$stand_status" == "200" ]]; then
      check_pass "Fair Stand health ${stand_status}"
    else
      check_fail "Fair Stand health ${stand_status}"
    fi
  fi
}

login_smoke_parse_response_body() {
  local body_file="$1"
  python3 -c '
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        raw = handle.read()
except OSError as exc:
    print(f"read_error={exc}")
    raise SystemExit(1)

if not raw.strip():
    print("empty_body")
    raise SystemExit(1)

try:
    data = json.loads(raw)
except json.JSONDecodeError as exc:
    preview = raw.replace("\n", " ").replace("\r", " ")[:300]
    print(f"json_error={exc}; raw={preview}")
    raise SystemExit(1)

if data.get("access_token"):
    print("ok")
    raise SystemExit(0)

preview = raw.replace("\n", " ").replace("\r", " ")[:300]
print(f"missing_access_token; raw={preview}")
raise SystemExit(1)
' "$body_file"
}

run_login_smoke_test() {
  local core_port="${1:-8000}"
  local fail_mode="${2:-check}"
  local url="http://127.0.0.1:${core_port}/api/v1/auth/login"
  local tmp_body tmp_payload tmp_curl_err
  local http_code curl_rc=0 body_preview parse_detail parse_rc=0
  local attempt max_attempts=5

  require_dev_login_password

  tmp_body="$(mktemp -t login-smoke-body.XXXXXX)"
  tmp_payload="$(mktemp -t login-smoke-payload.XXXXXX)"
  tmp_curl_err="$(mktemp -t login-smoke-curl.XXXXXX)"

  LOGIN_SMOKE_FAIL_DETAIL=""

  _login_smoke_cleanup() {
    rm -f "$tmp_body" "$tmp_payload" "$tmp_curl_err"
  }

  _login_smoke_fail() {
    local status="$1"
    local body="$2"
    local extra="${3:-}"
    LOGIN_SMOKE_FAIL_DETAIL="status=${status}, body=${body}"
    if [[ -n "$extra" ]]; then
      LOGIN_SMOKE_FAIL_DETAIL="${LOGIN_SMOKE_FAIL_DETAIL}, ${extra}"
    fi
    _login_smoke_cleanup
    if [[ "$fail_mode" != "deploy" ]]; then
      check_fail "Login smoke test failed (${LOGIN_SMOKE_FAIL_DETAIL})"
    fi
    return 1
  }

  export DEV_LOGIN_EMAIL DEV_LOGIN_PASSWORD
  python3 -c 'import json, os, sys; json.dump({"email": os.environ["DEV_LOGIN_EMAIL"], "password": os.environ["DEV_LOGIN_PASSWORD"]}, sys.stdout)' \
    >"$tmp_payload"

  http_code="000"
  curl_rc=0
  parse_detail=""

  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    : >"$tmp_body"
    : >"$tmp_curl_err"
    curl_rc=0
    http_code="$(
      curl -sS -o "$tmp_body" -w '%{http_code}' -X POST "$url" \
        -H "Content-Type: application/json" \
        --data-binary "@${tmp_payload}" \
        --connect-timeout 10 --max-time 30 2>"$tmp_curl_err"
    )" || curl_rc=$?

    body_preview="$(tr -d '\n\r' <"$tmp_body" 2>/dev/null | head -c 300)"
    [[ -n "$body_preview" ]] || body_preview="empty"

    if [[ "$curl_rc" -ne 0 ]]; then
      if [[ "$attempt" -lt "$max_attempts" ]]; then
        sleep 2
        continue
      fi
      local curl_error
      curl_error="$(tr -d '\n\r' <"$tmp_curl_err" 2>/dev/null | head -c 200)"
      _login_smoke_fail "${http_code:-000}" "$body_preview" "curl_error=${curl_error:-unknown}"
      return 1
    fi

    if [[ -z "$http_code" || "$http_code" == "000" ]]; then
      if [[ "$attempt" -lt "$max_attempts" ]]; then
        sleep 2
        continue
      fi
      _login_smoke_fail "000" "$body_preview"
      return 1
    fi

    if [[ "$http_code" != "200" ]]; then
      if [[ "$attempt" -lt "$max_attempts" ]]; then
        sleep 2
        continue
      fi
      _login_smoke_fail "$http_code" "$body_preview"
      return 1
    fi

    if [[ ! -s "$tmp_body" ]]; then
      if [[ "$attempt" -lt "$max_attempts" ]]; then
        sleep 2
        continue
      fi
      _login_smoke_fail "$http_code" "empty"
      return 1
    fi

    parse_rc=0
    parse_detail="$(login_smoke_parse_response_body "$tmp_body" 2>&1)" || parse_rc=$?
    if [[ "$parse_rc" -eq 0 ]]; then
      break
    fi

    if [[ "$attempt" -lt "$max_attempts" ]]; then
      sleep 2
      continue
    fi

    _login_smoke_fail "$http_code" "$body_preview" "${parse_detail:-parse_failed}"
    return 1
  done

  _login_smoke_cleanup
  if [[ "$fail_mode" != "deploy" ]]; then
    check_pass "Login smoke test passed"
  fi
  return 0
}

print_core_seed_identity_report() {
  local pw_len=0
  local pw_fp="n/a"
  if [[ -n "${DEV_USER_PASSWORD:-}" ]]; then
    pw_len="${#DEV_USER_PASSWORD}"
    pw_fp="$(dev_password_fingerprint "$DEV_USER_PASSWORD")"
  fi
  echo ""
  echo "Core dev seed identity (idempotent):"
  echo "  email: ${DEV_LOGIN_EMAIL}"
  echo "  password: (from DEV_USER_PASSWORD / ${DEV_SEED_ENV_FILE}; not shown)"
  echo "  password_length: ${pw_len}"
  echo "  password_fingerprint: ${pw_fp}"
  echo "  org id: ${DEV_LOGIN_ORG_ID}"
  echo "  role: owner/admin"
  echo "  permissions: all fair_crm.* permissions in Core catalog"
  echo "  behavior: safe to re-run; creates or updates user/org/role/password mappings"
}

print_systemd_service_summary() {
  local script_dir="$1"
  local stand_unit="${FAIR_STAND_DIR}/scripts/server/systemd/fair-stand.service"
  local -a units=(
    "kyrox-core.service#8000#${KYROX_CORE_DIR}#${script_dir}/systemd/kyrox-core.service"
    "fair-stand.service#8002#${FAIR_STAND_DIR}#${stand_unit}"
    "fair-crm-backend.service#8001#${FAIR_CRM_DIR}#${script_dir}/systemd/fair-crm-backend.service"
  )
  local entry service port root_dir template
  for entry in "${units[@]}"; do
    IFS='#' read -r service port root_dir template <<<"$entry"
    echo "${template#${script_dir}/}"
    echo "  bind: 127.0.0.1"
    echo "  port: ${port}"
    if [[ -f "$template" ]]; then
      echo "  Restart=$(grep -E '^Restart=' "$template" | head -n1 | cut -d= -f2-)"
      echo "  RestartSec=$(grep -E '^RestartSec=' "$template" | head -n1 | cut -d= -f2-)"
      echo "  WorkingDirectory=${root_dir}/backend"
      echo "  EnvironmentFile=${root_dir}/backend/.env"
      if [[ "$service" == "kyrox-core.service" ]]; then
        echo "  ExecStart=${KYROX_CORE_DIR}/.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port ${port}"
      elif [[ "$service" == "fair-stand.service" ]]; then
        echo "  ExecStart=${FAIR_STAND_DIR}/backend/.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port ${port}"
      else
        echo "  ExecStart=${FAIR_CRM_DIR}/backend/.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port ${port}"
      fi
    fi
    echo ""
  done
}

print_systemd_service_audit() {
  print_systemd_service_summary "$1"
  local installed port
  for service in kyrox-core.service fair-stand.service fair-crm-backend.service; do
    installed="/etc/systemd/system/${service}"
    port="8000"
    [[ "$service" == "fair-stand.service" ]] && port="8002"
    [[ "$service" == "fair-crm-backend.service" ]] && port="8001"
    if [[ -f "$installed" ]]; then
      local verify_rc=0 verify_out=""
      if command -v systemd-analyze >/dev/null 2>&1; then
        verify_out="$(systemd-analyze verify "$installed" 2>&1)" || verify_rc=$?
      fi
      if [[ "$verify_rc" -ne 0 ]]; then
        check_fail "${service} unit valid (systemd-analyze: ${verify_out})"
      elif grep -Eq '@(DEPLOY_SERVICE_USER|KYROX_CORE_DIR|FAIR_CRM_DIR|FAIR_STAND_DIR)@|__(DEPLOY_SERVICE_USER|KYROX_CORE_DIR|FAIR_CRM_DIR|FAIR_STAND_DIR)__' "$installed"; then
        check_fail "${service} unit valid (unreplaced template placeholders in ${installed})"
      elif grep -q '127.0.0.1' "$installed" && grep -q 'Restart=always' "$installed"; then
        check_pass "${service} unit configured (127.0.0.1:${port}, Restart=always)"
      else
        check_warn_item "${service} unit configured (verify bind/Restart in ${installed})"
      fi
    else
      check_fail "${service} unit installed"
    fi
  done
}

print_nginx_config_audit() {
  local fair_dir="$1"
  echo ""
  echo "nginx routing audit:"
  echo "  /              -> ${fair_dir}/frontend/dist"
  echo "  /api/          -> Fair CRM backend 127.0.0.1:8001"
  echo "  /api/v1/fair-stand/ -> Fair Stand API 127.0.0.1:8002"
  echo "  /kyrox-core/   -> KYROX Core 127.0.0.1:8000"
  echo "  template: scripts/server/nginx/fair-crm.conf"
  if command -v nginx >/dev/null 2>&1; then
    local nginx_test_output nginx_test_rc=0
    nginx_test_output="$(run_root nginx -t 2>&1)" || nginx_test_rc=$?
    echo "  nginx -t: rc=${nginx_test_rc} (${nginx_test_output//$'\n'/; })"
    if run_root systemctl is-active nginx >/dev/null 2>&1; then
      echo "  systemctl reload nginx: service active"
      check_pass "nginx routing configured"
    else
      check_fail "nginx routing configured"
    fi
  fi
}

resolve_core_db_url() {
  read_env_key "${KYROX_CORE_DIR}/backend/.env" DATABASE_URL \
    || read_env_key "${KYROX_CORE_DIR}/backend/.env" KYROX_CORE_DATABASE_URL \
    || echo "postgresql://${PG_USER}:${PG_PASS}@${PG_HOST}:${PG_PORT}/kyrox_core"
}

resolve_fair_db_url() {
  read_env_key "${FAIR_CRM_DIR}/backend/.env" DATABASE_URL \
    || read_env_key "${FAIR_CRM_DIR}/backend/.env" FAIR_CRM_DATABASE_URL \
    || echo "postgresql+psycopg2://${PG_USER}:${PG_PASS}@${PG_HOST}:${PG_PORT}/fair_crm"
}

resolve_stand_db_url() {
  read_env_key "${FAIR_STAND_DIR}/backend/.env" FAIR_STAND_DATABASE_URL \
    || read_env_key "${FAIR_STAND_DIR}/backend/.env" DATABASE_URL \
    || echo "postgresql+psycopg2://${PG_USER}:${PG_PASS}@${PG_HOST}:${PG_PORT}/fair_stand"
}

assert_db_url_resolvers() {
  local fn
  for fn in resolve_core_db_url resolve_fair_db_url resolve_stand_db_url; do
    declare -F "$fn" >/dev/null || die "common.sh missing ${fn} (Core/CRM/Stand each keep their own DATABASE_URL helper)"
  done
}
