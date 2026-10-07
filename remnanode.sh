#!/usr/bin/env bash
# remnanode.sh — управление Remnawave Node (Linux / macOS, Bash 3.2+)
#
#   Обычная нода       → ./remnanode/       (логи ./log → /var/log/remnanode)
#   Нода + Hysteria2   → ./remnanode-hy2/   (сертификат берёт из Caddy через /certs)
#   Caddy              → ./caddy/           (отдельный docker-compose: выпускает и продлевает
#                                            TLS-сертификаты для одного или нескольких доменов)
#
# Структура после установки:
#   ~/remnanode/
#   ├── remnanode.sh
#   ├── caddy/            docker-compose.yml, Caddyfile, domains.list, .env, data/, config/, www/
#   ├── remnanode/        docker-compose.yml, log/
#   └── remnanode-hy2/    docker-compose.yml, log/
#
# Если Caddy установлен, обе ноды монтируют каталог сертификатов на уровень выше:
#   ../caddy/data/caddy/certificates/<CA> → /certs (только чтение)
# Установка Caddy добавляет это монтирование в compose нод, удаление Caddy — убирает.
#
# У каждого домена в Caddy свой способ выдачи сертификата: http (HTTP-01), alpn (HTTP-01 + TLS-ALPN)
# или cf (DNS-01 через Cloudflare API). На домене можно разместить статический сайт (порт 443).

set -euo pipefail

# =============================================================================
# НАСТРОЙКИ ПО УМОЛЧАНИЮ (то, что подставляется при нажатии Enter)
# =============================================================================

# --- Имена папок и контейнеров ---
NODE_DIR_NAME="remnanode"              # обычная нода: ~/remnanode/remnanode
HY2_DIR_NAME="remnanode-hy2"           # нода с Hysteria2: ~/remnanode/remnanode-hy2
CADDY_DIR_NAME="caddy"                 # Caddy: ~/remnanode/caddy
NODE_CONTAINER="remnanode"             # должен совпадать с container_name в compose из панели
HY2_CONTAINER="remnanode-hy2"
CADDY_CONTAINER="remnanode-caddy"
CADDY_PROJECT_NAME="remnanode-caddy"   # имя compose-проекта Caddy
LEGACY_CADDY_CONTAINER="caddy-hy2"     # имя Caddy в старой раскладке (внутри remnanode-hy2)

# --- Образы ---
NODE_IMAGE="remnawave/node:latest"
CADDY_IMAGE="iarekylew00t/caddy-cloudflare:latest"   # официальный Caddy + модуль caddy-dns/cloudflare (готовый образ)

# --- NODE_PORT (если занят — берётся следующий свободный: +1, +2, …) ---
DEFAULT_NODE_PORT=2222                 # обычная нода
DEFAULT_HY2_NODE_PORT=3333             # нода с Hysteria2

# --- Сертификаты (Caddy) ---
# Способ выдачи выбирается для каждого домена: http | alpn | cf (по умолчанию cf, если есть токен Cloudflare)
DEFAULT_ACME_EMAIL_PREFIX="admin"      # email по умолчанию: admin@<первый домен>
ACME_CA="https://acme-v02.api.letsencrypt.org/directory"
CADDY_INTERNAL_HTTPS_PORT=8443         # если 443 не нужен (нет сайтов и alpn): внутренний HTTPS-порт Caddy, наружу не публикуется
CF_DNS_RESOLVER="1.1.1.1"              # резолвер для проверки TXT-записей при DNS-01 (Cloudflare)
CERT_WAIT_SECONDS=330                  # сколько ждать получения сертификата для одного домена
CERTS_MOUNT_CONTAINER="/certs"         # куда монтируются сертификаты внутри нод

# --- Сайты (статика; файлы лежат в caddy/www/<домен>/) ---
SITES_REPO="BragiOk/scripts"           # GitHub-репозиторий с сайтами
SITES_BRANCH="main"
SITES_PATH="www"                       # папка в репозитории: www/<имя_сайта>/index.html
# Где открывать сайт (у каждого сайта своё, меняется в «Caddy → Сайты → Порт / доступ»):
#   443 — https://домен/;  свой порт — https://домен:ПОРТ/;  локально 127.0.0.1:ПОРТ — для VLESS Reality selfsteal
DEFAULT_SITE_PUBLIC_PORT=2053          # порт по умолчанию для «своего публичного» (2053 — из HTTPS-портов, которые проксирует Cloudflare)
DEFAULT_SITE_LOCAL_PORT=9443           # порт по умолчанию для локального режима (target в realitySettings)

# --- Ответы на вопросы да/нет (y — да, n — нет) ---
DEFAULT_USE_EXISTING_COMPOSE=y         # использовать найденный docker-compose.yml
DEFAULT_OVERWRITE_INSTALL=n            # перезаписать существующую установку
DEFAULT_CONTINUE_ON_DNS_MISMATCH=n     # продолжать, если DNS домена не указывает на сервер
DEFAULT_PRUNE_IMAGES=y                 # удалить старые образы после обновления
DEFAULT_DELETE_OLD_CERT=y              # удалить файлы сертификата при удалении домена
DEFAULT_REMOVE_DOMAIN_ON_FAIL=y        # убрать домен из Caddy, если сертификат не получен
DEFAULT_DELETE_SITE_FILES=y            # удалить файлы сайта при отключении сайта / удалении домена
DEFAULT_CADDY_UNINSTALL_DELETE_DATA=n  # при удалении Caddy удалить и сертификаты
DEFAULT_LOGROTATE_REVERT=y             # подтверждение удаления конфига logrotate

# --- Проверка после запуска второй ноды (конфликт в host-сети) ---
POST_START_CHECK_SECONDS=10

# --- IPv6 ---
DISABLE_IPV6_ON_INSTALL=1              # 1 — при установке ноды отключать IPv6 (sysctl, сохраняется после перезагрузки); 0 — не трогать
IPV6_SYSCTL_FILE="/etc/sysctl.d/99-zz-remnanode-disable-ipv6.conf"

# --- Фаервол (ufw; на RHEL/Fedora — firewalld) ---
FIREWALL_ON_INSTALL=1                  # 1 — при установке ноды открыть SSH и NODE_PORT, при установке Caddy — 80/tcp
FIREWALL_INSTALL_ADD_DEFAULT_PORTS=1   # 1 — при установке ноды заодно открыть DEFAULT_FIREWALL_PORTS
DEFAULT_ENABLE_FIREWALL_ON_INSTALL=y   # включить фаервол при установке, если он выключен (ответ по Enter)
SSH_PORT=""                            # пусто — определить автоматически (текущая SSH-сессия, sshd -T, sshd_config)
PANEL_IP=""                            # IP панели: NODE_PORT открывается только для него; пусто — спросить при установке

# Порты по умолчанию — открываются одной командой («Управление фаерволом → 6») и при установке ноды.
# Формат: "порт" (tcp+udp), "порт/tcp", "порт/udp", "начало:конец/udp".
# Сюда же добавьте порты inbound'ов из профилей Xray на панели.
DEFAULT_FIREWALL_PORTS=(
  "443/tcp"    # VLESS Reality / TLS
  "443/udp"    # Hysteria2
  "8443/tcp"
  "55410/tcp"
)

# =============================================================================
# Ротация логов на хосте (access.log / error.log в каталоге ./log рядом с compose)
# Используется системный logrotate с copytruncate (копия + обнуление текущего файла),
# открытые дескрипторы в контейнере не ломаются.
# Имена конфигов: /etc/logrotate.d/$NODE_DIR_NAME и /etc/logrotate.d/$HY2_DIR_NAME
# =============================================================================
# 1 — при установке (и по команде logrotate-setup) записать конфиг в /etc/logrotate.d/
# 0 — полностью отключить логику logrotate в скрипте
LOGROTATE_SETUP=1

# 1 — если logrotate не найден, попробовать поставить пакет (нужны apt|dnf|yum|apk и sudo)
LOGROTATE_TRY_INSTALL=1

# Маркер внутри файла: по нему logrotate-revert удаляет только наш конфиг, не чужой с тем же именем
LOGROTATE_FILE_MARKER="REMNANODE_SH_LOGROTATE_MANAGED"

# Ротировать, когда текущий .log вырастет до этого размера (синтаксис logrotate: 50M, 100k, 1G)
LOGROTATE_SIZE="50M"

# Сколько старых файлов хранить (access.log.1 … .N; дальше удаляются)
LOGROTATE_ROTATE=5

# 1 — gzip для архивов; 0 — только переименование без сжатия
LOGROTATE_COMPRESS=1

# Тест скорости сервера (bench.sh с российскими серверами)
BENCH_URL="https://raw.githubusercontent.com/BragiOk/scripts/refs/heads/main/bench_ru.sh"

# =============================================================================
# Внутренние переменные (менять не нужно)
# =============================================================================
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
[[ -f "$SCRIPT_PATH" ]] || SCRIPT_NAME="remnanode.sh"
STATE_FILE_NAME=".remnanode_compose_dir"
STATE_FILE="$SCRIPT_DIR/$STATE_FILE_NAME"
BASE_DIR=""

LOG_MOUNT_HOST="./log"
LOG_MOUNT_CONTAINER="/var/log/remnanode"
LOG_MOUNT_LINE="${LOG_MOUNT_HOST}:${LOG_MOUNT_CONTAINER}"

HY2_MARKER="REMNANODE_SH_HY2_MANAGED"
CADDY_MARKER="REMNANODE_SH_CADDY_MANAGED"

# Строка тома, смонтированного в /certs: «- host/path:/certs[:ro]» (с кавычками или без).
CERT_MOUNT_RE="^[[:space:]]*-[[:space:]]*[\"']?([^\"'[:space:]]+:${CERTS_MOUNT_CONTAINER}(:ro)?)[\"']?[[:space:]]*(#.*)?\$"

# Результаты интерактивных функций (чтобы не возвращать через stdout).
CADDY_DOMAINS=()
CADDY_METHODS=()
CADDY_TOKENS=()
CADDY_SITES=()
CADDY_LISTENS=()
CADDY_EXTRA_SPECS=()
SITE_LISTEN=""
CADDY_IDX=-1
CADDY_PICKED=""
CADDY_LAST_DOMAIN=""
CADDY_ENV_CHANGED=0
CADDY_NEED_80=0
CADDY_NEED_443=0
CADDY_SITE_COUNT=0
CF_PICKED=""
NEW_METHOD=""
NEW_TOKEN="-"
SITE_SRC_DIR=""
SITE_NAME=""
SITE_TMP=""
HY2_PICKED=""

usage() {
  cat <<EOF
Использование: $SCRIPT_NAME [команда]

Без команды — интерактивное меню.

Обычная нода:
  setup            установка / переустановка
  start            docker compose up -d
  stop             docker compose down
  log              docker compose logs -f -t
  du               размер каталога ./log
  token            сменить SECRET_KEY
  port             сменить NODE_PORT
  update           обновить Docker-образ
  certs            подключить / обновить монтирование сертификатов Caddy в /certs
  logrotate-setup  установить/обновить logrotate для ./log
  logrotate-check  проверить конфиг и расписание logrotate
  logrotate-revert [-y|--yes]  удалить конфиг /etc/logrotate.d/ (пакет logrotate не удаляется)

Нода + Hysteria2 — те же команды с префиксом hy2, плюс:
  hy2 domain       выбрать другой домен (из доменов Caddy или добавить новый)
  hy2 cert         статус сертификатов (то же, что caddy cert)
  hy2              меню ноды Hysteria2

Caddy (сертификаты для нод и сайты):
  caddy                          меню Caddy
  caddy setup                    установка / переустановка
  caddy start|stop|log           запуск / остановка / логи
  caddy domains                  домены, способы выдачи, сайты, сроки сертификатов
  caddy add [домен] [способ]     добавить домен (способ: http | alpn | cf)
  caddy remove [домен]           удалить домен
  caddy method [домен] [способ]  сменить способ выдачи сертификата для домена
  caddy cert                     подробный статус сертификатов + JSON для профиля Xray
  caddy token [list|add|check|remove [N]]   токены Cloudflare API
  caddy site [list|set|update|remove] [домен]  сайт на домене (из репозитория или своя папка)
  caddy site listen [домен] [443|pub:ПОРТ|loc:ПОРТ]  где открывать сайт: 443 / свой порт / локально (Reality selfsteal)
  caddy email                    сменить email для Let's Encrypt
  caddy update                   обновить образ Caddy
  caddy sync                     обновить монтирование /certs в обеих нодах
  caddy uninstall                удалить Caddy (монтирование /certs из нод будет убрано)

Способы выдачи сертификата:
  http — HTTP-01, нужен 80/tcp;  alpn — HTTP-01 + TLS-ALPN, 80 и 443/tcp;
  cf — DNS-01 через Cloudflare API, порты не нужны (токен спрашивается один раз на зону).
Сайт открывается на выбор: на 443 (Caddy займёт 443/tcp), на своём порту (https://домен:ПОРТ/)
или только локально 127.0.0.1:ПОРТ — для VLESS Reality selfsteal (Reality на 443 показывает сайт).

  migrate          перенести старую раскладку (Caddy внутри remnanode-hy2, compose рядом со скриптом)

IPv6:
  ipv6 [status|disable|enable]

Фаервол (ufw; на RHEL/Fedora — firewalld):
  firewall status             статус и правила
  firewall enable|disable     включить (SSH открывается автоматически) / выключить
  firewall allow <порт> [IP]  открыть порт: 8443, 8443/tcp, 20000:30000/udp
  firewall delete             удалить правило (выбор по номеру)
  firewall defaults           открыть SSH + DEFAULT_FIREWALL_PORTS
  firewall nodes              открыть SSH + NODE_PORT обеих нод + порты Caddy (80/443)

  bench            тест скорости сервера (bench.sh с российскими серверами)
  help             эта справка

Каталоги:
  ${NODE_DIR_NAME}/, ${HY2_DIR_NAME}/ и ${CADDY_DIR_NAME}/ рядом со скриптом
  (скрипт при установке сам переносится в ~/${NODE_DIR_NAME}/).
  Переопределение: REMNANODE_COMPOSE_DIR (обычная нода), REMNANODE_HY2_DIR (Hysteria2),
  REMNANODE_CADDY_DIR (Caddy).

Сертификаты внутри нод: ${CERTS_MOUNT_CONTAINER}/<домен>/<домен>.crt и .key

При вставке полного docker-compose: после вставки нажмите Enter, затем Ctrl+D
(иначе длинная строка SECRET_KEY может не прочитаться целиком).

Обе ноды работают в network_mode: host одновременно — NODE_PORT и порты inbound'ов
в профилях Xray на панели не должны пересекаться.

В конфиге Xray (профиль на панели) пути логов: /var/log/remnanode/
(см. Node Logs: https://remna.st/docs/install/remnawave-node ).
EOF
}

# =============================================================================
# Общие помощники
# =============================================================================
die() { echo "Ошибка: $*" >&2; exit 1; }
warn() { echo "Внимание: $*" >&2; }
say() { echo "$*" >&2; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

in_list() {
  local needle="$1" x
  shift
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

pause() {
  local _p
  echo
  read -r -p "Нажмите Enter, чтобы продолжить… " _p || true
}

# Выполнить команду от root при необходимости (запись в /etc, файлы Caddy).
run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# Да/нет. $2 — ответ по умолчанию (y|n), подставляется по Enter.
prompt_yes_no() {
  local def="${2:-y}"
  local p q
  if [[ "$def" == "y" ]]; then
    p="[Y/n]"
    q="y"
  else
    p="[y/N]"
    q="n"
  fi
  local r
  read -r -p "$1 $p " r || true
  r="$(lower "$(trim "${r:-$q}")")"
  [[ -n "$r" ]] || r="$q"
  [[ "$r" == "y" || "$r" == "yes" || "$r" == "д" || "$r" == "да" ]]
}

# Спросить значение; Enter — значение по умолчанию. Результат — в stdout.
ask_value() {
  local prompt="$1" def="${2:-}" r=""
  if [[ -n "$def" ]]; then
    read -r -p "$prompt [Enter — $def]: " r || true
  else
    read -r -p "$prompt: " r || true
  fi
  r="$(trim "$r")"
  [[ -n "$r" ]] || r="$def"
  printf '%s' "$r"
}

backup_file() {
  local f="$1" b
  [[ -f "$f" ]] || return 0
  b="${f}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p "$f" "$b"
  say "Бэкап: $b"
}

# Атомарная запись (через временный файл + mv). Не использовать для файлов,
# смонтированных в контейнер как отдельный файл (Caddyfile) — mv меняет inode.
write_lines() {
  local file="$1"
  shift
  local tmp="${file}.tmp.$$"
  printf '%s\n' "$@" >"$tmp" || die "Не удалось записать $tmp"
  mv -f "$tmp" "$file" || die "Не удалось заменить $file"
}

# =============================================================================
# Пути, типы нод
# =============================================================================

# Корень: каталог ~/remnanode со скриптом внутри.
compute_base_dir() {
  if [[ "$(basename "$SCRIPT_DIR")" == "$NODE_DIR_NAME" ]]; then
    BASE_DIR="$SCRIPT_DIR"
  elif [[ "$(basename "$PWD")" == "$NODE_DIR_NAME" ]]; then
    BASE_DIR="$(pwd -P)"
  else
    BASE_DIR="$(pwd -P)/$NODE_DIR_NAME"
  fi
}

# Перенос скрипта в корень (~/remnanode/). Вызывается перед установкой.
relocate_script_to_base() {
  mkdir -p "$BASE_DIR" || die "Не удалось создать $BASE_DIR"
  BASE_DIR="$(cd "$BASE_DIR" && pwd -P)"
  [[ "$SCRIPT_DIR" == "$BASE_DIR" ]] && return 0
  if [[ ! -f "$SCRIPT_PATH" ]]; then
    warn "скрипт запущен не из файла — перенос в $BASE_DIR пропущен."
    return 0
  fi
  local src_abs
  src_abs="$SCRIPT_DIR/$(basename "$SCRIPT_PATH")"
  local dest="$BASE_DIR/$SCRIPT_NAME"
  [[ "$src_abs" == "$dest" ]] && return 0
  if mv -f "$src_abs" "$dest" 2>/dev/null || cp -f "$src_abs" "$dest"; then
    chmod +x "$dest" 2>/dev/null || true
    local old_state="$STATE_FILE"
    SCRIPT_PATH="$dest"
    SCRIPT_DIR="$BASE_DIR"
    STATE_FILE="$SCRIPT_DIR/$STATE_FILE_NAME"
    if [[ -f "$old_state" && ! -f "$STATE_FILE" ]]; then
      cp -f "$old_state" "$STATE_FILE" 2>/dev/null || true
    fi
    say "Скрипт перенесён в $dest (дальше запускайте его оттуда)."
  fi
}

compose_dir_from_state() {
  if [[ -f "$STATE_FILE" ]]; then
    local d
    d="$(tr -d '\r\n' <"$STATE_FILE" | sed 's/[[:space:]]*$//')"
    [[ -n "$d" ]] && echo "$d"
  fi
  return 0
}

save_compose_dir() {
  printf '%s\n' "$1" >"$STATE_FILE"
}

regular_node_dir() {
  if [[ -n "${REMNANODE_COMPOSE_DIR:-}" ]]; then
    echo "${REMNANODE_COMPOSE_DIR}"
    return
  fi
  local d
  d="$(compose_dir_from_state)"
  if [[ -n "$d" && -f "$d/docker-compose.yml" ]]; then
    echo "$d"
    return
  fi
  if [[ ! -f "$BASE_DIR/$NODE_DIR_NAME/docker-compose.yml" ]] && is_remnanode_compose_file "$BASE_DIR/docker-compose.yml"; then
    echo "$BASE_DIR"   # старая раскладка: compose рядом со скриптом
    return
  fi
  echo "$BASE_DIR/$NODE_DIR_NAME"
}

hy2_node_dir() {
  echo "${REMNANODE_HY2_DIR:-$BASE_DIR/$HY2_DIR_NAME}"
}

caddy_dir() {
  echo "${REMNANODE_CADDY_DIR:-$BASE_DIR/$CADDY_DIR_NAME}"
}

caddy_compose() { echo "$(caddy_dir)/docker-compose.yml"; }

caddy_installed() { [[ -f "$(caddy_compose)" ]]; }

caddy_domains_file() { echo "$(caddy_dir)/domains.list"; }

kind_dir() {
  case "$1" in
    node) regular_node_dir ;;
    hy2) hy2_node_dir ;;
  esac
}

kind_title() {
  case "$1" in
    node) echo "Обычная нода ($NODE_DIR_NAME)" ;;
    hy2) echo "Нода + Hysteria2 ($HY2_DIR_NAME)" ;;
  esac
}

kind_container() {
  case "$1" in
    node) echo "$NODE_CONTAINER" ;;
    hy2) echo "$HY2_CONTAINER" ;;
  esac
}

kind_lr_name() {
  case "$1" in
    node) echo "$NODE_DIR_NAME" ;;
    hy2) echo "$HY2_DIR_NAME" ;;
  esac
}

kind_default_port() {
  case "$1" in
    node) echo "$DEFAULT_NODE_PORT" ;;
    hy2) echo "$DEFAULT_HY2_NODE_PORT" ;;
  esac
}

kind_cli() {
  case "$1" in
    node) echo "$SCRIPT_NAME" ;;
    hy2) echo "$SCRIPT_NAME hy2" ;;
  esac
}

other_kind() {
  case "$1" in
    node) echo "hy2" ;;
    hy2) echo "node" ;;
  esac
}

kind_compose() { echo "$(kind_dir "$1")/docker-compose.yml"; }

kind_installed() { [[ -f "$(kind_compose "$1")" ]]; }

require_installed() {
  if [[ "$1" == "hy2" ]]; then
    ensure_new_hy2_layout
  fi
  kind_installed "$1" || die "$(kind_title "$1") не установлена. Сначала: $(kind_cli "$1") setup"
}

kind_port() {
  local f
  f="$(kind_compose "$1")"
  [[ -f "$f" ]] || return 0
  compose_get_env NODE_PORT "$f"
}

# =============================================================================
# Docker
# =============================================================================
require_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker не найден. Установите: curl -fsSL https://get.docker.com | sh"
  docker compose version >/dev/null 2>&1 || die "Нет плагина «docker compose» (v2). Обновите Docker."
}

# docker compose для каталога, без cd (имя проекта = имя каталога или name: из compose).
dc() {
  local dir="$1"
  shift
  docker compose --project-directory "$dir" -f "$dir/docker-compose.yml" "$@"
}

container_state() {
  local s
  s="$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true)"
  echo "${s:-нет контейнера}"
}

container_running() {
  command -v docker >/dev/null 2>&1 || return 1
  [[ "$(container_state "$1")" == "running" ]]
}

restart_count() {
  local n
  n="$(docker inspect -f '{{.RestartCount}}' "$1" 2>/dev/null || true)"
  echo "${n:-0}"
}

# Контейнер с таким именем есть, но из другого каталога — предложить удалить (имена в Docker глобальные).
ensure_container_name_free() {
  local name="$1" dir="$2" wd dir_abs
  docker inspect "$name" >/dev/null 2>&1 || return 0
  wd="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$name" 2>/dev/null || true)"
  [[ "$wd" == "<no value>" ]] && wd=""
  dir_abs="$(cd "$dir" && pwd -P)"
  if [[ -n "$wd" && -d "$wd" ]]; then
    wd="$(cd "$wd" && pwd -P)"
  fi
  [[ "$wd" == "$dir_abs" ]] && return 0
  warn "контейнер «$name» уже существует (${wd:-создан не через compose или каталог удалён})."
  if prompt_yes_no "Остановить и удалить его, чтобы запустить из $dir_abs?" y; then
    docker rm -f "$name" >/dev/null
    say "Контейнер $name удалён."
  else
    die "Имя контейнера $name занято — запуск невозможен."
  fi
}

follow_logs() {
  local dir="$1"
  say "Логи (Ctrl+C — выйти из просмотра, контейнер продолжит работать)…"
  trap 'echo' INT
  dc "$dir" logs -f -t || true
  trap - INT
}

