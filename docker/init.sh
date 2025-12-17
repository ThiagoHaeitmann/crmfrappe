#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Variáveis controláveis via HCL
# ----------------------------
SITE_NAME="${SITE_NAME:-crm.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"

FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"

# Para GxP: controle de origem e versão do app
CRM_REPO_URL="${CRM_REPO_URL:-https://github.com/frappe/crm}"
CRM_REF="${CRM_REF:-main}"           # pode ser branch, tag ou commit SHA

DEVELOPER_MODE="${DEVELOPER_MODE:-1}"
MUTE_EMAILS="${MUTE_EMAILS:-1}"
SERVER_SCRIPT_ENABLED="${SERVER_SCRIPT_ENABLED:-1}"

# Comportamento
RUN_BUILD_ASSETS="${RUN_BUILD_ASSETS:-1}"  # 1 = gera CSS/JS
RUN_MIGRATE="${RUN_MIGRATE:-1}"            # 1 = roda migrate

# Pastas (persistência)
WORKDIR="/home/frappe"
BENCH_DIR="/home/frappe/frappe-bench"

echo "[init] SITE_NAME=${SITE_NAME}"
echo "[init] DB=${DB_HOST}:${DB_PORT}"
echo "[init] REDIS=${REDIS_HOST}:${REDIS_PORT}"
echo "[init] FRAPPE_BRANCH=${FRAPPE_BRANCH}"
echo "[init] CRM_REPO_URL=${CRM_REPO_URL}"
echo "[init] CRM_REF=${CRM_REF}"

cd "${WORKDIR}"

# ----------------------------
# 1) Cria bench se não existir
# ----------------------------
if [ -d "${BENCH_DIR}/apps/frappe" ]; then
  echo "[init] Bench já existe. Pulando bench init."
else
  echo "[init] Criando bench..."
  bench init --skip-redis-config-generation frappe-bench --version "${FRAPPE_BRANCH}"
fi

cd "${BENCH_DIR}"

# ----------------------------
# 2) Configura endpoints DB/Redis (Nomad host-mode ou service IP)
# ----------------------------
bench set-mariadb-host "${DB_HOST}"

bench set-redis-cache-host "redis://${REDIS_HOST}:${REDIS_PORT}"
bench set-redis-queue-host "redis://${REDIS_HOST}:${REDIS_PORT}"
bench set-redis-socketio-host "redis://${REDIS_HOST}:${REDIS_PORT}"

# Remove redis/watch do Procfile (como no oficial)
sed -i '/redis/d' ./Procfile || true
sed -i '/watch/d' ./Procfile || true

# ----------------------------
# 3) Instala app CRM se não existir
# ----------------------------
if bench list-apps | grep -qx 'crm'; then
  echo "[init] App crm já existe. Pulando get-app."
else
  echo "[init] Instalando app crm..."
  bench get-app crm "${CRM_REPO_URL}" --branch "${CRM_REF}"
fi

# ----------------------------
# 4) Cria site se não existir
# ----------------------------
if [ -d "${BENCH_DIR}/sites/${SITE_NAME}" ]; then
  echo "[init] Site ${SITE_NAME} já existe. Pulando new-site."
else
  echo "[init] Criando site ${SITE_NAME}..."
  bench new-site "${SITE_NAME}" \
    --force \
    --mariadb-root-password "${DB_ROOT_PASSWORD}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --no-mariadb-socket
fi

# ----------------------------
# 5) Instala CRM no site se não estiver instalado
# ----------------------------
if bench --site "${SITE_NAME}" list-apps | grep -qx 'crm'; then
  echo "[init] CRM já instalado no site. OK."
else
  echo "[init] Instalando CRM no site..."
  bench --site "${SITE_NAME}" install-app crm
fi

# ----------------------------
# 6) Configs (via env)
# ----------------------------
bench --site "${SITE_NAME}" set-config developer_mode "${DEVELOPER_MODE}"
bench --site "${SITE_NAME}" set-config mute_emails "${MUTE_EMAILS}"
bench --site "${SITE_NAME}" set-config server_script_enabled "${SERVER_SCRIPT_ENABLED}"

bench use "${SITE_NAME}"

# ----------------------------
# 7) Migrações (importante para upgrades)
# ----------------------------
if [ "${RUN_MIGRATE}" = "1" ]; then
  echo "[init] Rodando migrate..."
  bench --site "${SITE_NAME}" migrate
else
  echo "[init] RUN_MIGRATE=0, pulando migrate."
fi

# ----------------------------
# 8) Build assets (CSS/JS)
# ----------------------------
if [ "${RUN_BUILD_ASSETS}" = "1" ]; then
  echo "[init] Rodando bench build (assets)..."
  bench build --force
else
  echo "[init] RUN_BUILD_ASSETS=0, pulando build."
fi

# ----------------------------
# 9) Limpa cache e sobe
# ----------------------------
bench --site "${SITE_NAME}" clear-cache || true
echo "[init] Subindo bench start..."
exec bench start
