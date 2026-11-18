#!/usr/bin/env bash
set -euo pipefail

ANET_DIR="/opt/anet"
NODE_ENV="${ANET_DIR}/node.env"
SERVER_TOML="${ANET_DIR}/server.toml"
CLIENT_TEMPLATE="${ANET_DIR}/client_template.toml"
COMPOSE_FILE="${ANET_DIR}/docker-compose.yaml"
BACKUP_ROOT="${ANET_DIR}/backups"
DEFAULT_REPO="ZeroTworu/anet"
REPO="${ANET_REPO:-${DEFAULT_REPO}}"

CHECK_ONLY=0
AUTO_YES=0
FORCE_UPDATE=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[ОШИБКА]${NC} $*"; exit 1; }

usage() {
  cat <<EOF
Использование: sudo bash $0 [опции]

Опции:
  -c, --check           Только проверить наличие новой версии на GitHub (ничего не менять)
  -y, --yes             Не спрашивать подтверждение (удобно для cron / автоматизации)
  -f, --force           Переустановить сервер и обновить Docker-образы панели, даже если тег совпадает
  -r, --repo OWNER/REPO Использовать другой GitHub-репозиторий (по умолчанию: ${DEFAULT_REPO})
  -h, --help            Показать эту справку
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--check)
      CHECK_ONLY=1
      shift
      ;;
    -y|--yes)
      AUTO_YES=1
      shift
      ;;
    -f|--force)
      FORCE_UPDATE=1
      shift
      ;;
    -r|--repo)
      [[ $# -ge 2 ]] || fail "Для опции $1 укажите OWNER/REPO"
      REPO="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Неизвестная опция: $1 (используйте --help)"
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  fail "Запустите скрипт от пользователя root: sudo bash $0"
fi

ARCH="$(uname -m)"
if [[ "${ARCH}" != "x86_64" ]]; then
  fail "Готовые серверные бинарники ANet собираются только под x86_64 (сейчас: ${ARCH})."
fi

[[ -d "${ANET_DIR}" && -x "${ANET_DIR}/anet-server" ]] \
  || fail "Установленный сервер ANet не найден в ${ANET_DIR}. Сначала выполните установку."

for cmd in curl unzip python3 systemctl; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "Не найдена необходимая утилита: ${cmd}"
done

CURRENT_VERSION="неизвестна"
if [[ -f "${NODE_ENV}" ]]; then
  # Читаем только ANET_VERSION без выполнения произвольного кода, если файл редактировали вручную
  CURRENT_VERSION="$(
    python3 - "${NODE_ENV}" <<'PY'
import shlex, sys
path = sys.argv[1]
val = ""
with open(path, "r", encoding="utf-8") as f:
    for line in f:
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        if k.strip() == "ANET_VERSION":
            parts = shlex.split(v)
            val = parts[0] if parts else v.strip().strip("'\"")
            break
print(val or "неизвестна")
PY
  )"
fi

HAS_PANEL=0
DC_CMD=()
if [[ -f "${COMPOSE_FILE}" ]]; then
  HAS_PANEL=1
  if docker compose version >/dev/null 2>&1; then
    DC_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    DC_CMD=(docker-compose)
  else
    fail "Обнаружен ${COMPOSE_FILE}, но не найден docker compose."
  fi
fi

echo
echo "=========================================================="
echo "   Проверка и обновление ANet VPN на VPS (${REPO})"
echo "=========================================================="
info "Текущая версия на сервере : ${CURRENT_VERSION}"
if (( HAS_PANEL == 1 )); then
  info "Режим установки            : с веб-панелью (anet-auth + WebUI + PostgreSQL)"
else
  info "Режим установки            : автономный (anet-vpn без БД и панели)"
fi

info "Проверяю последний релиз ${REPO} на GitHub..."
RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")" \
  || fail "Не удалось получить информацию о релизе с GitHub API."

read -r TAG_NAME SERVER_ZIP_URL PUBLISHED_AT < <(
  python3 -c '
import json, sys
data = json.load(sys.stdin)
tag = data.get("tag_name", "")
pub = data.get("published_at", "")
url = ""
for asset in data.get("assets", []):
    name = asset.get("name", "")
    if name.startswith("server_") and name.endswith(".zip"):
        url = asset.get("browser_download_url", "")
        break
print(tag, url, pub)
' <<< "${RELEASE_JSON}"
)

if [[ -z "${TAG_NAME}" || -z "${SERVER_ZIP_URL}" ]]; then
  fail "В последнем релизе ${REPO} не найден архив server_*.zip."
fi

info "Последний релиз на GitHub  : ${TAG_NAME} (${PUBLISHED_AT:-дата неизвестна})"

if (( HAS_PANEL == 1 )) && (( CHECK_ONLY == 1 )); then
  info "Для Docker-образов панели (ghcr.io/zerotworu/anet-auth:latest, anet-webui:latest) свежие слои проверяются при обновлении."
fi

if [[ "${CURRENT_VERSION}" == "${TAG_NAME}" ]] && (( FORCE_UPDATE == 0 )); then
  ok "У вас уже установлена актуальная версия ${TAG_NAME}."
  if (( CHECK_ONLY == 1 )); then
    exit 0
  fi
  if (( HAS_PANEL == 1 )); then
    warn "Если хотите всё равно подтянуть свежие Docker-образы панели (:latest), перезапустите с ключом --force."
  fi
  exit 0
fi

if (( CHECK_ONLY == 1 )); then
  warn "Доступно обновление: ${CURRENT_VERSION} -> ${TAG_NAME}"
  echo "Для обновления запустите: sudo bash $0"
  exit 0
fi

if (( AUTO_YES == 0 )); then
  echo
  read -rp "Обновить ANet до ${TAG_NAME}? Конфиги, ключи и база данных сохранятся [Y/n]: " CONFIRM
  CONFIRM="${CONFIRM:-y}"
  if [[ ! "${CONFIRM,,}" =~ ^(y|yes|д|да)$ ]]; then
    info "Обновление отменено пользователем."
    exit 0
  fi
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

info "Скачиваю ${SERVER_ZIP_URL}..."
curl -fsSL -L "${SERVER_ZIP_URL}" -o "${TMP_DIR}/server.zip" || fail "Ошибка скачивания архива сервера."
unzip -q "${TMP_DIR}/server.zip" -d "${TMP_DIR}/unpack"

[[ -f "${TMP_DIR}/unpack/server/anet-server" ]] || fail "В архиве не найден server/anet-server"
[[ -f "${TMP_DIR}/unpack/server/keygen/anet-keygen" ]] || fail "В архиве не найден server/keygen/anet-keygen"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${CURRENT_VERSION}_${STAMP}"
mkdir -p "${BACKUP_DIR}"
cp -a "${ANET_DIR}/anet-server" "${BACKUP_DIR}/"
[[ -f "${ANET_DIR}/anet-keygen" ]] && cp -a "${ANET_DIR}/anet-keygen" "${BACKUP_DIR}/"
[[ -f "${SERVER_TOML}" ]] && cp -a "${SERVER_TOML}" "${BACKUP_DIR}/"
[[ -f "${NODE_ENV}" ]] && cp -a "${NODE_ENV}" "${BACKUP_DIR}/"
[[ -f "${CLIENT_TEMPLATE}" ]] && cp -a "${CLIENT_TEMPLATE}" "${BACKUP_DIR}/"
ok "Резервная копия текущей версии сохранена в ${BACKUP_DIR}"

# Оставляем только 3 последних бэкапа, чтобы не засорять диск VPS
mapfile -t OLD_BACKUPS < <(ls -1dt "${BACKUP_ROOT}"/* 2>/dev/null | tail -n +4 || true)
for old_b in "${OLD_BACKUPS[@]}"; do
  rm -rf "${old_b}"
done

# Обновляем шаблон клиентских конфигов (без смены inode, чтобы не сломать bind-mount в Docker)
if curl -fsSL -L "https://raw.githubusercontent.com/${REPO}/${TAG_NAME}/contrib/client_template.toml" -o "${TMP_DIR}/client_template.toml"; then
  cat "${TMP_DIR}/client_template.toml" > "${CLIENT_TEMPLATE}"
  chmod 644 "${CLIENT_TEMPLATE}"
  ok "Обновлён ${CLIENT_TEMPLATE}"
else
  warn "Не удалось скачать новый client_template.toml — оставлен прежний файл."
fi

if [[ -f "${TMP_DIR}/unpack/server/server.toml" ]]; then
  cp "${TMP_DIR}/unpack/server/server.toml" "${ANET_DIR}/server.toml.new"
  info "Эталонный server.toml нового релиза сохранён рядом как ${ANET_DIR}/server.toml.new (ваш рабочий ${SERVER_TOML} не тронут)."
fi

if systemctl is-active --quiet anet-vpn 2>/dev/null; then
  info "Останавливаю anet-vpn..."
  systemctl stop anet-vpn
fi

cp "${TMP_DIR}/unpack/server/anet-server" "${ANET_DIR}/anet-server.next"
cp "${TMP_DIR}/unpack/server/keygen/anet-keygen" "${ANET_DIR}/anet-keygen.next"
chmod 755 "${ANET_DIR}/anet-server.next" "${ANET_DIR}/anet-keygen.next"
mv -f "${ANET_DIR}/anet-server.next" "${ANET_DIR}/anet-server"
mv -f "${ANET_DIR}/anet-keygen.next" "${ANET_DIR}/anet-keygen"

if (( HAS_PANEL == 1 )); then
  info "Обновляю Docker-образы панели (anet-auth, anet-webui), не трогая базу PostgreSQL..."
  "${DC_CMD[@]}" -f "${COMPOSE_FILE}" pull anet-auth anet-webui
  "${DC_CMD[@]}" -f "${COMPOSE_FILE}" up -d --no-deps anet-auth anet-webui

  info "Жду готовности anet-auth на 127.0.0.1:3000..."
  AUTH_READY=0
  for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:3000/spec >/dev/null 2>&1; then
      AUTH_READY=1
      break
    fi
    sleep 2
  done
  if (( AUTH_READY == 0 )); then
    warn "anet-auth долго отвечает после обновления — проверьте: docker logs anet-auth"
  else
    ok "Панель (anet-auth + anet-webui) обновлена."
  fi
fi

info "Запускаю сервис anet-vpn..."
systemctl start anet-vpn
sleep 2

if ! systemctl is-active --quiet anet-vpn; then
  warn "Новый anet-vpn не смог удержаться в работе! Откатываю бинарники из ${BACKUP_DIR}..."
  cp -a "${BACKUP_DIR}/anet-server" "${ANET_DIR}/anet-server"
  [[ -f "${BACKUP_DIR}/anet-keygen" ]] && cp -a "${BACKUP_DIR}/anet-keygen" "${ANET_DIR}/anet-keygen"
  chmod 755 "${ANET_DIR}/anet-server" "${ANET_DIR}/anet-keygen"
  systemctl start anet-vpn || true
  fail "Обновление отменено (выполнен автоматический откат). Посмотрите логи: journalctl -u anet-vpn -n 50 --no-pager"
fi

# Фиксируем новую версию в /opt/anet/node.env (создаём или аккуратно обновляем ANET_VERSION)
python3 - "${NODE_ENV}" "${TAG_NAME}" <<'PY'
import os, shlex, sys
path, new_ver = sys.argv[1], sys.argv[2]
quoted = shlex.quote(new_ver)
lines = []
found = False
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            if line.lstrip().startswith("ANET_VERSION="):
                lines.append(f"ANET_VERSION={quoted}\n")
                found = True
            else:
                lines.append(line)
if not found:
    lines.insert(0, f"ANET_VERSION={quoted}\n")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(path, 0o600)
PY

echo
ok "ANet успешно обновлён: ${CURRENT_VERSION} -> ${TAG_NAME}"
info "Сервис anet-vpn активен. Ваши настройки, ключи, пользователи и сторонние контейнеры сохранены."
info "Логи при необходимости: journalctl -u anet-vpn -n 30 --no-pager"
