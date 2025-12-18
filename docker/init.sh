#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[init] $*"; }

# ----------------------------
# Vars (env)
# ----------------------------
SITE_NAME="${SITE_NAME:-crm.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

DB_ROOT_USERNAME="${DB_ROOT_USERNAME:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"

DB_USER="${DB_USER:-frappe_crm}"
DB_PASSWORD="${DB_PASSWORD:-frappe_crm}"
DB_NAME="${DB_NAME:-}"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_URL="redis://${REDIS_HOST}:${REDIS_PORT}"

FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
CRM_REPO_URL="${CRM_REPO_URL:-https://github.com/frappe/crm}"
CRM_REF="${CRM_REF:-main}"

DEVELOPER_MODE="${DEVELOPER_MODE:-0}"
MUTE_EMAILS="${MUTE_EMAILS:-1}"
SERVER_SCRIPT_ENABLED="${SERVER_SCRIPT_ENABLED:-1}"

RUN_MIGRATE="${RUN_MIGRATE:-1}"
RUN_BUILD_ASSETS="${RUN_BUILD_ASSETS:-1}"

HTTP_PORT="${HTTP_PORT:-8000}"
SOCKETIO_PORT="${SOCKETIO_PORT:-9000}"

# GxP controls
GXP_MODE="${GXP_MODE:-1}"
AUTO_REPAIR_SITE="${AUTO_REPAIR_SITE:-1}"
PROTECT_IF_FILES="${PROTECT_IF_FILES:-1}"
PROTECT_IF_DB_HAS_FILES="${PROTECT_IF_DB_HAS_FILES:-1}"

BENCH_DIR="/home/frappe/frappe-bench"
LOCKDIR="/tmp/frappe-init.lock"

