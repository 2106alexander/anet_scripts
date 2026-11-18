#!/usr/bin/env bash
set -euo pipefail

ANET_DIR="/opt/anet"
NODE_ENV="${ANET_DIR}/node.env"
SERVER_TOML="${ANET_DIR}/server.toml"
CLIENT_TEMPLATE="${ANET_DIR}/client_template.toml"
COMPOSE_FILE="${ANET_DIR}/docker-compose.yaml"
SSH_KEY_PATH="${ANET_DIR}/anet_ssh_host_key"
REPO="ZeroTworu/anet"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[ОШИБКА]${NC} $*"; exit 1; }

if [[ "${EUID}" -ne 0 ]]; then
  fail "Запустите скрипт от пользователя root: sudo bash $0"
fi

ARCH="$(uname -m)"
if [[ "${ARCH}" != "x86_64" ]]; then
  fail "Готовые серверные бинарники ANet собираются только под x86_64 (сейчас: ${ARCH})."
fi

if ! command -v systemctl >/dev/null 2>&1; then
  fail "Не найден systemctl (требуется Linux с systemd, например Ubuntu 22.04/24.04 или Debian 12)."
fi

if ! command -v apt-get >/dev/null 2>&1; then
  fail "Скрипт рассчитан на Ubuntu / Debian (не найден apt-get)."
fi

is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

ask_port() {
  local label="$1"
  local default_val="$2"
  local input=""
  while true; do
    read -rp "  ${label} [${default_val}] (или 0 чтобы выключить): " input
    input="${input// /}"
    if [[ -z "$input" ]]; then
      echo "$default_val"
      return 0
    fi
    if [[ "$input" == "0" || "${input,,}" == "off" || "${input,,}" == "no" || "${input,,}" == "нет" ]]; then
      echo "0"
      return 0
    fi
    if is_valid_port "$input"; then
      echo "$input"
      return 0
    fi
    echo "  Введите число от 1 до 65535 (или 0 для отключения, или Enter для ${default_val})." >&2
  done
}

