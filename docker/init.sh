#!/usr/bin/env bash
set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"     # volume persistente
LOCKDIR="/tmp/frappe-bench-init.lock"

log() { echo "[init] $*"; }

# -------- Vars (HCL) --------
SITE_NAME="${SITE_NAME:-crm.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_ROOT_USERNAME="${DB_ROOT_USERNAME:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"

# ✅ usuário da aplicação
DB_USER="${DB_USER:-frappe_crm}"
DB_PASSWORD="${DB_PASSWORD:-frappe_crm}"
DB_NAME="${DB_NAME:-}"  # opcional

# Redis (URL única)
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_URL="${REDIS_URL:-redis://${REDIS_HOST}:${REDIS_PORT}}"

# GxP pin
CRM_REPO_URL="${CRM_REPO_URL:-https://github.com/frappe/crm}"
CRM_REF="${CRM_REF:-v1.3.0}"   # tag/commit/branch (ideal tag ou commit)

# Ports (se quiser controlar)
HTTP_PORT="${HTTP_PORT:-8000}"
SOCKETIO_PORT="${SOCKETIO_PORT:-9000}"

DEVELOPER_MODE="${DEVELOPER_MODE:-0}"
MUTE_EMAILS="${MUTE_EMAILS:-1}"
SERVER_SCRIPT_ENABLED="${SERVER_SCRIPT_ENABLED:-1}"

# DB_NAME default
if [ -z "${DB_NAME}" ]; then
  DB_NAME="$(echo "${SITE_NAME}" | tr '.' '_' | tr -cd 'a-zA-Z0-9_')"
fi

log "SITE_NAME=${SITE_NAME}"
log "DB=${DB_HOST}:${DB_PORT} root=${DB_ROOT_USERNAME} user=${DB_USER} db=${DB_NAME}"
log "REDIS_URL=${REDIS_URL}"
log "CRM_REPO_URL=${CRM_REPO_URL}"
log "CRM_REF=${CRM_REF}"

is_valid_bench() {
  [[ -f "${BENCH_DIR}/Procfile" && -d "${BENCH_DIR}/apps/frappe" && -d "${BENCH_DIR}/sites" ]]
}

wipe_bench_contents() {
  find "${BENCH_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

# lock simples pra impedir init concorrente (Nomad restart + race)
if ! mkdir "${LOCKDIR}" 2>/dev/null; then
  log "Another init is running (lock=${LOCKDIR}). Exiting to avoid corruption."
  exit 1
fi
trap 'rmdir "${LOCKDIR}" 2>/dev/null || true' EXIT

cd /home/frappe

# -------- perms mínimas (evita bench.log permission denied) --------
mkdir -p "${BENCH_DIR}/logs" "${BENCH_DIR}/sites"
chmod -R u+rwX,g+rwX "${BENCH_DIR}/logs" "${BENCH_DIR}/sites" || true

if is_valid_bench; then
  log "Bench already exists and is valid. Starting..."
  cd "${BENCH_DIR}"
else
  log "Bench missing/zombie. Recreating..."

  mkdir -p "${BENCH_DIR}"
  wipe_bench_contents

  # bench init precisa de path que NÃO exista
  TMP_BASE="/home/frappe"
  TMP_DIR="${TMP_BASE}/.bench-tmp.$(date +%s).$RANDOM$RANDOM"

  log "Creating new bench at temp path: ${TMP_DIR}"
  bench init --skip-redis-config-generation "${TMP_DIR}" --version "${FRAPPE_BRANCH:-version-15}"

  log "Moving fresh bench into ${BENCH_DIR}..."
  shopt -s dotglob
  mv "${TMP_DIR}"/* "${BENCH_DIR}/"
  shopt -u dotglob
  rm -rf "${TMP_DIR}" || true

  cd "${BENCH_DIR}"
fi

# GARANTE common_site_config.json antes de set-mariadb-host
mkdir -p "${BENCH_DIR}/sites"
[[ -f "${BENCH_DIR}/sites/common_site_config.json" ]] || echo "{}" > "${BENCH_DIR}/sites/common_site_config.json"

# Configura DB + Redis
bench set-mariadb-host "${DB_HOST}"

bench set-redis-cache-host "${REDIS_URL}"
bench set-redis-queue-host "${REDIS_URL}"
bench set-redis-socketio-host "${REDIS_URL}"

sed -i '/redis/d' ./Procfile || true
sed -i '/watch/d' ./Procfile || true

# App CRM (pinado)
if [[ ! -d "apps/crm" ]]; then
  log "Installing CRM app (ref=${CRM_REF})..."
  bench get-app crm "${CRM_REPO_URL}" --branch "${CRM_REF}"
else
  log "CRM app already present."
fi

# Site
if [[ ! -d "sites/${SITE_NAME}" ]]; then
  log "Creating site ${SITE_NAME}..."
  bench new-site "${SITE_NAME}" \
    --force \
    --admin-password "${ADMIN_PASSWORD}" \
    --db-root-username "${DB_ROOT_USERNAME}" \
    --db-root-password "${DB_ROOT_PASSWORD}" \
    --mariadb-user-host-login-scope=% \
    --no-mariadb-socket
else
  log "Site already exists."
fi

# ✅ aplica user/pass do DB da aplicação (HCL controla isso)
log "Applying DB_USER/DB_PASSWORD into site_config..."
bench --site "${SITE_NAME}" set-config db_host "${DB_HOST}"
bench --site "${SITE_NAME}" set-config db_port "${DB_PORT}"
bench --site "${SITE_NAME}" set-config db_name "${DB_NAME}"
bench --site "${SITE_NAME}" set-config db_user "${DB_USER}"
bench --site "${SITE_NAME}" set-config db_password "${DB_PASSWORD}"

# Instala CRM só se não estiver instalado
if bench --site "${SITE_NAME}" list-apps | grep -qx 'crm'; then
  log "CRM already installed on site."
else
  log "Installing CRM on site..."
  bench --site "${SITE_NAME}" install-app crm
fi

bench --site "${SITE_NAME}" set-config developer_mode "${DEVELOPER_MODE}"
bench --site "${SITE_NAME}" set-config mute_emails "${MUTE_EMAILS}"
bench --site "${SITE_NAME}" set-config server_script_enabled "${SERVER_SCRIPT_ENABLED}"

bench --site "${SITE_NAME}" clear-cache || true
bench use "${SITE_NAME}"

exec bench start --port "${HTTP_PORT}" --socketio-port "${SOCKETIO_PORT}"
