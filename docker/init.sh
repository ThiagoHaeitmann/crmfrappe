#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[init] $*"; }

# ----------------------------
# Vars
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

BENCH_DIR="/home/frappe/frappe-bench"
LOCKDIR="/tmp/frappe-init.lock"

# ----------------------------
# GxP controls
# ----------------------------
GXP_MODE="${GXP_MODE:-1}"
AUTO_REPAIR_SITE="${AUTO_REPAIR_SITE:-1}"                 # tenta auto-repair
PROTECT_IF_FILES="${PROTECT_IF_FILES:-1}"                 # se houver arquivos no FS, NÃO repara
PROTECT_IF_DB_HAS_FILES="${PROTECT_IF_DB_HAS_FILES:-1}"   # se houver File no DB, NÃO repara

# ----------------------------
# Helpers
# ----------------------------
wait_tcp() {
  local host="$1" port="$2" name="$3"
  log "Waiting for ${name} at ${host}:${port} ..."
  for i in $(seq 1 180); do
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

derive_db_name() {
  echo "${SITE_NAME}" | tr '.' '_' | tr -cd 'a-zA-Z0-9_'
}

site_db_has_core_tables() {
  "${BENCH_DIR}/env/bin/python" - <<'PY'
import os, sys
import pymysql
db_host=os.environ["DB_HOST"]; db_port=int(os.environ["DB_PORT"])
db_user=os.environ["DB_USER"]; db_pass=os.environ["DB_PASSWORD"]
db_name=os.environ["DB_NAME_EFFECTIVE"]
try:
  conn=pymysql.connect(host=db_host,port=db_port,user=db_user,password=db_pass,database=db_name)
  with conn.cursor() as cur:
    cur.execute("SHOW TABLES LIKE 'tabDefaultValue';")
    row=cur.fetchone()
  conn.close()
  sys.exit(0 if row else 2)
except Exception:
  sys.exit(3)
PY
}

# evidência de documento no filesystem do site?
site_has_files_on_disk() {
  local site_dir="${BENCH_DIR}/sites/${SITE_NAME}"
  [[ -d "${site_dir}" ]] || return 1

  # Qualquer coisa em private/files ou public/files => assume dado/documento
  if [[ -d "${site_dir}/private/files" ]] && find "${site_dir}/private/files" -type f -size +0c 2>/dev/null | head -n 1 | grep -q .; then
    return 0
  fi
  if [[ -d "${site_dir}/public/files" ]] && find "${site_dir}/public/files" -type f -size +0c 2>/dev/null | head -n 1 | grep -q .; then
    return 0
  fi
  return 1
}

# evidência de documento no DB (File doctype)?
db_has_file_records() {
  "${BENCH_DIR}/env/bin/python" - <<'PY'
import os, sys
import pymysql
db_host=os.environ["DB_HOST"]; db_port=int(os.environ["DB_PORT"])
db_user=os.environ["DB_USER"]; db_pass=os.environ["DB_PASSWORD"]
db_name=os.environ["DB_NAME_EFFECTIVE"]
try:
  conn=pymysql.connect(host=db_host,port=db_port,user=db_user,password=db_pass,database=db_name)
  with conn.cursor() as cur:
    cur.execute("SHOW TABLES LIKE 'tabFile';")
    if not cur.fetchone():
      conn.close()
      sys.exit(1)
    cur.execute("SELECT COUNT(*) FROM tabFile;")
    c=cur.fetchone()[0]
  conn.close()
  sys.exit(0 if c and int(c)>0 else 2)
except Exception:
  sys.exit(1)
PY
}

ensure_db_and_user() {
  local db="$1"
  log "Ensuring MariaDB database/user exist: db=${db} user=${DB_USER}"
  DB_NAME_EFFECTIVE="${db}" "${BENCH_DIR}/env/bin/python" - <<'PY'
import os, pymysql
db_host=os.environ["DB_HOST"]; db_port=int(os.environ["DB_PORT"])
root_user=os.environ["DB_ROOT_USERNAME"]; root_pass=os.environ["DB_ROOT_PASSWORD"]
app_user=os.environ["DB_USER"]; app_pass=os.environ["DB_PASSWORD"]
db_name=os.environ["DB_NAME_EFFECTIVE"]

conn=pymysql.connect(host=db_host,port=db_port,user=root_user,password=root_pass,autocommit=True,charset="utf8mb4")

def q_ident(s): return "`"+s.replace("`","``")+"`"
def q_str(s): return "'"+s.replace("\\","\\\\").replace("'","\\'")+"'"

with conn.cursor() as cur:
  cur.execute(f"CREATE DATABASE IF NOT EXISTS {q_ident(db_name)} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")
  cur.execute(f"CREATE USER IF NOT EXISTS {q_ident(app_user)}@'%' IDENTIFIED BY {q_str(app_pass)};")
  cur.execute(f"GRANT ALL PRIVILEGES ON {q_ident(db_name)}.* TO {q_ident(app_user)}@'%';")
  cur.execute("FLUSH PRIVILEGES;")
conn.close()
print("[init] DB ensured OK")
PY
}

recreate_site_hard() {
  log "AUTO-REPAIR: Recreating site+DB (hard reset)..."

  rm -rf "${BENCH_DIR}/sites/${SITE_NAME}" || true

  "${BENCH_DIR}/env/bin/python" - <<'PY'
import os, pymysql
db_host=os.environ["DB_HOST"]; db_port=int(os.environ["DB_PORT"])
root_user=os.environ["DB_ROOT_USERNAME"]; root_pass=os.environ["DB_ROOT_PASSWORD"]
db_name=os.environ["DB_NAME_EFFECTIVE"]
conn=pymysql.connect(host=db_host,port=db_port,user=root_user,password=root_pass,autocommit=True)
with conn.cursor() as cur:
  cur.execute(f"DROP DATABASE IF EXISTS `{db_name}`;")
  cur.execute(f"CREATE DATABASE `{db_name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")
  cur.execute("FLUSH PRIVILEGES;")
conn.close()
print("[init] DB dropped+created OK")
PY

  bench new-site "${SITE_NAME}" \
    --force \
    --admin-password "${ADMIN_PASSWORD}" \
    --db-root-username "${DB_ROOT_USERNAME}" \
    --db-root-password "${DB_ROOT_PASSWORD}" \
    --mariadb-user-host-login-scope=% \
    --no-mariadb-socket
}

# ----------------------------
# lock
# ----------------------------
if ! mkdir "${LOCKDIR}" 2>/dev/null; then
  log "Another init is running (lock=${LOCKDIR}). Exiting."
  exit 1
fi
trap 'rmdir "${LOCKDIR}" 2>/dev/null || true' EXIT

if [ -z "${DB_NAME}" ]; then DB_NAME="$(derive_db_name)"; fi
export DB_NAME_EFFECTIVE="${DB_NAME}"

log "SITE_NAME=${SITE_NAME}"
log "DB=${DB_HOST}:${DB_PORT} root=${DB_ROOT_USERNAME} app_user=${DB_USER} db=${DB_NAME}"
log "REDIS=${REDIS_URL}"
log "FRAPPE_BRANCH=${FRAPPE_BRANCH}"
log "CRM_REPO_URL=${CRM_REPO_URL}"
log "CRM_REF=${CRM_REF}"
log "HTTP_PORT=${HTTP_PORT} SOCKETIO_PORT=${SOCKETIO_PORT}"
log "GXP_MODE=${GXP_MODE} AUTO_REPAIR_SITE=${AUTO_REPAIR_SITE} PROTECT_IF_FILES=${PROTECT_IF_FILES} PROTECT_IF_DB_HAS_FILES=${PROTECT_IF_DB_HAS_FILES}"

# deps
wait_tcp "127.0.0.1" "${REDIS_PORT}" "Redis"
wait_tcp "${DB_HOST}" "${DB_PORT}" "MariaDB"

ensure_sites_logs

# ----------------------------
# bench repair (preserva sites/logs)
# ----------------------------
if ! bench_ok; then
  log "Bench missing/broken. Recreating bench (preserve sites/logs) ..."

  find "${BENCH_DIR}" -mindepth 1 -maxdepth 1 \
    ! -name "sites" ! -name "logs" -exec rm -rf {} + || true

  TMP_DIR="/home/frappe/.bench-tmp.$(date +%s).$RANDOM"
  log "bench init at ${TMP_DIR}"
  bench init --skip-redis-config-generation "${TMP_DIR}" --version "${FRAPPE_BRANCH}"

  log "Syncing bench to ${BENCH_DIR} (excluding sites/logs)..."
  rsync -a --delete --exclude 'sites' --exclude 'logs' "${TMP_DIR}/" "${BENCH_DIR}/"

  log "Fixing editable install paths in final bench env..."
  "${BENCH_DIR}/env/bin/python" -m pip install --quiet --upgrade -e "${BENCH_DIR}/apps/frappe"

  rm -rf "${TMP_DIR}" || true
  ensure_sites_logs

  bench_ok || { log "ERROR: bench still not healthy"; exit 1; }
else
  log "Bench is healthy. Using existing bench."
fi

cd "${BENCH_DIR}"

# ----------------------------
# endpoints
# ----------------------------
log "Configuring DB/Redis endpoints..."
bench set-mariadb-host "${DB_HOST}" || true
bench set-redis-cache-host "${REDIS_URL}" || true
bench set-redis-queue-host "${REDIS_URL}" || true
bench set-redis-socketio-host "${REDIS_URL}" || true
sed -i '/redis/d' ./Procfile 2>/dev/null || true
sed -i '/watch/d' ./Procfile 2>/dev/null || true

# ----------------------------
# app crm
# ----------------------------
if bench list-apps 2>/dev/null | grep -qx 'crm'; then
  log "App crm already installed in bench."
else
  log "Getting app crm..."
  bench get-app crm "${CRM_REPO_URL}" --branch "${CRM_REF}" --skip-assets
fi

# ----------------------------
# site + GxP automatic gate
# ----------------------------
if [[ -d "sites/${SITE_NAME}" ]]; then
  log "Site ${SITE_NAME} exists."
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

ensure_db_and_user "${DB_NAME}"

log "Validating site core schema (tabDefaultValue)..."
if ! site_db_has_core_tables; then
  log "Core schema missing/broken."

  if [[ "${AUTO_REPAIR_SITE}" != "1" ]]; then
    log "AUTO_REPAIR_SITE=0 -> refusing to modify persistent data."
    exit 1
  fi

  # GxP automatic decision: só repara se NÃO houver evidência de dado/documento
  if [[ "${PROTECT_IF_FILES}" == "1" ]] && site_has_files_on_disk; then
    log "GxP STOP: Found files on disk (possible documents). Refusing auto-repair."
    exit 1
  fi

  if [[ "${PROTECT_IF_DB_HAS_FILES}" == "1" ]] && db_has_file_records; then
    log "GxP STOP: Found File records in DB (possible documents). Refusing auto-repair."
    exit 1
  fi

  log "GxP OK: No evidence of documents -> auto-repair allowed."
  recreate_site_hard
  ensure_db_and_user "${DB_NAME}"

  site_db_has_core_tables || { log "ERROR: core tables still missing after auto-repair"; exit 1; }
else
  log "Site schema OK."
fi

# configs do site
log "Applying DB config into site_config..."
bench --site "${SITE_NAME}" set-config db_host "${DB_HOST}" || true
bench --site "${SITE_NAME}" set-config db_port "${DB_PORT}" || true
bench --site "${SITE_NAME}" set-config db_name "${DB_NAME}" || true
bench --site "${SITE_NAME}" set-config db_user "${DB_USER}" || true
bench --site "${SITE_NAME}" set-config db_password "${DB_PASSWORD}" || true

log "Installing crm on site..."
bench --site "${SITE_NAME}" install-app crm

bench --site "${SITE_NAME}" set-config developer_mode "${DEVELOPER_MODE}" || true
bench --site "${SITE_NAME}" set-config mute_emails "${MUTE_EMAILS}" || true
bench --site "${SITE_NAME}" set-config server_script_enabled "${SERVER_SCRIPT_ENABLED}" || true

bench use "${SITE_NAME}" || true

if [ "${RUN_MIGRATE}" = "1" ]; then
  log "Running migrate..."
  bench --site "${SITE_NAME}" migrate
fi

if [ "${RUN_BUILD_ASSETS}" = "1" ]; then
  log "Building assets..."
  bench build --force
fi

bench --site "${SITE_NAME}" clear-cache || true

log "Starting bench..."
exec bench start --port "${HTTP_PORT}" --socketio-port "${SOCKETIO_PORT}"