normalize_wrtc_url() {
  local raw="$1"
  raw="${raw// /}"
  if [[ -z "$raw" ]]; then
    echo ""
    return 0
  fi
  if [[ "$raw" == https://* ]]; then
    echo "wrtc://${raw#https://}"
  elif [[ "$raw" == http://* ]]; then
    echo "wrtc://${raw#http://}"
  elif [[ "$raw" == wrtc://* ]]; then
    echo "$raw"
  else
    echo "wrtc://${raw}"
  fi
}

echo
echo "================================================================"
echo "   Установка ANet VPN + веб-панель управления (anet-auth/WebUI)"
echo "================================================================"
echo

info "Устанавливаю базовые системные пакеты..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl unzip openssl openssh-client iptables iproute2 python3 ca-certificates >/dev/null
ok "Системные пакеты готовы."

if ! command -v docker >/dev/null 2>&1; then
  info "Docker не найден — устанавливаю docker.io и плагин docker-compose..."
  apt-get install -y -qq docker.io docker-compose-v2 >/dev/null 2>&1 \
    || apt-get install -y -qq docker.io docker-compose >/dev/null
  systemctl enable --now docker
fi

if docker compose version >/dev/null 2>&1; then
  DC_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC_CMD=(docker-compose)
else
  info "Устанавливаю docker-compose..."
  apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 \
    || apt-get install -y -qq docker-compose >/dev/null
  if docker compose version >/dev/null 2>&1; then
    DC_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    DC_CMD=(docker-compose)
  else
    fail "Не удалось найти docker compose."
  fi
fi
ok "Docker готов (${DC_CMD[*]})."

info "Ищу последний релиз ${REPO} на GitHub..."
RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")" \
  || fail "Не удалось получить информацию о релизе с GitHub API."

read -r TAG_NAME SERVER_ZIP_URL < <(
  python3 -c '
import json, sys
data = json.load(sys.stdin)
tag = data.get("tag_name", "")
url = ""
for asset in data.get("assets", []):
    name = asset.get("name", "")
    if name.startswith("server_") and name.endswith(".zip"):
        url = asset.get("browser_download_url", "")
        break
print(tag, url)
' <<< "${RELEASE_JSON}"
)

if [[ -z "${TAG_NAME}" || -z "${SERVER_ZIP_URL}" ]]; then
  fail "Не найден архив server_*.zip в последнем релизе GitHub."
fi
ok "Найден релиз ${TAG_NAME}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

info "Скачиваю ${SERVER_ZIP_URL}..."
curl -fsSL -L "${SERVER_ZIP_URL}" -o "${TMP_DIR}/server.zip" || fail "Ошибка скачивания архива сервера."
unzip -q "${TMP_DIR}/server.zip" -d "${TMP_DIR}/unpack"

[[ -f "${TMP_DIR}/unpack/server/anet-server" ]] || fail "В архиве не найден server/anet-server"
[[ -f "${TMP_DIR}/unpack/server/keygen/anet-keygen" ]] || fail "В архиве не найден server/keygen/anet-keygen"

if systemctl is-active --quiet anet-vpn 2>/dev/null; then
  info "Останавливаю текущий сервис anet-vpn перед обновлением..."
  systemctl stop anet-vpn
fi

mkdir -p "${ANET_DIR}"
cp "${TMP_DIR}/unpack/server/anet-server" "${ANET_DIR}/anet-server"
cp "${TMP_DIR}/unpack/server/keygen/anet-keygen" "${ANET_DIR}/anet-keygen"
chmod 755 "${ANET_DIR}/anet-server" "${ANET_DIR}/anet-keygen"

if [[ -f "${TMP_DIR}/unpack/server/server.toml" ]]; then
  cp "${TMP_DIR}/unpack/server/server.toml" "${SERVER_TOML}"
else
  fail "В архиве не найден шаблон server/server.toml"
fi

info "Загружаю шаблон клиентского конфига client_template.toml..."
if ! curl -fsSL -L "https://raw.githubusercontent.com/${REPO}/${TAG_NAME}/contrib/client_template.toml" -o "${CLIENT_TEMPLATE}"; then
  warn "Не удалось скачать client_template.toml с GitHub, использую встроенный минимальный шаблон."
  cat > "${CLIENT_TEMPLATE}" <<'EOF'
[main]
tun_name = "anet-client"
manual_routing = false
per_app = {{PER_APP}}
per_app_mode = "{{PER_APP_MODE}}"
route_for = {{ROUTE_FOR}}
exclude_route_for = {{EXCLUDE_ROUTE_FOR}}
dns_server_list = ["1.1.1.1", "8.8.8.8"]
update_url = "https://api.github.com/repos/ZeroTworu/anet/releases/latest"

[keys]
private_key = "{{PRIVATE_KEY}}"
server_pub_key = "{{SERVER_PUB_KEY}}"

[stats]
enabled = true
interval_minutes = 1

[routing]
rules_url = "{{RULES_URL}}"
EOF
fi
chmod 644 "${CLIENT_TEMPLATE}"

echo
info "Настройка сервера и веб-панели (нажмите Enter для значения по умолчанию):"
echo

DETECTED_IP="$(curl -fsSL -4 --max-time 4 https://api.ipify.org 2>/dev/null || curl -fsSL -4 --max-time 4 https://ifconfig.me 2>/dev/null || true)"
DETECTED_IP="${DETECTED_IP// /}"
while true; do
  if [[ -n "${DETECTED_IP}" ]]; then
    read -rp "  Внешний IP или домен VPS [${DETECTED_IP}]: " SERVER_IP
    SERVER_IP="${SERVER_IP:-$DETECTED_IP}"
  else
    read -rp "  Внешний IP или домен VPS: " SERVER_IP
  fi
  SERVER_IP="${SERVER_IP// /}"
  [[ -n "${SERVER_IP}" ]] && break
  echo "  Адрес сервера не может быть пустым."
done

read -rp "  Название ноды в панели и клиенте [HomeVPS]: " NODE_NAME
NODE_NAME="${NODE_NAME:-HomeVPS}"

echo
echo "--- Настройка входа в веб-панель ---"
while true; do
  read -rp "  TCP порт для веб-панели (браузер) [80]: " WEBUI_PORT
  WEBUI_PORT="${WEBUI_PORT// /}"
  WEBUI_PORT="${WEBUI_PORT:-80}"
  if is_valid_port "${WEBUI_PORT}" && [[ "${WEBUI_PORT}" != "22" && "${WEBUI_PORT}" != "3000" ]]; then
    break
  fi
  warn "Укажите свободный TCP порт от 1 до 65535 (кроме 22 и 3000)."
done

read -rp "  Логин администратора панели [admin]: " ADMIN_LOGIN
ADMIN_LOGIN="${ADMIN_LOGIN// /}"
ADMIN_LOGIN="${ADMIN_LOGIN:-admin}"

while true; do
  read -rsp "  Пароль администратора панели: " ADMIN_PASS
  echo
  if [[ -z "${ADMIN_PASS}" ]]; then
    warn "Пароль не может быть пустым."
    continue
  fi
  read -rsp "  Повторите пароль администратора: " ADMIN_PASS_2
  echo
  if [[ "${ADMIN_PASS}" != "${ADMIN_PASS_2}" ]]; then
    warn "Пароли не совпадают, попробуйте ещё раз."
    continue
  fi
  break
done

echo
echo "--- Базовые транспорты VPN (работают сразу по IP) ---"
QUIC_PORT="$(ask_port "QUIC (UDP, самый быстрый)" "4519")"
while true; do
  SSH_PORT="$(ask_port "SSH (TCP, резерв — не ставьте 22)" "822")"
  if [[ "${SSH_PORT}" == "22" || "${SSH_PORT}" == "${WEBUI_PORT}" || "${SSH_PORT}" == "3000" ]]; then
    warn "Порт ${SSH_PORT} занят системой или панелью! Выберите другой (например 822)."
    continue
  fi
  break
done
while true; do
  VNC_PORT="$(ask_port "VNC (TCP, резерв)" "56678")"
  if [[ "${VNC_PORT}" != "0" && ( "${VNC_PORT}" == "${SSH_PORT}" || "${VNC_PORT}" == "${WEBUI_PORT}" || "${VNC_PORT}" == "3000" || "${VNC_PORT}" == "22" ) ]]; then
    warn "Порт VNC конфликтует с другим занятым портом."
    continue
  fi
  break
done

echo
echo "--- Дополнительные транспорты обхода (Enter — пропустить и не включать) ---"
read -rp "  WRTC (ссылка на комнату Контур.Толк, напр. https://xxx.ktalk.ru/room): " WRTC_RAW
WRTC_ROOM_URL="$(normalize_wrtc_url "${WRTC_RAW}")"
WRTC_ENABLED=0
WRTC_MODE="media_video"
if [[ -n "${WRTC_ROOM_URL}" ]]; then
  WRTC_ENABLED=1
fi

read -rp "  IMAP (почта Mail.ru для резерва, напр. user@mail.ru): " IMAP_EMAIL
IMAP_EMAIL="${IMAP_EMAIL// /}"
IMAP_ENABLED=0
IMAP_HOST="imap.mail.ru"
IMAP_PORT="993"
IMAP_SERVER_PASS=""
IMAP_CLIENT_PASS=""
if [[ -n "${IMAP_EMAIL}" ]]; then
  IMAP_ENABLED=1
  read -rp "    IMAP сервер [${IMAP_HOST}]: " tmp_host
  IMAP_HOST="${tmp_host:-$IMAP_HOST}"
  read -rp "    IMAP порт [${IMAP_PORT}]: " tmp_port
  IMAP_PORT="${tmp_port:-$IMAP_PORT}"
  while [[ -z "${IMAP_SERVER_PASS}" ]]; do
    read -rsp "    Пароль приложения для сервера: " IMAP_SERVER_PASS
    echo
  done
  read -rsp "    Пароль приложения для клиентов [Enter — такой же]: " IMAP_CLIENT_PASS
  echo
  IMAP_CLIENT_PASS="${IMAP_CLIENT_PASS:-$IMAP_SERVER_PASS}"
fi

QUIC_ENABLED=0; [[ "${QUIC_PORT}" != "0" ]] && QUIC_ENABLED=1
SSH_ENABLED=0;  [[ "${SSH_PORT}" != "0" ]] && SSH_ENABLED=1
VNC_ENABLED=0;  [[ "${VNC_PORT}" != "0" ]] && VNC_ENABLED=1

if (( QUIC_ENABLED == 0 && SSH_ENABLED == 0 && VNC_ENABLED == 0 && WRTC_ENABLED == 0 && IMAP_ENABLED == 0 )); then
  fail "Вы отключили все транспорты! Включите хотя бы один."
fi

echo
info "Генерирую криптографические ключи сервера и секреты панели..."

KEYGEN_OUT="$("${ANET_DIR}/anet-keygen" server)"
read -r SERVER_SIGNING_KEY SERVER_PUB_KEY < <(
  python3 -c '
import re, sys
text = sys.stdin.read()
m = re.search(r"server_signing_key\s*=\s*\"([^\"]+)\"", text)
sign_key = m.group(1) if m else ""
pub_key = ""
lines = [l.strip() for l in text.splitlines()]
for i, line in enumerate(lines):
    if line.startswith("Public Key") and i + 1 < len(lines):
        pub_key = lines[i + 1]
        break
print(sign_key, pub_key)
' <<< "${KEYGEN_OUT}"
)
[[ -n "${SERVER_SIGNING_KEY}" && -n "${SERVER_PUB_KEY}" ]] || fail "Не удалось разобрать вывод anet-keygen server."

openssl req -x509 -newkey ed25519 \
  -keyout "${TMP_DIR}/quic_key.pem" \
  -out "${TMP_DIR}/quic_cert.pem" \
  -days 3650 -nodes \
  -subj "/CN=alco" \
  -addext "subjectAltName = DNS:alco" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=digitalSignature,keyEncipherment" >/dev/null 2>&1

if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH}" -N "" -q
fi
chmod 600 "${SSH_KEY_PATH}" "${SSH_KEY_PATH}.pub" 2>/dev/null || true

# Секреты БД и панели (генерируются один раз или переиспользуются при повторном запуске)
PG_PASS="$(openssl rand -hex 20)"
AUTH_BACKEND_KEY="$(openssl rand -hex 24)"
JWT_SECRET="$(openssl rand -hex 32)"
DB_ENCRYPTION_KEY="$(openssl rand -hex 32)"

if [[ -f "${ANET_DIR}/panel.secrets.env" ]]; then
  # Сохраняем прежние ключи БД/JWT, чтобы не сломать уже существующую БД при обновлении
  # shellcheck disable=SC1090
  source "${ANET_DIR}/panel.secrets.env"
fi

umask 077
cat > "${ANET_DIR}/panel.secrets.env" <<EOF
PG_PASS=$(printf '%q' "${PG_PASS}")
AUTH_BACKEND_KEY=$(printf '%q' "${AUTH_BACKEND_KEY}")
JWT_SECRET=$(printf '%q' "${JWT_SECRET}")
DB_ENCRYPTION_KEY=$(printf '%q' "${DB_ENCRYPTION_KEY}")
EOF
chmod 600 "${ANET_DIR}/panel.secrets.env"

if [[ "${WEBUI_PORT}" == "80" ]]; then
  PUBLIC_URL="http://${SERVER_IP}"
else
  PUBLIC_URL="http://${SERVER_IP}:${WEBUI_PORT}"
fi

info "Создаю ${COMPOSE_FILE} и запускаю PostgreSQL + anet-auth + anet-webui..."
cat > "${COMPOSE_FILE}" <<EOF
services:
  postgres:
    image: postgres:17-alpine
    container_name: anet-db
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${PG_PASS}
      POSTGRES_DB: db
    volumes:
      - anet_pg_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d db"]
      interval: 2s
      timeout: 5s
      retries: 10
    restart: unless-stopped

  anet-auth:
    image: ghcr.io/zerotworu/anet-auth:latest
    container_name: anet-auth
    environment:
      DATABASE_URL: postgres://postgres:${PG_PASS}@postgres:5432/db
      BIND_TO: 0.0.0.0:3000
      AUTH_BACKEND_KEY: ${AUTH_BACKEND_KEY}
      JWT_SECRET: ${JWT_SECRET}
      DB_ENCRYPTION_KEY: ${DB_ENCRYPTION_KEY}
      CLIENT_TEMPLATE_PATH: /opt/anet/client_template.toml
      ANET_PUBLIC_URL: ${PUBLIC_URL}
      RUST_LOG: info
    volumes:
      - ${CLIENT_TEMPLATE}:/opt/anet/client_template.toml:ro
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "127.0.0.1:3000:3000"
    restart: unless-stopped

  anet-webui:
    image: ghcr.io/zerotworu/anet-webui:latest
    container_name: anet-webui
    ports:
      - "${WEBUI_PORT}:80"
    depends_on:
      - anet-auth
    restart: unless-stopped

volumes:
  anet_pg_data:
EOF
chmod 600 "${COMPOSE_FILE}"

"${DC_CMD[@]}" -f "${COMPOSE_FILE}" pull
"${DC_CMD[@]}" -f "${COMPOSE_FILE}" up -d --force-recreate

info "Жду запуска anet-auth и применения миграций БД..."
AUTH_READY=0
for _ in $(seq 1 45); do
  if curl -fsS http://127.0.0.1:3000/spec >/dev/null 2>&1; then
    AUTH_READY=1
    break
  fi
  sleep 2
done
(( AUTH_READY == 1 )) || fail "anet-auth не ответил на 127.0.0.1:3000. Проверьте: docker logs anet-auth"
ok "Бэкенд anet-auth и база PostgreSQL запущены!"

info "Создаю администратора '${ADMIN_LOGIN}' в панели и регистрирую ноду '${NODE_NAME}'..."
export ADMIN_LOGIN ADMIN_PASS SERVER_IP NODE_NAME SERVER_PUB_KEY
export QUIC_ENABLED QUIC_PORT SSH_ENABLED SSH_PORT VNC_ENABLED VNC_PORT
export WRTC_ENABLED WRTC_ROOM_URL WRTC_MODE
export IMAP_ENABLED IMAP_HOST IMAP_PORT IMAP_EMAIL IMAP_SERVER_PASS IMAP_CLIENT_PASS

read -r NODE_ID NODE_TOKEN < <(
  python3 - <<'PY'
import json, os, pty, select, subprocess, sys, time, urllib.error, urllib.request

admin_login = os.environ["ADMIN_LOGIN"]
admin_pass = os.environ["ADMIN_PASS"]

def api_call(method, path, payload=None, token=None):
    url = f"http://127.0.0.1:3000/api/v1{path}"
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as resp:
        raw = resp.read().decode("utf-8").strip()
        return json.loads(raw) if raw else None

def try_login():
    try:
        res = api_call("POST", "/login", {"login": admin_login, "password": admin_pass})
        return res.get("access_token") if res else None
    except urllib.error.HTTPError:
        return None

jwt = try_login()
if not jwt:
    # Запускаем ./anet-auth --add-su внутри pty, чтобы rpassword корректно считал пароль
    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        ["docker", "exec", "-i", "anet-auth", "./anet-auth", "--add-su", admin_login],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
    )
    os.close(slave_fd)
    sent = False
    deadline = time.time() + 20
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([master_fd], [], [], 0.3)
        if r:
            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            if not sent and (b"Password" in buf or b":" in buf):
                time.sleep(0.1)
                os.write(master_fd, (admin_pass + "\n").encode("utf-8"))
                sent = True
        if proc.poll() is not None:
            break
    if not sent:
        try:
            os.write(master_fd, (admin_pass + "\n").encode("utf-8"))
        except OSError:
            pass
    proc.wait(timeout=10)
    os.close(master_fd)
    jwt = try_login()

if not jwt:
    sys.stderr.write("Не удалось авторизоваться в anet-auth после создания администратора.\n")
    sys.exit(1)

srv_payload = {
    "name": os.environ["NODE_NAME"],
    "address": os.environ["SERVER_IP"],
    "public_key": os.environ["SERVER_PUB_KEY"],
    "quic_port": int(os.environ["QUIC_PORT"]) if os.environ["QUIC_ENABLED"] == "1" else None,
    "ssh_port": int(os.environ["SSH_PORT"]) if os.environ["SSH_ENABLED"] == "1" else None,
    "vnc_port": int(os.environ["VNC_PORT"]) if os.environ["VNC_ENABLED"] == "1" else None,
    "websocket_url": None,
    "ahttp_url": None,
    "wrtc_url": os.environ["WRTC_ROOM_URL"] if os.environ["WRTC_ENABLED"] == "1" else None,
    "wrtc_mode": os.environ["WRTC_MODE"] if os.environ["WRTC_ENABLED"] == "1" else None,
    "ssh_user": "hanyuu",
    "is_active": True,
}

existing = api_call("GET", "/servers", token=jwt) or []
node_id = ""
for srv in existing:
    if srv.get("name") == os.environ["NODE_NAME"]:
        node_id = srv["id"]
        api_call("PATCH", f"/servers/{node_id}", srv_payload, token=jwt)
        break

if not node_id:
    created = api_call("POST", "/servers", srv_payload, token=jwt)
    node_id = created["id"]
    # В create_server поле address при создании сбрасывается в "", поэтому дозаписываем через PATCH
    api_call("PATCH", f"/servers/{node_id}", {"address": os.environ["SERVER_IP"]}, token=jwt)

cred = api_call("POST", f"/servers/{node_id}/credentials", {}, token=jwt)
node_token = cred["token"]

if os.environ["IMAP_ENABLED"] == "1" and os.environ.get("IMAP_EMAIL"):
    mailboxes = api_call("GET", "/mailboxes", token=jwt) or []
    already = any(m.get("email") == os.environ["IMAP_EMAIL"] for m in mailboxes)
    if not already:
        api_call(
            "POST",
            "/mailboxes",
            {
                "host": os.environ["IMAP_HOST"],
                "port": int(os.environ["IMAP_PORT"]),
                "email": os.environ["IMAP_EMAIL"],
                "client_password": os.environ["IMAP_CLIENT_PASS"],
                "server_password": os.environ["IMAP_SERVER_PASS"],
                "is_active": True,
            },
            token=jwt,
        )

print(node_id, node_token)
PY
)
[[ -n "${NODE_ID}" && -n "${NODE_TOKEN}" ]] || fail "Не удалось зарегистрировать ноду в anet-auth."
ok "Нода зарегистрирована в панели (node_id=${NODE_ID})."

info "Сохраняю ${NODE_ENV} и настраиваю ${SERVER_TOML} для работы с панелью..."
umask 077
cat > "${NODE_ENV}" <<EOF
ANET_VERSION=$(printf '%q' "${TAG_NAME}")
SERVER_IP=$(printf '%q' "${SERVER_IP}")
NODE_NAME=$(printf '%q' "${NODE_NAME}")
SERVER_PUB_KEY=$(printf '%q' "${SERVER_PUB_KEY}")
NODE_ID=$(printf '%q' "${NODE_ID}")
WEBUI_PORT=${WEBUI_PORT}
SSH_USER='hanyuu'
QUIC_ENABLED=${QUIC_ENABLED}
QUIC_PORT=${QUIC_PORT}
SSH_ENABLED=${SSH_ENABLED}
SSH_PORT=${SSH_PORT}
VNC_ENABLED=${VNC_ENABLED}
VNC_PORT=${VNC_PORT}
WRTC_ENABLED=${WRTC_ENABLED}
WRTC_ROOM_URL=$(printf '%q' "${WRTC_ROOM_URL}")
WRTC_MODE=$(printf '%q' "${WRTC_MODE}")
IMAP_ENABLED=${IMAP_ENABLED}
IMAP_HOST=$(printf '%q' "${IMAP_HOST}")
IMAP_PORT=${IMAP_PORT}
IMAP_EMAIL=$(printf '%q' "${IMAP_EMAIL}")
IMAP_SERVER_PASS=$(printf '%q' "${IMAP_SERVER_PASS}")
IMAP_CLIENT_PASS=$(printf '%q' "${IMAP_CLIENT_PASS}")
EOF
chmod 600 "${NODE_ENV}"

export TMP_CERT_PEM="${TMP_DIR}/quic_cert.pem"
export TMP_KEY_PEM="${TMP_DIR}/quic_key.pem"
export SERVER_TOML SERVER_SIGNING_KEY SSH_KEY_PATH AUTH_BACKEND_KEY NODE_ID NODE_TOKEN

python3 - <<'PY'
import os, re, urllib.parse

toml_path = os.environ["SERVER_TOML"]
with open(toml_path, "r", encoding="utf-8") as f:
    text = f.read()

with open(os.environ["TMP_CERT_PEM"], "r", encoding="utf-8") as f:
    cert_pem = f.read().strip()
with open(os.environ["TMP_KEY_PEM"], "r", encoding="utf-8") as f:
    key_pem = f.read().strip()

quic_bind = f"0.0.0.0:{os.environ['QUIC_PORT']}" if os.environ["QUIC_ENABLED"] == "1" else ""
ssh_bind  = f"0.0.0.0:{os.environ['SSH_PORT']}"  if os.environ["SSH_ENABLED"] == "1"  else ""
vnc_bind  = f"0.0.0.0:{os.environ['VNC_PORT']}"  if os.environ["VNC_ENABLED"] == "1"  else ""

imap_dsn = ""
if os.environ["IMAP_ENABLED"] == "1":
    email_q = urllib.parse.quote(os.environ["IMAP_EMAIL"], safe="")
    pass_q  = urllib.parse.quote(os.environ["IMAP_SERVER_PASS"], safe="")
    imap_dsn = f"imaps://{os.environ['IMAP_HOST']}:{os.environ['IMAP_PORT']}?acc={email_q}:{pass_q}"

wrtc_url = os.environ["WRTC_ROOM_URL"] if os.environ["WRTC_ENABLED"] == "1" else ""

updates = {
    ("server", "quic_bind_to"): f'"{quic_bind}"',
    ("server", "ssh_bind_to"): f'"{ssh_bind}"',
    ("server", "vnc_bind_to"): f'"{vnc_bind}"',
    ("server", "websocket_bind_to"): '""',
    ("server", "ahttp_bind_to"): '""',
    ("server", "ssh_host_key"): f'"{os.environ["SSH_KEY_PATH"]}"',
    ("server", "wrtc_room_url"): f'"{wrtc_url}"',
    ("server", "wrtc_mode"): f'"{os.environ["WRTC_MODE"]}"',
    ("server", "imap_dsn"): f'"{imap_dsn}"',
    ("authentication", "allowed_clients"): "[]",
    ("authentication", "auth_servers"): '["http://127.0.0.1:3000/api/v1"]',
    ("authentication", "auth_server_token"): f'"{os.environ["AUTH_BACKEND_KEY"]}"',
    ("control_plane", "node_id"): f'"{os.environ["NODE_ID"]}"',
    ("control_plane", "url"): '"http://127.0.0.1:3000/api/v1"',
    ("control_plane", "token"): f'"{os.environ["NODE_TOKEN"]}"',
    ("crypto", "quic_cert"): f'"""\n{cert_pem}\n"""',
    ("crypto", "quic_key"): f'"""\n{key_pem}\n"""',
    ("crypto", "server_signing_key"): f'"{os.environ["SERVER_SIGNING_KEY"]}"',
}

lines = text.splitlines(keepends=True)
out = []
sec = ""
skip_ml = False
keep_ml = False
done = set()
sec_re = re.compile(r'^\s*\[([^\[\]]+)\]\s*(?:#.*)?$')
key_re = re.compile(r'^\s*(?:#\s*)?([A-Za-z0-9_]+)\s*=')

for line in lines:
    stripped = line.strip()
    if skip_ml:
        if '"""' in line:
            skip_ml = False
        continue
    if keep_ml:
        out.append(line)
        if '"""' in line:
            keep_ml = False
        continue

    m_sec = sec_re.match(line)
    if m_sec and not stripped.startswith("[["):
        for (s, k), val in updates.items():
            if s == sec and (s, k) not in done:
                out.append(f"{k} = {val}\n")
                done.add((s, k))
        sec = m_sec.group(1).strip()
        out.append(line)
        continue

    m_key = key_re.match(line)
    if m_key and (sec, m_key.group(1)) in updates:
        k = m_key.group(1)
        if not stripped.startswith("#"):
            rhs = line.split("=", 1)[1].lstrip()
            if rhs.startswith('"""') and rhs.count('"""') < 2:
                skip_ml = True
        if (sec, k) not in done:
            out.append(f"{k} = {updates[(sec, k)]}\n")
            done.add((sec, k))
        else:
            out.append(line)
        continue

    if not stripped.startswith("#") and "=" in line:
        rhs = line.split("=", 1)[1].lstrip()
        if rhs.startswith('"""') and rhs.count('"""') < 2:
            keep_ml = True
    out.append(line)

for (s, k), val in updates.items():
    if s == sec and (s, k) not in done:
        out.append(f"{k} = {val}\n")
        done.add((s, k))

updated = "".join(out)
try:
    import tomllib
    tomllib.loads(updated)
except ImportError:
    pass

with open(toml_path, "w", encoding="utf-8") as f:
    f.write(updated)
PY

chmod 600 "${SERVER_TOML}"
ok "Конфигурация server.toml сохранена."

info "Настраиваю маршрутизацию (ip_forward + NAT без установки файрволла)..."
cat > /etc/sysctl.d/99-anet.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/99-anet.conf >/dev/null

cat > "${ANET_DIR}/setup-nat.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
EXT_IF="$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [[ -z "${EXT_IF}" ]]; then
  echo "Не удалось определить внешний сетевой интерфейс" >&2
  exit 1
fi
iptables -C FORWARD -i "${EXT_IF}" -o anet-server -j ACCEPT 2>/dev/null || iptables -I FORWARD -i "${EXT_IF}" -o anet-server -j ACCEPT
iptables -C FORWARD -i anet-server -o "${EXT_IF}" -j ACCEPT 2>/dev/null || iptables -I FORWARD -i anet-server -o "${EXT_IF}" -j ACCEPT
iptables -t nat -C POSTROUTING -s 172.112.222.0/24 -o "${EXT_IF}" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 172.112.222.0/24 -o "${EXT_IF}" -j MASQUERADE
EOF
chmod 755 "${ANET_DIR}/setup-nat.sh"

cat > /etc/systemd/system/anet-nat.service <<EOF
[Unit]
Description=ANet VPN NAT Setup
After=network-online.target
Wants=network-online.target
Before=anet-vpn.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${ANET_DIR}/setup-nat.sh

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/anet-vpn.service <<EOF
[Unit]
Description=ANet VPN Server
After=network-online.target anet-nat.service docker.service
Requires=anet-nat.service

[Service]
Type=simple
User=root
Environment=RUST_LOG=info
WorkingDirectory=${ANET_DIR}
ExecStart=${ANET_DIR}/anet-server -c ${SERVER_TOML}
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now anet-nat.service
systemctl enable --now anet-vpn.service

sleep 2
if systemctl is-active --quiet anet-vpn; then
  ok "Сервис anet-vpn запущен и подключён к панели!"
else
  warn "Сервис anet-vpn не запустился. Последние строки журнала:"
  journalctl -u anet-vpn -n 25 --no-pager || true
  exit 1
fi

echo
echo "================================================================"
ok "Установка ANet VPN + WebUI завершена! (версия ${TAG_NAME})"
echo "  Веб-панель:    ${PUBLIC_URL}"
echo "  Логин панели:  ${ADMIN_LOGIN}"
echo "  Нода в панели: ${NODE_NAME} (уже добавлена и привязана!)"
echo
echo "  Активные транспорты:"
(( QUIC_ENABLED == 1 )) && echo "    • QUIC (UDP): ${QUIC_PORT}"
(( SSH_ENABLED == 1 ))  && echo "    • SSH  (TCP): ${SSH_PORT}"
(( VNC_ENABLED == 1 ))  && echo "    • VNC  (TCP): ${VNC_PORT}"
(( WRTC_ENABLED == 1 )) && echo "    • WRTC:       ${WRTC_ROOM_URL}"
(( IMAP_ENABLED == 1 )) && echo "    • IMAP:       ${IMAP_EMAIL} (${IMAP_HOST}:${IMAP_PORT})"
echo
echo "  Как добавить семью:"
echo "    1) Откройте ${PUBLIC_URL} в браузере и войдите."
echo "    2) Создайте пользователей и отметьте им сервер '${NODE_NAME}'."
echo "    3) Скачайте их .toml или откройте QR-код прямо из панели."
echo
echo "  Логи ноды:   journalctl -u anet-vpn -f"
echo "  Логи панели: docker logs -f anet-auth"
echo "================================================================"
