#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Variáveis (via HCL)
# ----------------------------
SITE_NAME="${SITE_NAME:-crm.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

# credenciais admin/root do MariaDB (pra criar DB/user no new-site)
DB_ROOT_USERNAME="${DB_ROOT_USERNAME:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"

# credenciais da aplicação (frappe_crm)
DB_USER="${DB_USER:-frappe_crm}"
DB_PASSWORD="${DB_PASSWORD:-frappe_crm}"
DB_NAME="${DB_NAME:-}"   # se vazio, deriva do SITE_NAME

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_URL="redis://${REDIS_HOST}:${REDIS_PORT}"

FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
CRM_REPO_URL="${CRM_REPO_URL:-https://github.com/frappe/crm}"
CRM_REF="${CRM_REF:-main}"   # tag/commit/branch

DEVELOPER_MODE="${DEVELOPER_MODE:-0}"
MUTE_EMAILS="${MUTE_EMAILS:-1}"
SERVER_SCRIPT_ENABLED="${SERVER_SCRIPT_ENABLED:-1}"

RUN_BUILD_ASSETS="${RUN_BUILD_ASSETS:-1}"
RUN_MIGRATE="${RUN_MIGRATE:-1}"

HTTP_PORT="${HTTP_PORT:-8000}"
SOCKETIO_PORT="${SOCKETIO_PORT:-9000}"

# Persistência: teu volume crm/bench montado aqui
BENCH_DIR="/home/frappe/frappe-bench"
LOCKDIR="/tmp/frappe-bench-init.lock"

log() { echo "[init] $*"; }

# DB_NAME default (se não vier)
if [ -z "${DB_NAME}" ]; then
  DB_NAME="$(echo "${SITE_NAME}" | tr '.' '_' | tr -cd 'a-zA-Z0-9_')"
fi

log "SITE_NAME=${SITE_NAME}"
log "DB=${DB_HOST}:${DB_PORT} root=${DB_ROOT_USERNAME} app_user=${DB_USER} db=${DB_NAME}"
log "REDIS=${REDIS_URL}"
log "FRAPPE_BRANCH=${FRAPPE_BRANCH}"
log "CRM_REPO_URL=${CRM_REPO_URL}"
log "CRM_REF=${CRM_REF}"
log "HTTP_PORT=${HTTP_PORT} SOCKETIO_PORT=${SOCKETIO_PORT}"

is_valid_bench() {
  [[ -f "${BENCH_DIR}/Procfile" && -d "${BENCH_DIR}/apps/frappe" && -d "${BENCH_DIR}/sites" ]]
}

wipe_bench_contents() {
    find "${BENCH_DIR}" -mindepth 1 -maxdepth 1 \
    ! -name "sites" \
    ! -name "logs" \
    -exec rm -rf {} +
}

# lock simples pra impedir init concorrente
if ! mkdir "${LOCKDIR}" 2>/dev/null; then
  log "Another init is running (lock=${LOCKDIR}). Exiting."
  exit 1
fi
trap 'rmdir "${LOCKDIR}" 2>/dev/null || true' EXIT

cd /home/frappe

if is_valid_bench; then
  log "Bench already exists and is valid."
else
  log "Bench missing/zombie. Recreating..."

  mkdir -p "${BENCH_DIR}"
  wipe_bench_contents

  # bench init precisa de um path que NÃO exista
  TMP_BASE="/home/frappe"
  TMP_DIR="${TMP_BASE}/.bench-tmp.$(date +%s).$RANDOM$RANDOM"

  log "Creating new bench at temp path: ${TMP_DIR}"
  bench init --skip-redis-config-generation "${TMP_DIR}" --version "${FRAPPE_BRANCH}"

  log "Moving fresh bench into ${BENCH_DIR}..."
  shopt -s dotglob
  mv "${TMP_DIR}"/* "${BENCH_DIR}/"
  shopt -u dotglob
  rm -rf "${TMP_DIR}" || true
fi

# entra no bench SEMPRE
cd "${BENCH_DIR}"

# garante sites/common_site_config.json antes dos set-*host
mkdir -p "${BENCH_DIR}/sites"
[[ -f "${BENCH_DIR}/sites/common_site_config.json" ]] || echo "{}" > "${BENCH_DIR}/sites/common_site_config.json"

# garante logs pra não tomar PermissionError
mkdir -p "${BENCH_DIR}/logs"
chmod -R u+rwX,g+rwX "${BENCH_DIR}/logs" || true

# ----------------------------
# Configura DB + Redis
# ----------------------------
log "Configuring DB/Redis endpoints..."
bench set-mariadb-host "${DB_HOST}"
bench set-redis-cache-host "${REDIS_URL}"
bench set-redis-queue-host "${REDIS_URL}"
bench set-redis-socketio-host "${REDIS_URL}"

# remove redis/watch do Procfile
sed -i '/redis/d' ./Procfile || true
sed -i '/watch/d' ./Procfile || true

# ----------------------------
# App CRM
# ----------------------------
if bench list-apps | grep -qx 'crm'; then
  log "App crm already exists."
else
  log "Installing app crm..."
  bench get-app crm "${CRM_REPO_URL}" --branch "${CRM_REF}"
fi

# ----------------------------
# Site
# ----------------------------
if [[ -d "sites/${SITE_NAME}" ]]; then
  log "Site ${SITE_NAME} already exists."
else
  log "Creating site ${SITE_NAME}..."
  bench new-site "${SITE_NAME}" \
    --force \
    --admin-password "${ADMIN_PASSWORD}" \
    --db-root-username "${DB_ROOT_USERNAME}" \
    --db-root-password "${DB_ROOT_PASSWORD}" \
    --mariadb-user-host-login-scope=% \
    --no-mariadb-socket
fi

# aplica config do DB da aplicação (user/pass/db)
log "Applying DB_USER/DB_PASSWORD/DB_NAME into site_config..."
bench --site "${SITE_NAME}" set-config db_host "${DB_HOST}"
bench --site "${SITE_NAME}" set-config db_port "${DB_PORT}"
bench --site "${SITE_NAME}" set-config db_name "${DB_NAME}"
bench --site "${SITE_NAME}" set-config db_user "${DB_USER}"
bench --site "${SITE_NAME}" set-config db_password "${DB_PASSWORD}"

# instala CRM no site
log "Installing crm on site (if needed)..."
bench --site "${SITE_NAME}" install-app crm || true

# configs gerais
bench --site "${SITE_NAME}" set-config developer_mode "${DEVELOPER_MODE}"
bench --site "${SITE_NAME}" set-config mute_emails "${MUTE_EMAILS}"
bench --site "${SITE_NAME}" set-config server_script_enabled "${SERVER_SCRIPT_ENABLED}"

bench use "${SITE_NAME}"

if [ "${RUN_MIGRATE}" = "1" ]; then
  log "Running migrate..."
  bench --site "${SITE_NAME}" migrate
fi

if [ "${RUN_BUILD_ASSETS}" = "1" ]; then
  log "Running build assets..."
  bench build --force
fi

bench --site "${SITE_NAME}" clear-cache || true

log "Starting bench..."
exec bench start --port "${HTTP_PORT}" --socketio-port "${SOCKETIO_PORT}"
