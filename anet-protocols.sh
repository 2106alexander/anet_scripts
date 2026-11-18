#!/usr/bin/env bash
set -euo pipefail

ANET_DIR="/opt/anet"
CLIENTS_DIR="${ANET_DIR}/clients"
NODE_ENV="${ANET_DIR}/node.env"
USERS_TSV="${ANET_DIR}/users.tsv"
SERVER_TOML="${ANET_DIR}/server.toml"
CLIENT_TEMPLATE="${ANET_DIR}/client_template.toml"
SSH_KEY_PATH="${ANET_DIR}/anet_ssh_host_key"

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
  fail "Запустите скрипт от root: sudo bash $0"
fi

[[ -f "${NODE_ENV}" && -f "${SERVER_TOML}" ]] \
  || fail "Сервер ANet не установлен в ${ANET_DIR}. Сначала выполните: bash anet-install.sh"

# shellcheck disable=SC1090
source "${NODE_ENV}"

DIRTY=0

is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

normalize_wrtc_url() {
  local raw="$1"
  raw="${raw// /}"
  if [[ -z "$raw" ]]; then
    echo ""
  elif [[ "$raw" == https://* ]]; then
    echo "wrtc://${raw#https://}"
  elif [[ "$raw" == http://* ]]; then
    echo "wrtc://${raw#http://}"
  elif [[ "$raw" == wrtc://* ]]; then
    echo "$raw"
  else
    echo "wrtc://${raw}"
  fi
}

count_enabled() {
  echo $(( QUIC_ENABLED + SSH_ENABLED + VNC_ENABLED + WRTC_ENABLED + IMAP_ENABLED ))
}

save_node_env() {
  umask 077
  cat > "${NODE_ENV}" <<EOF
ANET_VERSION=$(printf '%q' "${ANET_VERSION:-}")
SERVER_IP=$(printf '%q' "${SERVER_IP}")
NODE_NAME=$(printf '%q' "${NODE_NAME:-HomeVPS}")
SERVER_PUB_KEY=$(printf '%q' "${SERVER_PUB_KEY}")
SSH_USER=$(printf '%q' "${SSH_USER:-hanyuu}")
QUIC_ENABLED=${QUIC_ENABLED}
QUIC_PORT=${QUIC_PORT}
SSH_ENABLED=${SSH_ENABLED}
SSH_PORT=${SSH_PORT}
VNC_ENABLED=${VNC_ENABLED}
VNC_PORT=${VNC_PORT}
WRTC_ENABLED=${WRTC_ENABLED}
WRTC_ROOM_URL=$(printf '%q' "${WRTC_ROOM_URL:-}")
WRTC_MODE=$(printf '%q' "${WRTC_MODE:-media_video}")
IMAP_ENABLED=${IMAP_ENABLED}
IMAP_HOST=$(printf '%q' "${IMAP_HOST:-imap.mail.ru}")
IMAP_PORT=${IMAP_PORT:-993}
IMAP_EMAIL=$(printf '%q' "${IMAP_EMAIL:-}")
IMAP_SERVER_PASS=$(printf '%q' "${IMAP_SERVER_PASS:-}")
IMAP_CLIENT_PASS=$(printf '%q' "${IMAP_CLIENT_PASS:-}")
EOF
  chmod 600 "${NODE_ENV}"
}

apply_and_rebuild() {
  if (( $(count_enabled) == 0 )); then
    fail "Нельзя отключить все транспорты одновременно! Включите хотя бы один."
  fi

  if (( SSH_ENABLED == 1 )) && [[ ! -f "${SSH_KEY_PATH}" ]]; then
    info "Создаю SSH ключ хоста ${SSH_KEY_PATH}..."
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH}" -N "" -q
    chmod 600 "${SSH_KEY_PATH}" "${SSH_KEY_PATH}.pub" 2>/dev/null || true
  fi

  save_node_env

  export SERVER_TOML CLIENTS_DIR USERS_TSV CLIENT_TEMPLATE SSH_KEY_PATH
  export SERVER_IP NODE_NAME SERVER_PUB_KEY SSH_USER
  export QUIC_ENABLED QUIC_PORT SSH_ENABLED SSH_PORT VNC_ENABLED VNC_PORT
  export WRTC_ENABLED WRTC_ROOM_URL WRTC_MODE
  export IMAP_ENABLED IMAP_HOST IMAP_PORT IMAP_EMAIL IMAP_SERVER_PASS IMAP_CLIENT_PASS

  info "Обновляю ${SERVER_TOML}..."
  python3 - <<'PY'
import os, re, urllib.parse

toml_path = os.environ["SERVER_TOML"]
with open(toml_path, "r", encoding="utf-8") as f:
    src = f.read()

quic_bind = f"0.0.0.0:{os.environ['QUIC_PORT']}" if os.environ["QUIC_ENABLED"] == "1" else ""
ssh_bind  = f"0.0.0.0:{os.environ['SSH_PORT']}"  if os.environ["SSH_ENABLED"] == "1"  else ""
vnc_bind  = f"0.0.0.0:{os.environ['VNC_PORT']}"  if os.environ["VNC_ENABLED"] == "1"  else ""

imap_dsn = ""
if os.environ["IMAP_ENABLED"] == "1" and os.environ.get("IMAP_EMAIL"):
    email_q = urllib.parse.quote(os.environ["IMAP_EMAIL"], safe="")
    pass_q  = urllib.parse.quote(os.environ.get("IMAP_SERVER_PASS", ""), safe="")
    imap_dsn = f"imaps://{os.environ['IMAP_HOST']}:{os.environ['IMAP_PORT']}?acc={email_q}:{pass_q}"

wrtc_url = os.environ.get("WRTC_ROOM_URL", "") if os.environ["WRTC_ENABLED"] == "1" else ""

updates = {
    ("server", "quic_bind_to"): f'"{quic_bind}"',
    ("server", "ssh_bind_to"): f'"{ssh_bind}"',
    ("server", "vnc_bind_to"): f'"{vnc_bind}"',
    ("server", "ssh_host_key"): f'"{os.environ["SSH_KEY_PATH"]}"',
    ("server", "wrtc_room_url"): f'"{wrtc_url}"',
    ("server", "wrtc_mode"): f'"{os.environ.get("WRTC_MODE", "media_video")}"',
    ("server", "imap_dsn"): f'"{imap_dsn}"',
}

lines = src.splitlines(keepends=True)
out = []
sec = ""
in_ml = False
done = set()
sec_re = re.compile(r'^\s*\[([^\[\]]+)\]\s*(?:#.*)?$')
key_re = re.compile(r'^\s*(?:#\s*)?([A-Za-z0-9_]+)\s*=')

for line in lines:
    stripped = line.strip()
    if in_ml:
        out.append(line)
        if '"""' in line:
            in_ml = False
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
                in_ml = True
        if (sec, k) not in done:
            out.append(f"{k} = {updates[(sec, k)]}\n")
            done.add((sec, k))
        else:
            out.append(line)
        continue

    if not stripped.startswith("#"):
        rhs = line.split("=", 1)[1].lstrip() if "=" in line else ""
        if rhs.startswith('"""') and rhs.count('"""') < 2:
            in_ml = True
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

  info "Перезапускаю сервис anet-vpn..."
  systemctl restart anet-vpn
  if systemctl is-active --quiet anet-vpn; then
    ok "Сервер перезапущен с новыми протоколами!"
  else
    fail "Не удалось запустить anet-vpn. Смотрите: journalctl -u anet-vpn -n 20"
  fi

  # Пересобираем все существующие клиентские .toml с их сохранёнными ключами
  if [[ -s "${USERS_TSV}" ]]; then
    info "Обновляю клиентские конфиги в ${CLIENTS_DIR}/..."
    python3 - <<'PY'
import os, re, urllib.parse

users_path = os.environ["USERS_TSV"]
clients_dir = os.environ["CLIENTS_DIR"]
tpl_path = os.environ["CLIENT_TEMPLATE"]
server_pub = os.environ["SERVER_PUB_KEY"]
server_ip = os.environ["SERVER_IP"]
node_name = os.environ.get("NODE_NAME", "HomeVPS")
ssh_user = os.environ.get("SSH_USER", "hanyuu")

if os.path.exists(tpl_path):
    with open(tpl_path, "r", encoding="utf-8") as f:
        base_tpl = f.read()
else:
    base_tpl = """[main]
tun_name = "anet-client"
manual_routing = false
per_app = []
per_app_mode = "all"
route_for = []
exclude_route_for = ["192.168.0.0/16"]
dns_server_list = ["1.1.1.1", "8.8.8.8"]
update_url = "https://api.github.com/repos/ZeroTworu/anet/releases/latest"

[keys]
private_key = "{{PRIVATE_KEY}}"
server_pub_key = "{{SERVER_PUB_KEY}}"

[stats]
enabled = true
interval_minutes = 1

[routing]
rules_url = ""
"""

base_tpl = re.sub(r'(?ms)^\[\[servers\]\].*?(?=^\[|\Z)', '', base_tpl).rstrip() + "\n\n"

blocks = []
if os.environ.get("QUIC_ENABLED") == "1":
    blocks.append(
        f'[[servers]]\nname = "{node_name} — QUIC (Быстрый)"\n'
        f'dsn = "quic://{server_ip}:{os.environ["QUIC_PORT"]}"\n'
        f'timeout_secs = 8\nserver_pub_key = "{server_pub}"\n'
    )
if os.environ.get("WRTC_ENABLED") == "1" and os.environ.get("WRTC_ROOM_URL"):
    blocks.append(
        f'[[servers]]\nname = "{node_name} — Видеосвязь (WRTC)"\n'
        f'dsn = "{os.environ["WRTC_ROOM_URL"]}"\n'
        f'wrtc_mode = "{os.environ.get("WRTC_MODE", "media_video")}"\n'
        f'timeout_secs = 15\nserver_pub_key = "{server_pub}"\n'
    )
if os.environ.get("SSH_ENABLED") == "1":
    blocks.append(
        f'[[servers]]\nname = "{node_name} — SSH"\n'
        f'dsn = "ssh://{server_ip}:{os.environ["SSH_PORT"]}"\n'
        f'ssh_user = "{ssh_user}"\ntimeout_secs = 8\nserver_pub_key = "{server_pub}"\n'
    )
if os.environ.get("VNC_ENABLED") == "1":
    blocks.append(
        f'[[servers]]\nname = "{node_name} — VNC"\n'
        f'dsn = "vnc://{server_ip}:{os.environ["VNC_PORT"]}"\n'
        f'timeout_secs = 8\nserver_pub_key = "{server_pub}"\n'
    )
if os.environ.get("IMAP_ENABLED") == "1" and os.environ.get("IMAP_EMAIL"):
    email_q = urllib.parse.quote(os.environ["IMAP_EMAIL"], safe="")
    pass_q = urllib.parse.quote(os.environ.get("IMAP_CLIENT_PASS", ""), safe="")
    blocks.append(
        f'[[servers]]\nname = "{node_name} — Почта (IMAP)"\n'
        f'dsn = "imaps://{os.environ.get("IMAP_HOST", "imap.mail.ru")}:{os.environ.get("IMAP_PORT", "993")}?acc={email_q}:{pass_q}"\n'
        f'timeout_secs = 15\nserver_pub_key = "{server_pub}"\n'
    )

servers_part = "\n".join(blocks)
os.makedirs(clients_dir, exist_ok=True)

count = 0
with open(users_path, "r", encoding="utf-8") as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 3 or not parts[0].strip():
            continue
        uname, _, priv_key = parts[0].strip(), parts[1].strip(), parts[2].strip()
        cfg = base_tpl
        for k, v in {
            "{{PER_APP}}": "[]",
            "{{PER_APP_MODE}}": "all",
            "{{ROUTE_FOR}}": "[]",
            "{{EXCLUDE_ROUTE_FOR}}": '["192.168.0.0/16"]',
            "{{PRIVATE_KEY}}": priv_key,
            "{{SERVER_PUB_KEY}}": server_pub,
            "{{RULES_URL}}": "",
        }.items():
            cfg = cfg.replace(k, v)
        cfg += servers_part
        out_file = os.path.join(clients_dir, f"{uname}.toml")
        with open(out_file, "w", encoding="utf-8") as out:
            out.write(cfg)
        os.chmod(out_file, 0o600)
        count += 1

print(f"Обновлено файлов: {count}")
PY
    ok "Готово! Не забудьте заново скинуть обновлённые .toml из ${CLIENTS_DIR}/ пользователям."
  fi
  DIRTY=0
}

edit_quic() {
  echo
  read -rp "QUIC UDP порт [${QUIC_PORT}] (или 0 / off чтобы выключить): " inp
  inp="${inp// /}"
  if [[ "${inp,,}" == "0" || "${inp,,}" == "off" || "${inp,,}" == "нет" ]]; then
    QUIC_ENABLED=0
    DIRTY=1
  elif [[ -n "${inp}" ]]; then
    is_valid_port "${inp}" || { warn "Неверный порт."; return; }
    QUIC_PORT="${inp}"
    QUIC_ENABLED=1
    DIRTY=1
  else
    QUIC_ENABLED=1
    DIRTY=1
  fi
}

edit_ssh() {
  echo
  read -rp "SSH TCP порт [${SSH_PORT}] (или 0 / off чтобы выключить): " inp
  inp="${inp// /}"
  if [[ "${inp,,}" == "0" || "${inp,,}" == "off" || "${inp,,}" == "нет" ]]; then
    SSH_ENABLED=0
    DIRTY=1
  elif [[ -n "${inp}" ]]; then
    is_valid_port "${inp}" || { warn "Неверный порт."; return; }
    [[ "${inp}" == "22" ]] && { warn "Порт 22 занят системным SSH VPS!"; return; }
    [[ "${VNC_ENABLED}" == "1" && "${inp}" == "${VNC_PORT}" ]] && { warn "Порт совпадает с VNC (${VNC_PORT})."; return; }
    SSH_PORT="${inp}"
    SSH_ENABLED=1
    DIRTY=1
  else
    [[ "${VNC_ENABLED}" == "1" && "${SSH_PORT}" == "${VNC_PORT}" ]] && { warn "Порт совпадает с VNC (${VNC_PORT})."; return; }
    SSH_ENABLED=1
    DIRTY=1
  fi
}

edit_vnc() {
  echo
  read -rp "VNC TCP порт [${VNC_PORT}] (или 0 / off чтобы выключить): " inp
  inp="${inp// /}"
  if [[ "${inp,,}" == "0" || "${inp,,}" == "off" || "${inp,,}" == "нет" ]]; then
    VNC_ENABLED=0
    DIRTY=1
  elif [[ -n "${inp}" ]]; then
    is_valid_port "${inp}" || { warn "Неверный порт."; return; }
    [[ "${SSH_ENABLED}" == "1" && "${inp}" == "${SSH_PORT}" ]] && { warn "Порт совпадает с SSH (${SSH_PORT})."; return; }
    VNC_PORT="${inp}"
    VNC_ENABLED=1
    DIRTY=1
  else
    [[ "${SSH_ENABLED}" == "1" && "${VNC_PORT}" == "${SSH_PORT}" ]] && { warn "Порт совпадает с SSH (${SSH_PORT})."; return; }
    VNC_ENABLED=1
    DIRTY=1
  fi
}

edit_wrtc() {
  echo
  echo "Текущая ссылка WRTC: ${WRTC_ROOM_URL:-не задана}"
  read -rp "Новая ссылка на комнату (или off чтобы выключить, Enter — оставить/включить текущую): " inp
  inp="${inp// /}"
  if [[ "${inp,,}" == "0" || "${inp,,}" == "off" || "${inp,,}" == "нет" ]]; then
    WRTC_ENABLED=0
    DIRTY=1
  elif [[ -n "${inp}" ]]; then
    WRTC_ROOM_URL="$(normalize_wrtc_url "${inp}")"
    WRTC_ENABLED=1
    DIRTY=1
  elif [[ -n "${WRTC_ROOM_URL:-}" ]]; then
    WRTC_ENABLED=1
    DIRTY=1
  else
    warn "Ссылка WRTC не задана — включать нечего."
  fi
}

edit_imap() {
  echo
  echo "Текущий IMAP ящик: ${IMAP_EMAIL:-не задан} (${IMAP_HOST:-imap.mail.ru}:${IMAP_PORT:-993})"
  read -rp "Email ящика (или off чтобы выключить, Enter — оставить текущий '${IMAP_EMAIL:-}'): " inp_email
  inp_email="${inp_email// /}"
  if [[ "${inp_email,,}" == "0" || "${inp_email,,}" == "off" || "${inp_email,,}" == "нет" ]]; then
    IMAP_ENABLED=0
    DIRTY=1
    return
  fi

  if [[ -n "${inp_email}" ]]; then
    IMAP_EMAIL="${inp_email}"
  elif [[ -z "${IMAP_EMAIL:-}" ]]; then
    warn "Email не задан — включать нечего."
    return
  fi

  read -rp "IMAP сервер [${IMAP_HOST:-imap.mail.ru}]: " h
  IMAP_HOST="${h:-${IMAP_HOST:-imap.mail.ru}}"
  read -rp "IMAP порт [${IMAP_PORT:-993}]: " p
  IMAP_PORT="${p:-${IMAP_PORT:-993}}"
  read -rsp "Пароль приложения для сервера [Enter — оставить прежний]: " sp
  echo
  [[ -n "${sp}" ]] && IMAP_SERVER_PASS="${sp}"
  [[ -n "${IMAP_SERVER_PASS:-}" ]] || { warn "Пароль сервера не может быть пустым."; return; }
  read -rsp "Пароль приложения для клиентов [Enter — оставить прежний / как у сервера]: " cp
  echo
  if [[ -n "${cp}" ]]; then
    IMAP_CLIENT_PASS="${cp}"
  elif [[ -z "${IMAP_CLIENT_PASS:-}" ]]; then
    IMAP_CLIENT_PASS="${IMAP_SERVER_PASS}"
  fi

  IMAP_ENABLED=1
  DIRTY=1
}

edit_ip_name() {
  echo
  read -rp "Внешний IP/домен сервера [${SERVER_IP}]: " ip_in
  [[ -n "${ip_in// /}" ]] && { SERVER_IP="${ip_in// /}"; DIRTY=1; }
  read -rp "Название сервера в приложении [${NODE_NAME:-HomeVPS}]: " nm_in
  [[ -n "${nm_in}" ]] && { NODE_NAME="${nm_in}"; DIRTY=1; }
}

status_badge() {
  if [[ "$1" == "1" ]]; then
    echo -e "${GREEN}ВКЛ${NC}"
  else
    echo -e "${RED}ВЫКЛ${NC}"
  fi
}

while true; do
  echo
  echo "===================================================="
  echo "  Управление протоколами и портами ANet (${NODE_NAME:-HomeVPS})"
  echo "===================================================="
  echo -e "  1) QUIC (UDP)         : $(status_badge "${QUIC_ENABLED}")  | порт: ${QUIC_PORT}"
  echo -e "  2) SSH  (TCP)         : $(status_badge "${SSH_ENABLED}")  | порт: ${SSH_PORT}"
  echo -e "  3) VNC  (TCP)         : $(status_badge "${VNC_ENABLED}")  | порт: ${VNC_PORT}"
  echo -e "  4) WRTC (видеосвязь)  : $(status_badge "${WRTC_ENABLED}")  | ${WRTC_ROOM_URL:-не задана}"
  echo -e "  5) IMAP (почта)       : $(status_badge "${IMAP_ENABLED}")  | ${IMAP_EMAIL:-не задан}"
  echo "  6) Изменить IP / название сервера (${SERVER_IP})"
  echo "  --------------------------------------------------"
  if (( DIRTY == 1 )); then
    echo -e "  7) ${YELLOW}Применить изменения, перезапустить VPN и обновить .toml${NC}"
  else
    echo "  7) Применить и пересобрать клиентские .toml"
  fi
  echo "  0) Выход"
  echo "===================================================="
  read -rp "Выберите пункт [0-7]: " choice
  case "${choice}" in
    1) edit_quic ;;
    2) edit_ssh ;;
    3) edit_vnc ;;
    4) edit_wrtc ;;
    5) edit_imap ;;
    6) edit_ip_name ;;
    7) apply_and_rebuild ;;
    0)
      if (( DIRTY == 1 )); then
        read -rp "Есть несохранённые изменения. Применить перед выходом? [Y/n]: " ans
        if [[ -z "${ans}" || "${ans,,}" == "y" || "${ans,,}" == "д" ]]; then
          apply_and_rebuild
        fi
      fi
      exit 0
      ;;
    *) warn "Неизвестный пункт." ;;
  esac
done