# Проверка после запуска, если вторая нода тоже работает (общая host-сеть).
post_start_check() {
  local kind="$1" me other okind
  okind="$(other_kind "$kind")"
  me="$(kind_container "$kind")"
  other="$(kind_container "$okind")"
  container_running "$other" || return 0

  local before_me before_other
  before_me="$(restart_count "$me")"
  before_other="$(restart_count "$other")"
  say "Вторая нода ($other) тоже запущена — проверяю совместную работу ${POST_START_CHECK_SECONDS} с…"
  sleep "$POST_START_CHECK_SECONDS"

  local problems=0 c before st rc logs
  for c in "$me" "$other"; do
    if [[ "$c" == "$me" ]]; then before="$before_me"; else before="$before_other"; fi
    st="$(container_state "$c")"
    rc="$(restart_count "$c")"
    if [[ "$st" != "running" ]]; then
      warn "$c в состоянии «$st»."
      problems=1
    elif [[ "$rc" != "$before" ]]; then
      warn "$c перезапускался за время проверки (RestartCount $before → $rc)."
      problems=1
    fi
    logs="$(docker logs --since "$((POST_START_CHECK_SECONDS + 5))s" "$c" 2>&1 || true)"
    if grep -qiE 'address already in use|EADDRINUSE' <<<"$logs"; then
      warn "в логах $c: «address already in use» — конфликт портов/сокетов в host-сети."
      problems=1
    fi
  done

  if ((problems)); then
    warn "похоже, ноды конфликтуют. Последние строки логов $me:"
    docker logs --tail 20 "$me" 2>&1 || true
  else
    say "OK: обе ноды работают ($me, $other)."
  fi
  say "Напоминание: порты inbound'ов в профилях Xray обеих нод не должны пересекаться (например, 443/tcp — только у одной)."
}

# =============================================================================
# Порты
# =============================================================================
tcp_listen_list() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk 'NR>1{print $4}' || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -an 2>/dev/null | awk '/LISTEN/{print $4}' || true
  fi
}

tcp_port_busy() {
  local p="$1" list
  list="$(tcp_listen_list)"
  [[ -n "$list" ]] || return 1
  grep -qE "[:.]${p}\$" <<<"$list"
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Причина, по которой порт нельзя использовать (пусто — можно). $3 — текущий порт этой ноды.
port_problem() {
  local kind="$1" p="$2" own="${3:-}" okind other_port
  if ! valid_port "$p"; then
    echo "некорректный порт «$p»"
    return
  fi
  if [[ "$p" == "80" ]]; then
    echo "порт 80 нужен Caddy для получения сертификатов"
    return
  fi
  okind="$(other_kind "$kind")"
  other_port="$(kind_port "$okind")"
  if [[ -n "$other_port" && "$p" == "$other_port" ]]; then
    echo "порт $p уже использует $(kind_title "$okind")"
    return
  fi
  if [[ "$p" != "$own" ]] && tcp_port_busy "$p"; then
    echo "порт $p уже занят на этом сервере"
    return
  fi
}

pick_free_port() {
  local kind="$1" p="$2" own="${3:-}" i=0
  while ((i < 1000)); do
    if [[ -z "$(port_problem "$kind" "$p" "$own")" ]]; then
      echo "$p"
      return 0
    fi
    p=$((p + 1))
    i=$((i + 1))
  done
  echo "$2"
}

ask_node_port() {
  local kind="$1" suggested="$2" own="${3:-}" p prob
  while true; do
    p="$(ask_value "NODE_PORT (порт управления — такой же, как у ноды на панели)" "$suggested")"
    prob="$(port_problem "$kind" "$p" "$own")"
    if [[ -z "$prob" ]]; then
      echo "$p"
      return 0
    fi
    warn "$prob"
  done
}

remind_panel_port() {
  say "На панели в настройках этой ноды должен быть указан порт $1."
  if [[ "$FIREWALL_ON_INSTALL" != "1" ]]; then
    say "В фаерволе откройте $1/tcp только для IP панели («Управление фаерволом»)."
  fi
}

# =============================================================================
# Работа с docker-compose.yml (env-переменные, тома, маркеры)
# =============================================================================

# Значение переменной окружения из строк compose (stdin): «- KEY=val» или «KEY: val».
env_value_from_lines() {
  local key="$1" line val re_list re_map
  re_list="^[[:space:]]*-[[:space:]]*[\"']?${key}[[:space:]]*=(.*)$"
  re_map="^[[:space:]]*${key}:[[:space:]]*(.*)$"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ $re_list ]] || [[ "$line" =~ $re_map ]]; then
      val="$(trim "${BASH_REMATCH[1]}")"
      val="${val#\"}"
      val="${val%\"}"
      val="${val#\'}"
      val="${val%\'}"
      printf '%s' "$(trim "$val")"
      return 0
    fi
  done
  return 0
}

compose_get_env() {
  [[ -f "$2" ]] || return 0
  env_value_from_lines "$1" <"$2"
}

# Заменить значение переменной окружения (формат строки сохраняется). Вернёт 1, если ключ не найден.
compose_set_env() {
  local key="$1" value="$2" file="$3" line found=0 re_list re_map
  local out=()
  re_list="^([[:space:]]*)-[[:space:]]*[\"']?${key}[[:space:]]*="
  re_map="^([[:space:]]*)${key}:[[:space:]]"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ ! "$line" =~ ^[[:space:]]*# ]]; then
      if [[ "$line" =~ $re_list ]]; then
        line="${BASH_REMATCH[1]}- ${key}=${value}"
        found=1
      elif [[ "$line" =~ $re_map ]]; then
        line="${BASH_REMATCH[1]}${key}: ${value}"
        found=1
      fi
    fi
    out+=("$line")
  done <"$file"
  [[ "$found" -eq 1 ]] || return 1
  write_lines "$file" "${out[@]}"
}

