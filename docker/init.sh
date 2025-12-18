#!/usr/bin/env bash
set -euo pipefail

# ============================
# Vars via HCL
# ============================
SITE_NAME="${SITE_NAME:-crm.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

# root/admin do MariaDB (pra criar DB e user no new-site)
DB_ROOT_USERNAME="${DB_ROOT_USERNAME:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"

# usuário/senha da aplicação (o que você pediu)
DB_USER="${DB_USER:-frappe_crm}"
DB_PASSWORD="${DB_PASSWORD:-frappe_crm}"
DB_NAME="${DB_NAME:-}"   # opcional

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_URL="${REDIS_URL:-redis://${REDIS_HOST}:${REDIS_PORT}}"

FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"

CRM_REPO_URL="${CRM_REPO_URL:-https://github.com/frappe/crm}"
CRM_REF="${CRM_REF:-main}"   # tag/commit p/ GxP

RUN_BUILD_ASSETS="${RUN_BUILD_ASSETS:-1}"
RUN_MIGRATE="${RUN_MIGRATE:-1}"

DEVELOPER_MODE="${DEVELOPER_MODE:-0}"
MUTE_EMAILS="${MUTE_EMAILS:-1}"
SERVER_SCRIPT_ENABLED="${SERVER_SCRIPT_ENABLED:-1}"

# ============================
# Paths
# ============================
WORKDIR="/home/frappe"
BENCH_DIR="/home/frappe/frappe-bench"     # <- SEU VOLUME MONTADO AQUI
LOCKDIR="/tmp/frappe-bench-init.lock"

log() { echo "[init] $*"; }

is_valid_bench() {
  [[ -f "${BENCH_DIR}/Procfile" && -d "${BENCH_DIR}/apps/frappe" && -d "${BENCH_DIR}/sites" ]]
}

wipe_bench_contents() {
  # NÃO remove o mountpoint, só o conteúdo
  find "${BENCH_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

# DB_NAME default (se não vier do HCL)
if [[ -z "${DB_NAME}" ]]; then
  DB_NAME="$(echo "${SITE_NAME}" | tr '.' '_' | tr -cd 'a-zA-Z0-9_')"
fi

log "SITE_NAME=${SITE_NAME}"
log "DB=${DB_HOST}:${DB_PORT} root_user=${DB_ROOT_USERNAME} app_user=${DB_USER} db=${DB_NAME}"
log "REDIS=${REDIS_URL}"
log "FRAPPE_BRANCH=${FRAPPE_BRANCH}"
log "CRM=${CRM_REPO_URL} ref=${CRM_REF}"

# lock anti-corrupção (restart/race)
if ! mkdir "${LOCKDIR}" 2>/dev/null; then
  log "Another init is running (lock=${LOCKDIR}). Exiting."
  exit 1
fi
trap 'rmdir "${LOCKDIR}" 2>/dev/null || true' EXIT

cd "${WORKDIR}"

mkdir -p "${BENCH_DIR}"

if is_valid_bench; then
  log "Bench already exists and is valid."
else
  log "Bench missing/zombie. Recreating inside persistent volume..."

  wipe_bench_contents

  # bench init precisa de path que NÃO exista
  TMP_DIR="${WORKDIR}/.bench-tmp.$(date +%s).$RANDOM$RANDOM"
  log "bench init temp=${TMP_DIR}"
  bench init --skip-redis-config-generation "${TMP_DIR}" --version "${FRAPPE_BRANCH}"

  log "Moving fresh bench into ${BENCH_DIR}..."
  shopt -s dotglob
  mv "${TMP_DIR}"/* "${BENCH_DIR}/"
  shopt -u dotglob
  rm -rf "${TMP_DIR}" || true
fi

cd "${BENCH_DIR}"

# garante common_site_config.json antes de set-*
mkdir -p "${BENCH_DIR}/sites"
[[ -f "${BENCH_DIR}/sites/common_site_config.json" ]] || echo "{}" > "${BENCH_DIR}/sites/common_site_config.json"

# aponta DB/Redis no bench
bench set-mariadb-host "${DB_HOST}"
bench set-redis-cache-host "${REDIS_URL}"
bench set-redis-queue-host "${REDIS_URL}"
bench set-redis-socketio-host "${REDIS_URL}"

# remove redis/watch (igual oficial)
sed -i '/redis/d' ./Procfile || true
sed -i '/watch/d' ./Procfile || true

# app crm
if bench list-apps | grep -qx 'crm'; then
  log "App crm already present."
else
  log "Installing crm app..."
  bench get-app crm "${CRM_REPO_URL}" --branch "${CRM_REF}"
fi

# site
if [[ -d "sites/${SITE_NAME}" ]]; then
  log "Site exists: ${SITE_NAME}"
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

# aplica configs do site (inclui user/pass do app)
bench --site "${SITE_NAME}" set-config db_host "${DB_HOST}"
bench --site "${SITE_NAME}" set-config db_port "${DB_PORT}"
bench --site "${SITE_NAME}" set-config db_name "${DB_NAME}"
bench --site "${SITE_NAME}" set-config db_user "${DB_USER}"
bench --site "${SITE_NAME}" set-config db_password "${DB_PASSWORD}"

bench --site "${SITE_NAME}" set-config developer_mode "${DEVELOPER_MODE}"
bench --site "${SITE_NAME}" set-config mute_emails "${MUTE_EMAILS}"
bench --site "${SITE_NAME}" set-config server_script_enabled "${SERVER_SCRIPT_ENABLED}"

# instala app no site
bench --site "${SITE_NAME}" install-app crm || true
bench use "${SITE_NAME}"

if [[ "${RUN_MIGRATE}" == "1" ]]; then
  log "Running migrate..."
  bench --site "${SITE_NAME}" migrate
fi

if [[ "${RUN_BUILD_ASSETS}" == "1" ]]; then
  log "Running build assets..."
  bench build --force
fi

bench --site "${SITE_NAME}" clear-cache || true

log "Starting bench..."
exec bench start