# ----------------------------
# Helpers
# ----------------------------
wait_tcp() {
  local host="$1" port="$2" name="$3"
  log "Waiting for ${name} at ${host}:${port} ..."
  for _ in $(seq 1 240); do
    if (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1; then
      log "${name} is up."
      return 0
    fi
    sleep 1
  done
  log "ERROR: ${name} did not become ready in time."
  return 1
}

bench_ok() {
  [[ -f "${BENCH_DIR}/Procfile" ]] || return 1
  [[ -d "${BENCH_DIR}/apps/frappe" ]] || return 1
  [[ -x "${BENCH_DIR}/env/bin/python" ]] || return 1
  "${BENCH_DIR}/env/bin/python" -c "import frappe" >/dev/null 2>&1
}

ensure_sites_logs() {
  mkdir -p "${BENCH_DIR}/sites" "${BENCH_DIR}/logs"
  chmod -R u+rwX,g+rwX "${BENCH_DIR}/sites" "${BENCH_DIR}/logs" || true
  [[ -f "${BENCH_DIR}/sites/common_site_config.json" ]] || echo "{}" > "${BENCH_DIR}/sites/common_site_config.json"
}

site_exists() {
  [[ -d "${BENCH_DIR}/sites/${SITE_NAME}" ]]
}

site_has_files_on_disk() {
  local pub="${BENCH_DIR}/sites/${SITE_NAME}/public/files"
  local prv="${BENCH_DIR}/sites/${SITE_NAME}/private/files"
  if [[ -d "$pub" ]] && find "$pub" -type f -maxdepth 1 2>/dev/null | head -n 1 | grep -q .; then return 0; fi
  if [[ -d "$prv" ]] && find "$prv" -type f -maxdepth 1 2>/dev/null | head -n 1 | grep -q .; then return 0; fi
  return 1
}

db_has_files() {
  # Só roda se o site estiver minimamente funcional.
  bench --site "${SITE_NAME}" console <<'PY' >/dev/null 2>&1
import frappe
frappe.connect()
n = frappe.db.count("File") or 0
frappe.destroy()
raise SystemExit(0 if n > 0 else 1)
PY
}

core_schema_ok() {
  # Smoke test: esse import + conexão + existência de tabela core.
  bench --site "${SITE_NAME}" console <<'PY' >/dev/null 2>&1
import frappe
frappe.connect()
ok = frappe.db.table_exists("DefaultValue")
frappe.destroy()
raise SystemExit(0 if ok else 1)
PY
}

wipe_bench_keep_sites_logs() {
  find "${BENCH_DIR}" -mindepth 1 -maxdepth 1 \
    ! -name "sites" \
    ! -name "logs" \
    -exec rm -rf {} + || true
}

bench_recreate_preserving_volumes() {
  log "Bench missing/broken. Recreating bench (preserve sites/logs) ..."
  wipe_bench_keep_sites_logs
  local tmp="/home/frappe/.bench-tmp.$(date +%s).$RANDOM"
  log "bench init at ${tmp}"
  bench init --skip-redis-config-generation "${tmp}" --version "${FRAPPE_BRANCH}"

  log "Syncing bench to ${BENCH_DIR} (excluding sites/logs)..."
  rsync -a --delete \
    --exclude 'sites' \
    --exclude 'logs' \
    "${tmp}/" "${BENCH_DIR}/"

  rm -rf "${tmp}" || true
  ensure_sites_logs

  if ! bench_ok; then
    log "ERROR: bench still broken after recreate."
    exit 1
  fi
}

ensure_db_user_db_exist() {
  log "Ensuring MariaDB database/user exist: db=${DB_NAME} user=${DB_USER}"
  # usa python padrão do container pra evitar depender de mysql-client
  python3 - <<PY
import sys
import pymysql

host="${DB_HOST}"
port=int("${DB_PORT}")
root_user="${DB_ROOT_USERNAME}"
root_pass="${DB_ROOT_PASSWORD}"
db="${DB_NAME}"
app_user="${DB_USER}"
app_pass="${DB_PASSWORD}"

conn = pymysql.connect(host=host, port=port, user=root_user, password=root_pass, autocommit=True)
cur = conn.cursor()
cur.execute(f"CREATE DATABASE IF NOT EXISTS `{db}` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
cur.execute(f"CREATE USER IF NOT EXISTS '{app_user}'@'%' IDENTIFIED BY '{app_pass}'")
cur.execute(f\"GRANT ALL PRIVILEGES ON `{db}`.* TO '{app_user}'@'%'\")
cur.execute("FLUSH PRIVILEGES")
cur.close()
conn.close()
print("DB ensured OK")
PY
}

hard_reset_site_and_db() {
  log "AUTO-REPAIR: Recreating site+DB (hard reset)..."

  # cuidado: isso apaga DB e pastas do site (não apaga logs gerais)
  python3 - <<PY
import pymysql
host="${DB_HOST}"; port=int("${DB_PORT}")
root_user="${DB_ROOT_USERNAME}"; root_pass="${DB_ROOT_PASSWORD}"
db="${DB_NAME}"
conn=pymysql.connect(host=host, port=port, user=root_user, password=root_pass, autocommit=True)
cur=conn.cursor()
cur.execute(f"DROP DATABASE IF EXISTS `{db}`")
cur.execute(f"CREATE DATABASE `{db}` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
cur.close(); conn.close()
print("DB dropped+created OK")
PY

  rm -rf "${BENCH_DIR}/sites/${SITE_NAME}" 2>/dev/null || true

  bench new-site "${SITE_NAME}" \
    --force \
    --admin-password "${ADMIN_PASSWORD}" \
    --db-root-username "${DB_ROOT_USERNAME}" \
    --db-root-password "${DB_ROOT_PASSWORD}" \
    --db-host "${DB_HOST}" \
    --db-port "${DB_PORT}" \
    --db-name "${DB_NAME}" \
    --mariadb-user-host-login-scope="%" \
    --no-mariadb-socket || true
}

# ----------------------------
# Lock
# ----------------------------
if ! mkdir "${LOCKDIR}" 2>/dev/null; then
  log "Another init is running (lock=${LOCKDIR}). Exiting."
  exit 1
fi
trap 'rmdir "${LOCKDIR}" 2>/dev/null || true' EXIT

# DB_NAME default
if [[ -z "${DB_NAME}" ]]; then
  DB_NAME="$(echo "${SITE_NAME}" | tr '.' '_' | tr -cd 'a-zA-Z0-9_')"
fi

log "SITE_NAME=${SITE_NAME}"
log "DB=${DB_HOST}:${DB_PORT} root=${DB_ROOT_USERNAME} app_user=${DB_USER} db=${DB_NAME}"
log "REDIS=${REDIS_URL}"
log "FRAPPE_BRANCH=${FRAPPE_BRANCH}"
log "CRM_REPO_URL=${CRM_REPO_URL}"
log "CRM_REF=${CRM_REF}"
log "HTTP_PORT=${HTTP_PORT} SOCKETIO_PORT=${SOCKETIO_PORT}"
log "GXP_MODE=${GXP_MODE} AUTO_REPAIR_SITE=${AUTO_REPAIR_SITE} PROTECT_IF_FILES=${PROTECT_IF_FILES} PROTECT_IF_DB_HAS_FILES=${PROTECT_IF_DB_HAS_FILES}"

# ----------------------------
# Wait deps
# ----------------------------
wait_tcp "127.0.0.1" "${REDIS_PORT}" "Redis"
wait_tcp "${DB_HOST}" "${DB_PORT}" "MariaDB"

# ----------------------------
# Bench
# ----------------------------
ensure_sites_logs
if ! bench_ok; then
  bench_recreate_preserving_volumes
fi
cd "${BENCH_DIR}"

# ----------------------------
# Configure endpoints
# ----------------------------
log "Configuring DB/Redis endpoints..."
bench set-mariadb-host "${DB_HOST}" || true
bench set-redis-cache-host "${REDIS_URL}" || true
bench set-redis-queue-host "${REDIS_URL}" || true
bench set-redis-socketio-host "${REDIS_URL}" || true

sed -i '/redis/d' ./Procfile 2>/dev/null || true
sed -i '/watch/d' ./Procfile 2>/dev/null || true

# ----------------------------
# App CRM
# ----------------------------
if bench list-apps 2>/dev/null | grep -qx 'crm'; then
  log "App crm already installed in bench."
else
  log "Getting app crm..."
  bench get-app crm "${CRM_REPO_URL}" --branch "${CRM_REF}" --skip-assets
fi

# ----------------------------
# DB ensure + Site validate/repair (GxP)
# ----------------------------
ensure_db_user_db_exist

if site_exists; then
  log "Site ${SITE_NAME} exists."
else
  log "Creating site ${SITE_NAME} (db=${DB_NAME})..."
  bench new-site "${SITE_NAME}" \
    --force \
    --admin-password "${ADMIN_PASSWORD}" \
    --db-root-username "${DB_ROOT_USERNAME}" \
    --db-root-password "${DB_ROOT_PASSWORD}" \
    --db-host "${DB_HOST}" \
    --db-port "${DB_PORT}" \
    --db-name "${DB_NAME}" \
    --mariadb-user-host-login-scope="%" \
    --no-mariadb-socket
fi

# Se core schema tá quebrado: decidir reset automático ou travar (GxP)
if core_schema_ok; then
  log "Core schema OK."
else
  log "Core schema missing/broken."
  if [[ "${AUTO_REPAIR_SITE}" != "1" ]]; then
    log "AUTO_REPAIR_SITE=0 => refusing to repair."
    exit 1
  fi

  # Proteções GxP
  if [[ "${GXP_MODE}" == "1" && "${PROTECT_IF_FILES}" == "1" ]] && site_has_files_on_disk; then
    log "GxP BLOCK: Found files on disk (public/private). Refusing hard reset."
    exit 1
  fi
  if [[ "${GXP_MODE}" == "1" && "${PROTECT_IF_DB_HAS_FILES}" == "1" ]]; then
    if db_has_files; then
      log "GxP BLOCK: DB has File records. Refusing hard reset."
      exit 1
    fi
  fi

  log "GxP OK: no evidence of customer documents -> auto-repair allowed."
  hard_reset_site_and_db

  if ! core_schema_ok; then
    log "ERROR: core tables still missing after auto-repair"
    exit 1
  fi
fi

# ----------------------------
# Enforce DB config (keeps deterministic DB_NAME)
# ----------------------------
bench --site "${SITE_NAME}" set-config db_host "${DB_HOST}" || true
bench --site "${SITE_NAME}" set-config db_port "${DB_PORT}" || true
bench --site "${SITE_NAME}" set-config db_name "${DB_NAME}" || true
bench --site "${SITE_NAME}" set-config db_user "${DB_USER}" || true
bench --site "${SITE_NAME}" set-config db_password "${DB_PASSWORD}" || true

log "Installing crm on site..."
bench --site "${SITE_NAME}" install-app crm || true

bench --site "${SITE_NAME}" set-config developer_mode "${DEVELOPER_MODE}" || true
bench --site "${SITE_NAME}" set-config mute_emails "${MUTE_EMAILS}" || true
bench --site "${SITE_NAME}" set-config server_script_enabled "${SERVER_SCRIPT_ENABLED}" || true

bench use "${SITE_NAME}" || true

if [[ "${RUN_MIGRATE}" == "1" ]]; then
  log "Running migrate..."
  bench --site "${SITE_NAME}" migrate
fi

if [[ "${RUN_BUILD_ASSETS}" == "1" ]]; then
  log "Building assets..."
  bench build --force
fi

bench --site "${SITE_NAME}" clear-cache || true

log "Starting bench..."
exec bench start --port "${HTTP_PORT}" --socketio-port "${SOCKETIO_PORT}"