# Заменить строку только в строках-комментариях (пути к сертификату в шапке compose).
replace_in_comments() {
  local file="$1" old="$2" new="$3" line
  local out=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      line="${line//"$old"/$new}"
    fi
    out+=("$line")
  done <"$file"
  ((${#out[@]} > 0)) || return 0
  write_lines "$file" "${out[@]}"
}

# Маркер-комментарий «# KEY=value» (заменить или вставить второй строкой).
set_comment_marker() {
  local file="$1" key="$2" value="$3" line found=0
  local out=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" == "# ${key}="* ]]; then
      line="# ${key}=${value}"
      found=1
    fi
    out+=("$line")
  done <"$file"
  if ((found == 0)); then
    if ((${#out[@]} > 1)); then
      out=("${out[0]}" "# ${key}=${value}" "${out[@]:1}")
    elif ((${#out[@]} == 1)); then
      out=("${out[0]}" "# ${key}=${value}")
    else
      out=("# ${key}=${value}")
    fi
  fi
  write_lines "$file" "${out[@]}"
}

compose_has_container() {
  local f="$1" name="$2"
  [[ -f "$f" ]] || return 1
  grep -qiE "^[[:space:]]*container_name:[[:space:]]*[\"']?${name}[\"']?[[:space:]]*(#.*)?\$" "$f"
}

is_remnanode_compose_file() {
  compose_has_container "$1" "$NODE_CONTAINER"
}

has_log_mount_in_file() {
  grep -qE '(\./log|/var/log/remnanode)[[:space:]]*:[[:space:]]*/var/log/remnanode' "$1" 2>/dev/null
}

compose_load_lines() {
  local file="$1"
  _remnanode_sh_lines=()
  while IFS= read -r _cl_line || [[ -n "${_cl_line}" ]]; do
    _remnanode_sh_lines+=("${_cl_line}")
  done < <(tr -d '\r' <"$file")
}

# Дописать элемент в volumes сервиса с container_name: $2 (создать volumes:, если нет).
compose_add_volume() {
  local main="$1" cname="$2" spec="$3"
  compose_load_lines "$main"
  local n=${#_remnanode_sh_lines[@]}
  ((n > 0)) || die "Пустой $main"

  local idx="" i j k m ins last_vol vol_idx="" _ln
  local re_cn="^[[:space:]]*container_name:[[:space:]]*[\"']?${cname}[\"']?[[:space:]]*(#.*)?\$"
  local re_svc='^[[:space:]]{2}[a-zA-Z0-9_.-]+:[[:space:]]*(#.*)?$'
  local re_top='^[a-zA-Z0-9_.-]+:'
  shopt -s nocasematch
  for ((i = 0; i < n; i++)); do
    if [[ "${_remnanode_sh_lines[i]}" =~ $re_cn ]]; then
      idx=$i
      break
    fi
  done
  shopt -u nocasematch
  [[ -n "$idx" ]] || die "В $main не найден container_name: $cname"

  local svc_start=""
  for ((j = idx; j >= 0; j--)); do
    if [[ "${_remnanode_sh_lines[j]}" =~ $re_svc ]]; then
      svc_start=$j
      break
    fi
  done
  [[ -n "$svc_start" ]] || die "Не удалось найти начало сервиса в YAML ($main)"

  local svc_end=$n
  for ((j = svc_start + 1; j < n; j++)); do
    if [[ "${_remnanode_sh_lines[j]}" =~ $re_svc ]] || [[ "${_remnanode_sh_lines[j]}" =~ $re_top ]]; then
      svc_end=$j
      break
    fi
  done

  for ((k = svc_start; k < svc_end; k++)); do
    if [[ "${_remnanode_sh_lines[k]}" =~ ^[[:space:]]{4}volumes:[[:space:]]*(\#.*)?$ ]]; then
      vol_idx=$k
      break
    fi
  done

  local insert_line="      - ${spec}"
  local new_lines=()

  if [[ -n "$vol_idx" ]]; then
    last_vol=$vol_idx
    k=$((vol_idx + 1))
    while ((k < svc_end)); do
      _ln="${_remnanode_sh_lines[k]}"
      if [[ "${_ln}" =~ ^[[:space:]]{4}[a-zA-Z0-9_-]+: ]]; then
        break
      fi
      if [[ "${_ln}" =~ ^[[:space:]]{6}-[[:space:]] ]]; then
        last_vol=$k
      fi
      k=$((k + 1))
    done
    for ((m = 0; m < n; m++)); do
      new_lines+=("${_remnanode_sh_lines[m]}")
      if ((m == last_vol)); then
        new_lines+=("$insert_line")
      fi
    done
  else
    ins=$((svc_end - 1))
    while ((ins > svc_start)) && [[ -z "${_remnanode_sh_lines[ins]// /}" ]]; do
      ins=$((ins - 1))
    done
    for ((m = 0; m < n; m++)); do
      new_lines+=("${_remnanode_sh_lines[m]}")
      if ((m == ins)); then
        new_lines+=("    volumes:")
        new_lines+=("$insert_line")
      fi
    done
  fi

  write_lines "$main" "${new_lines[@]}"
  unset _remnanode_sh_lines
}

# Дописывает том логов в сервис с container_name: $2 (по умолчанию — обычная нода).
ensure_log_volume_in_compose() {
  local main="$1" cname="${2:-$NODE_CONTAINER}"
  has_log_mount_in_file "$main" && return 0
  compose_has_container "$main" "$cname" || die "В $main не найден container_name: $cname — не правлю чужой compose."
  compose_add_volume "$main" "$cname" "$LOG_MOUNT_LINE"
  say "В docker-compose.yml добавлен том: ${LOG_MOUNT_LINE}"
}

# Текущий том на /certs (спецификация «host:/certs[:ro]») или пусто.
compose_cert_mount_spec() {
  local f="$1" line
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ $CERT_MOUNT_RE ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"$f"
  return 0
}

# Убрать наш том сертификатов Caddy (и пустой ключ volumes:, если он остался без элементов).
compose_remove_cert_mount() {
  local file="$1" line i j n ind nind
  local orig=() out=() res=()
  compose_load_lines "$file"
  ((${#_remnanode_sh_lines[@]} > 0)) || return 0
  orig=("${_remnanode_sh_lines[@]}")
  unset _remnanode_sh_lines
  for line in "${orig[@]}"; do
    if [[ ! "$line" =~ ^[[:space:]]*# ]] && [[ "$line" =~ $CERT_MOUNT_RE ]] && [[ "$line" == *caddy/certificates* ]]; then
      continue
    fi
    out+=("$line")
  done
  n=${#out[@]}
  for ((i = 0; i < n; i++)); do
    line="${out[i]}"
    if [[ "$line" =~ ^([[:space:]]+)volumes:[[:space:]]*$ ]]; then
      ind=${#BASH_REMATCH[1]}
      j=$((i + 1))
      while ((j < n)) && [[ -z "${out[j]//[[:space:]]/}" ]]; do
        j=$((j + 1))
      done
      if ((j >= n)); then
        continue
      fi
      nind="${out[j]%%[![:space:]]*}"
      if ((${#nind} < ind)) || { ((${#nind} == ind)) && [[ ! "${out[j]}" =~ ^[[:space:]]*- ]]; }; then
        continue
      fi
    fi
    res+=("$line")
  done
  write_lines "$file" "${res[@]}"
}

# Каталог логов на хосте: относительно каталога с docker-compose.yml (./log).
ensure_log_dir() {
  local base="${1:-.}"
  local path="${base}/${LOG_MOUNT_HOST#./}"
  if mkdir -p "${path}" 2>/dev/null; then
    return 0
  fi
  warn "не удалось создать ${path}."
}

write_minimal_compose() {
  local outfile="$1"
  local secret="$2"
  local port="$3"
  cat >"$outfile" <<EOF
services:
  remnanode:
    container_name: ${NODE_CONTAINER}
    hostname: ${NODE_CONTAINER}
    image: ${NODE_IMAGE}
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=${port}
      - SECRET_KEY=${secret}
    volumes:
      - ${LOG_MOUNT_LINE}
EOF
}

# =============================================================================
# Ввод токена (SECRET_KEY или весь compose из панели)
# =============================================================================
looks_like_compose_yaml() {
  local t="$1"
  grep -qE '(^|[[:space:]])(services:|image:[[:space:]]*remnawave/node|remnanode:)' <<<"$t"
}

normalize_pasted_secret_or_compose() {
  local t="$1"
  if looks_like_compose_yaml "$t"; then
    printf '%s' "$t"
    return
  fi
  local flat
  flat="$(echo "$t" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$flat" =~ ^SECRET_KEY[[:space:]]*=[[:space:]]* ]]; then
    flat="${flat#SECRET_KEY}"
    flat="$(echo "$flat" | sed 's/^[[:space:]]*=[[:space:]]*//')"
  fi
  flat="${flat#\"}"
  flat="${flat%\"}"
  flat="${flat#\'}"
  flat="${flat%\'}"
  printf '%s\n' "$flat"
}

looks_like_secret_only() {
  local t="$1"
  [[ "$(echo "$t" | wc -l | tr -d ' ')" -le 2 ]] || return 1
  local one
  one="$(echo "$t" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ ${#one} -ge 16 ]] && [[ "$one" =~ ^[A-Za-z0-9_+/=\.-]+$ ]]
}

# Длинная строка SECRET_KEY и лимиты TTY ломают read -t (таймаут посреди строки). Для compose дочитываем до EOF (Ctrl+D).
looks_like_compose_start_line() {
  local s="$1"
  [[ "$s" =~ ^[[:space:]]*services: ]] && return 0
  [[ "$s" =~ ^[[:space:]]*# ]] && return 0
  [[ "$s" =~ ^[[:space:]]*version: ]] && return 0
  [[ "$s" =~ ^[[:space:]]*---[[:space:]]*$ ]] && return 0
  [[ "$s" =~ ^[[:space:]]{2}remnanode: ]] && return 0
  return 1
}

read_secret_or_compose() {
  say "SECRET_KEY — одна строка, затем Enter (без Ctrl+D)."
  say "Docker-compose — вставьте весь YAML (можно одним вставлением с первой строки services:)."
  say "Когда вставка закончилась, нажмите Enter и затем Ctrl+D — иначе очень длинная строка SECRET_KEY может обрезаться из‑за таймаута терминала."
  local line1 buf line
  IFS= read -r line1 || die "Пустой ввод"
  if [[ -z "$line1" ]]; then
    IFS= read -r line1 || die "Пустой ввод"
  fi
  buf="$line1"
  if looks_like_compose_start_line "$line1"; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      buf+=$'\n'"$line"
    done
  fi
  REMNANODE_PASTED="$buf"
}

# Результат: TOKEN_VALUE (без кавычек), TOKEN_PANEL_PORT, TOKEN_COMPOSE_TEXT (если вставлен compose).
read_token_input() {
  TOKEN_VALUE=""
  TOKEN_PANEL_PORT=""
  TOKEN_COMPOSE_TEXT=""
  say "Нужен конфиг из панели Remnawave (кнопка «Copy docker-compose.yml») или только SECRET_KEY."
  local pasted
  read_secret_or_compose
  pasted="${REMNANODE_PASTED:-}"
  unset REMNANODE_PASTED
  [[ -n "${pasted//[$'\t\n\r ']/}" ]] || die "Пустой ввод."
  pasted="$(normalize_pasted_secret_or_compose "$pasted")"

  if looks_like_compose_yaml "$pasted"; then
    TOKEN_COMPOSE_TEXT="$pasted"
    TOKEN_VALUE="$(env_value_from_lines SECRET_KEY <<<"$pasted")"
    TOKEN_PANEL_PORT="$(env_value_from_lines NODE_PORT <<<"$pasted")"
    [[ -n "$TOKEN_VALUE" ]] || die "Во вставленном compose не найден SECRET_KEY."
  elif looks_like_secret_only "$pasted"; then
    TOKEN_VALUE="$(trim "$(echo "$pasted" | tr -d '\r\n')")"
  else
    die "Не удалось распознать ввод: ожидается YAML compose или одна строка SECRET_KEY."
  fi
  looks_like_secret_only "$TOKEN_VALUE" || die "SECRET_KEY выглядит некорректно (возможно, обрезан при вставке)."
  say "SECRET_KEY получен (${#TOKEN_VALUE} символов)."
}

# =============================================================================
# Ротация логов (logrotate)
# =============================================================================

# Абсолютный путь к каталогу логов на хосте (рядом с docker-compose.yml).
absolute_host_log_dir() {
  local compose_dir="$1"
  echo "$(cd "$compose_dir" && pwd -P)/${LOG_MOUNT_HOST#./}"
}

# Содержимое stanza для logrotate (пишется в /etc/logrotate.d/).
generate_logrotate_stanza() {
  local abs_logs="$1" label="${2:-}"
  {
    echo "# ${LOGROTATE_FILE_MARKER}"
    echo "# --- remnanode.sh: ротация логов ноды ${label} (access/error в контейнере → *.log здесь) ---"
    echo "# Путь: $abs_logs/*.log | missingok: нет каталога/файлов — без ошибок"
    echo "# copytruncate: процесс держит файл открытым — копируем и обнуляем исходник"
    echo "$abs_logs/*.log {"
    echo "    missingok"
    echo "    notifempty"
    echo "    copytruncate"
    echo "    size ${LOGROTATE_SIZE}"
    echo "    rotate ${LOGROTATE_ROTATE}"
    if [[ "${LOGROTATE_COMPRESS}" == "1" ]]; then
      echo "    compress"
      echo "    delaycompress"
    fi
    echo "}"
  }
}

# Установка пакета logrotate под распространённые дистрибутивы Linux / Homebrew на macOS.
install_logrotate_package() {
  if command -v apt-get >/dev/null 2>&1; then
    run_as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y logrotate
    return $?
  fi
  if command -v dnf >/dev/null 2>&1; then
    run_as_root dnf install -y logrotate
    return $?
  fi
  if command -v yum >/dev/null 2>&1; then
    run_as_root yum install -y logrotate
    return $?
  fi
  if command -v apk >/dev/null 2>&1; then
    run_as_root apk add --no-cache logrotate
    return $?
  fi
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    brew install logrotate
    return $?
  fi
  return 1
}

ensure_logrotate_available() {
  command -v logrotate >/dev/null 2>&1 && return 0
  [[ "${LOGROTATE_TRY_INSTALL}" == "1" ]] || return 1
  say "Пакет logrotate не найден, пробуем установить…"
  if ! install_logrotate_package; then
    say "Не удалось установить logrotate; вручную: apt install logrotate / dnf install logrotate и т.п."
    return 1
  fi
  command -v logrotate >/dev/null 2>&1
}

# Записать конфиг в /etc/logrotate.d/<conf_name> для каталога логов ноды.
setup_logrotate_for_dir() {
  local compose_dir="$1" conf_name="$2"

  [[ "${LOGROTATE_SETUP}" == "1" ]] || return 0

  local abs_log
  abs_log="$(absolute_host_log_dir "$compose_dir")"
  local conf_path="/etc/logrotate.d/${conf_name}"

  if ! ensure_logrotate_available; then
    say "Пропуск настройки logrotate (нет пакета или sudo)."
    return 0
  fi

  if [[ ! -d /etc/logrotate.d ]]; then
    say "Нет каталога /etc/logrotate.d — типично это не Linux-сервер; пропуск."
    return 0
  fi

  if [[ -f "$conf_path" ]] && ! logrotate_file_is_managed_by_script "$conf_path"; then
    warn "$conf_path существует и создан не этим скриптом — не перезаписываю."
    return 0
  fi

  local tmp
  tmp="$(mktemp)" || return 0
  generate_logrotate_stanza "$abs_log" "$conf_name" >"$tmp"

  if ! run_as_root tee "$conf_path" <"$tmp" >/dev/null; then
    say "Не удалось записать $conf_path (нужны права root/sudo)."
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  run_as_root chmod 0644 "$conf_path" 2>/dev/null || true

  say "Logrotate: записан $conf_path для $abs_log/*.log (rotate=${LOGROTATE_ROTATE}, size=${LOGROTATE_SIZE})."
  verify_logrotate_will_run "$conf_path"
  return 0
}

# Убедиться, что конфиг валиден и что по системе logrotate реально вызывается по расписанию.
verify_logrotate_will_run() {
  local conf_path="${1:-}"

  if [[ -n "$conf_path" && -f "$conf_path" ]]; then
    if run_as_root logrotate -d "$conf_path" >/dev/null 2>&1; then
      say "Logrotate: проверка OK — «logrotate -d $conf_path» завершился успешно."
    else
      say "Внимание: «logrotate -d $conf_path» завершился с ошибкой — ротация может не сработать; смотрите вывод: sudo logrotate -d $conf_path"
    fi
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    say "Logrotate (macOS): системное расписание не проверяется; при необходимости добавьте в crontab вызов logrotate с путём к конфигу."
    return 0
  fi

  local scheduler_ok=0
  local timer_unit=""

  if command -v systemctl >/dev/null 2>&1; then
    for timer_unit in /usr/lib/systemd/system/logrotate.timer /lib/systemd/system/logrotate.timer /etc/systemd/system/logrotate.timer; do
      if [[ -f "$timer_unit" ]]; then
        if systemctl is-enabled --quiet logrotate.timer 2>/dev/null || systemctl is-active --quiet logrotate.timer 2>/dev/null; then
          say "Logrotate: systemd — logrotate.timer включён или сейчас активен (расписание есть)."
          scheduler_ok=1
        else
          say "Внимание: найден logrotate.timer, но unit не enabled/active. Включите: sudo systemctl enable --now logrotate.timer"
        fi
        break
      fi
    done
  fi

  if [[ -f /etc/cron.daily/logrotate ]]; then
    say "Logrotate: найден /etc/cron.daily/logrotate (ежедневный запуск через cron)."
    scheduler_ok=1
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null; then
        say "Logrotate: сервис cron или crond сейчас active — ежедневные задания должны выполняться."
      else
        say "Внимание: cron/crond не в состоянии active — /etc/cron.daily/ может не отрабатывать. Проверьте: sudo systemctl status cron"
      fi
    fi
  fi

  if [[ -f /etc/periodic/daily/logrotate ]]; then
    say "Logrotate: найден /etc/periodic/daily/logrotate (Alpine/periodic)."
    scheduler_ok=1
  fi

  if [[ "$scheduler_ok" -eq 0 ]]; then
    say "Внимание: не обнаружен ни logrotate.timer, ни /etc/cron.daily/logrotate, ни periodic/daily — автоматическая ротация, возможно, не настроена."
    say "  Проверьте вручную: ls /lib/systemd/system/logrotate.timer /etc/cron.daily/logrotate 2>/dev/null; sudo systemctl status logrotate.timer"
  fi
}

# Файл создан этим скриптом (маркер или старый комментарий до появления маркера).
logrotate_file_is_managed_by_script() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -qF "${LOGROTATE_FILE_MARKER}" "$f" 2>/dev/null && return 0
  grep -qF "remnanode.sh: ротация логов ноды" "$f" 2>/dev/null
}

cmd_logrotate_setup() {
  local kind="$1"
  require_installed "$kind"
  setup_logrotate_for_dir "$(kind_dir "$kind")" "$(kind_lr_name "$kind")" || true
}

cmd_logrotate_check() {
  local kind="$1"
  local conf_path
  conf_path="/etc/logrotate.d/$(kind_lr_name "$kind")"
  if [[ ! -f "$conf_path" ]]; then
    die "Нет файла $conf_path — сначала: $(kind_cli "$kind") logrotate-setup"
  fi
  verify_logrotate_will_run "$conf_path"
}

# Удалить только наш drop-in в /etc/logrotate.d/. Пакет logrotate не удаляем.
cmd_logrotate_revert() {
  local kind="$1" force="${2:-}"
  local conf_path
  conf_path="/etc/logrotate.d/$(kind_lr_name "$kind")"

  if [[ ! -f "$conf_path" ]]; then
    say "Файл $conf_path не найден — следов этого скрипта в logrotate.d нет."
    return 0
  fi

  if ! logrotate_file_is_managed_by_script "$conf_path"; then
    say "Файл $conf_path не содержит маркера ${LOGROTATE_FILE_MARKER} (и не похож на старый конфиг скрипта) — удаление отменено, чтобы не снести чужой файл."
    die "Если это всё же файл скрипта, удалите вручную: sudo rm $conf_path"
  fi

  if [[ "$force" != "-y" && "$force" != "--yes" ]]; then
    if ! prompt_yes_no "Удалить $conf_path? Пакет logrotate в системе останется." "$DEFAULT_LOGROTATE_REVERT"; then
      say "Отмена."
      return 0
    fi
  fi

  run_as_root rm -f "$conf_path" || die "Не удалось удалить $conf_path (нужен sudo)."
  say "Удалён $conf_path. Пакет logrotate не удалялся."
}

# =============================================================================
# Домены, DNS
# =============================================================================
valid_domain() {
  local re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
  [[ "$1" =~ $re ]]
}

normalize_domain() {
  local d
  d="$(lower "$(trim "$1")")"
  d="${d#http://}"
  d="${d#https://}"
  d="${d%%/*}"
  printf '%s' "$d"
}

ask_domain() {
  local def="${1:-}" d
  while true; do
    d="$(ask_value "Домен (A-запись должна указывать на этот сервер)" "$def")"
    d="$(normalize_domain "$d")"
    if valid_domain "$d"; then
      echo "$d"
      return 0
    fi
    warn "некорректный домен «$d»."
  done
}

ask_email() {
  local def="$1" e
  while true; do
    e="$(ask_value "Email для Let's Encrypt" "$def")"
    if [[ "$e" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
      echo "$e"
      return 0
    fi
    warn "некорректный email «$e»."
  done
}

resolve_ipv4() {
  local d="$1"
  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u || true
  elif command -v dig >/dev/null 2>&1; then
    dig +short A "$d" 2>/dev/null | grep -E '^[0-9.]+$' || true
  elif command -v host >/dev/null 2>&1; then
    host -t A "$d" 2>/dev/null | awk '/has address/{print $4}' || true
  fi
}

public_ipv4() {
  local u ip
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=""
    if command -v curl >/dev/null 2>&1; then
      ip="$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null || true)"
    elif command -v wget >/dev/null 2>&1; then
      ip="$(wget -4 -qO- -T 5 "$u" 2>/dev/null || true)"
    else
      return 0
    fi
    ip="$(trim "$ip")"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 0
}

local_ipv4s() {
  if command -v hostname >/dev/null 2>&1 && hostname -I >/dev/null 2>&1; then
    hostname -I 2>/dev/null || true
  elif command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true
  fi
}

# 0 — можно продолжать; 1 — пользователь отказался.
check_domain_dns() {
  local domain="$1" ips pub locals ip ok=0
  say "Проверяю DNS для $domain…"
  ips="$(resolve_ipv4 "$domain")"
  pub="$(public_ipv4)"
  locals="$(local_ipv4s)"
  if [[ -z "$ips" ]]; then
    warn "домен $domain не резолвится в IPv4 (нет A-записи или DNS ещё не обновился)."
  elif [[ -z "$pub$locals" ]]; then
    say "DNS: $domain → $(echo $ips) (IP сервера определить не удалось — проверка пропущена)."
    return 0
  else
    for ip in $ips; do
      if [[ " $(echo $pub $locals) " == *" $ip "* ]]; then
        ok=1
      fi
    done
    if ((ok)); then
      say "DNS OK: $domain → $(echo $ips)"
      return 0
    fi
    warn "A-запись $domain → $(echo $ips), а IP этого сервера: ${pub:-$(echo $locals)}."
    say "  Если домен за Cloudflare — выключите проксирование (серое облако), иначе Let's Encrypt не выдаст сертификат."
  fi
  prompt_yes_no "Всё равно продолжить?" "$DEFAULT_CONTINUE_ON_DNS_MISMATCH"
}

# =============================================================================
# Caddy: файлы, домены, способы выдачи, Cloudflare
# =============================================================================
#
# domains.list — одна строка на домен:
#   <домен> <способ> token=<N|-> site=<repo:имя|own|->
#   способ: http — HTTP-01 (80/tcp); alpn — HTTP-01 + TLS-ALPN (80 и 443/tcp);
#           cf — DNS-01 через Cloudflare API (токен CF_API_TOKEN_<N> из .env)
# .env — ACME_EMAIL и токены Cloudflare (CF_API_TOKEN_1, CF_API_TOKEN_2, …), права 600.

acme_ca_dir_name() {
  local s="${ACME_CA#*://}"
  echo "${s//\//-}"
}

valid_method() { [[ "$1" == "http" || "$1" == "alpn" || "$1" == "cf" ]]; }

method_desc() {
  case "$1" in
    http) echo "http — HTTP-01 (порт 80)" ;;
    alpn) echo "alpn — HTTP-01 + TLS-ALPN (порты 80 и 443)" ;;
    cf) echo "cf — DNS-01 через Cloudflare API" ;;
    *) echo "$1" ;;
  esac
}

ask_method() {
  local def="${1:-http}" m defn=1
  case "$def" in
    alpn) defn=2 ;;
    cf) defn=3 ;;
  esac
  say "Способ получения сертификата:"
  say "  1) http — HTTP-01: нужен открытый 80/tcp и A-запись на этот сервер"
  say "  2) alpn — HTTP-01 + TLS-ALPN: Caddy займёт 80/tcp и 443/tcp"
  say "  3) cf   — DNS-01 через Cloudflare API: порты не нужны, работает и с проксированием (оранжевое облако)"
  while true; do
    m="$(ask_value "Способ (1/2/3)" "$defn")"
    case "$(lower "$m")" in
      1 | http) echo http; return 0 ;;
      2 | alpn) echo alpn; return 0 ;;
      3 | cf | cloudflare) echo cf; return 0 ;;
    esac
    warn "введите 1, 2 или 3."
  done
}

# Режим из compose старой версии скрипта: маркер «# CERT_MODE=N», иначе по наличию 443:443.
compose_cert_mode() {
  local f="$1" m
  m="$(grep -m1 -E '^# CERT_MODE=' "$f" 2>/dev/null | sed 's/^# CERT_MODE=//' | tr -d '[:space:]' || true)"
  if [[ "$m" == "1" || "$m" == "2" ]]; then
    echo "$m"
  elif grep -qE '^[[:space:]]*-[[:space:]]*["'\'']?443:443' "$f" 2>/dev/null; then
    echo 2
  else
    echo 1
  fi
}

caddy_env_file() { echo "$(caddy_dir)/.env"; }

caddy_www_dir() { echo "$(caddy_dir)/www"; }

# Откуда брать настройки Caddy (compose или сохранённый после удаления).
caddy_settings_source() {
  local c
  c="$(caddy_compose)"
  if [[ -f "$c" ]]; then
    echo "$c"
  elif [[ -f "$c.removed" ]]; then
    echo "$c.removed"
  fi
  return 0
}

caddy_compose_is_current() {
  grep -q '^# CADDY_FORMAT=2' "$1" 2>/dev/null
}

# --- .env ---
caddy_ensure_env() {
  local f
  f="$(caddy_env_file)"
  [[ -f "$f" ]] && return 0
  mkdir -p "$(dirname "$f")" || die "Не удалось создать $(dirname "$f")"
  (
    umask 077
    printf '%s\n' "# ${CADDY_MARKER}" \
      "# Создаётся и редактируется ${SCRIPT_NAME}: email для Let's Encrypt и токены Cloudflare." \
      "# Содержит секреты — права 600." >"$f"
  ) || die "Не удалось создать $f"
  chmod 600 "$f" 2>/dev/null || true
  say "Создан $f"
}

caddy_env_get() {
  local key="$1" f line
  f="$(caddy_env_file)"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" == "${key}="* ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <"$f"
  return 0
}

# $3: «del» — удалить ключ.
caddy_env_write() {
  local key="$1" val="$2" mode="${3:-set}" f line found=0
  local out=()
  caddy_ensure_env
  f="$(caddy_env_file)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" == "${key}="* ]]; then
      found=1
      [[ "$mode" == "del" ]] && continue
      line="${key}=${val}"
    fi
    out+=("$line")
  done <"$f"
  if ((found == 0)) && [[ "$mode" != "del" ]]; then
    out+=("${key}=${val}")
  fi
  ((${#out[@]})) || out=("# ${CADDY_MARKER}")
  (
    umask 077
    write_lines "$f" "${out[@]}"
  ) || die "Не удалось записать $f"
  chmod 600 "$f" 2>/dev/null || true
}

caddy_env_set() { caddy_env_write "$1" "$2" set; }
caddy_env_del() { caddy_env_write "$1" "" del; }

caddy_email() {
  local e s
  e="$(caddy_env_get ACME_EMAIL)"
  if [[ -z "$e" ]]; then
    s="$(caddy_settings_source)"
    if [[ -n "$s" ]]; then
      e="$(compose_get_env ACME_EMAIL "$s")"
    fi
  fi
  printf '%s' "$e"
}

# --- Сертификаты ---
caddy_cert_root() { echo "$(caddy_dir)/data/caddy/certificates/$(acme_ca_dir_name)"; }

caddy_cert_file() { echo "$(caddy_cert_root)/$1/$1.crt"; }

# Каталог data/caddy создаёт Caddy (root, 0700) — проверяем через root.
caddy_cert_exists() {
  local f
  f="$(caddy_cert_file "$1")"
  [[ -r "$f" ]] && return 0
  run_as_root test -f "$f" 2>/dev/null
}

caddy_cert_enddate() {
  local f
  f="$(caddy_cert_file "$1")"
  command -v openssl >/dev/null 2>&1 || return 0
  run_as_root openssl x509 -in "$f" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true
}

# --- Список доменов ---
caddy_legacy_default_method() {
  local s
  s="$(caddy_settings_source)"
  if [[ -n "$s" ]] && ! caddy_compose_is_current "$s" && [[ "$(compose_cert_mode "$s")" == "2" ]]; then
    echo alpn
  else
    echo http
  fi
}

load_caddy_domains() {
  CADDY_DOMAINS=()
  CADDY_METHODS=()
  CADDY_TOKENS=()
  CADDY_SITES=()
  CADDY_LISTENS=()
  local f line d m t s l w defm=""
  f="$(caddy_domains_file)"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="$(trim "${line%%#*}")"
    [[ -n "$line" ]] || continue
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    d="$(lower "$1")"
    shift
    m=""
    t="-"
    s="-"
    l=""
    for w in "$@"; do
      case "$w" in
        http | alpn | cf) m="$w" ;;
        token=*) t="${w#token=}" ;;
        site=*) s="${w#site=}" ;;
        listen=*) l="${w#listen=}" ;;
      esac
    done
    if [[ -z "$m" ]]; then
      [[ -n "$defm" ]] || defm="$(caddy_legacy_default_method)"
      m="$defm"
    fi
    [[ -n "$t" ]] || t="-"
    [[ -n "$s" ]] || s="-"
    if [[ "$s" == "-" ]]; then
      l="-"
    elif ! site_listen_valid "$l"; then
      l="443"
    fi
    CADDY_DOMAINS+=("$d")
    CADDY_METHODS+=("$m")
    CADDY_TOKENS+=("$t")
    CADDY_SITES+=("$s")
    CADDY_LISTENS+=("$l")
  done <"$f"
}

save_caddy_domains() {
  local f i n
  local lines=("# <домен> <способ: http|alpn|cf> token=<N|-> site=<repo:имя|own|-> listen=<443|pub:ПОРТ|loc:ПОРТ|-> — управляется ${SCRIPT_NAME}")
  f="$(caddy_domains_file)"
  mkdir -p "$(dirname "$f")" || die "Не удалось создать $(dirname "$f")"
  n=${#CADDY_DOMAINS[@]}
  for ((i = 0; i < n; i++)); do
    lines+=("${CADDY_DOMAINS[i]} ${CADDY_METHODS[i]} token=${CADDY_TOKENS[i]} site=${CADDY_SITES[i]} listen=${CADDY_LISTENS[i]:--}")
  done
  write_lines "$f" "${lines[@]}"
}

# Индекс домена в загруженном списке → CADDY_IDX.
caddy_find() {
  local d="$1" i
  CADDY_IDX=-1
  for ((i = 0; i < ${#CADDY_DOMAINS[@]}; i++)); do
    if [[ "${CADDY_DOMAINS[i]}" == "$d" ]]; then
      CADDY_IDX=$i
      return 0
    fi
  done
  return 1
}

caddy_has_domain() {
  load_caddy_domains
  caddy_find "$1"
}

caddy_append_domain() {
  CADDY_DOMAINS+=("$1")
  CADDY_METHODS+=("$2")
  CADDY_TOKENS+=("${3:--}")
  CADDY_SITES+=("${4:--}")
  CADDY_LISTENS+=("${5:--}")
}

caddy_delete_at() {
  local del="$1" i
  local d=() m=() t=() s=() l=()
  for ((i = 0; i < ${#CADDY_DOMAINS[@]}; i++)); do
    if ((i != del)); then
      d+=("${CADDY_DOMAINS[i]}")
      m+=("${CADDY_METHODS[i]}")
      t+=("${CADDY_TOKENS[i]}")
      s+=("${CADDY_SITES[i]}")
      l+=("${CADDY_LISTENS[i]}")
    fi
  done
  CADDY_DOMAINS=(${d[@]+"${d[@]}"})
  CADDY_METHODS=(${m[@]+"${m[@]}"})
  CADDY_TOKENS=(${t[@]+"${t[@]}"})
  CADDY_SITES=(${s[@]+"${s[@]}"})
  CADDY_LISTENS=(${l[@]+"${l[@]}"})
}

caddy_remove_from_list() {
  load_caddy_domains
  caddy_find "$1" || return 0
  caddy_delete_at "$CADDY_IDX"
  save_caddy_domains
}

# Снимок domains.list до изменения — чтобы откатить, если порты заняты.
caddy_snapshot() {
  local f
  f="$(caddy_domains_file)"
  if [[ -f "$f" ]]; then cp -p "$f" "$f.snap"; else : >"$f.snap"; fi
}

caddy_restore_snapshot() {
  local f
  f="$(caddy_domains_file)"
  if [[ -f "$f.snap" ]]; then mv -f "$f.snap" "$f"; fi
  return 0
}

caddy_drop_snapshot() { rm -f "$(caddy_domains_file).snap"; }

# Какие порты нужны Caddy при текущем списке доменов.
# CADDY_NEED_80 / CADDY_NEED_443 и CADDY_EXTRA_SPECS — порты сайтов на своих портах
# («ПОРТ:ПОРТ» — публично, «127.0.0.1:ПОРТ:ПОРТ» — локально).
caddy_compute_needs() {
  local i n l spec
  CADDY_NEED_80=0
  CADDY_NEED_443=0
  CADDY_SITE_COUNT=0
  CADDY_EXTRA_SPECS=()
  n=${#CADDY_DOMAINS[@]}
  for ((i = 0; i < n; i++)); do
    case "${CADDY_METHODS[i]}" in
      http) CADDY_NEED_80=1 ;;
      alpn)
        CADDY_NEED_80=1
        CADDY_NEED_443=1
        ;;
    esac
    if [[ "${CADDY_SITES[i]}" != "-" ]]; then
      CADDY_SITE_COUNT=$((CADDY_SITE_COUNT + 1))
      CADDY_NEED_80=1
      l="${CADDY_LISTENS[i]}"
      spec=""
      case "$l" in
        pub:*) spec="${l#pub:}:${l#pub:}" ;;
        loc:*) spec="127.0.0.1:${l#loc:}:${l#loc:}" ;;
        *) CADDY_NEED_443=1 ;;
      esac
      if [[ -n "$spec" ]] && ! in_list "$spec" ${CADDY_EXTRA_SPECS[@]+"${CADDY_EXTRA_SPECS[@]}"}; then
        CADDY_EXTRA_SPECS+=("$spec")
      fi
    fi
  done
}

# Публикуемые порты (спецификации docker «хост:контейнер») — по одной на строку. Нужен caddy_compute_needs.
caddy_publish_specs() {
  local s
  if ((CADDY_NEED_80)); then echo "80:80"; fi
  if ((CADDY_NEED_443)); then echo "443:443"; fi
  for s in ${CADDY_EXTRA_SPECS[@]+"${CADDY_EXTRA_SPECS[@]}"}; do
    echo "$s"
  done
}

# Порты, опубликованные в текущем compose Caddy.
caddy_compose_specs() {
  local f
  f="$(caddy_compose)"
  [[ -f "$f" ]] || return 0
  sed -nE 's/^[[:space:]]*-[[:space:]]*"([0-9.]+:)?([0-9]+:[0-9]+)"[[:space:]]*$/\1\2/p' "$f" || true
}

spec_host_port() {
  local p="${1%:*}"
  echo "${p##*:}"
}

caddy_default_method() {
  if [[ -n "$(cf_token_ids)" ]]; then echo cf; else echo http; fi
}

caddy_domain_info_short() {
  local i="$1" m t s info
  m="${CADDY_METHODS[i]}"
  t="${CADDY_TOKENS[i]}"
  s="${CADDY_SITES[i]}"
  info="$m"
  if [[ "$m" == "cf" ]]; then info="cf (токен #$t)"; fi
  if [[ "$s" != "-" ]]; then info="$info · сайт: $s, $(site_listen_desc "${CADDY_LISTENS[i]}")"; fi
  printf '%s' "$info"
}

# Выбор домена из списка. $1: all|site|repo, $2: текст вопроса, $3: new — разрешить «0) новый домен».
# Результат: CADDY_PICKED (или «__new__»). return 1 — отмена.
caddy_pick_domain() {
  local filter="$1" prompt="$2" allow_new="${3:-}" i n k choice s
  local idxs=()
  CADDY_PICKED=""
  load_caddy_domains
  n=${#CADDY_DOMAINS[@]}
  for ((i = 0; i < n; i++)); do
    s="${CADDY_SITES[i]}"
    case "$filter" in
      site) [[ "$s" != "-" ]] || continue ;;
      repo) [[ "$s" == repo:* ]] || continue ;;
    esac
    idxs+=("$i")
  done
  if ((${#idxs[@]} == 0)) && [[ -z "$allow_new" ]]; then
    say "Подходящих доменов нет."
    return 1
  fi
  k=1
  for i in ${idxs[@]+"${idxs[@]}"}; do
    printf ' %2d) %s — %s\n' "$k" "${CADDY_DOMAINS[i]}" "$(caddy_domain_info_short "$i")" >&2
    k=$((k + 1))
  done
  if [[ -n "$allow_new" ]]; then
    say "  0) новый домен"
  fi
  choice="$(ask_value "$prompt (Enter — отмена)" "")"
  [[ -n "$choice" ]] || return 1
  if [[ -n "$allow_new" && "$choice" == "0" ]]; then
    CADDY_PICKED="__new__"
    return 0
  fi
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#idxs[@]}" ]; then
    i="${idxs[$((choice - 1))]}"
    CADDY_PICKED="${CADDY_DOMAINS[i]}"
    return 0
  fi
  die "Нет пункта с номером $choice."
}

# --- Генерация Caddyfile и compose ---

# Caddyfile пишется «на месте» (cat >), без mv: файл смонтирован в контейнер отдельно,
# и смена inode сломала бы caddy reload.
# shellcheck disable=SC2016
caddy_write_caddyfile() {
  local out tmp i n d m t s l
  out="$(caddy_dir)/Caddyfile"
  load_caddy_domains
  caddy_compute_needs
  n=${#CADDY_DOMAINS[@]}
  tmp="$(mktemp)" || die "mktemp не сработал"
  {
    echo "# ${CADDY_MARKER}"
    echo "# Генерируется ${SCRIPT_NAME} из domains.list — вручную не редактируйте."
    echo "# Домены без сайта: Caddy только получает и продлевает сертификат (respond \"OK\")."
    echo "{"
    printf '\t%s\n' 'email {$ACME_EMAIL}'
    printf '\tacme_ca %s\n' "$ACME_CA"
    if ((CADDY_NEED_443 == 0)); then
      echo "	# 443/tcp хоста не занят: домены без сайта (и сайтов на 443) — HTTPS внутри контейнера"
      printf '\thttps_port %s\n' "$CADDY_INTERNAL_HTTPS_PORT"
    fi
    printf '\t%s\n' 'auto_https disable_redirects'
    echo "	# без HTTP/3: 443/udp на хосте занят Hysteria2"
    printf '\tservers {\n\t\tprotocols h1 h2\n\t}\n'
    echo "}"
    for ((i = 0; i < n; i++)); do
      d="${CADDY_DOMAINS[i]}"
      m="${CADDY_METHODS[i]}"
      t="${CADDY_TOKENS[i]}"
      s="${CADDY_SITES[i]}"
      l="${CADDY_LISTENS[i]}"
      echo
      echo "# ${d} — $(caddy_domain_info_short "$i")"
      if [[ "$s" != "-" ]]; then
        if [[ "$l" == pub:* ]]; then
          printf 'http://%s {\n\tredir https://{host}:%s{uri} permanent\n}\n\n' "$d" "${l#pub:}"
        else
          printf 'http://%s {\n\tredir https://{host}{uri} permanent\n}\n\n' "$d"
        fi
      elif [[ "$m" != "cf" ]]; then
        printf 'http://%s {\n\trespond "OK"\n}\n\n' "$d"
      fi
      if [[ "$s" != "-" && ( "$l" == pub:* || "$l" == loc:* ) ]]; then
        printf '%s:%s {\n' "$d" "${l#*:}"
      else
        printf '%s {\n' "$d"
      fi
      case "$m" in
        http)
          printf '\ttls {\n\t\tissuer acme {\n\t\t\tdir %s\n' "$ACME_CA"
          printf '\t\t\t%s\n' 'email {$ACME_EMAIL}'
          printf '\t\t\tdisable_tlsalpn_challenge\n\t\t}\n\t}\n'
          ;;
        cf)
          printf '\ttls {\n\t\tdns cloudflare {env.CF_API_TOKEN_%s}\n\t\tresolvers %s\n\t}\n' "$t" "$CF_DNS_RESOLVER"
          ;;
      esac
      if [[ "$s" != "-" ]]; then
        printf '\troot * /srv/%s\n\tfile_server\n' "$d"
      else
        printf '\trespond "OK"\n'
      fi
      echo "}"
    done
  } >"$tmp"
  if ! cat "$tmp" >"$out"; then
    rm -f "$tmp"
    die "Не удалось записать $out"
  fi
  rm -f "$tmp"
}

caddy_write_compose() {
  local outfile cadir ports="" spec
  outfile="$(caddy_compose)"
  cadir="$(acme_ca_dir_name)"
  load_caddy_domains
  caddy_compute_needs
  for spec in $(caddy_publish_specs); do
    ports+=$'\n      - "'"$spec"'"'
  done
  if [[ -n "$ports" ]]; then
    ports=$'\n    ports:'"$ports"
  fi
  cat >"$outfile" <<EOF2
# ${CADDY_MARKER}
# CADDY_FORMAT=2
# Генерируется ${SCRIPT_NAME}. Домены, способы выдачи и сайты — в domains.list,
# email и токены Cloudflare — в .env (меняйте через скрипт).
# Сертификаты на хосте: ./data/caddy/certificates/${cadir}/<домен>/<домен>.crt|.key
# Ноды монтируют этот каталог в ${CERTS_MOUNT_CONTAINER} (только чтение). Сайты: ./www/<домен>/
name: ${CADDY_PROJECT_NAME}

services:
  caddy:
    image: ${CADDY_IMAGE}
    container_name: ${CADDY_CONTAINER}
    restart: unless-stopped
    env_file:
      - ./.env${ports}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
      - ./www:/srv:ro
EOF2
}

caddy_write_all() {
  local dir
  dir="$(caddy_dir)"
  mkdir -p "$dir/data" "$dir/config" "$dir/www" || die "Не удалось создать каталоги в $dir"
  caddy_ensure_env
  caddy_write_caddyfile
  caddy_write_compose
}

caddy_compose_publishes() {
  grep -qE "^[[:space:]]*-[[:space:]]*\"?${1}:${1}\"?[[:space:]]*$" "$(caddy_compose)" 2>/dev/null
}

# Нужные порты свободны (или уже заняты нашим Caddy)? Нужен caddy_compute_needs.
caddy_ports_ok() {
  local ours=false spec p cur_ports=" "
  if container_running "$CADDY_CONTAINER"; then
    ours=true
    for spec in $(caddy_compose_specs); do
      cur_ports="$cur_ports$(spec_host_port "$spec") "
    done
  fi
  for spec in $(caddy_publish_specs); do
    p="$(spec_host_port "$spec")"
    if $ours && [[ "$cur_ports" == *" $p "* ]]; then
      continue
    fi
    if tcp_port_busy "$p"; then
      warn "порт ${p}/tcp занят другим процессом — Caddy не сможет его опубликовать."
      case "$p" in
        443) say "  443/tcp нужен сайтам с доступом на 443 и способу alpn. Если на 443 стоит VLESS Reality — откройте сайт на своём порту или локально (Caddy → Сайты → Порт)." ;;
        80) say "  80/tcp нужен способам http/alpn и редиректу сайтов на HTTPS." ;;
      esac
      say "  Кто слушает: sudo ss -ltnp 'sport = :${p}'"
      return 1
    fi
  done
  return 0
}

caddy_state_sum() {
  cat "$(caddy_compose)" "$(caddy_env_file)" 2>/dev/null | cksum
}

# Применить domains.list/.env: перегенерировать файлы; пересоздать контейнер, если поменялись
# compose/.env (порты, токены), иначе — caddy reload. $1=force — пересоздать в любом случае.
# return 1 — нужные порты заняты (файлы при этом не меняются).
caddy_commit() {
  local force="${1:-}" dir before after before_specs spec new_public=0
  dir="$(caddy_dir)"
  load_caddy_domains
  caddy_compute_needs
  caddy_ports_ok || return 1
  before_specs=" $(caddy_compose_specs | tr '\n' ' ') "
  before="$(caddy_state_sum)"
  caddy_write_all
  after="$(caddy_state_sum)"
  for spec in $(caddy_publish_specs); do
    if [[ "$spec" != 127.* && "$before_specs" != *" $spec "* ]]; then
      new_public=1
    fi
  done
  if ((new_public)); then
    fw_caddy_on_install
  fi
  if [[ -n "$force" || "$before" != "$after" || "${CADDY_ENV_CHANGED:-0}" == "1" ]] || ! container_running "$CADDY_CONTAINER"; then
    dc "$dir" config >/dev/null || die "docker compose config: ошибка в $(caddy_compose)"
    ensure_container_name_free "$CADDY_CONTAINER" "$dir"
    say "Пересоздаю контейнер Caddy (изменились порты/токены/образ)…"
    dc "$dir" up -d --force-recreate
    CADDY_ENV_CHANGED=0
  else
    caddy_apply_config
  fi
}

# Применить новый Caddyfile: reload в работающем контейнере, иначе запуск.
caddy_apply_config() {
  local dir
  dir="$(caddy_dir)"
  if container_running "$CADDY_CONTAINER"; then
    if docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
      say "Caddy: конфигурация перезагружена."
      return 0
    fi
    warn "caddy reload не удался — перезапускаю контейнер."
    docker restart "$CADDY_CONTAINER" >/dev/null
  else
    ensure_container_name_free "$CADDY_CONTAINER" "$dir"
    dc "$dir" up -d
  fi
}

caddy_ensure_running() {
  container_running "$CADDY_CONTAINER" && return 0
  local dir
  dir="$(caddy_dir)"
  say "Caddy не запущен — запускаю…"
  ensure_container_name_free "$CADDY_CONTAINER" "$dir"
  dc "$dir" up -d
}

caddy_wait_cert() {
  local d="$1" timeout="${2:-$CERT_WAIT_SECONDS}" t=0
  if caddy_cert_exists "$d"; then
    return 0
  fi
  say "Жду сертификат для $d (до ${timeout} с)…"
  while ((t < timeout)); do
    if caddy_cert_exists "$d"; then
      say "Сертификат для $d получен."
      return 0
    fi
    if ! container_running "$CADDY_CONTAINER"; then
      warn "контейнер $CADDY_CONTAINER не запущен ($(container_state "$CADDY_CONTAINER"))."
      return 1
    fi
    sleep 5
    t=$((t + 5))
  done
  return 1
}

# Удалить сертификат домена и перезапустить Caddy — он выпустит новый текущим способом.
caddy_reissue() {
  local d="$1"
  run_as_root rm -rf "$(caddy_cert_root)/$d"
  say "Старый сертификат $d удалён, перезапускаю Caddy…"
  docker restart "$CADDY_CONTAINER" >/dev/null
  if caddy_wait_cert "$d"; then
    say "Сертификат $d перевыпущен."
    return 0
  fi
  caddy_failure_hints "$d"
  return 1
}

caddy_failure_hints() {
  local d="${1:-}" m=""
  if [[ -n "$d" ]] && caddy_has_domain "$d"; then
    m="${CADDY_METHODS[$CADDY_IDX]}"
  fi
  warn "Caddy не получил сертификат${d:+ для $d}. Последние строки логов $CADDY_CONTAINER:"
  docker logs --tail 40 "$CADDY_CONTAINER" 2>&1 || true
  say ""
  say "Проверьте:"
  if [[ "$m" == "cf" ]]; then
    say "  • у токена Cloudflare есть права Zone → Zone → Read и Zone → DNS → Edit для зоны домена;"
    say "  • домен действительно обслуживается этим аккаунтом Cloudflare (NS-записи у Cloudflare);"
  else
    say "  • A-запись домена указывает на IP этого сервера (Cloudflare — серое облако; иначе используйте способ cf);"
    say "  • порт 80/tcp открыт снаружи (фаервол: ufw allow 80/tcp, security group у провайдера);"
  fi
  say "  • лимиты Let's Encrypt (много попыток подряд для одного домена)."
}

print_cert_json() {
  local d="$1"
  say ""
  say "Блок для профиля Xray (inbound → tlsSettings) на панели, домен $d:"
  cat <<EOF
"certificates": [
  {
    "certificateFile": "${CERTS_MOUNT_CONTAINER}/${d}/${d}.crt",
    "keyFile": "${CERTS_MOUNT_CONTAINER}/${d}/${d}.key"
  }
]
EOF
}

caddy_status_line() {
  if ! caddy_installed; then
    if is_legacy_hy2_layout; then
      echo "внутри $HY2_DIR_NAME (старая раскладка, нужен перенос)"
    else
      echo "не установлен"
    fi
    return
  fi
  local st
  if command -v docker >/dev/null 2>&1; then
    st="$(container_state "$CADDY_CONTAINER")"
  else
    st="docker не найден"
  fi
  load_caddy_domains
  caddy_compute_needs
  echo "${st} · доменов: ${#CADDY_DOMAINS[@]} · сайтов: ${CADDY_SITE_COUNT}"
}

# Установка старой версии скрипта (без .env, способов у доменов, сайтов) → новый формат.
caddy_needs_upgrade() {
  caddy_installed && ! caddy_compose_is_current "$(caddy_compose)"
}

caddy_upgrade_format() {
  caddy_needs_upgrade || return 0
  require_docker
  local dir email
  dir="$(caddy_dir)"
  say "Обновляю конфигурацию Caddy до новой версии скрипта:"
  say "  .env (email, токены Cloudflare), способ выдачи у каждого домена, каталог www/, образ ${CADDY_IMAGE}."
  email="$(caddy_email)"
  caddy_ensure_env
  if [[ -z "$(caddy_env_get ACME_EMAIL)" && -n "$email" ]]; then
    caddy_env_set ACME_EMAIL "$email"
  fi
  load_caddy_domains
  save_caddy_domains
  backup_file "$(caddy_compose)"
  caddy_write_all
  dc "$dir" config >/dev/null || die "docker compose config: ошибка в $(caddy_compose)"
  ensure_container_name_free "$CADDY_CONTAINER" "$dir"
  dc "$dir" up -d --force-recreate
  say "Готово: сертификаты и домены сохранены."
}

require_caddy() {
  ensure_new_hy2_layout
  caddy_installed || die "Caddy не установлен. Сначала: $SCRIPT_NAME caddy setup"
  caddy_upgrade_format
}

# =============================================================================
# Cloudflare API (токены)
# =============================================================================
CF_API="https://api.cloudflare.com/client/v4"

cf_token_ids() {
  local f
  f="$(caddy_env_file)"
  [[ -f "$f" ]] || return 0
  grep -oE '^CF_API_TOKEN_[0-9]+=' "$f" 2>/dev/null | sed -E 's/^CF_API_TOKEN_([0-9]+)=$/\1/' | sort -n || true
}

cf_next_id() {
  local max=0 i
  for i in $(cf_token_ids); do
    if ((i > max)); then max=$i; fi
  done
  echo $((max + 1))
}

cf_mask() {
  local t="$1"
  if ((${#t} > 10)); then
    printf '%s…%s' "${t:0:4}" "${t: -4}"
  else
    printf '***'
  fi
}

cf_require_curl() {
  command -v curl >/dev/null 2>&1 || die "Для работы с Cloudflare API нужен curl (apt install curl)."
}

cf_get() {
  local tok="$1" path="$2"
  curl -fsS --max-time 15 -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" "${CF_API}${path}" 2>/dev/null
}

# Токен рабочий (видит хотя бы список зон).
cf_token_valid() {
  local resp
  resp="$(cf_get "$1" "/zones?per_page=1")" || return 1
  grep -q '"success":[[:space:]]*true' <<<"$resp"
}

# Зона домена, доступная токену (example.com для a.b.example.com) → stdout. return 1 — нет доступа.
cf_zone_for() {
  local tok="$1" cand="$2" resp
  while [[ "$cand" == *.* ]]; do
    resp="$(cf_get "$tok" "/zones?name=${cand}")" || return 1
    if grep -qE "\"name\":[[:space:]]*\"${cand//./\\.}\"" <<<"$resp"; then
      echo "$cand"
      return 0
    fi
    cand="${cand#*.}"
  done
  return 1
}

cf_token_domains() {
  local id="$1" i out=""
  load_caddy_domains
  for ((i = 0; i < ${#CADDY_DOMAINS[@]}; i++)); do
    if [[ "${CADDY_METHODS[i]}" == "cf" && "${CADDY_TOKENS[i]}" == "$id" ]]; then
      out="$out ${CADDY_DOMAINS[i]}"
    fi
  done
  trim "$out"
}

# Ввести новый токен. $1 — домен, к зоне которого нужен доступ (необязательно). Результат: CF_PICKED.
cf_ask_new_token() {
  local d="${1:-}" t zone id
  CF_PICKED=""
  cf_require_curl
  caddy_ensure_env
  say "Нужен API-токен Cloudflare: https://dash.cloudflare.com/profile/api-tokens → Create Token → Custom token."
  say "  Права: Zone → Zone → Read и Zone → DNS → Edit; Zone Resources — нужные зоны (или All zones)."
  while true; do
    t=""
    read -r -s -p "API-токен Cloudflare (ввод скрыт; Enter — отмена): " t || true
    echo >&2
    t="$(trim "$t")"
    [[ -n "$t" ]] || return 1
    if [[ ! "$t" =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
      warn "токен выглядит некорректно."
      continue
    fi
    for id in $(cf_token_ids); do
      if [[ "$(caddy_env_get "CF_API_TOKEN_$id")" == "$t" ]]; then
        warn "этот токен уже сохранён как #$id."
        if [[ -z "$d" ]] || cf_zone_for "$t" "$d" >/dev/null; then
          CF_PICKED="$id"
          return 0
        fi
        continue 2
      fi
    done
    if [[ -n "$d" ]]; then
      if ! zone="$(cf_zone_for "$t" "$d")"; then
        warn "токен не видит зону домена $d (неверный токен, нет прав Zone → Read или зона в другом аккаунте)."
        continue
      fi
      say "Токен видит зону $zone."
    elif ! cf_token_valid "$t"; then
      warn "Cloudflare отклонил токен."
      continue
    fi
    id="$(cf_next_id)"
    caddy_env_set "CF_API_TOKEN_$id" "$t"
    CADDY_ENV_CHANGED=1
    CF_PICKED="$id"
    say "Токен сохранён как #$id в $(caddy_env_file)."
    return 0
  done
}

# Подобрать токен для домена: сначала из сохранённых (по доступу к зоне), иначе спросить новый.
cf_pick_token() {
  local d="$1" id tok zone
  CF_PICKED=""
  cf_require_curl
  for id in $(cf_token_ids); do
    tok="$(caddy_env_get "CF_API_TOKEN_$id")"
    [[ -n "$tok" ]] || continue
    if zone="$(cf_zone_for "$tok" "$d")"; then
      say "Cloudflare: для $d используется сохранённый токен #$id (зона $zone)."
      CF_PICKED="$id"
      return 0
    fi
  done
  if [[ -n "$(cf_token_ids)" ]]; then
    say "Ни один сохранённый токен Cloudflare не видит зону домена $d — нужен ещё один."
  fi
  cf_ask_new_token "$d"
}

caddy_tokens_show() {
  require_caddy
  local id tok doms
  if [[ -z "$(cf_token_ids)" ]]; then
    say "Токенов Cloudflare нет. Они запрашиваются автоматически при выборе способа cf для домена."
    return 0
  fi
  say "Токены Cloudflare ($(caddy_env_file)):"
  for id in $(cf_token_ids); do
    tok="$(caddy_env_get "CF_API_TOKEN_$id")"
    doms="$(cf_token_domains "$id")"
    printf ' #%s  %s — домены: %s\n' "$id" "$(cf_mask "$tok")" "${doms:-нет}" >&2
  done
}

caddy_token_add() {
  require_caddy
  if cf_ask_new_token ""; then
    say "Токен #$CF_PICKED будет подбираться автоматически для доменов своих зон."
  else
    say "Отмена."
  fi
}

caddy_token_check() {
  require_caddy
  cf_require_curl
  local id tok d i
  if [[ -z "$(cf_token_ids)" ]]; then
    say "Токенов Cloudflare нет."
    return 0
  fi
  load_caddy_domains
  for id in $(cf_token_ids); do
    tok="$(caddy_env_get "CF_API_TOKEN_$id")"
    if cf_token_valid "$tok"; then
      say "#$id $(cf_mask "$tok"): OK"
    else
      warn "#$id $(cf_mask "$tok"): Cloudflare отклонил токен (отозван или истёк)."
      continue
    fi
    for ((i = 0; i < ${#CADDY_DOMAINS[@]}; i++)); do
      d="${CADDY_DOMAINS[i]}"
      if [[ "${CADDY_METHODS[i]}" == "cf" && "${CADDY_TOKENS[i]}" == "$id" ]]; then
        if cf_zone_for "$tok" "$d" >/dev/null; then
          say "    $d: зона доступна"
        else
          warn "    $d: токен #$id не видит зону этого домена."
        fi
      fi
    done
  done
}

caddy_token_remove() {
  require_caddy
  local id="${1:-}" doms
  caddy_tokens_show
  [[ -n "$(cf_token_ids)" ]] || return 0
  if [[ -z "$id" ]]; then
    id="$(ask_value "Номер токена для удаления (Enter — отмена)" "")"
    id="${id#\#}"
    [[ -n "$id" ]] || {
      say "Отмена."
      return 0
    }
  fi
  [[ -n "$(caddy_env_get "CF_API_TOKEN_$id")" ]] || die "Нет токена #$id."
  doms="$(cf_token_domains "$id")"
  if [[ -n "$doms" ]]; then
    die "Токен #$id используется доменами: $doms. Сначала смените им способ (caddy method) или удалите их."
  fi
  prompt_yes_no "Удалить токен #$id?" y || {
    say "Отмена."
    return 0
  }
  caddy_env_del "CF_API_TOKEN_$id"
  say "Токен #$id удалён из $(caddy_env_file)."
}

# =============================================================================
# Монтирование сертификатов Caddy в ноды
# =============================================================================

# Путь к сертификатам для тома ноды: относительный, если нода и caddy — соседние каталоги.
cert_mount_spec_for() {
  local node_dir="$1" nabs cabs cdir host
  cdir="$(caddy_dir)"
  [[ -d "$node_dir" ]] || die "Нет каталога $node_dir"
  [[ -d "$cdir" ]] || die "Нет каталога $cdir"
  nabs="$(cd "$node_dir" && pwd -P)"
  cabs="$(cd "$cdir" && pwd -P)"
  if [[ "$(dirname "$nabs")" == "$(dirname "$cabs")" ]]; then
    host="../$(basename "$cabs")"
  elif [[ "$nabs" == "$(dirname "$cabs")" ]]; then
    host="./$(basename "$cabs")"
  else
    host="$cabs"
  fi
  echo "${host}/data/caddy/certificates/$(acme_ca_dir_name):${CERTS_MOUNT_CONTAINER}:ro"
}

compose_has_our_cert_mount() {
  local spec
  spec="$(compose_cert_mount_spec "$1")"
  [[ -n "$spec" && "$spec" == *caddy/certificates* ]]
}

# $2: 1 — подключить, 0 — убрать. $3: 1 — перезапустить работающую ноду (по умолчанию).
sync_kind_cert_mount() {
  local kind="$1" want="$2" restart="${3:-1}" file dir cname cur desired
  kind_installed "$kind" || return 0
  if [[ "$kind" == "hy2" ]] && is_legacy_hy2_layout; then
    return 0
  fi
  dir="$(kind_dir "$kind")"
  file="$(kind_compose "$kind")"
  cname="$(kind_container "$kind")"
  cur="$(compose_cert_mount_spec "$file")"

  if [[ "$want" == "1" ]]; then
    desired="$(cert_mount_spec_for "$dir")"
    if [[ "$cur" == "$desired" ]]; then
      say "$(kind_title "$kind"): сертификаты Caddy уже смонтированы в ${CERTS_MOUNT_CONTAINER}."
      return 0
    fi
    if [[ -n "$cur" && "$cur" != *caddy/certificates* ]]; then
      warn "в $file уже есть свой том на ${CERTS_MOUNT_CONTAINER} ($cur) — не трогаю."
      return 0
    fi
    backup_file "$file"
    if [[ -n "$cur" ]]; then
      compose_remove_cert_mount "$file"
    fi
    compose_add_volume "$file" "$cname" "$desired"
    say "$(kind_title "$kind"): подключены сертификаты Caddy → ${CERTS_MOUNT_CONTAINER} (${desired%%:*})"
  else
    if [[ -z "$cur" || "$cur" != *caddy/certificates* ]]; then
      return 0
    fi
    backup_file "$file"
    compose_remove_cert_mount "$file"
    say "$(kind_title "$kind"): монтирование сертификатов Caddy убрано."
  fi

  if [[ "$restart" == "1" ]] && container_running "$cname"; then
    say "Перезапуск $cname с новой конфигурацией томов…"
    dc "$dir" up -d
  fi
}

# Привести монтирование /certs в обеих нодах в соответствие с тем, установлен ли Caddy.
sync_cert_mounts() {
  local want=0 kind
  caddy_installed && want=1
  for kind in node hy2; do
    soft_step "не удалось обновить монтирование сертификатов: $(kind_title "$kind")" sync_kind_cert_mount "$kind" "$want"
  done
}

action_kind_certs() {
  local kind="$1"
  require_installed "$kind"
  if caddy_installed; then
    sync_kind_cert_mount "$kind" 1
    say "Сертификаты в ноде: ${CERTS_MOUNT_CONTAINER}/<домен>/<домен>.crt и .key"
  else
    say "Caddy не установлен — подключать нечего (монтирование убирается, если было)."
    sync_kind_cert_mount "$kind" 0
  fi
}

action_sync_mounts() {
  require_caddy
  require_docker
  sync_cert_mounts
}

# =============================================================================

# =============================================================================
# Caddy: установка, домены, управление
# =============================================================================

# Спросить способ (и токен для cf) для нового домена. Результат: NEW_METHOD, NEW_TOKEN.
# $2 — способ, заданный заранее (CLI). return 1 — отмена.
caddy_ask_domain_method() {
  local d="$1" m="${2:-}"
  NEW_METHOD=""
  NEW_TOKEN="-"
  if [[ -n "$m" ]]; then
    valid_method "$m" || die "Способ должен быть http, alpn или cf."
  else
    m="$(ask_method "$(caddy_default_method)")"
  fi
  if [[ "$m" == "cf" ]]; then
    cf_pick_token "$d" || return 1
    NEW_TOKEN="$CF_PICKED"
    say "Для способа cf A-запись может указывать куда угодно (в т.ч. на прокси Cloudflare)."
  else
    check_domain_dns "$d" || return 1
  fi
  NEW_METHOD="$m"
}

caddy_install() {
  local need_domain="${1:-}"
  require_docker
  ensure_new_hy2_layout
  local dir compose d email def_email
  dir="$(caddy_dir)"
  compose="$(caddy_compose)"

  if caddy_installed; then
    if [[ -n "$need_domain" ]]; then
      caddy_upgrade_format
      return 0
    fi
    prompt_yes_no "Caddy уже установлен в $dir. Пересоздать конфигурацию? Домены, токены, сайты и сертификаты сохранятся." n || {
      say "Отмена."
      return 0
    }
  fi

  mkdir -p "$dir/data" "$dir/config" "$dir/www" || die "Не удалось создать $dir"
  caddy_ensure_env

  say ""
  say "=== Caddy: домены ==="
  load_caddy_domains
  if ((${#CADDY_DOMAINS[@]})); then
    say "Домены из domains.list: ${CADDY_DOMAINS[*]}"
  fi
  while true; do
    load_caddy_domains
    if [[ -n "$need_domain" && ${#CADDY_DOMAINS[@]} -eq 0 ]]; then
      d="$(ask_domain "")"
    else
      d="$(ask_value "Добавить домен (Enter — продолжить)" "")"
      [[ -z "$d" ]] && break
      d="$(normalize_domain "$d")"
      if ! valid_domain "$d"; then
        warn "некорректный домен «$d»."
        continue
      fi
    fi
    if caddy_has_domain "$d"; then
      warn "домен $d уже в списке."
      continue
    fi
    if ! caddy_ask_domain_method "$d"; then
      warn "домен $d пропущен."
      continue
    fi
    load_caddy_domains
    caddy_append_domain "$d" "$NEW_METHOD" "$NEW_TOKEN" "-"
    save_caddy_domains
  done

  say ""
  say "=== Caddy: email для Let's Encrypt ==="
  load_caddy_domains
  def_email="$(caddy_email)"
  if [[ -z "$def_email" && ${#CADDY_DOMAINS[@]} -gt 0 ]]; then
    def_email="${DEFAULT_ACME_EMAIL_PREFIX}@${CADDY_DOMAINS[0]}"
  fi
  email="$(ask_email "$def_email")"
  caddy_env_set ACME_EMAIL "$email"

  load_caddy_domains
  caddy_compute_needs
  caddy_ports_ok || die "Нужные Caddy порты заняты — установка остановлена."
  backup_file "$compose"
  caddy_write_all
  rm -f "$compose.removed"
  mkdir -p "$(caddy_cert_root)" 2>/dev/null || run_as_root mkdir -p "$(caddy_cert_root)" || true
  say "Записаны $dir/{docker-compose.yml,Caddyfile,domains.list,.env}."

  fw_caddy_on_install

  dc "$dir" config >/dev/null || die "docker compose config: проверьте синтаксис YAML ($compose)."
  ensure_container_name_free "$CADDY_CONTAINER" "$dir"
  say "Запуск Caddy (образ $CADDY_IMAGE)…"
  dc "$dir" up -d --force-recreate
  CADDY_ENV_CHANGED=0

  local failed=0 doms=()
  load_caddy_domains
  doms=(${CADDY_DOMAINS[@]+"${CADDY_DOMAINS[@]}"})
  for d in ${doms[@]+"${doms[@]}"}; do
    if ! caddy_wait_cert "$d"; then
      warn "сертификат для $d пока не получен."
      failed=1
    fi
  done
  if ((failed)); then
    caddy_failure_hints
  fi

  say ""
  say "=== Монтирование сертификатов в ноды ==="
  sync_cert_mounts

  for d in ${doms[@]+"${doms[@]}"}; do
    if caddy_cert_exists "$d"; then
      print_cert_json "$d"
    fi
  done
  say ""
  say "Caddy установлен. Домены, способы выдачи, сайты и токены — меню «Caddy» или «$SCRIPT_NAME caddy»."
}

caddy_uninstall() {
  require_caddy
  require_docker
  local dir compose
  dir="$(caddy_dir)"
  compose="$(caddy_compose)"
  if kind_installed hy2; then
    warn "нода Hysteria2 использует сертификаты Caddy (домен: $(hy2_domain))."
    say "  После удаления Caddy монтирование ${CERTS_MOUNT_CONTAINER} будет убрано из её compose — inbound Hysteria2 с сертификатом не запустится."
  fi
  prompt_yes_no "Удалить Caddy (контейнер $CADDY_CONTAINER, сайты перестанут открываться)?" n || {
    say "Отмена."
    return 0
  }
  dc "$dir" down || warn "не удалось остановить Caddy (продолжаю)."

  if prompt_yes_no "Удалить и каталог $dir (сертификаты, сайты, токены)? Нет — всё сохранится для повторной установки." "$DEFAULT_CADDY_UNINSTALL_DELETE_DATA"; then
    run_as_root rm -rf "$dir"
    say "Удалён $dir"
  else
    mv -f "$compose" "$compose.removed"
    say "Данные сохранены в $dir (compose переименован в docker-compose.yml.removed)."
  fi

  say ""
  say "=== Монтирование сертификатов в нодах ==="
  sync_cert_mounts

  if [[ "$FIREWALL_ON_INSTALL" == "1" ]] && is_linux && [[ "$(fw_backend)" != "none" ]]; then
    if prompt_yes_no "Закрыть в фаерволе 80/tcp (открывался для Caddy)?" y; then
      soft_step "не удалось удалить правило 80/tcp." fw_delete_port_quiet 80
      say "  закрыт: 80/tcp"
    fi
    if prompt_yes_no "Закрыть и 443/tcp? (Нет, если 443 нужен VLESS Reality)" n; then
      soft_step "не удалось удалить правило 443/tcp." fw_delete_port_quiet 443
      say "  закрыт: 443/tcp"
    fi
    soft_step "не удалось перезагрузить правила фаервола." fw_reload
  fi
  say "Caddy удалён."
}

caddy_show_domains() {
  require_caddy
  local i d n hy2d info end
  load_caddy_domains
  n=${#CADDY_DOMAINS[@]}
  say "Caddy: $(caddy_status_line)"
  say "Образ: $CADDY_IMAGE · email: $(caddy_email)"
  say "Сертификаты на хосте: $(caddy_cert_root) → в нодах: ${CERTS_MOUNT_CONTAINER}/<домен>/"
  if ((n == 0)); then
    say "Доменов нет. Добавить: $SCRIPT_NAME caddy add <домен>"
    return 0
  fi
  hy2d="$(hy2_domain)"
  load_caddy_domains
  for ((i = 0; i < n; i++)); do
    d="${CADDY_DOMAINS[i]}"
    if caddy_cert_exists "$d"; then
      end="$(caddy_cert_enddate "$d")"
      info="сертификат до ${end:-?}"
    else
      info="сертификата нет"
    fi
    if [[ -n "$hy2d" && "$d" == "$hy2d" ]]; then
      info="$info · нода Hysteria2"
    fi
    printf ' %2d) %s — %s — %s\n' "$((i + 1))" "$d" "$(caddy_domain_info_short "$i")" "$info" >&2
  done
}

# Добавить домен. Результат — в CADDY_LAST_DOMAIN. return 1 — сертификат не получен / отмена.
caddy_add_domain_flow() {
  local d="${1:-}" m="${2:-}"
  CADDY_LAST_DOMAIN=""
  require_caddy
  require_docker
  if [[ -n "$d" ]]; then
    d="$(normalize_domain "$d")"
    valid_domain "$d" || die "Некорректный домен «$d»."
  else
    d="$(ask_domain "")"
  fi
  if caddy_has_domain "$d"; then
    say "Домен $d уже есть в Caddy ($(caddy_domain_info_short "$CADDY_IDX"))."
    caddy_ensure_running
    if caddy_wait_cert "$d"; then
      CADDY_LAST_DOMAIN="$d"
      return 0
    fi
    caddy_failure_hints "$d"
    return 1
  fi
  if ! caddy_ask_domain_method "$d" "$m"; then
    say "Отмена."
    return 1
  fi
  caddy_snapshot
  load_caddy_domains
  caddy_append_domain "$d" "$NEW_METHOD" "$NEW_TOKEN" "-"
  save_caddy_domains
  if ! caddy_commit; then
    caddy_restore_snapshot
    die "Домен $d не добавлен: нужные порты заняты."
  fi
  caddy_drop_snapshot
  if caddy_wait_cert "$d"; then
    CADDY_LAST_DOMAIN="$d"
    print_cert_json "$d"
    return 0
  fi
  caddy_failure_hints "$d"
  if prompt_yes_no "Убрать $d из Caddy (иначе он будет повторять попытки и может упереться в лимиты Let's Encrypt)?" "$DEFAULT_REMOVE_DOMAIN_ON_FAIL"; then
    caddy_remove_from_list "$d"
    caddy_commit || true
    say "Домен $d убран из Caddy."
  fi
  return 1
}

caddy_remove_domain_flow() {
  local d="${1:-}" hy2d cert_dir def_del site
  require_caddy
  require_docker
  if [[ -z "$d" ]]; then
    caddy_pick_domain all "Номер домена для удаления" || {
      say "Отмена."
      return 0
    }
    d="$CADDY_PICKED"
  else
    d="$(normalize_domain "$d")"
  fi
  caddy_has_domain "$d" || die "Домена $d нет в Caddy."
  site="${CADDY_SITES[$CADDY_IDX]}"

  def_del="$DEFAULT_DELETE_OLD_CERT"
  hy2d="$(hy2_domain)"
  if [[ -n "$hy2d" && "$d" == "$hy2d" ]]; then
    warn "домен $d используется нодой Hysteria2 — после удаления сертификат перестанет продлеваться."
    say "  Сначала выберите для неё другой домен: $SCRIPT_NAME hy2 domain"
    prompt_yes_no "Всё равно удалить $d из Caddy?" n || {
      say "Отмена."
      return 0
    }
    def_del=n
  else
    local site_note=""
    if [[ "$site" != "-" ]]; then site_note=" (сайт: $site)"; fi
    prompt_yes_no "Удалить домен $d из Caddy${site_note}?" y || {
      say "Отмена."
      return 0
    }
  fi

  caddy_remove_from_list "$d"
  caddy_commit || warn "не удалось применить конфигурацию Caddy."

  cert_dir="$(caddy_cert_root)/$d"
  if run_as_root test -d "$cert_dir" 2>/dev/null; then
    if prompt_yes_no "Удалить файлы сертификата $d? (сначала уберите пути к нему из профилей Xray на панели — иначе Xray не запустится)" "$def_del"; then
      run_as_root rm -rf "$cert_dir"
      say "Удалён $cert_dir"
    fi
  fi
  if [[ -d "$(caddy_www_dir)/$d" ]]; then
    if prompt_yes_no "Удалить файлы сайта $(caddy_www_dir)/$d?" "$DEFAULT_DELETE_SITE_FILES"; then
      site_rm_files "$d"
    fi
  fi
  say "Домен $d удалён из Caddy."
}

# Сменить способ выдачи сертификата для домена.
caddy_change_method() {
  local d="${1:-}" new="${2:-}" cur curt t
  require_caddy
  require_docker
  if [[ -z "$d" ]]; then
    caddy_pick_domain all "Домен, для которого сменить способ" || {
      say "Отмена."
      return 0
    }
    d="$CADDY_PICKED"
  else
    d="$(normalize_domain "$d")"
  fi
  caddy_has_domain "$d" || die "Домена $d нет в Caddy."
  cur="${CADDY_METHODS[$CADDY_IDX]}"
  curt="${CADDY_TOKENS[$CADDY_IDX]}"
  say "Текущий способ для $d: $(method_desc "$cur")$([[ "$cur" == "cf" ]] && echo " (токен #$curt)")"
  if [[ -n "$new" ]]; then
    valid_method "$new" || die "Способ должен быть http, alpn или cf."
  else
    new="$(ask_method "$cur")"
  fi
  t="-"
  if [[ "$new" == "cf" ]]; then
    cf_pick_token "$d" || {
      say "Отмена."
      return 0
    }
    t="$CF_PICKED"
  elif [[ "$cur" == "cf" ]]; then
    check_domain_dns "$d" || {
      say "Отмена."
      return 0
    }
  fi
  if [[ "$new" == "$cur" && "$t" == "$curt" ]]; then
    say "Способ не изменился."
    return 0
  fi

  caddy_snapshot
  load_caddy_domains
  caddy_find "$d"
  CADDY_METHODS[CADDY_IDX]="$new"
  CADDY_TOKENS[CADDY_IDX]="$t"
  save_caddy_domains
  if ! caddy_commit; then
    caddy_restore_snapshot
    die "Способ не изменён: нужные порты заняты."
  fi
  caddy_drop_snapshot
  say "Способ для $d: $(method_desc "$new")."

  if caddy_cert_exists "$d"; then
    say "Действующий сертификат остаётся до продления — тогда Caddy использует новый способ."
    if prompt_yes_no "Перевыпустить сертификат сейчас, чтобы проверить новый способ?" n; then
      caddy_reissue "$d" || return 1
    fi
  elif ! caddy_wait_cert "$d"; then
    caddy_failure_hints "$d"
    return 1
  fi
}

caddy_cert_status() {
  require_caddy
  local d crt doms=()
  caddy_show_domains
  if command -v docker >/dev/null 2>&1; then
    say "Контейнер $CADDY_CONTAINER: $(container_state "$CADDY_CONTAINER")"
  fi
  load_caddy_domains
  doms=(${CADDY_DOMAINS[@]+"${CADDY_DOMAINS[@]}"})
  for d in ${doms[@]+"${doms[@]}"}; do
    crt="$(caddy_cert_file "$d")"
    say ""
    say "=== $d ==="
    if ! run_as_root test -f "$crt" 2>/dev/null; then
      warn "файл сертификата не найден: $crt"
      continue
    fi
    say "Файл: $crt"
    if command -v openssl >/dev/null 2>&1; then
      run_as_root openssl x509 -in "$crt" -noout -subject -issuer -enddate || true
      if run_as_root openssl x509 -in "$crt" -noout -checkend $((30 * 24 * 3600)) >/dev/null 2>&1; then
        say "Срок действия: больше 30 дней (Caddy продлевает автоматически)."
      else
        warn "сертификат истекает менее чем через 30 дней — проверьте логи Caddy."
      fi
    else
      say "openssl не установлен — срок действия не показан."
    fi
    print_cert_json "$d"
  done
}

caddy_change_email() {
  require_caddy
  require_docker
  local old email
  old="$(caddy_email)"
  say "Текущий email: ${old:-не задан}"
  email="$(ask_email "$old")"
  if [[ "$email" == "$old" ]]; then
    say "Email не изменился."
    return 0
  fi
  caddy_env_set ACME_EMAIL "$email"
  CADDY_ENV_CHANGED=1
  caddy_commit force || die "Не удалось применить конфигурацию."
  say "Email обновлён: $email"
}

caddy_start() {
  require_caddy
  require_docker
  ensure_container_name_free "$CADDY_CONTAINER" "$(caddy_dir)"
  dc "$(caddy_dir)" up -d
}

caddy_stop() {
  require_caddy
  require_docker
  say "Пока Caddy остановлен, сертификаты не продлеваются и сайты не открываются (ноды продолжают работать)."
  dc "$(caddy_dir)" down
}

caddy_logs() {
  require_caddy
  require_docker
  follow_logs "$(caddy_dir)"
}

caddy_update() {
  require_caddy
  require_docker
  local dir
  dir="$(caddy_dir)"
  say "Скачиваю новый образ Caddy ($CADDY_IMAGE)…"
  dc "$dir" pull
  dc "$dir" up -d
  if prompt_yes_no "Удалить старые неиспользуемые образы (docker image prune -f)?" "$DEFAULT_PRUNE_IMAGES"; then
    docker image prune -f
  fi
  say "Обновление Caddy завершено."
}

# =============================================================================
# Caddy: сайты (статические, из репозитория или своя папка)
# =============================================================================

# Скачать архив репозитория и выбрать сайт из $SITES_PATH. $1 — имя по умолчанию.
# Результат: SITE_SRC_DIR, SITE_NAME, SITE_TMP (временный каталог — удалить после копирования).
site_fetch_repo() {
  local cur="${1:-}" url tmp root base x i n choice def=1
  local names=()
  SITE_SRC_DIR=""
  SITE_NAME=""
  SITE_TMP=""
  url="https://codeload.github.com/${SITES_REPO}/tar.gz/refs/heads/${SITES_BRANCH}"
  tmp="$(mktemp -d)" || die "mktemp не сработал"
  say "Скачиваю ${SITES_REPO} (ветка ${SITES_BRANCH})…"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 120 "$url" -o "$tmp/repo.tgz" || {
      rm -rf "$tmp"
      die "Не удалось скачать $url"
    }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp/repo.tgz" -T 120 "$url" || {
      rm -rf "$tmp"
      die "Не удалось скачать $url"
    }
  else
    rm -rf "$tmp"
    die "Нужен curl или wget."
  fi
  tar -xzf "$tmp/repo.tgz" -C "$tmp" || {
    rm -rf "$tmp"
    die "Не удалось распаковать архив репозитория."
  }
  root="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  base="$root/$SITES_PATH"
  if [[ -z "$root" || ! -d "$base" ]]; then
    rm -rf "$tmp"
    die "В репозитории нет папки $SITES_PATH/."
  fi
  for x in "$base"/*/; do
    [[ -d "$x" ]] || continue
    x="${x%/}"
    names+=("$(basename "$x")")
  done
  n=${#names[@]}
  if ((n == 0)); then
    rm -rf "$tmp"
    die "В $SITES_REPO/$SITES_PATH/ нет папок с сайтами."
  fi
  say "Сайты в репозитории:"
  for ((i = 0; i < n; i++)); do
    if [[ "${names[i]}" == "$cur" ]]; then
      def=$((i + 1))
      say "  $((i + 1))) ${names[i]} (текущий)"
    else
      say "  $((i + 1))) ${names[i]}"
    fi
  done
  while true; do
    choice="$(ask_value "Сайт (номер, 0 — отмена)" "$def")"
    if [[ "$choice" == "0" ]]; then
      rm -rf "$tmp"
      return 1
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then
      break
    fi
    warn "введите номер из списка."
  done
  SITE_NAME="${names[$((choice - 1))]}"
  SITE_SRC_DIR="$base/$SITE_NAME"
  SITE_TMP="$tmp"
  if [[ ! -f "$SITE_SRC_DIR/index.html" ]]; then
    warn "в папке $SITE_NAME нет index.html в корне."
    if ! prompt_yes_no "Всё равно использовать?" n; then
      rm -rf "$tmp"
      SITE_TMP=""
      return 1
    fi
  fi
}

# Спросить путь к своей папке сайта. Результат: SITE_SRC_DIR.
site_ask_own_dir() {
  local p
  SITE_SRC_DIR=""
  while true; do
    p="$(ask_value "Путь к папке сайта на сервере (Enter — отмена)" "")"
    [[ -n "$p" ]] || return 1
    p="${p/#\~/$HOME}"
    if [[ ! -d "$p" ]]; then
      warn "нет папки $p"
      continue
    fi
    if [[ ! -f "$p/index.html" ]]; then
      warn "в $p нет index.html."
      prompt_yes_no "Всё равно использовать?" n || continue
    fi
    SITE_SRC_DIR="$(cd "$p" && pwd -P)"
    return 0
  done
}

# Скопировать файлы сайта в caddy/www/<домен>/ (прежняя версия — в www-backup/).
site_install_files() {
  local d="$1" src="$2" www dest bak
  www="$(caddy_www_dir)"
  dest="$www/$d"
  mkdir -p "$www" || die "Не удалось создать $www"
  if [[ -d "$dest" && "$(cd "$src" && pwd -P)" == "$(cd "$dest" && pwd -P)" ]]; then
    say "Файлы уже лежат в $dest."
    return 0
  fi
  if [[ -d "$dest" ]] && [[ -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
    bak="$(caddy_dir)/www-backup/$d.$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$(dirname "$bak")"
    mv "$dest" "$bak" 2>/dev/null || run_as_root mv "$dest" "$bak"
    say "Прежняя версия сайта: $bak"
  fi
  rm -rf "$dest" 2>/dev/null || true
  mkdir -p "$dest" || die "Не удалось создать $dest"
  cp -R "$src/." "$dest/" || die "Не удалось скопировать файлы сайта."
  find "$dest" -name .DS_Store -type f -delete 2>/dev/null || true
  chmod -R a+rX "$dest" 2>/dev/null || true
  say "Файлы сайта: $dest"
}

# --- Где открывается сайт: listen=443 | pub:ПОРТ | loc:ПОРТ ---
site_listen_valid() {
  local v="$1"
  [[ "$v" == "443" ]] && return 0
  [[ "$v" =~ ^(pub|loc):[0-9]+$ ]] && valid_port "${v#*:}"
}

site_listen_port() {
  case "$1" in
    pub:* | loc:*) echo "${1#*:}" ;;
    *) echo 443 ;;
  esac
}

site_listen_desc() {
  case "$1" in
    pub:*) echo "порт ${1#pub:}" ;;
    loc:*) echo "локально 127.0.0.1:${1#loc:}" ;;
    443) echo "порт 443" ;;
    *) echo "—" ;;
  esac
}

site_url() {
  local d="$1" l="$2"
  case "$l" in
    pub:*) echo "https://$d:${l#pub:}/" ;;
    loc:*) echo "https://$d/ через VLESS Reality (Caddy: 127.0.0.1:${l#loc:})" ;;
    *) echo "https://$d/" ;;
  esac
}

# Почему порт нельзя использовать для сайта (пусто — можно). $1: pub|loc, $2: порт, $3: домен.
site_port_problem() {
  local kind="$1" p="$2" d="$3" i k other_spec
  if ! valid_port "$p"; then
    echo "некорректный порт «$p»"
    return
  fi
  if [[ "$p" == "80" || "$p" == "443" ]]; then
    echo "порты 80 и 443 здесь не подходят (для 443 выберите вариант 1)"
    return
  fi
  for k in node hy2; do
    if [[ "$(kind_port "$k")" == "$p" ]]; then
      echo "порт $p — NODE_PORT ($(kind_title "$k"))"
      return
    fi
  done
  load_caddy_domains
  for ((i = 0; i < ${#CADDY_DOMAINS[@]}; i++)); do
    [[ "${CADDY_DOMAINS[i]}" != "$d" ]] || continue
    other_spec="${CADDY_LISTENS[i]}"
    if [[ "$other_spec" == pub:"$p" && "$kind" == "loc" ]] || [[ "$other_spec" == loc:"$p" && "$kind" == "pub" ]]; then
      echo "порт $p уже использует сайт ${CADDY_DOMAINS[i]} ($(site_listen_desc "$other_spec")) — нельзя открыть его и публично, и локально"
      return
    fi
  done
  if tcp_port_busy "$p"; then
    if container_running "$CADDY_CONTAINER" && [[ " $(caddy_compose_specs | tr '\n' ' ') " == *":$p "* ]]; then
      return
    fi
    echo "порт $p уже занят на этом сервере"
  fi
}

# Спросить, где открывать сайт. $2 — текущее значение. Результат: SITE_LISTEN.
site_ask_listen() {
  local d="$1" cur="${2:-}" def choice kind p defp prob
  SITE_LISTEN=""
  case "$cur" in
    pub:*) def=2 ;;
    loc:*) def=3 ;;
    443) def=1 ;;
    *)
      def=1
      if tcp_port_busy 443 && ! { container_running "$CADDY_CONTAINER" && caddy_compose_publishes 443; }; then
        say "443/tcp на сервере уже занят (например, VLESS Reality) — по умолчанию предлагаю локальный режим."
        def=3
      fi
      ;;
  esac
  say "Где открывать сайт $d:"
  say "  1) 443 — https://$d/ (Caddy займёт 443/tcp; VLESS Reality на 443 тогда не поставить)"
  say "  2) свой публичный порт — https://$d:ПОРТ/ (работает рядом с Reality на 443)"
  say "  3) только локально 127.0.0.1:ПОРТ — для VLESS Reality selfsteal: Reality на 443 показывает этот сайт"
  while true; do
    choice="$(ask_value "Вариант (1/2/3)" "$def")"
    case "$choice" in
      1)
        SITE_LISTEN="443"
        return 0
        ;;
      2) kind=pub ;;
      3) kind=loc ;;
      *)
        warn "введите 1, 2 или 3."
        continue
        ;;
    esac
    if [[ "$cur" == "$kind":* ]]; then
      defp="${cur#*:}"
    elif [[ "$kind" == "pub" ]]; then
      defp="$DEFAULT_SITE_PUBLIC_PORT"
    else
      defp="$DEFAULT_SITE_LOCAL_PORT"
    fi
    while true; do
      p="$(ask_value "Порт" "$defp")"
      prob="$(site_port_problem "$kind" "$p" "$d")"
      if [[ -z "$prob" ]]; then
        SITE_LISTEN="$kind:$p"
        return 0
      fi
      warn "$prob"
    done
  done
}

print_reality_snippet() {
  local d="$1" p="$2"
  say ""
  say "Фрагмент для профиля Xray на панели (inbound VLESS Reality на 443/tcp) → streamSettings.realitySettings:"
  cat <<EOF2
  "realitySettings": {
    "show": false,
    "target": "127.0.0.1:${p}",
    "xver": 0,
    "serverNames": ["${d}"],
    "privateKey": "<ваш privateKey>",
    "shortIds": ["<ваш shortId>"]
  }
EOF2
  say "В старых версиях Xray поле \"target\" называется \"dest\". Клиенту: SNI = $d."
}

# Проверить, что сайт открывается (локально, с SNI домена).
site_verify() {
  local d="$1" l="${2:-443}" p code
  p="$(site_listen_port "$l")"
  if ! caddy_wait_cert "$d"; then
    caddy_failure_hints "$d"
    warn "сайт заработает, когда Caddy получит сертификат."
    return 0
  fi
  sleep 2
  if command -v curl >/dev/null 2>&1; then
    code="$(curl -sk --max-time 10 --resolve "$d:$p:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$d:$p/" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      say "Проверка: https://$d:$p/ через 127.0.0.1 отвечает 200 OK."
    else
      warn "проверка https://$d:$p/ через 127.0.0.1 вернула код «${code:-нет ответа}»."
    fi
  fi
  say "Адрес: $(site_url "$d" "$l")"
  if [[ "$l" == loc:* ]]; then
    print_reality_snippet "$d" "$p"
  fi
}

# Удалить файлы сайта caddy/www/<домен>/.
site_rm_files() {
  local d="$1" www
  www="$(caddy_www_dir)"
  [[ -n "$d" && -n "$www" ]] || return 0
  rm -rf "${www:?}/${d:?}" 2>/dev/null || run_as_root rm -rf "${www:?}/${d:?}"
  say "Файлы сайта удалены: $www/$d"
}

caddy_sites_show() {
  require_caddy
  local i n found=0
  load_caddy_domains
  n=${#CADDY_DOMAINS[@]}
  say "Сайты (файлы: $(caddy_www_dir)/<домен>/, репозиторий: $SITES_REPO/$SITES_PATH):"
  for ((i = 0; i < n; i++)); do
    if [[ "${CADDY_SITES[i]}" != "-" ]]; then
      printf '  %s — %s — %s\n' "${CADDY_DOMAINS[i]}" "${CADDY_SITES[i]}" "$(site_url "${CADDY_DOMAINS[i]}" "${CADDY_LISTENS[i]}")" >&2
      found=1
    fi
  done
  if ((found == 0)); then
    say "  сайтов нет. Добавить: $SCRIPT_NAME caddy site set"
  fi
}

# Добавить или изменить сайт на домене.
caddy_site_set() {
  local d="${1:-}" choice kind src cur="" listen tmp=""
  require_caddy
  require_docker
  if [[ -z "$d" ]]; then
    say "Домены Caddy:"
    caddy_pick_domain all "Домен для сайта" new || {
      say "Отмена."
      return 0
    }
    d="$CADDY_PICKED"
    if [[ "$d" == "__new__" ]]; then
      caddy_add_domain_flow || return 1
      d="$CADDY_LAST_DOMAIN"
    fi
  else
    d="$(normalize_domain "$d")"
    if ! caddy_has_domain "$d"; then
      prompt_yes_no "Домена $d нет в Caddy. Добавить?" y || {
        say "Отмена."
        return 0
      }
      caddy_add_domain_flow "$d" || return 1
    fi
  fi
  caddy_has_domain "$d" || die "Домена $d нет в Caddy."
  cur="${CADDY_SITES[$CADDY_IDX]}"
  listen="${CADDY_LISTENS[$CADDY_IDX]}"
  if [[ "$cur" == "-" ]]; then
    say "Сайт для $d: сейчас нет."
  else
    say "Сайт для $d: сейчас $cur, $(site_listen_desc "$listen") (порт меняется в «Сайты → Порт / доступ»)."
  fi
  say "  1) скачать из репозитория $SITES_REPO ($SITES_PATH/)"
  say "  2) свой сайт — указать папку на сервере"
  say "  0) отмена"
  choice="$(ask_value "Источник" "1")"
  case "$choice" in
    1)
      site_fetch_repo "${cur#repo:}" || {
        say "Отмена."
        return 0
      }
      src="$SITE_SRC_DIR"
      tmp="$SITE_TMP"
      kind="repo:$SITE_NAME"
      ;;
    2)
      site_ask_own_dir || {
        say "Отмена."
        return 0
      }
      src="$SITE_SRC_DIR"
      kind="own"
      ;;
    *)
      say "Отмена."
      return 0
      ;;
  esac

  if [[ "$cur" == "-" ]]; then
    site_ask_listen "$d" ""
    listen="$SITE_LISTEN"
  fi

  site_install_files "$d" "$src"
  if [[ -n "$tmp" ]]; then rm -rf "$tmp"; fi

  caddy_snapshot
  load_caddy_domains
  caddy_find "$d"
  CADDY_SITES[CADDY_IDX]="$kind"
  CADDY_LISTENS[CADDY_IDX]="$listen"
  save_caddy_domains
  if ! caddy_commit; then
    caddy_restore_snapshot
    die "Сайт не включён: нужные порты заняты (файлы оставлены в $(caddy_www_dir)/$d)."
  fi
  caddy_drop_snapshot
  say "Сайт на $d: $kind, $(site_listen_desc "$listen")"
  site_verify "$d" "$listen"
}

# Сменить, где открывается сайт: 443 / свой порт / локально (Reality selfsteal).
caddy_site_listen() {
  local d="${1:-}" new="${2:-}" old p still
  require_caddy
  require_docker
  if [[ -z "$d" ]]; then
    caddy_pick_domain site "Сайт, для которого сменить порт / доступ" || {
      say "Отмена."
      return 0
    }
    d="$CADDY_PICKED"
  else
    d="$(normalize_domain "$d")"
  fi
  caddy_has_domain "$d" || die "Домена $d нет в Caddy."
  [[ "${CADDY_SITES[$CADDY_IDX]}" != "-" ]] || die "На $d нет сайта — сначала: $SCRIPT_NAME caddy site set $d"
  old="${CADDY_LISTENS[$CADDY_IDX]}"
  say "Сейчас: $(site_url "$d" "$old")"
  if [[ -n "$new" ]]; then
    case "$new" in
      local:*) new="loc:${new#local:}" ;;
      public:*) new="pub:${new#public:}" ;;
    esac
    site_listen_valid "$new" || die "Ожидается 443, pub:ПОРТ или loc:ПОРТ."
    if [[ "$new" != "443" ]]; then
      p="$(site_port_problem "${new%%:*}" "${new#*:}" "$d")"
      [[ -z "$p" ]] || die "$p"
    fi
  else
    site_ask_listen "$d" "$old"
    new="$SITE_LISTEN"
  fi
  if [[ "$new" == "$old" ]]; then
    say "Ничего не изменилось."
    return 0
  fi
  caddy_snapshot
  load_caddy_domains
  caddy_find "$d"
  CADDY_LISTENS[CADDY_IDX]="$new"
  save_caddy_domains
  if ! caddy_commit; then
    caddy_restore_snapshot
    die "Не изменено: нужные порты заняты."
  fi
  caddy_drop_snapshot
  say "Сайт $d: $(site_listen_desc "$old") → $(site_listen_desc "$new")."

  # Старый публичный порт больше никому не нужен — предложить закрыть в фаерволе.
  if [[ "$old" == pub:* || ( "$old" == "443" && "$new" != "443" ) ]]; then
    p="$(site_listen_port "$old")"
    load_caddy_domains
    caddy_compute_needs
    still=0
    if [[ " $(caddy_publish_specs | tr '\n' ' ') " == *" $p:$p "* ]]; then still=1; fi
    if ((still == 0)) && [[ "$FIREWALL_ON_INSTALL" == "1" ]] && is_linux && [[ "$(fw_backend)" != "none" ]]; then
      if [[ "$p" == "443" ]]; then
        say "Caddy больше не занимает 443/tcp — его можно отдать VLESS Reality (правило в фаерволе оставлено)."
      elif prompt_yes_no "Закрыть в фаерволе старый порт сайта $p/tcp?" y; then
        soft_step "не удалось удалить правило $p/tcp." fw_delete_port_quiet "$p"
        soft_step "не удалось перезагрузить правила фаервола." fw_reload
        say "  закрыт: $p/tcp"
      fi
    fi
  fi
  site_verify "$d" "$new"
}

# Скачать заново сайт из репозитория (тот же или другой).
caddy_site_update() {
  local d="${1:-}" cur
  require_caddy
  if [[ -z "$d" ]]; then
    caddy_pick_domain repo "Сайт для обновления из репозитория" || {
      say "Отмена."
      return 0
    }
    d="$CADDY_PICKED"
  else
    d="$(normalize_domain "$d")"
  fi
  caddy_has_domain "$d" || die "Домена $d нет в Caddy."
  cur="${CADDY_SITES[$CADDY_IDX]}"
  [[ "$cur" == repo:* ]] || die "На $d нет сайта из репозитория (сейчас: $cur)."
  site_fetch_repo "${cur#repo:}" || {
    say "Отмена."
    return 0
  }
  site_install_files "$d" "$SITE_SRC_DIR"
  rm -rf "$SITE_TMP"
  if [[ "repo:$SITE_NAME" != "$cur" ]]; then
    load_caddy_domains
    caddy_find "$d"
    CADDY_SITES[CADDY_IDX]="repo:$SITE_NAME"
    save_caddy_domains
    caddy_write_caddyfile
  fi
  say "Сайт на $d обновлён (repo:$SITE_NAME). Caddy отдаёт новые файлы сразу."
}

caddy_site_remove() {
  local d="${1:-}"
  require_caddy
  require_docker
  if [[ -z "$d" ]]; then
    caddy_pick_domain site "Сайт для отключения" || {
      say "Отмена."
      return 0
    }
    d="$CADDY_PICKED"
  else
    d="$(normalize_domain "$d")"
  fi
  caddy_has_domain "$d" || die "Домена $d нет в Caddy."
  [[ "${CADDY_SITES[$CADDY_IDX]}" != "-" ]] || die "На $d нет сайта."
  prompt_yes_no "Отключить сайт на $d? Домен и сертификат останутся." y || {
    say "Отмена."
    return 0
  }
  CADDY_SITES[CADDY_IDX]="-"
  CADDY_LISTENS[CADDY_IDX]="-"
  save_caddy_domains
  caddy_commit || warn "не удалось применить конфигурацию Caddy."
  if [[ -d "$(caddy_www_dir)/$d" ]] && prompt_yes_no "Удалить файлы сайта $(caddy_www_dir)/$d?" "$DEFAULT_DELETE_SITE_FILES"; then
    site_rm_files "$d"
  fi
  say "Сайт на $d отключён."
}

# =============================================================================
# Hysteria2: домен ноды
# =============================================================================
hy2_domain() {
  local f m
  f="$(kind_compose hy2)"
  [[ -f "$f" ]] || return 0
  m="$(grep -m1 -E '^# HY2_DOMAIN=' "$f" 2>/dev/null | sed 's/^# HY2_DOMAIN=//' | tr -d '[:space:]' || true)"
  if [[ -z "$m" ]]; then
    m="$(compose_get_env DOMAIN "$f")"
  fi
  printf '%s' "$m"
}

# Выбрать домен для ноды Hysteria2 из доменов Caddy (или добавить новый). Результат — HY2_PICKED.
hy2_pick_domain() {
  local cur="${1:-}" i n choice def=1 d mark
  HY2_PICKED=""
  load_caddy_domains
  n=${#CADDY_DOMAINS[@]}
  if ((n == 0)); then
    say "В Caddy нет доменов — добавим новый."
    caddy_add_domain_flow || return 1
    HY2_PICKED="$CADDY_LAST_DOMAIN"
    return 0
  fi
  say "Домены Caddy:"
  for ((i = 0; i < n; i++)); do
    d="${CADDY_DOMAINS[i]}"
    mark=""
    if [[ -n "$cur" && "$d" == "$cur" ]]; then
      mark=" (текущий)"
      def=$((i + 1))
    fi
    say "  $((i + 1))) $d$mark"
  done
  say "  0) добавить новый домен"
  while true; do
    choice="$(ask_value "Домен для Hysteria2 (номер или имя)" "$def")"
    if [[ "$choice" == "0" ]]; then
      caddy_add_domain_flow || return 1
      HY2_PICKED="$CADDY_LAST_DOMAIN"
      return 0
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then
      HY2_PICKED="${CADDY_DOMAINS[$((choice - 1))]}"
      return 0
    fi
    d="$(normalize_domain "$choice")"
    if valid_domain "$d"; then
      caddy_add_domain_flow "$d" || return 1
      HY2_PICKED="$CADDY_LAST_DOMAIN"
      return 0
    fi
    warn "введите номер из списка, 0 или имя домена."
  done
}

write_hy2_compose() {
  local outfile="$1" token="$2" port="$3" domain="$4" mount
  mount="$(cert_mount_spec_for "$(dirname "$outfile")")"
  cat >"$outfile" <<EOF
# ${HY2_MARKER}
# HY2_DOMAIN=${domain}
# Сертификаты выпускает Caddy ($(caddy_dir)), каталог смонтирован в ${CERTS_MOUNT_CONTAINER} (только чтение).
# Пути к сертификату для профиля Xray (Hysteria2) на панели:
#   "certificates": [
#     {
#       "certificateFile": "${CERTS_MOUNT_CONTAINER}/${domain}/${domain}.crt",
#       "keyFile": "${CERTS_MOUNT_CONTAINER}/${domain}/${domain}.key"
#     }
#   ]
services:
  remnanode:
    image: ${NODE_IMAGE}
    container_name: ${HY2_CONTAINER}
    hostname: ${HY2_CONTAINER}
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=${port}
      - SECRET_KEY="${token}"
    volumes:
      - ${mount}
      - ${LOG_MOUNT_LINE}
EOF
}

action_hy2_change_domain() {
  require_installed hy2
  require_docker
  require_caddy
  local dir compose old new
  dir="$(hy2_node_dir)"
  compose="$dir/docker-compose.yml"
  old="$(hy2_domain)"
  say "Текущий домен ноды Hysteria2: ${old:-не задан}"
  if ! hy2_pick_domain "$old"; then
    say "Домен не изменён."
    return 0
  fi
  new="$HY2_PICKED"
  if [[ "$new" == "$old" ]]; then
    say "Домен не изменился."
    return 0
  fi
  caddy_ensure_running
  if ! caddy_wait_cert "$new"; then
    caddy_failure_hints
    return 1
  fi
  backup_file "$compose"
  set_comment_marker "$compose" HY2_DOMAIN "$new"
  if [[ -n "$old" ]]; then
    replace_in_comments "$compose" "$old" "$new"
  fi
  say "Домен ноды Hysteria2: ${old:-—} → $new (перезапуск не нужен: ${CERTS_MOUNT_CONTAINER} содержит все домены)."
  print_cert_json "$new"
  say ""
  say "Замените пути в профиле Xray на панели на новые (выше). После сохранения профиля панель перезапустит Xray на ноде."
  if [[ -n "$old" ]]; then
    say "Домен $old остался в Caddy. Удалить: $SCRIPT_NAME caddy remove $old"
  fi
}

# =============================================================================
# Общее: Linux, root, «мягкие» шаги
# =============================================================================
is_linux() { [[ "$(uname -s)" == "Linux" ]]; }

require_linux() { is_linux || die "Эта функция работает только на Linux."; }

# root без запроса пароля (для статусов в меню, чтобы не дёргать sudo).
can_root_quiet() { [[ "$(id -u)" -eq 0 ]] || sudo -n true 2>/dev/null; }

# Выполнить шаг; ошибка не прерывает установку, а выводит предупреждение.
soft_step() {
  local msg="$1" rc
  shift
  set +e
  (
    set -e
    "$@"
  )
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || warn "$msg"
  return 0
}

# =============================================================================
# IPv6
# =============================================================================
IPV6_MARKER="REMNANODE_SH_IPV6_MANAGED"

ipv6_state() {
  if [[ ! -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
    echo kernel
  elif [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "1" ]]; then
    echo off
  else
    echo on
  fi
}

ipv6_status_line() {
  is_linux || {
    echo "не Linux"
    return
  }
  case "$(ipv6_state)" in
    kernel) echo "отключён в ядре" ;;
    off)
      if [[ -f "$IPV6_SYSCTL_FILE" ]]; then echo "отключён"; else echo "отключён до перезагрузки"; fi
      ;;
    on)
      if [[ -f "$IPV6_SYSCTL_FILE" ]]; then echo "включён (отключится после перезагрузки)"; else echo "включён"; fi
      ;;
  esac
}

# SSH-сессия идёт по IPv6 — отключение её оборвёт.
ssh_over_ipv6() {
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  local srv
  srv="$(awk '{print $3}' <<<"$SSH_CONNECTION")"
  [[ "$srv" == *:* && "$srv" != ::ffff:* ]]
}

# Другие sysctl-файлы, которые задают противоположное значение.
ipv6_conflicts() {
  local want="$1" other=1 f
  [[ "$want" == "1" ]] && other=0
  for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf; do
    [[ -f "$f" && "$f" != "$IPV6_SYSCTL_FILE" ]] || continue
    if grep -qE "^[[:space:]]*net\.ipv6\.conf\.[a-z0-9._-]+\.disable_ipv6[[:space:]]*=[[:space:]]*${other}" "$f" 2>/dev/null; then
      warn "в $f задано disable_ipv6 = $other — может переопределить настройку после перезагрузки."
    fi
  done
  return 0
}

ipv6_show_status() {
  require_linux
  say "IPv6: $(ipv6_status_line)"
  [[ -f "$IPV6_SYSCTL_FILE" ]] && say "Файл настройки: $IPV6_SYSCTL_FILE"
  if [[ "$(ipv6_state)" == "on" ]] && command -v ip >/dev/null 2>&1; then
    local addrs
    addrs="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print "  " $2}' || true)"
    if [[ -n "$addrs" ]]; then
      say "Глобальные IPv6-адреса:"
      say "$addrs"
    else
      say "Глобальных IPv6-адресов нет."
    fi
  fi
}

# $1=auto — вызов при установке (без вопросов; при SSH по IPv6 — пропуск).
ipv6_disable() {
  local auto="${1:-}" tmp i
  require_linux
  if [[ "$(ipv6_state)" == "kernel" ]]; then
    say "IPv6 уже отключён в ядре (ipv6.disable=1)."
    return 0
  fi
  if [[ "$(ipv6_state)" == "off" && -f "$IPV6_SYSCTL_FILE" ]]; then
    say "IPv6 уже отключён."
    return 0
  fi
  if ssh_over_ipv6; then
    warn "вы подключены по SSH через IPv6 — после отключения сессия оборвётся."
    if [[ -n "$auto" ]]; then
      say "IPv6 не отключаю. Сделайте это позже из меню («Управление IPv6»), подключившись по IPv4."
      return 0
    fi
    prompt_yes_no "Всё равно отключить?" n || {
      say "Отмена."
      return 0
    }
  fi
  tmp="$(mktemp)"
  {
    echo "# ${IPV6_MARKER}"
    echo "# Создано ${SCRIPT_NAME}: отключение IPv6. Вернуть — «Управление IPv6 → Включить»."
    for i in all default lo; do
      echo "net.ipv6.conf.${i}.disable_ipv6 = 1"
    done
  } >"$tmp"
  if ! run_as_root tee "$IPV6_SYSCTL_FILE" <"$tmp" >/dev/null; then
    rm -f "$tmp"
    die "Не удалось записать $IPV6_SYSCTL_FILE"
  fi
  rm -f "$tmp"
  run_as_root chmod 0644 "$IPV6_SYSCTL_FILE" 2>/dev/null || true
  run_as_root sysctl -q -p "$IPV6_SYSCTL_FILE" >/dev/null || warn "sysctl -p завершился с ошибкой."
  if [[ "$(ipv6_state)" == "off" ]]; then
    say "IPv6 отключён (сохранится после перезагрузки: $IPV6_SYSCTL_FILE)."
  else
    warn "IPv6 не отключился — проверьте: sysctl net.ipv6.conf.all.disable_ipv6"
  fi
  ipv6_conflicts 1
}

ipv6_enable() {
  local f
  require_linux
  if [[ "$(ipv6_state)" == "kernel" ]]; then
    warn "IPv6 отключён в ядре (параметр загрузки ipv6.disable=1)."
    say "  Уберите его из GRUB_CMDLINE_LINUX в /etc/default/grub, выполните update-grub и перезагрузите сервер."
    return 0
  fi
  if [[ -f "$IPV6_SYSCTL_FILE" ]]; then
    if grep -qF "$IPV6_MARKER" "$IPV6_SYSCTL_FILE" 2>/dev/null; then
      run_as_root rm -f "$IPV6_SYSCTL_FILE"
      say "Удалён $IPV6_SYSCTL_FILE"
    else
      warn "$IPV6_SYSCTL_FILE создан не этим скриптом — не удаляю."
    fi
  fi
  for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [[ -f "$f" ]] || continue
    echo 0 | run_as_root tee "$f" >/dev/null 2>&1 || true
  done
  if [[ "$(ipv6_state)" == "on" ]]; then
    say "IPv6 включён."
    say "Если IPv6-адреса не появились — перезапустите сеть (netplan apply / systemctl restart networking) или перезагрузите сервер."
  else
    warn "IPv6 не включился — проверьте: sysctl net.ipv6.conf.all.disable_ipv6"
  fi
  ipv6_conflicts 0
}

ipv6_on_install() {
  [[ "$DISABLE_IPV6_ON_INSTALL" == "1" ]] || return 0
  is_linux || return 0
  if [[ "$(ipv6_state)" == "kernel" ]] || [[ "$(ipv6_state)" == "off" && -f "$IPV6_SYSCTL_FILE" ]]; then
    return 0
  fi
  say ""
  say "=== IPv6: отключаю (DISABLE_IPV6_ON_INSTALL=1) ==="
  soft_step "не удалось отключить IPv6 — можно сделать позже из меню." ipv6_disable auto
}

# =============================================================================
# Фаервол (ufw; на RHEL/Fedora — firewalld)
# =============================================================================
fw_backend() {
  if command -v ufw >/dev/null 2>&1 || [[ -x /usr/sbin/ufw ]]; then
    echo ufw
  elif command -v firewall-cmd >/dev/null 2>&1 || [[ -x /usr/bin/firewall-cmd ]]; then
    echo firewalld
  else
    echo none
  fi
}

fw_install() {
  if command -v apt-get >/dev/null 2>&1; then
    prompt_yes_no "Фаервол ufw не установлен. Установить?" y || return 1
    run_as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
  elif command -v dnf >/dev/null 2>&1; then
    prompt_yes_no "Фаервол firewalld не установлен. Установить?" y || return 1
    run_as_root dnf install -y firewalld
  elif command -v yum >/dev/null 2>&1; then
    prompt_yes_no "Фаервол firewalld не установлен. Установить?" y || return 1
    run_as_root yum install -y firewalld
  elif command -v apk >/dev/null 2>&1; then
    prompt_yes_no "Фаервол ufw не установлен. Установить?" y || return 1
    run_as_root apk add --no-cache ufw
  else
    warn "не знаю, как установить фаервол на этой системе (нужен ufw или firewalld)."
    return 1
  fi
  [[ "$(fw_backend)" != "none" ]]
}

fw_require() {
  require_linux
  if [[ "$(fw_backend)" == "none" ]]; then
    fw_install || die "Фаервол не установлен."
  fi
}

# firewalld: постоянные правила (работает и при остановленном firewalld).
fwc() {
  if run_as_root firewall-cmd --state >/dev/null 2>&1; then
    run_as_root firewall-cmd --permanent "$@"
  elif command -v firewall-offline-cmd >/dev/null 2>&1 || [[ -x /usr/bin/firewall-offline-cmd ]]; then
    run_as_root firewall-offline-cmd "$@"
  else
    warn "firewalld не запущен и нет firewall-offline-cmd."
    return 1
  fi
}

fw_reload() {
  if [[ "$(fw_backend)" == "firewalld" ]] && run_as_root firewall-cmd --state >/dev/null 2>&1; then
    run_as_root firewall-cmd --reload >/dev/null
  fi
  return 0
}

fw_active() {
  case "$(fw_backend)" in
    ufw)
      local out
      out="$(run_as_root env LC_ALL=C ufw status 2>/dev/null || true)"
      [[ "$out" == *"Status: active"* ]]
      ;;
    firewalld) run_as_root firewall-cmd --state >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

fw_status_line() {
  is_linux || {
    echo "не Linux"
    return
  }
  local b
  b="$(fw_backend)"
  if [[ "$b" == "none" ]]; then
    echo "не установлен"
  elif ! can_root_quiet; then
    echo "$b"
  elif fw_active; then
    echo "$b · включён"
  else
    echo "$b · выключен"
  fi
}

ssh_ports() {
  if [[ -n "$SSH_PORT" ]]; then
    echo "$SSH_PORT"
    return
  fi
  local ports="" p sshd_bin=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    p="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
    valid_port "$p" && ports="$ports $p"
  fi
  if command -v sshd >/dev/null 2>&1; then
    sshd_bin="$(command -v sshd)"
  elif [[ -x /usr/sbin/sshd ]]; then
    sshd_bin=/usr/sbin/sshd
  fi
  if [[ -n "$sshd_bin" ]] && can_root_quiet; then
    p="$(run_as_root "$sshd_bin" -T 2>/dev/null | awk '$1=="port"{print $2}' || true)"
    ports="$ports $p"
  fi
  if [[ -z "$(trim "$ports")" ]]; then
    p="$(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk 'tolower($1)=="port"{print $2}' || true)"
    ports="$ports $p"
  fi
  # shellcheck disable=SC2086
  ports="$(printf '%s\n' $ports | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ' || true)"
  ports="$(trim "$ports")"
  echo "${ports:-22}"
}

fw_spec_valid() {
  local s="$1" a b
  [[ "$s" =~ ^[0-9]+(:[0-9]+)?(/(tcp|udp))?$ ]] || return 1
  a="${s%%/*}"
  if [[ "$a" == *:* ]]; then
    [[ "$s" == */* ]] || return 1 # диапазон — только с протоколом
    b="${a#*:}"
    a="${a%%:*}"
    valid_port "$a" && valid_port "$b" && [ "$a" -lt "$b" ]
  else
    valid_port "$a"
  fi
}

valid_ip_or_cidr() {
  [[ "$1" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] && [[ "$1" == *.* || "$1" == *:* ]]
}

# Открыть порт. $1 — «порт[/proto]» или «a:b/proto», $2 — источник (IP/подсеть, пусто — все), $3 — комментарий.
fw_allow() {
  local spec="$1" from="${2:-}" comment="${3:-remnanode.sh}" port proto="" pr p2 fam
  port="${spec%%/*}"
  [[ "$spec" == */* ]] && proto="${spec#*/}"
  case "$(fw_backend)" in
    ufw)
      if [[ -n "$from" && -n "$proto" ]]; then
        run_as_root ufw allow from "$from" to any port "$port" proto "$proto" comment "$comment" >/dev/null
      elif [[ -n "$from" ]]; then
        run_as_root ufw allow from "$from" to any port "$port" comment "$comment" >/dev/null
      else
        run_as_root ufw allow "$spec" comment "$comment" >/dev/null
      fi
      ;;
    firewalld)
      p2="${port/:/-}"
      for pr in ${proto:-tcp udp}; do
        if [[ -n "$from" ]]; then
          fam=ipv4
          [[ "$from" == *:* ]] && fam=ipv6
          fwc --add-rich-rule="rule family=\"$fam\" source address=\"$from\" port port=\"$p2\" protocol=\"$pr\" accept" >/dev/null
        else
          fwc --add-port="$p2/$pr" >/dev/null
        fi
      done
      ;;
    *) return 1 ;;
  esac
  say "  открыт: $spec${from:+ (только с $from)}"
}

# Тихо удалить правило для порта (при смене NODE_PORT, удалении Caddy).
fw_delete_port_quiet() {
  local port="$1" from="${2:-}" fam
  case "$(fw_backend)" in
    ufw)
      run_as_root ufw delete allow "$port/tcp" >/dev/null 2>&1 || true
      if [[ -n "$from" ]]; then
        run_as_root ufw delete allow from "$from" to any port "$port" proto tcp >/dev/null 2>&1 || true
      fi
      ;;
    firewalld)
      fwc --remove-port="$port/tcp" >/dev/null 2>&1 || true
      if [[ -n "$from" ]]; then
        fam=ipv4
        [[ "$from" == *:* ]] && fam=ipv6
        fwc --remove-rich-rule="rule family=\"$fam\" source address=\"$from\" port port=\"$port\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
      fi
      ;;
  esac
  return 0
}

fw_allow_ssh() {
  local p
  for p in $(ssh_ports); do
    fw_allow "$p/tcp" "" "SSH"
  done
}

fw_enable() {
  fw_require
  say "Сначала открываю SSH (порт: $(ssh_ports)), чтобы не потерять доступ…"
  fw_allow_ssh
  case "$(fw_backend)" in
    ufw)
      run_as_root ufw default deny incoming >/dev/null
      run_as_root ufw default allow outgoing >/dev/null
      run_as_root ufw --force enable
      ;;
    firewalld)
      run_as_root systemctl enable --now firewalld
      fw_allow_ssh
      fw_reload
      say "Если Docker-контейнеры потеряли сеть — выполните: sudo systemctl restart docker"
      ;;
  esac
  say "Фаервол включён."
}

fw_disable() {
  fw_require
  prompt_yes_no "Выключить фаервол? Правила сохранятся и применятся при включении." y || {
    say "Отмена."
    return 0
  }
  case "$(fw_backend)" in
    ufw) run_as_root ufw --force disable ;;
    firewalld) run_as_root systemctl disable --now firewalld ;;
  esac
  say "Фаервол выключен."
}

fw_show() {
  fw_require
  say "SSH-порт(ы): $(ssh_ports)"
  case "$(fw_backend)" in
    ufw)
      if fw_active; then
        run_as_root ufw status verbose
      else
        say "ufw выключен. Добавленные правила (применятся при включении):"
        run_as_root ufw show added
      fi
      ;;
    firewalld)
      if fw_active; then
        run_as_root firewall-cmd --list-all
      else
        say "firewalld выключен. Постоянная конфигурация:"
        run_as_root firewall-offline-cmd --list-all 2>/dev/null || true
      fi
      ;;
  esac
}

fw_add_port_interactive() {
  fw_require
  local spec from
  while true; do
    spec="$(ask_value "Порт (например 8443 — tcp+udp, 8443/tcp, 20000:30000/udp)" "")"
    fw_spec_valid "$spec" && break
    warn "некорректный формат «$spec» (для диапазона нужен протокол: 20000:30000/udp)."
  done
  while true; do
    from="$(ask_value "Открыть только для IP/подсети (Enter — для всех)" "")"
    [[ -z "$from" ]] && break
    valid_ip_or_cidr "$from" && break
    warn "некорректный IP/подсеть «$from»."
  done
  fw_allow "$spec" "$from" "remnanode.sh"
  fw_reload
}

fw_delete_interactive() {
  fw_require
  local items=() line i n choice sel args p is_ssh=0
  local -a arr
  case "$(fw_backend)" in
    ufw)
      while IFS= read -r line; do
        [[ "$line" == ufw\ * ]] && items+=("${line#ufw }")
      done < <(run_as_root env LC_ALL=C ufw show added 2>/dev/null || true)
      ;;
    firewalld)
      for p in $(fwc --list-ports 2>/dev/null || true); do items+=("port $p"); done
      for p in $(fwc --list-services 2>/dev/null || true); do items+=("service $p"); done
      while IFS= read -r line; do
        [[ -n "$line" ]] && items+=("rich $line")
      done < <(fwc --list-rich-rules 2>/dev/null || true)
      ;;
  esac
  n=${#items[@]}
  if ((n == 0)); then
    say "Правил нет."
    return 0
  fi
  i=1
  for line in "${items[@]}"; do
    printf ' %2d) %s\n' "$i" "$line"
    i=$((i + 1))
  done
  choice="$(ask_value "Номер правила для удаления (Enter — отмена)" "")"
  [[ -z "$choice" ]] && {
    say "Отмена."
    return 0
  }
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ] || die "Нет правила с номером $choice."
  sel="${items[$((choice - 1))]}"

  for p in $(ssh_ports); do
    grep -qE "(^|[[:space:]=\"])${p}(/tcp)?([[:space:]\"]|$)" <<<"$sel" && is_ssh=1
  done
  if ((is_ssh)); then
    prompt_yes_no "Похоже, это правило SSH — можно потерять доступ к серверу. Точно удалить?" n || {
      say "Отмена."
      return 0
    }
  fi

  case "$(fw_backend)" in
    ufw)
      args="${sel%% comment *}"
      read -r -a arr <<<"$args"
      run_as_root ufw delete "${arr[@]}"
      ;;
    firewalld)
      case "$sel" in
        port\ *) fwc --remove-port="${sel#port }" >/dev/null ;;
        service\ *) fwc --remove-service="${sel#service }" >/dev/null ;;
        rich\ *) fwc --remove-rich-rule="${sel#rich }" >/dev/null ;;
      esac
      fw_reload
      ;;
  esac
  say "Удалено: $sel"
}

fw_default_ports_list() {
  local s out=""
  for s in ${DEFAULT_FIREWALL_PORTS[@]+"${DEFAULT_FIREWALL_PORTS[@]}"}; do
    out="$out $s"
  done
  trim "$out"
}

fw_open_defaults() {
  fw_require
  local s
  say "Открываю SSH и порты по умолчанию: $(fw_default_ports_list)"
  fw_allow_ssh
  for s in ${DEFAULT_FIREWALL_PORTS[@]+"${DEFAULT_FIREWALL_PORTS[@]}"}; do
    if fw_spec_valid "$s"; then
      fw_allow "$s" "" "remnanode.sh default"
    else
      warn "пропуск некорректного значения в DEFAULT_FIREWALL_PORTS: «$s»"
    fi
  done
  fw_reload
}

# --- IP панели (для ограничения NODE_PORT) ---
panel_ip_file() { echo "$BASE_DIR/.remnanode_panel_ip"; }

saved_panel_ip() {
  if [[ -n "$PANEL_IP" ]]; then
    echo "$PANEL_IP"
    return
  fi
  local f
  f="$(panel_ip_file)"
  [[ -f "$f" ]] && trim "$(cat "$f")"
  return 0
}

# stdout: IP панели или пусто (без ограничения).
ask_panel_ip() {
  if [[ -n "$PANEL_IP" ]]; then
    echo "$PANEL_IP"
    return
  fi
  local saved ip def
  saved="$(saved_panel_ip)"
  def="${saved:--}"
  say "IP панели: NODE_PORT будет открыт только для него. «-» — открыть для всех."
  while true; do
    ip="$(ask_value "IP панели" "$def")"
    if [[ "$ip" == "-" ]]; then
      ip=""
      break
    fi
    valid_ip_or_cidr "$ip" && break
    warn "некорректный IP «$ip»."
  done
  mkdir -p "$BASE_DIR" 2>/dev/null || true
  printf '%s\n' "${ip:--}" >"$(panel_ip_file)" 2>/dev/null || true
  [[ "$ip" == "-" ]] && ip=""
  echo "$ip"
}

# Открыть порты, которые нужны Caddy публично (80, 443, свои порты сайтов; локальные — нет).
fw_allow_caddy_ports() {
  local spec
  load_caddy_domains
  caddy_compute_needs
  for spec in $(caddy_publish_specs); do
    [[ "$spec" != 127.* ]] || continue
    fw_allow "$(spec_host_port "$spec")/tcp" "" "caddy"
  done
}

fw_open_node_ports() {
  fw_require
  local ip kind port
  ip="$(ask_panel_ip)"
  say "Открываю SSH и порты нод…"
  fw_allow_ssh
  for kind in node hy2; do
    kind_installed "$kind" || continue
    port="$(kind_port "$kind")"
    [[ -n "$port" ]] && fw_allow "$port/tcp" "$ip" "remnanode NODE_PORT $(kind_lr_name "$kind")"
  done
  if caddy_installed; then
    fw_allow_caddy_ports
  fi
  fw_reload
}

# Открыть в фаерволе порты, нужные Caddy (если фаервол есть).
fw_caddy_setup() {
  say ""
  say "=== Фаервол: порты Caddy ==="
  fw_allow_caddy_ports
  fw_reload
}

fw_caddy_on_install() {
  local spec any=0
  [[ "$FIREWALL_ON_INSTALL" == "1" ]] || return 0
  is_linux || return 0
  load_caddy_domains
  caddy_compute_needs
  for spec in $(caddy_publish_specs); do
    if [[ "$spec" != 127.* ]]; then any=1; fi
  done
  ((any)) || return 0
  if [[ "$(fw_backend)" == "none" ]]; then
    say "Фаервол не установлен — если он появится, откройте порты Caddy: $(caddy_publish_specs | grep -v '^127\.' | sed 's/:.*//' | tr '\n' ' ')"
    return 0
  fi
  soft_step "не удалось открыть порты Caddy в фаерволе." fw_caddy_setup
}

# При установке ноды: SSH + NODE_PORT + порты по умолчанию; предложить включить.
fw_setup_on_install() {
  local kind="$1" port="$2" old_port="${3:-}" ip s
  say ""
  say "=== Фаервол ==="
  if [[ "$(fw_backend)" == "none" ]]; then
    fw_install || {
      warn "фаервол не установлен — пропуск."
      return 0
    }
  fi
  ip="$(ask_panel_ip)"
  fw_allow_ssh
  fw_allow "$port/tcp" "$ip" "remnanode NODE_PORT $(kind_lr_name "$kind")"
  if [[ -n "$old_port" && "$old_port" != "$port" ]]; then
    fw_delete_port_quiet "$old_port" "$ip"
  fi
  if caddy_installed; then
    fw_allow_caddy_ports
  fi
  if [[ "$FIREWALL_INSTALL_ADD_DEFAULT_PORTS" == "1" ]]; then
    for s in ${DEFAULT_FIREWALL_PORTS[@]+"${DEFAULT_FIREWALL_PORTS[@]}"}; do
      fw_spec_valid "$s" && fw_allow "$s" "" "remnanode.sh default"
    done
  fi
  fw_reload
  if ! fw_active; then
    if prompt_yes_no "Фаервол сейчас выключен. Включить?" "$DEFAULT_ENABLE_FIREWALL_ON_INSTALL"; then
      fw_enable
    fi
  fi
  say "Порты inbound'ов из профиля Xray должны быть открыты: DEFAULT_FIREWALL_PORTS в начале скрипта или «Управление фаерволом → Открыть порт»."
}

fw_on_install() {
  [[ "$FIREWALL_ON_INSTALL" == "1" ]] || return 0
  is_linux || return 0
  soft_step "настройка фаервола не завершена — проверьте в меню «Управление фаерволом»." fw_setup_on_install "$@"
}

# Смена NODE_PORT: открыть новый, закрыть старый (если фаервол есть).
fw_node_port_changed() {
  local kind="$1" old="$2" new="$3" ip okport
  [[ "$FIREWALL_ON_INSTALL" == "1" ]] || return 0
  is_linux || return 0
  [[ "$(fw_backend)" != "none" ]] || return 0
  ip="$(saved_panel_ip)"
  [[ "$ip" == "-" ]] && ip=""
  soft_step "не удалось открыть порт $new в фаерволе." fw_allow "$new/tcp" "$ip" "remnanode NODE_PORT $(kind_lr_name "$kind")"
  okport="$(kind_port "$(other_kind "$kind")")"
  if [[ -n "$old" && "$old" != "$okport" && " $(ssh_ports) " != *" $old "* ]]; then
    fw_delete_port_quiet "$old" "$ip"
    say "  закрыт старый порт: $old/tcp"
  fi
  soft_step "не удалось перезагрузить правила фаервола." fw_reload
}

# =============================================================================
# Миграция старых раскладок
# =============================================================================

# --- Обычная нода: compose рядом со скриптом → ./remnanode/ ---
find_legacy_node_dir() {
  local newdir="$BASE_DIR/$NODE_DIR_NAME" d cand
  for cand in "$(compose_dir_from_state)" "$BASE_DIR" "$SCRIPT_DIR" "$PWD"; do
    [[ -n "$cand" && -d "$cand" ]] || continue
    d="$(cd "$cand" && pwd -P)"
    [[ -d "$newdir" && "$d" == "$(cd "$newdir" && pwd -P)" ]] && continue
    if is_remnanode_compose_file "$d/docker-compose.yml"; then
      echo "$d"
      return 0
    fi
  done
  return 0
}

migrate_node_dir() {
  local src="$1" dst="$2" f
  [[ "$src" != "$dst" ]] || return 0
  [[ ! -e "$dst/docker-compose.yml" ]] || die "В $dst уже есть docker-compose.yml"
  say "Останавливаю ноду в $src…"
  dc "$src" down || warn "не удалось остановить (продолжаю)."
  mkdir -p "$dst"
  mv "$src/docker-compose.yml" "$dst/"
  for f in .env log; do
    if [[ -e "$src/$f" && ! -e "$dst/$f" ]]; then
      mv "$src/$f" "$dst/" 2>/dev/null || run_as_root mv "$src/$f" "$dst/"
    fi
  done
  save_compose_dir "$dst"
  if logrotate_file_is_managed_by_script "/etc/logrotate.d/$NODE_DIR_NAME"; then
    setup_logrotate_for_dir "$dst" "$NODE_DIR_NAME" || true
  fi
  if caddy_installed; then
    sync_kind_cert_mount node 1 0 || warn "не удалось подключить сертификаты Caddy."
  fi
  say "Перенесено: $src → $dst"
}

migrate_and_start() {
  migrate_node_dir "$1" "$2"
  dc "$2" up -d
}

check_legacy_node_on_start() {
  [[ -f "$BASE_DIR/$NODE_DIR_NAME/docker-compose.yml" ]] && return 0
  [[ -n "${REMNANODE_COMPOSE_DIR:-}" ]] && return 0
  command -v docker >/dev/null 2>&1 || return 0
  local legacy
  legacy="$(find_legacy_node_dir)"
  [[ -n "$legacy" ]] || return 0
  say "Найдена обычная нода в старой раскладке: $legacy"
  if prompt_yes_no "Перенести её в $BASE_DIR/$NODE_DIR_NAME? (нода будет перезапущена)" y; then
    relocate_script_to_base
    run_action_nopause migrate_and_start "$legacy" "$BASE_DIR/$NODE_DIR_NAME"
  fi
}

# --- Hysteria2: Caddy внутри remnanode-hy2 → отдельный ./caddy/ ---
is_legacy_hy2_layout() {
  local f
  f="$(hy2_node_dir)/docker-compose.yml"
  [[ -f "$f" ]] || return 1
  compose_has_container "$f" "$LEGACY_CADDY_CONTAINER" && return 0
  grep -qE '^[[:space:]]{2}caddy:[[:space:]]*$' "$f" 2>/dev/null
}

migrate_legacy_hy2() {
  require_docker
  local hdir cdir hcompose domain email mode token port
  hdir="$(hy2_node_dir)"
  cdir="$(caddy_dir)"
  hcompose="$hdir/docker-compose.yml"
  is_legacy_hy2_layout || {
    say "Нода Hysteria2 уже в новой раскладке — переносить нечего."
    return 0
  }
  caddy_installed && die "В $cdir уже есть docker-compose.yml — автоматический перенос невозможен, разберитесь вручную."
  if [[ -e "$cdir/data" ]]; then
    die "Каталог $cdir/data уже существует — перенос остановлен, чтобы не смешать сертификаты."
  fi

  domain="$(compose_get_env DOMAIN "$hcompose")"
  email="$(compose_get_env ACME_EMAIL "$hcompose")"
  mode="$(compose_cert_mode "$hcompose")"
  token="$(compose_get_env SECRET_KEY "$hcompose")"
  port="$(compose_get_env NODE_PORT "$hcompose")"
  [[ -n "$domain" && -n "$token" && -n "$port" ]] || die "Не удалось прочитать DOMAIN / SECRET_KEY / NODE_PORT из $hcompose."
  [[ -n "$email" ]] || email="${DEFAULT_ACME_EMAIL_PREFIX}@${domain}"

  say "Перенос: Caddy из $hdir → $cdir (домен $domain, режим сертификата $mode → способ $([[ "$mode" == "2" ]] && echo alpn || echo http))."
  say "Останавливаю ноду Hysteria2 и встроенный Caddy…"
  dc "$hdir" down || warn "не удалось остановить (продолжаю)."
  if docker inspect "$LEGACY_CADDY_CONTAINER" >/dev/null 2>&1; then
    docker rm -f "$LEGACY_CADDY_CONTAINER" >/dev/null 2>&1 || true
  fi

  mkdir -p "$cdir"
  if [[ -d "$hdir/data" ]]; then
    mv "$hdir/data" "$cdir/data" 2>/dev/null || run_as_root mv "$hdir/data" "$cdir/data" || die "Не удалось перенести $hdir/data"
  fi
  if [[ -d "$cdir/data/config" && ! -e "$cdir/config" ]]; then
    mv "$cdir/data/config" "$cdir/config" 2>/dev/null || run_as_root mv "$cdir/data/config" "$cdir/config" || true
  fi
  mkdir -p "$cdir/data" "$cdir/config" 2>/dev/null || run_as_root mkdir -p "$cdir/data" "$cdir/config"

  backup_file "$hcompose"
  if [[ -f "$hdir/Caddyfile" ]]; then
    mv -f "$hdir/Caddyfile" "$hdir/Caddyfile.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  local method=http
  if [[ "$mode" == "2" ]]; then method=alpn; fi
  caddy_ensure_env
  caddy_env_set ACME_EMAIL "$email"
  CADDY_DOMAINS=("$domain")
  CADDY_METHODS=("$method")
  CADDY_TOKENS=("-")
  CADDY_SITES=("-")
  CADDY_LISTENS=("-")
  save_caddy_domains
  caddy_write_all
  write_hy2_compose "$hcompose" "$token" "$port" "$domain"
  say "Записаны $cdir/{docker-compose.yml,Caddyfile,domains.list,.env} и новый $hcompose."

  dc "$cdir" config >/dev/null || die "docker compose config: ошибка в $cdir/docker-compose.yml"
  dc "$hdir" config >/dev/null || die "docker compose config: ошибка в $hcompose"

  ensure_container_name_free "$CADDY_CONTAINER" "$cdir"
  say "Запуск Caddy…"
  dc "$cdir" up -d
  if ! caddy_wait_cert "$domain"; then
    caddy_failure_hints
    warn "нода Hysteria2 будет запущена, но сертификата для $domain пока нет."
  fi
  ensure_container_name_free "$HY2_CONTAINER" "$hdir"
  say "Запуск ноды Hysteria2…"
  dc "$hdir" up -d

  say ""
  say "=== Монтирование сертификатов в обычную ноду ==="
  sync_kind_cert_mount node 1 || warn "не удалось подключить сертификаты к обычной ноде."

  say ""
  say "Перенос завершён. Пути в профиле Xray не меняются: ${CERTS_MOUNT_CONTAINER}/${domain}/${domain}.crt"
}

ensure_new_hy2_layout() {
  is_legacy_hy2_layout || return 0
  warn "нода Hysteria2 в $(hy2_node_dir) установлена в старой раскладке (Caddy внутри)."
  if prompt_yes_no "Перенести Caddy в $(caddy_dir)? Нода hy2 будет перезапущена, сертификаты сохранятся." y; then
    relocate_script_to_base
    migrate_legacy_hy2
  else
    die "Без переноса работа с Caddy и нодой Hysteria2 невозможна. Позже: $SCRIPT_NAME migrate"
  fi
}

check_legacy_hy2_on_start() {
  command -v docker >/dev/null 2>&1 || return 0
  is_legacy_hy2_layout || return 0
  say "Нода Hysteria2 установлена в старой раскладке (Caddy внутри $(hy2_node_dir))."
  if prompt_yes_no "Перенести Caddy в отдельный каталог $(caddy_dir)? (нода hy2 будет перезапущена, сертификаты сохранятся)" y; then
    relocate_script_to_base
    run_action_nopause migrate_legacy_hy2
  fi
}

check_caddy_format_on_start() {
  command -v docker >/dev/null 2>&1 || return 0
  caddy_needs_upgrade || return 0
  say "Caddy установлен старой версией скрипта (нет .env, способов выдачи у доменов, сайтов)."
  if prompt_yes_no "Обновить его конфигурацию сейчас? (контейнер будет пересоздан, сертификаты сохранятся)" y; then
    run_action_nopause caddy_upgrade_format
  fi
}

check_legacy_on_start() {
  check_legacy_node_on_start
  check_legacy_hy2_on_start
  check_caddy_format_on_start
}

cmd_migrate() {
  relocate_script_to_base
  local legacy=""
  if [[ ! -f "$BASE_DIR/$NODE_DIR_NAME/docker-compose.yml" && -z "${REMNANODE_COMPOSE_DIR:-}" ]]; then
    legacy="$(find_legacy_node_dir)"
  fi
  if [[ -n "$legacy" ]]; then
    migrate_and_start "$legacy" "$BASE_DIR/$NODE_DIR_NAME"
  fi
  if is_legacy_hy2_layout; then
    migrate_legacy_hy2
  fi
  if [[ -z "$legacy" ]] && ! is_legacy_hy2_layout; then
    say "Старых раскладок не найдено."
  fi
}

# =============================================================================
# Установка нод
# =============================================================================
install_node() {
  require_docker
  local newdir="$BASE_DIR/$NODE_DIR_NAME"
  local compose="$newdir/docker-compose.yml"
  local legacy own_port="" port prob use_existing=false

  if [[ ! -f "$compose" && -z "${REMNANODE_COMPOSE_DIR:-}" ]]; then
    legacy="$(find_legacy_node_dir)"
    if [[ -n "$legacy" ]]; then
      if prompt_yes_no "Найдена установка обычной ноды в $legacy. Перенести в $newdir? (нода будет остановлена)" y; then
        migrate_node_dir "$legacy" "$newdir"
      fi
    fi
  fi

  if [[ -f "$compose" ]]; then
    own_port="$(compose_get_env NODE_PORT "$compose")"
    if prompt_yes_no "Найден $compose. Использовать его (без перезаписи)?" "$DEFAULT_USE_EXISTING_COMPOSE"; then
      use_existing=true
    elif prompt_yes_no "Перезаписать установку (будет бэкап)?" "$DEFAULT_OVERWRITE_INSTALL"; then
      backup_file "$compose"
    else
      say "Отмена."
      return 0
    fi
  fi

  mkdir -p "$newdir"

  if ! $use_existing; then
    read_token_input
    if [[ -n "$TOKEN_COMPOSE_TEXT" ]]; then
      printf '%s\n' "$TOKEN_COMPOSE_TEXT" >"$compose"
      is_remnanode_compose_file "$compose" || die "Вставленный YAML не похож на ноду Remnawave: нужна строка container_name: $NODE_CONTAINER."
      say "Записан $compose"
      port="$TOKEN_PANEL_PORT"
      prob=""
      if [[ -z "$port" ]]; then
        prob="в compose нет NODE_PORT"
      else
        prob="$(port_problem node "$port" "$own_port")"
      fi
      if [[ -n "$prob" ]]; then
        warn "$prob"
        port="$(ask_node_port node "$(pick_free_port node "$DEFAULT_NODE_PORT" "$own_port")" "$own_port")"
        compose_set_env NODE_PORT "$port" "$compose" || die "Не удалось записать NODE_PORT в $compose"
      fi
    else
      port="$(ask_node_port node "$(pick_free_port node "$DEFAULT_NODE_PORT" "$own_port")" "$own_port")"
      write_minimal_compose "$compose" "\"${TOKEN_VALUE}\"" "$port"
      say "Создан минимальный $compose (проверьте образ при необходимости)."
    fi
  else
    port="$own_port"
    prob="$(port_problem node "$port" "$own_port")"
    if [[ -n "$prob" ]]; then
      warn "$prob"
      port="$(ask_node_port node "$(pick_free_port node "$DEFAULT_NODE_PORT" "$own_port")" "$own_port")"
      backup_file "$compose"
      compose_set_env NODE_PORT "$port" "$compose" || die "Не удалось записать NODE_PORT в $compose"
    fi
  fi

  ensure_log_dir "$newdir"
  ensure_log_volume_in_compose "$compose"
  save_compose_dir "$newdir"

  # Сертификаты Caddy: монтируем, только если Caddy установлен
  if caddy_installed; then
    soft_step "не удалось подключить сертификаты Caddy — позже: $SCRIPT_NAME certs" sync_kind_cert_mount node 1 0
  fi

  # Ротация логов на хосте; при сбое (нет sudo и т.д.) установка всё равно продолжается
  setup_logrotate_for_dir "$newdir" "$NODE_DIR_NAME" || true

  ipv6_on_install
  fw_on_install node "$port" "$own_port"

  dc "$newdir" config >/dev/null || die "docker compose config: проверьте синтаксис YAML."
  ensure_container_name_free "$NODE_CONTAINER" "$newdir"

  say "Запуск: docker compose up -d"
  dc "$newdir" up -d
  post_start_check node
  remind_panel_port "$port"
  follow_logs "$newdir"
}

install_hy2() {
  require_docker
  ensure_new_hy2_layout
  local dir compose own_port="" port domain suggestion cur_domain=""
  dir="$(hy2_node_dir)"
  compose="$dir/docker-compose.yml"

  if [[ -f "$compose" ]]; then
    own_port="$(compose_get_env NODE_PORT "$compose")"
    cur_domain="$(hy2_domain)"
    if ! prompt_yes_no "Нода Hysteria2 уже установлена в $dir. Переустановить (токен, порт, домен; будет бэкап)?" "$DEFAULT_OVERWRITE_INSTALL"; then
      say "Отмена."
      return 0
    fi
  fi

  say ""
  say "=== Шаг 1/3: токен ==="
  read_token_input

  say ""
  say "=== Шаг 2/3: NODE_PORT ==="
  if [[ -n "$TOKEN_PANEL_PORT" ]]; then
    say "В compose из панели указан NODE_PORT=$TOKEN_PANEL_PORT (для этой ноды по умолчанию — от $DEFAULT_HY2_NODE_PORT)."
  fi
  suggestion="$(pick_free_port hy2 "$DEFAULT_HY2_NODE_PORT" "$own_port")"
  port="$(ask_node_port hy2 "$suggestion" "$own_port")"

  say ""
  say "=== Шаг 3/3: домен и сертификат (Caddy) ==="
  if ! caddy_installed; then
    say "Caddy не установлен — устанавливаю (отдельный каталог $(caddy_dir))."
    caddy_install need_domain
    caddy_installed || die "Caddy не установлен — установка ноды Hysteria2 остановлена."
  fi
  hy2_pick_domain "$cur_domain" || die "Домен не выбран — установка остановлена."
  domain="$HY2_PICKED"
  caddy_ensure_running
  if ! caddy_wait_cert "$domain"; then
    caddy_failure_hints
    die "Нет сертификата для $domain — нода не установлена."
  fi

  mkdir -p "$dir"
  ensure_log_dir "$dir"
  backup_file "$compose"
  write_hy2_compose "$compose" "$TOKEN_VALUE" "$port" "$domain"
  say "Записан $compose (домен $domain, сертификаты: ${CERTS_MOUNT_CONTAINER})."

  setup_logrotate_for_dir "$dir" "$HY2_DIR_NAME" || true

  ipv6_on_install
  fw_on_install hy2 "$port" "$own_port"

  dc "$dir" config >/dev/null || die "docker compose config: проверьте синтаксис YAML."
  ensure_container_name_free "$HY2_CONTAINER" "$dir"

  say "Запуск: docker compose up -d"
  dc "$dir" up -d
  post_start_check hy2
  remind_panel_port "$port"
  print_cert_json "$domain"
  follow_logs "$dir"
}

install_kind() {
  case "$1" in
    node) install_node ;;
    hy2) install_hy2 ;;
  esac
}

# =============================================================================
# Действия управления нодами
# =============================================================================
action_start() {
  local kind="$1" dir d
  require_installed "$kind"
  require_docker
  dir="$(kind_dir "$kind")"
  if [[ "$kind" == "hy2" ]]; then
    caddy_installed || die "Caddy не установлен — у ноды Hysteria2 нет сертификатов. Сначала: $SCRIPT_NAME caddy setup"
    caddy_upgrade_format
    caddy_ensure_running
    d="$(hy2_domain)"
    if [[ -n "$d" ]] && ! caddy_wait_cert "$d" 60; then
      warn "сертификата для $d пока нет — Hysteria2 может не запуститься."
    fi
  fi
  ensure_container_name_free "$(kind_container "$kind")" "$dir"
  dc "$dir" up -d
  post_start_check "$kind"
}

action_stop() {
  local kind="$1"
  require_installed "$kind"
  require_docker
  dc "$(kind_dir "$kind")" down
}

action_logs() {
  local kind="$1"
  require_installed "$kind"
  require_docker
  follow_logs "$(kind_dir "$kind")"
}

action_du() {
  local kind="$1" d logpath
  d="$(kind_dir "$kind")"
  logpath="${d}/${LOG_MOUNT_HOST#./}"
  if [[ ! -d "$logpath" ]]; then
    echo "Папка логов не найдена: $logpath"
    return 0
  fi
  echo "Каталог: $logpath"
  du -sh "$logpath" 2>/dev/null || true
  echo "--- Файлы ---"
  du -ah "$logpath" 2>/dev/null | sort -h || true
}

action_change_token() {
  local kind="$1" dir compose cur_port new_port="" prob
  require_installed "$kind"
  require_docker
  dir="$(kind_dir "$kind")"
  compose="$dir/docker-compose.yml"
  cur_port="$(compose_get_env NODE_PORT "$compose")"

  read_token_input

  if [[ -n "$TOKEN_PANEL_PORT" && "$TOKEN_PANEL_PORT" != "$cur_port" ]]; then
    prob="$(port_problem "$kind" "$TOKEN_PANEL_PORT" "$cur_port")"
    if [[ -n "$prob" ]]; then
      warn "в compose из панели NODE_PORT=$TOKEN_PANEL_PORT — $prob. Порт не меняю (остаётся $cur_port)."
    elif prompt_yes_no "В compose из панели NODE_PORT=$TOKEN_PANEL_PORT (сейчас $cur_port). Применить?" y; then
      new_port="$TOKEN_PANEL_PORT"
    fi
  fi

  backup_file "$compose"
  compose_set_env SECRET_KEY "\"${TOKEN_VALUE}\"" "$compose" || die "В $compose не найдена строка SECRET_KEY."
  if [[ -n "$new_port" ]]; then
    compose_set_env NODE_PORT "$new_port" "$compose" || die "В $compose не найдена строка NODE_PORT."
  fi
  say "SECRET_KEY обновлён. Перезапуск ноды…"
  dc "$dir" up -d
  if [[ -n "$new_port" ]]; then
    fw_node_port_changed "$kind" "$cur_port" "$new_port"
  fi
  post_start_check "$kind"
  if [[ -n "$new_port" ]]; then
    remind_panel_port "$new_port"
  fi
  say "Готово."
}

action_change_port() {
  local kind="$1" dir compose cur sugg p
  require_installed "$kind"
  require_docker
  dir="$(kind_dir "$kind")"
  compose="$dir/docker-compose.yml"
  cur="$(compose_get_env NODE_PORT "$compose")"
  say "Текущий NODE_PORT: ${cur:-не задан}"
  sugg="$(pick_free_port "$kind" "$(kind_default_port "$kind")" "")"
  [[ "$sugg" == "$cur" ]] && sugg="$(pick_free_port "$kind" "$((cur + 1))" "")"
  p="$(ask_node_port "$kind" "$sugg" "$cur")"
  if [[ "$p" == "$cur" ]]; then
    say "Порт не изменился."
    return 0
  fi
  backup_file "$compose"
  compose_set_env NODE_PORT "$p" "$compose" || die "В $compose не найдена строка NODE_PORT."
  say "NODE_PORT: $cur → $p. Перезапуск ноды…"
  dc "$dir" up -d
  fw_node_port_changed "$kind" "$cur" "$p"
  post_start_check "$kind"
  remind_panel_port "$p"
}

action_update() {
  local kind="$1" dir
  require_installed "$kind"
  require_docker
  dir="$(kind_dir "$kind")"
  say "Скачиваю новый образ ноды…"
  dc "$dir" pull
  dc "$dir" up -d
  post_start_check "$kind"
  if prompt_yes_no "Удалить старые неиспользуемые образы (docker image prune -f)?" "$DEFAULT_PRUNE_IMAGES"; then
    docker image prune -f
  fi
  say "Обновление завершено."
}

# =============================================================================
# Меню
# =============================================================================

# Выполнить действие в подоболочке: ошибка (die) не закрывает меню.
run_action_nopause() {
  local rc
  set +e
  (
    set -e
    "$@"
  )
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "Действие завершилось с ошибкой (код $rc)." >&2
  fi
  return 0
}

run_action() {
  run_action_nopause "$@"
  pause
}

kind_status_line() {
  local kind="$1" compose st port extra=""
  if ! kind_installed "$kind"; then
    echo "не установлена"
    return
  fi
  compose="$(kind_compose "$kind")"
  port="$(compose_get_env NODE_PORT "$compose")"
  if command -v docker >/dev/null 2>&1; then
    st="$(container_state "$(kind_container "$kind")")"
  else
    st="docker не найден"
  fi
  if [[ "$kind" == "hy2" ]]; then
    extra=" · $(hy2_domain)"
    if is_legacy_hy2_layout; then
      extra="$extra · старая раскладка"
    fi
  fi
  if compose_has_our_cert_mount "$compose"; then
    extra="$extra · ${CERTS_MOUNT_CONTAINER}"
  fi
  echo "${st} · порт ${port:-?}${extra}"
}

# Тест скорости: скачать bench_ru.sh (wget или curl) и запустить
action_speedtest() {
  local tmp url
  url="${BENCH_URL}?$(date +%s)"   # ?время — чтобы GitHub не отдал старую копию из кэша
  tmp="$(mktemp)"
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$url" || true
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmp" || true
  else
    rm -f "$tmp"
    die "Не найден ни wget, ни curl"
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    die "Не удалось скачать скрипт теста скорости: $BENCH_URL"
  fi
  run_as_root bash "$tmp" || true
  rm -f "$tmp"
}

menu_header() {
  echo
  echo "================================================================"
  echo " $1"
  echo "================================================================"
}

menu_main() {
  local c
  while true; do
    menu_header "Remnawave Node — $SCRIPT_NAME  (каталог: $BASE_DIR)"
    echo " 1) Управление Remnawave Node"
    echo " 2) Caddy (сертификаты)    [$(caddy_status_line)]"
    echo " 3) Управление IPv6        [$(ipv6_status_line)]"
    echo " 4) Управление фаерволом   [$(fw_status_line)]"
    echo " 5) Тест скорости сервера"
    echo " 0) Выход"
    read -r -p "Выберите пункт: " c || exit 0
    case "$(trim "$c")" in
      1) menu_nodes ;;
      2) menu_caddy ;;
      3) menu_ipv6 ;;
      4) menu_firewall ;;
      5) run_action action_speedtest ;;
      0 | q) exit 0 ;;
      *) ;;
    esac
  done
}

menu_ipv6() {
  local c
  while true; do
    menu_header "Управление IPv6  [$(ipv6_status_line)]"
    echo " 1) Отключить IPv6"
    echo " 2) Включить IPv6"
    echo " 3) Статус и адреса"
    echo " 0) Назад"
    read -r -p "Выберите пункт: " c || exit 0
    case "$(trim "$c")" in
      1) run_action ipv6_disable ;;
      2) run_action ipv6_enable ;;
      3) run_action ipv6_show_status ;;
      0 | q) return 0 ;;
      *) ;;
    esac
  done
}

menu_firewall() {
  local c
  while true; do
    menu_header "Управление фаерволом  [$(fw_status_line)]"
    echo " 1) Статус и список правил"
    echo " 2) Включить"
    echo " 3) Выключить"
    echo " 4) Открыть порт"
    echo " 5) Удалить правило"
    echo " 6) Открыть порты по умолчанию (SSH + $(fw_default_ports_list))"
    echo " 7) Открыть порты нод (SSH + NODE_PORT + 80 для Caddy)"
    echo " 0) Назад"
    read -r -p "Выберите пункт: " c || exit 0
    case "$(trim "$c")" in
      1) run_action fw_show ;;
      2) run_action fw_enable ;;
      3) run_action fw_disable ;;
      4) run_action fw_add_port_interactive ;;
      5) run_action fw_delete_interactive ;;
      6) run_action fw_open_defaults ;;
      7) run_action fw_open_node_ports ;;
      0 | q) return 0 ;;
      *) ;;
    esac
  done
}

