#!/usr/bin/env bash
set -euo pipefail

ANET_DIR="/opt/anet"
CLIENTS_DIR="${ANET_DIR}/clients"
NODE_ENV="${ANET_DIR}/node.env"
USERS_TSV="${ANET_DIR}/users.tsv"
SERVER_TOML="${ANET_DIR}/server.toml"
CLIENT_TEMPLATE="${ANET_DIR}/client_template.toml"
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
echo "=========================================================="
echo "   Установка ANet VPN Server (автономно, без БД и Nginx)"
echo "=========================================================="
echo

info "Устанавливаю базовые системные пакеты..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl unzip openssl openssh-client iptables iproute2 python3 ca-certificates >/dev/null
ok "Системные пакеты готовы."

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

mkdir -p "${ANET_DIR}" "${CLIENTS_DIR}"
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

echo
info "Настройка параметров сервера (нажмите Enter для значения по умолчанию):"
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

read -rp "  Название сервера в приложении [HomeVPS]: " NODE_NAME
NODE_NAME="${NODE_NAME:-HomeVPS}"

echo
echo "--- Базовые транспорты (работают сразу по IP) ---"
QUIC_PORT="$(ask_port "QUIC (UDP, самый быстрый)" "4519")"
while true; do
  SSH_PORT="$(ask_port "SSH (TCP, резерв — не ставьте 22)" "822")"
  if [[ "${SSH_PORT}" == "22" ]]; then
    warn "Порт 22 обычно занят системным SSH вашего VPS! Выберите другой (например 822)."
    continue
  fi
  break
done
while true; do
  VNC_PORT="$(ask_port "VNC (TCP, резерв)" "56678")"
  if [[ "${VNC_PORT}" != "0" && "${VNC_PORT}" == "${SSH_PORT}" ]]; then
    warn "Порт VNC не должен совпадать с портом SSH (${SSH_PORT})."
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
info "Генерирую криптографические ключи и сертификаты сервера..."

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

ok "Ключи сервера сгенерированы."

info "Сохраняю ${NODE_ENV} и настраиваю ${SERVER_TOML}..."
umask 077
cat > "${NODE_ENV}" <<EOF
ANET_VERSION=$(printf '%q' "${TAG_NAME}")
SERVER_IP=$(printf '%q' "${SERVER_IP}")
NODE_NAME=$(printf '%q' "${NODE_NAME}")
SERVER_PUB_KEY=$(printf '%q' "${SERVER_PUB_KEY}")
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

[[ -f "${USERS_TSV}" ]] || : > "${USERS_TSV}"
chmod 600 "${USERS_TSV}"

export TMP_CERT_PEM="${TMP_DIR}/quic_cert.pem"
export TMP_KEY_PEM="${TMP_DIR}/quic_key.pem"
export SERVER_TOML SERVER_SIGNING_KEY SSH_KEY_PATH
export QUIC_ENABLED QUIC_PORT SSH_ENABLED SSH_PORT VNC_ENABLED VNC_PORT
export WRTC_ENABLED WRTC_ROOM_URL WRTC_MODE
export IMAP_ENABLED IMAP_HOST IMAP_PORT IMAP_EMAIL IMAP_SERVER_PASS

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
    ("authentication", "auth_servers"): "[]",
    ("authentication", "auth_server_token"): '""',
    ("control_plane", "node_id"): '""',
    ("control_plane", "url"): '""',
    ("control_plane", "token"): '""',
    ("crypto", "quic_cert"): f'"""\n{cert_pem}\n"""',
    ("crypto", "quic_key"): f'"""\n{key_pem}\n"""',
    ("crypto", "server_signing_key"): f'"{os.environ["SERVER_SIGNING_KEY"]}"',
}

