#!/usr/bin/env bash
set -euo pipefail

ANET_DIR="/opt/anet"
CLIENTS_DIR="${ANET_DIR}/clients"
NODE_ENV="${ANET_DIR}/node.env"
USERS_TSV="${ANET_DIR}/users.tsv"
SERVER_TOML="${ANET_DIR}/server.toml"
CLIENT_TEMPLATE="${ANET_DIR}/client_template.toml"

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

[[ -f "${NODE_ENV}" && -f "${SERVER_TOML}" && -x "${ANET_DIR}/anet-keygen" ]] \
  || fail "Сервер ANet не установлен в ${ANET_DIR}. Сначала выполните: bash anet-install.sh"

# shellcheck disable=SC1090
source "${NODE_ENV}"
mkdir -p "${CLIENTS_DIR}"
[[ -f "${USERS_TSV}" ]] || : > "${USERS_TSV}"
chmod 600 "${USERS_TSV}"

validate_username() {
  local name="$1"
  [[ "${name}" =~ ^[A-Za-z0-9_-]{1,32}$ ]]
}

user_exists() {
  local name="$1"
  awk -F'\t' -v n="${name}" '$1 == n {found=1} END{exit !found}' "${USERS_TSV}"
}

sync_allowed_clients() {
  export SERVER_TOML USERS_TSV
  python3 - <<'PY'
import os, re

toml_path = os.environ["SERVER_TOML"]
users_path = os.environ["USERS_TSV"]

fps = []
with open(users_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) >= 2 and parts[1].strip():
            fps.append(parts[1].strip())

arr_str = "[" + ", ".join(f'"{fp}"' for fp in fps) + "]"

with open(toml_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

out = []
sec = ""
replaced = False
sec_re = re.compile(r'^\s*\[([^\[\]]+)\]\s*(?:#.*)?$')
key_re = re.compile(r'^\s*(?:#\s*)?allowed_clients\s*=')

for line in lines:
    stripped = line.strip()
    m_sec = sec_re.match(line)
    if m_sec and not stripped.startswith("[["):
        if sec == "authentication" and not replaced:
            out.append(f"allowed_clients = {arr_str}\n")
            replaced = True
        sec = m_sec.group(1).strip()
        out.append(line)
        continue
    if sec == "authentication" and key_re.match(line) and not stripped.startswith("#"):
        if not replaced:
            out.append(f"allowed_clients = {arr_str}\n")
            replaced = True
        continue
    out.append(line)

if sec == "authentication" and not replaced:
    out.append(f"allowed_clients = {arr_str}\n")
    replaced = True

if not replaced:
    out.append(f"\n[authentication]\nallowed_clients = {arr_str}\n")

with open(toml_path, "w", encoding="utf-8") as f:
    f.writelines(out)
PY
}

generate_client_toml() {
  local name="$1"
  local priv_key="$2"
  export TARGET_FILE="${CLIENTS_DIR}/${name}.toml"
  export PRIV_KEY="${priv_key}"
  export CLIENT_TEMPLATE NODE_ENV

  python3 - <<'PY'
import os, re, urllib.parse

# Читаем параметры из уже загруженного окружения (source node.env)
tpl_path = os.environ["CLIENT_TEMPLATE"]
out_path = os.environ["TARGET_FILE"]
priv_key = os.environ["PRIV_KEY"]
server_pub = os.environ["SERVER_PUB_KEY"]
server_ip = os.environ["SERVER_IP"]
node_name = os.environ.get("NODE_NAME", "HomeVPS")
ssh_user = os.environ.get("SSH_USER", "hanyuu")

if os.path.exists(tpl_path):
    with open(tpl_path, "r", encoding="utf-8") as f:
        tpl = f.read()
else:
    tpl = """[main]
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

# Подстановка плейсхолдеров шаблона
replacements = {
    "{{PER_APP}}": "[]",
    "{{PER_APP_MODE}}": "all",
    "{{ROUTE_FOR}}": "[]",
    "{{EXCLUDE_ROUTE_FOR}}": '["192.168.0.0/16"]',
    "{{PRIVATE_KEY}}": priv_key,
    "{{SERVER_PUB_KEY}}": server_pub,
    "{{RULES_URL}}": "",
}
for k, v in replacements.items():
    tpl = tpl.replace(k, v)

# Удаляем возможные заготовленные [[servers]] блоки из шаблона
tpl = re.sub(r'(?ms)^\[\[servers\]\].*?(?=^\[|\Z)', '', tpl).rstrip() + "\n\n"

blocks = []
if os.environ.get("QUIC_ENABLED") == "1":
    port = os.environ["QUIC_PORT"]
    blocks.append(
        f'[[servers]]\n'
        f'name = "{node_name} — QUIC (Быстрый)"\n'
        f'dsn = "quic://{server_ip}:{port}"\n'
        f'timeout_secs = 8\n'
        f'server_pub_key = "{server_pub}"\n'
    )

if os.environ.get("WRTC_ENABLED") == "1" and os.environ.get("WRTC_ROOM_URL"):
    wrtc_url = os.environ["WRTC_ROOM_URL"]
    wrtc_mode = os.environ.get("WRTC_MODE", "media_video")
    blocks.append(
        f'[[servers]]\n'
        f'name = "{node_name} — Видеосвязь (WRTC)"\n'
        f'dsn = "{wrtc_url}"\n'
        f'wrtc_mode = "{wrtc_mode}"\n'
        f'timeout_secs = 15\n'
        f'server_pub_key = "{server_pub}"\n'
    )

if os.environ.get("SSH_ENABLED") == "1":
    port = os.environ["SSH_PORT"]
    blocks.append(
        f'[[servers]]\n'
        f'name = "{node_name} — SSH"\n'
        f'dsn = "ssh://{server_ip}:{port}"\n'
        f'ssh_user = "{ssh_user}"\n'
        f'timeout_secs = 8\n'
        f'server_pub_key = "{server_pub}"\n'
    )

if os.environ.get("VNC_ENABLED") == "1":
    port = os.environ["VNC_PORT"]
    blocks.append(
        f'[[servers]]\n'
        f'name = "{node_name} — VNC"\n'
        f'dsn = "vnc://{server_ip}:{port}"\n'
        f'timeout_secs = 8\n'
        f'server_pub_key = "{server_pub}"\n'
    )

if os.environ.get("IMAP_ENABLED") == "1" and os.environ.get("IMAP_EMAIL"):
    host = os.environ.get("IMAP_HOST", "imap.mail.ru")
    port = os.environ.get("IMAP_PORT", "993")
    email_q = urllib.parse.quote(os.environ["IMAP_EMAIL"], safe="")
    pass_q = urllib.parse.quote(os.environ.get("IMAP_CLIENT_PASS", ""), safe="")
    blocks.append(
        f'[[servers]]\n'
        f'name = "{node_name} — Почта (IMAP)"\n'
        f'dsn = "imaps://{host}:{port}?acc={email_q}:{pass_q}"\n'
        f'timeout_secs = 15\n'
        f'server_pub_key = "{server_pub}"\n'
    )

final_toml = tpl + "\n".join(blocks)

try:
    import tomllib
    tomllib.loads(final_toml)
except ImportError:
    pass

with open(out_path, "w", encoding="utf-8") as f:
    f.write(final_toml)
PY
  chmod 600 "${CLIENTS_DIR}/${name}.toml"
}

export SERVER_IP NODE_NAME SERVER_PUB_KEY SSH_USER
export QUIC_ENABLED QUIC_PORT SSH_ENABLED SSH_PORT VNC_ENABLED VNC_PORT
export WRTC_ENABLED WRTC_ROOM_URL WRTC_MODE
export IMAP_ENABLED IMAP_HOST IMAP_PORT IMAP_EMAIL IMAP_CLIENT_PASS

restart_server() {
  info "Перезапускаю сервис anet-vpn (~1–2 сек)..."
  systemctl restart anet-vpn
  if systemctl is-active --quiet anet-vpn; then
    ok "Сервис anet-vpn успешно перезапущен."
  else
    fail "Ошибка при перезапуске anet-vpn. Проверьте: journalctl -u anet-vpn -n 20"
  fi
}

cmd_list() {
  echo
  echo "=== Список пользователей ANet ==="
  if [[ ! -s "${USERS_TSV}" ]]; then
    echo "  (пока никого нет)"
    echo
    return 0
  fi
  printf "  %-18s %-28s %-12s %s\n" "ИМЯ" "FINGERPRINT" "ДАТА" "ФАЙЛ КОНФИГА"
  printf "  %-18s %-28s %-12s %s\n" "---" "-----------" "----" "------------"
  while IFS=$'\t' read -r uname ufp _upk udate; do
    [[ -z "${uname}" ]] && continue
    printf "  %-18s %-28s %-12s %s\n" "${uname}" "${ufp}" "${udate}" "${CLIENTS_DIR}/${uname}.toml"
  done < "${USERS_TSV}"
  echo
}

cmd_add() {
  local name="${1:-}"
  if [[ -z "${name}" ]]; then
    read -rp "Введите имя (латиница/цифры, напр. mama или alex_phone): " name
  fi
  name="${name// /}"
  if ! validate_username "${name}"; then
    fail "Некорректное имя '${name}'. Разрешены только латинские буквы, цифры, _ и - (до 32 символов)."
  fi
  if user_exists "${name}"; then
    fail "Пользователь '${name}' уже существует!"
  fi

  local key_out priv_key fp now_date
  key_out="$("${ANET_DIR}/anet-keygen" client)"
  read -r priv_key fp < <(
    python3 -c '
import re, sys
text = sys.stdin.read()
m = re.search(r"private_key\s*=\s*\"([^\"]+)\"", text)
pk = m.group(1) if m else ""
fp = ""
lines = [l.strip() for l in text.splitlines()]
for i, line in enumerate(lines):
    if line.startswith("Fingerprint") and i + 1 < len(lines):
        fp = lines[i + 1]
        break
print(pk, fp)
' <<< "${key_out}"
  )
  [[ -n "${priv_key}" && -n "${fp}" ]] || fail "Не удалось сгенерировать ключи через anet-keygen client."

  now_date="$(date +%Y-%m-%d)"
  printf '%s\t%s\t%s\t%s\n' "${name}" "${fp}" "${priv_key}" "${now_date}" >> "${USERS_TSV}"

  sync_allowed_clients
  generate_client_toml "${name}" "${priv_key}"
  restart_server

  echo
  ok "Пользователь '${name}' добавлен!"
  echo "  Готовый конфиг: ${CLIENTS_DIR}/${name}.toml"
  echo "  Просто передайте этот файл на устройство и откройте в клиенте ANet."
  echo
}

cmd_del() {
  local name="${1:-}"
  if [[ -z "${name}" ]]; then
    cmd_list
    read -rp "Введите имя пользователя для удаления: " name
  fi
  name="${name// /}"
  [[ -n "${name}" ]] || fail "Имя не указано."
  if ! user_exists "${name}"; then
    fail "Пользователь '${name}' не найден."
  fi

  local tmp_tsv
  tmp_tsv="$(mktemp)"
  awk -F'\t' -v n="${name}" '$1 != n' "${USERS_TSV}" > "${tmp_tsv}"
  mv "${tmp_tsv}" "${USERS_TSV}"
  chmod 600 "${USERS_TSV}"

  rm -f "${CLIENTS_DIR}/${name}.toml"
  sync_allowed_clients
  restart_server

  ok "Пользователь '${name}' удалён, доступ закрыт."
}

cmd_rebuild() {
  if [[ ! -s "${USERS_TSV}" ]]; then
    warn "Список пользователей пуст — нечего пересоздавать."
    return 0
  fi
  local count=0
  while IFS=$'\t' read -r uname _ufp upk _udate; do
    [[ -z "${uname}" || -z "${upk}" ]] && continue
    generate_client_toml "${uname}" "${upk}"
    count=$((count + 1))
  done < "${USERS_TSV}"
  ok "Перегенерировано конфигов: ${count} (папка ${CLIENTS_DIR}/)."
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    add)     shift; cmd_add "${1:-}" ;;
    del|rm|remove) shift; cmd_del "${1:-}" ;;
    list|ls) cmd_list ;;
    rebuild) cmd_rebuild ;;
    *)
      echo "Использование:"
      echo "  bash $0              — интерактивное меню"
      echo "  bash $0 list         — список пользователей"
      echo "  bash $0 add <имя>    — добавить пользователя и создать <имя>.toml"
      echo "  bash $0 del <имя>    — удалить пользователя"
      echo "  bash $0 rebuild      — пересобрать все .toml после смены протоколов"
      exit 1
      ;;
  esac
  exit 0
fi

while true; do
  echo
  echo "========================================"
  echo "  Управление пользователями ANet"
  echo "========================================"
  echo "  1) Показать список пользователей"
  echo "  2) Добавить пользователя"
  echo "  3) Удалить пользователя"
  echo "  4) Пересоздать все клиентские .toml"
  echo "  0) Выход"
  echo "========================================"
  read -rp "Выберите пункт [0-4]: " choice
  case "${choice}" in
    1) cmd_list ;;
    2) cmd_add ;;
    3) cmd_del ;;
    4) cmd_rebuild ;;
    0) exit 0 ;;
    *) warn "Неизвестный пункт меню." ;;
  esac
done