menu_nodes() {
  local c
  while true; do
    menu_header "Управление Remnawave Node"
    echo " 1) Обычная нода       [$(kind_status_line node)]"
    echo " 2) Нода + Hysteria2   [$(kind_status_line hy2)]"
    echo " 0) Назад"
    read -r -p "Выберите пункт: " c || exit 0
    case "$(trim "$c")" in
      1) menu_regular ;;
      2) menu_hy2 ;;
      0 | q) return 0 ;;
      *) ;;
    esac
  done
}

menu_regular() {
  local c
  while true; do
    menu_header "$(kind_title node)  [$(kind_status_line node)]"
    echo "  1) Установить / переустановить"
    echo "  2) Запустить"
    echo "  3) Остановить"
    echo "  4) Логи"
    echo "  5) Размер логов"
    echo "  6) Сменить токен (SECRET_KEY)"
    echo "  7) Сменить NODE_PORT"
    echo "  8) Обновить Docker-образ"
    echo "  9) Сертификаты Caddy (${CERTS_MOUNT_CONTAINER}): подключить / обновить"
    echo " 10) Logrotate: установить"
    echo " 11) Logrotate: проверить"
    echo " 12) Logrotate: удалить конфиг"
    echo "  0) Назад"
    read -r -p "Выберите пункт: " c || exit 0
    case "$(trim "$c")" in
      1)
        relocate_script_to_base
        run_action install_node
        ;;
      2) run_action action_start node ;;
      3) run_action action_stop node ;;
      4) run_action action_logs node ;;
      5) run_action action_du node ;;
      6) run_action action_change_token node ;;
      7) run_action action_change_port node ;;
      8) run_action action_update node ;;
      9) run_action action_kind_certs node ;;
      10) run_action cmd_logrotate_setup node ;;
      11) run_action cmd_logrotate_check node ;;
      12) run_action cmd_logrotate_revert node ;;
      0 | q) return 0 ;;
      *) ;;
    esac
  done
}