def apply_updates(src: str, kv_updates: dict) -> str:
    lines = src.splitlines(keepends=True)
    out = []
    sec = ""
    in_ml = False
    done = set()
    i = 0
    sec_re = re.compile(r'^\s*\[([^\[\]]+)\]\s*(?:#.*)?$')
    key_re = re.compile(r'^\s*(?:#\s*)?([A-Za-z0-9_]+)\s*=')

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        if in_ml:
            if '"""' in line:
                in_ml = False
            i += 1
            continue

        m_sec = sec_re.match(line)
        if m_sec and not stripped.startswith("[["):
            # Flush any missing keys for previous section
            for (s, k), val in kv_updates.items():
                if s == sec and (s, k) not in done:
                    out.append(f"{k} = {val}\n")
                    done.add((s, k))
            sec = m_sec.group(1).strip()
            out.append(line)
            i += 1
            continue

        m_key = key_re.match(line)
        if m_key and (sec, m_key.group(1)) in kv_updates:
            k = m_key.group(1)
            is_commented = stripped.startswith("#")
            if not is_commented:
                # Skip multiline if active value starts with """
                rhs = line.split("=", 1)[1].lstrip()
                if rhs.startswith('"""') and rhs.count('"""') < 2:
                    in_ml = True
            if (sec, k) not in done:
                out.append(f"{k} = {kv_updates[(sec, k)]}\n")
                done.add((sec, k))
            else:
                out.append(line)
            i += 1
            continue

        out.append(line)
        i += 1

    for (s, k), val in kv_updates.items():
        if s == sec and (s, k) not in done:
            out.append(f"{k} = {val}\n")
            done.add((s, k))

    return "".join(out)

updated = apply_updates(text, updates)
with open(toml_path, "w", encoding="utf-8") as f:
    f.write(updated)

try:
    import tomllib
    tomllib.loads(updated)
except ImportError:
    pass
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
After=network-online.target anet-nat.service
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
  ok "Сервис anet-vpn запущен и работает!"
else
  warn "Сервис anet-vpn не запустился. Последние строки журнала:"
  journalctl -u anet-vpn -n 25 --no-pager || true
  exit 1
fi

# Копируем соседние скрипты управления в /opt/anet для удобства, если они лежат рядом
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for s in anet-users.sh anet-protocols.sh; do
  if [[ -f "${SCRIPT_DIR}/${s}" ]]; then
    cp "${SCRIPT_DIR}/${s}" "${ANET_DIR}/${s}"
    chmod 755 "${ANET_DIR}/${s}"
  fi
done

echo
read -rp "Добавить первого пользователя прямо сейчас? (введите имя или Enter для пропуска): " FIRST_USER
FIRST_USER="${FIRST_USER// /}"
if [[ -n "${FIRST_USER}" ]]; then
  if [[ -x "${ANET_DIR}/anet-users.sh" ]]; then
    bash "${ANET_DIR}/anet-users.sh" add "${FIRST_USER}"
  elif [[ -f "${SCRIPT_DIR}/anet-users.sh" ]]; then
    bash "${SCRIPT_DIR}/anet-users.sh" add "${FIRST_USER}"
  else
    warn "Скрипт anet-users.sh не найден рядом. Запустите его вручную: bash anet-users.sh add ${FIRST_USER}"
  fi
fi

echo
echo "=========================================================="
ok "Установка ANet завершена! (версия ${TAG_NAME})"
echo "  IP сервера:    ${SERVER_IP}"
(( QUIC_ENABLED == 1 )) && echo "  QUIC (UDP):    ${QUIC_PORT}"
(( SSH_ENABLED == 1 ))  && echo "  SSH  (TCP):    ${SSH_PORT}"
(( VNC_ENABLED == 1 ))  && echo "  VNC  (TCP):    ${VNC_PORT}"
(( WRTC_ENABLED == 1 )) && echo "  WRTC:          ${WRTC_ROOM_URL}"
(( IMAP_ENABLED == 1 )) && echo "  IMAP:          ${IMAP_EMAIL} (${IMAP_HOST}:${IMAP_PORT})"
echo
echo "Дальнейшие команды:"
echo "  • Пользователи (семья): bash anet-users.sh"
echo "  • Протоколы и порты:    bash anet-protocols.sh"
echo "  • Логи сервера:         journalctl -u anet-vpn -f"
echo "=========================================================="