menu_hy2() {
  local c
  while true; do
    menu_header "$(kind_title hy2)  [$(kind_status_line hy2)]"
    echo "  1) Установить / переустановить"
    echo "  2) Запустить"
    echo "  3) Остановить"
    echo "  4) Логи"
    echo "  5) Размер логов"
    echo "  6) Сменить токен (SECRET_KEY)"
    echo "  7) Сменить домен (из доменов Caddy)"
    echo "  8) Сменить NODE_PORT"
    echo "  9) Статус сертификатов"
    echo " 10) Обновить Docker-образ ноды"
    echo " 11) Logrotate: установить"
    echo " 12) Logrotate: проверить"
    echo " 13) Logrotate: удалить конфиг"
    echo "  0) Назад"
    read -r -p "Выберите пункт: " c || exit 0
    case "$(trim "$c")" in
      1)
        relocate_script_to_base
        run_action install_hy2
        ;;
      2) run_action action_start hy2 ;;
      3) run_action action_stop hy2 ;;
      4) run_action action_logs hy2 ;;
      5) run_action action_du hy2 ;;
      6) run_action action_change_token hy2 ;;
      7) run_action action_hy2_change_domain ;;
      8) run_action action_change_port hy2 ;;
      9) run_action caddy_cert_status ;;
      10) run_action action_update hy2 ;;
      11) run_action cmd_logrotate_setup hy2 ;;
      12) run_action cmd_logrotate_check hy2 ;;
      13) run_action cmd_logrotate_revert hy2 ;;
      0 | q) return 0 ;;
      *) ;;
    esac
  done
}

menu_caddy() {
  local c
  while true; do
    menu_header "Caddy — сертификаты и сайты ($CADDY_DIR_NAME)  [$(caddy_status_line)]"
    echo "  1) Установить / переустановить"
    echo "  2) Запустить"
    echo "  3) Остановить"
    echo "  4) Логи"
    echo "  5) Домены и сертификаты (список)"
    echo "  6) Добавить домен"
    echo "  7) Удалить домен"
    echo "  8) Изменить способ выдачи сертификата для домена (http / alpn / Cloudflare API)"
    echo "  9) Сайты…"
    echo " 10) Cloudflare API-токены…"
    echo " 11) Подробный статус сертификатов + JSON для профиля"
    echo " 12) Сменить email"
    echo " 13) Обновить Docker-образ Caddy"
    echo " 14) Обновить монтирование ${CERTS_MOUNT_CONTAINER} в нодах"
    echo " 15) Удалить Caddy"
    echo "  0) Назад"
    read -r -p "Выберите пункт: " c || exit 0
    case "$(trim "$c")" in
      1)
        relocate_script_to_base
        run_action caddy_install
        ;;
      2) run_action caddy_start ;;
      3) run_action caddy_stop ;;
      4) run_action caddy_logs ;;
      5) run_action caddy_show_domains ;;
      6) run_action caddy_add_domain_flow ;;
      7) run_action caddy_remove_domain_flow ;;
      8) run_action caddy_change_method ;;
      9) menu_caddy_sites ;;
      10) menu_caddy_tokens ;;
      11) run_action caddy_cert_status ;;
      12) run_action caddy_change_email ;;
      13) run_action caddy_update ;;
      14) run_action action_sync_mounts ;;
      15) run_action caddy_uninstall ;;
      0 | q) return 0 ;;
      *) ;;
    esac
  done
}

menu_caddy_sites() {
  local c
  while true; do
    menu_header "Caddy — сайты  [репозиторий: $SITES_REPO/$SITES_PATH]"
    echo " 1) Список сайтов"
    echo " 2) Добавить / изменить сайт (новый домен или существующий)"
    echo " 3) Обновить сайт из репозитория"
    echo " 4) Порт / доступ: 443, свой порт или локально для Reality"
    echo " 5) Отключить сайт"
    echo " 0) Назад"
    read -r -p "Выберите пункт: " c || exit 0
    case "$(trim "$c")" in
      1) run_action caddy_sites_show ;;
      2) run_action caddy_site_set ;;
      3) run_action caddy_site_update ;;
      4) run_action caddy_site_listen ;;
      5) run_action caddy_site_remove ;;
      0 | q) return 0 ;;
      *) ;;
    esac
  done
}

menu_caddy_tokens() {
  local c
  while true; do
    menu_header "Caddy — Cloudflare API-токены"
    echo " 1) Список токенов"
    echo " 2) Добавить токен"
    echo " 3) Проверить токены (и доступ к зонам доменов)"
    echo " 4) Удалить токен"
    echo " 0) Назад"
    read -r -p "Выберите пункт: " c || exit 0
    case "$(trim "$c")" in
      1) run_action caddy_tokens_show ;;
      2) run_action caddy_token_add ;;
      3) run_action caddy_token_check ;;
      4) run_action caddy_token_remove ;;
      0 | q) return 0 ;;
      *) ;;
    esac
  done
}

# =============================================================================
# CLI
# =============================================================================
cli_kind() {
  local kind="$1"
  shift
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    if [[ "$kind" == "hy2" ]]; then
      menu_hy2
      return 0
    fi
    usage
    return 0
  fi
  case "$cmd" in
    setup | install)
      relocate_script_to_base
      install_kind "$kind"
      ;;
    start) action_start "$kind" ;;
    stop) action_stop "$kind" ;;
    log | logs) action_logs "$kind" ;;
    du) action_du "$kind" ;;
    token) action_change_token "$kind" ;;
    port) action_change_port "$kind" ;;
    update) action_update "$kind" ;;
    certs) action_kind_certs "$kind" ;;
    logrotate-setup) cmd_logrotate_setup "$kind" ;;
    logrotate-check) cmd_logrotate_check "$kind" ;;
    logrotate-revert) cmd_logrotate_revert "$kind" "${2:-}" ;;
    domain)
      [[ "$kind" == "hy2" ]] || die "Команда domain — только для hy2: $SCRIPT_NAME hy2 domain"
      action_hy2_change_domain
      ;;
    cert | cert-status)
      caddy_cert_status
      ;;
    cert-mode | method)
      caddy_change_method "$(hy2_domain)"
      ;;
    -h | --help | help) usage ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

cli_caddy() {
  local cmd="${1:-}"
  case "$cmd" in
    "") menu_caddy ;;
    setup | install)
      relocate_script_to_base
      caddy_install
      ;;
    start) caddy_start ;;
    stop) caddy_stop ;;
    log | logs) caddy_logs ;;
    domains | list | ls) caddy_show_domains ;;
    add) caddy_add_domain_flow "${2:-}" "${3:-}" ;;
    remove | rm | del | delete) caddy_remove_domain_flow "${2:-}" ;;
    method | mode | cert-mode) caddy_change_method "${2:-}" "${3:-}" ;;
    cert | certs | status) caddy_cert_status ;;
    token | tokens | cf)
      case "${2:-list}" in
        list | ls) caddy_tokens_show ;;
        add) caddy_token_add ;;
        check) caddy_token_check ;;
        remove | rm | del) caddy_token_remove "${3:-}" ;;
        *) die "caddy token: list | add | check | remove [N]" ;;
      esac
      ;;
    site | sites)
      case "${2:-list}" in
        list | ls) caddy_sites_show ;;
        set | add | edit) caddy_site_set "${3:-}" ;;
        update) caddy_site_update "${3:-}" ;;
        listen | port) caddy_site_listen "${3:-}" "${4:-}" ;;
        remove | rm | del | off) caddy_site_remove "${3:-}" ;;
        *) die "caddy site: list | set [домен] | update [домен] | listen [домен] [443|pub:ПОРТ|loc:ПОРТ] | remove [домен]" ;;
      esac
      ;;
    email) caddy_change_email ;;
    update) caddy_update ;;
    sync | mounts) action_sync_mounts ;;
    uninstall | purge) caddy_uninstall ;;
    -h | --help | help) usage ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main() {
  compute_base_dir
  local cmd="${1:-menu}"
  case "$cmd" in
    -h | --help | help)
      usage
      ;;
    menu)
      check_legacy_on_start
      menu_main
      ;;
    hy2)
      shift
      cli_kind hy2 "$@"
      ;;
    caddy)
      shift
      cli_caddy "$@"
      ;;
    migrate)
      cmd_migrate
      ;;
    bench | speedtest)
      action_speedtest
      ;;
    ipv6)
      case "${2:-status}" in
        status) ipv6_show_status ;;
        disable | off) ipv6_disable ;;
        enable | on) ipv6_enable ;;
        *) die "ipv6: status | disable | enable" ;;
      esac
      ;;
    firewall | fw)
      case "${2:-status}" in
        status) fw_show ;;
        enable | on) fw_enable ;;
        disable | off) fw_disable ;;
        allow | add)
          [[ -n "${3:-}" ]] || die "Укажите порт: $SCRIPT_NAME firewall allow 8443/tcp [IP]"
          fw_spec_valid "$3" || die "Некорректный порт: $3"
          fw_require
          fw_allow "$3" "${4:-}" "remnanode.sh"
          fw_reload
          ;;
        delete | del | rm) fw_delete_interactive ;;
        defaults) fw_open_defaults ;;
        nodes) fw_open_node_ports ;;
        *) die "firewall: status | enable | disable | allow <порт> [IP] | delete | defaults | nodes" ;;
      esac
      ;;
    *)
      cli_kind node "$@"
      ;;
  esac
}

main "$@"
