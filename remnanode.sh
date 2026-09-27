#!/usr/bin/env bash
# remnanode.sh — управление Remnawave Node (Linux / macOS, Bash 3.2+)
#
#   Обычная нода           → ./remnanode/       (логи ./log → /var/log/remnanode)
#   Нода + Hysteria2       → ./remnanode-hy2/   (Caddy выпускает TLS-сертификат, нода берёт его из /certs)
#
# Структура после установки:
#   ~/remnanode/
#   ├── remnanode.sh
#   ├── remnanode/        docker-compose.yml, log/
#   └── remnanode-hy2/    docker-compose.yml, Caddyfile, data/, log/

set -euo pipefail

# =============================================================================
# НАСТРОЙКИ ПО УМОЛЧАНИЮ (то, что подставляется при нажатии Enter)
# =============================================================================

# --- Имена папок и контейнеров ---
NODE_DIR_NAME="remnanode"              # обычная нода: ~/remnanode/remnanode
HY2_DIR_NAME="remnanode-hy2"           # нода с Hysteria2: ~/remnanode/remnanode-hy2
NODE_CONTAINER="remnanode"             # должен совпадать с container_name в compose из панели
HY2_CONTAINER="remnanode-hy2"
CADDY_CONTAINER="caddy-hy2"

# --- Образы ---
NODE_IMAGE="remnawave/node:latest"
CADDY_IMAGE="caddy:2-alpine"

# --- NODE_PORT (если занят — берётся следующий свободный: +1, +2, …) ---
DEFAULT_NODE_PORT=2222                 # обычная нода
DEFAULT_HY2_NODE_PORT=3333             # нода с Hysteria2

# --- Сертификат (Hysteria2) ---
DEFAULT_CERT_MODE=1                    # 1 — только HTTP-01 (порт 80), 2 — HTTP-01 + TLS-ALPN (80 и 443)
DEFAULT_ACME_EMAIL_PREFIX="admin"      # email по умолчанию: admin@<домен>
ACME_CA="https://acme-v02.api.letsencrypt.org/directory"
CADDY_INTERNAL_HTTPS_PORT=8443         # в режиме 1: внутренний HTTPS-порт Caddy, наружу не публикуется
CERT_WAIT_SECONDS=330                  # сколько ждать получения сертификата

# --- Ответы на вопросы да/нет (y — да, n — нет) ---
DEFAULT_USE_EXISTING_COMPOSE=y         # использовать найденный docker-compose.yml
DEFAULT_OVERWRITE_INSTALL=n            # перезаписать существующую установку
DEFAULT_CONTINUE_ON_DNS_MISMATCH=n     # продолжать, если DNS домена не указывает на сервер
DEFAULT_PRUNE_IMAGES=y                 # удалить старые образы после обновления
DEFAULT_DELETE_OLD_CERT=y              # удалить старый сертификат при смене домена
DEFAULT_LOGROTATE_REVERT=y             # подтверждение удаления конфига logrotate

# --- Проверка после запуска второй ноды (конфликт в host-сети) ---
POST_START_CHECK_SECONDS=10

# --- IPv6 ---
DISABLE_IPV6_ON_INSTALL=1              # 1 — при установке ноды отключать IPv6 (sysctl, сохраняется после перезагрузки); 0 — не трогать
IPV6_SYSCTL_FILE="/etc/sysctl.d/99-zz-remnanode-disable-ipv6.conf"

# --- Фаервол (ufw; на RHEL/Fedora — firewalld) ---
FIREWALL_ON_INSTALL=1                  # 1 — при установке ноды открыть SSH и NODE_PORT (+80/tcp для Hysteria2)
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
  "6443/tcp"
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

usage() {
  cat <<EOF
Использование: $SCRIPT_NAME [команда]

Без команды — интерактивное меню.

Обычная нода (как раньше):
  setup            установка / переустановка
  start            docker compose up -d
  stop             docker compose down
  log              docker compose logs -f -t
  du               размер каталога ./log
  token            сменить SECRET_KEY
  port             сменить NODE_PORT
  update           обновить Docker-образ
  logrotate-setup  установить/обновить logrotate для ./log
  logrotate-check  проверить конфиг и расписание logrotate
  logrotate-revert [-y|--yes]  удалить конфиг /etc/logrotate.d/ (пакет logrotate не удаляется)

Нода + Hysteria2 — те же команды с префиксом hy2, плюс:
  hy2 domain       сменить домен (новый сертификат)
  hy2 cert-mode    сменить режим получения сертификата (только 80 / 80+443)
  hy2 cert         статус сертификата
  hy2              меню ноды Hysteria2

IPv6:
  ipv6 [status|disable|enable]

Фаервол (ufw; на RHEL/Fedora — firewalld):
  firewall status             статус и правила
  firewall enable|disable     включить (SSH открывается автоматически) / выключить
  firewall allow <порт> [IP]  открыть порт: 8443, 8443/tcp, 20000:30000/udp
  firewall delete             удалить правило (выбор по номеру)
  firewall defaults           открыть SSH + DEFAULT_FIREWALL_PORTS
  firewall nodes              открыть SSH + NODE_PORT обеих нод + 80/tcp для Hysteria2

  help             эта справка

Каталоги:
  ${NODE_DIR_NAME}/ и ${HY2_DIR_NAME}/ рядом со скриптом (скрипт при установке сам переносится в ~/${NODE_DIR_NAME}/).
  Переопределение: REMNANODE_COMPOSE_DIR (обычная нода), REMNANODE_HY2_DIR (Hysteria2).

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

# docker compose для каталога, без cd (имя проекта = имя каталога, как при cd).
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
  if prompt_yes_no "Остановить и удалить его, чтобы запустить ноду из $dir_abs?" y; then
    docker rm -f "$name" >/dev/null
    say "Контейнер $name удалён."
  else
    die "Имя контейнера $name занято — запуск невозможен."
  fi
}

follow_logs() {
  local dir="$1"
  say "Логи (Ctrl+C — выйти из просмотра, нода продолжит работать)…"
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
    echo "порт 80 нужен Caddy для получения сертификата"
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
# Работа с docker-compose.yml (env-переменные)
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

is_remnanode_compose_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -qiE "^[[:space:]]*container_name:[[:space:]]*[\"']?${NODE_CONTAINER}[\"']?[[:space:]]*(#.*)?\$" "$f"
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

# Дописывает volumes в сервис с container_name: $NODE_CONTAINER (только bash).
ensure_log_volume_in_compose() {
  local main="$1"
  has_log_mount_in_file "$main" && return 0
  is_remnanode_compose_file "$main" || die "В $main не найден container_name: $NODE_CONTAINER — не правлю чужой compose."

  compose_load_lines "$main"
  local n=${#_remnanode_sh_lines[@]}
  ((n > 0)) || die "Пустой $main"

  local idx="" i j k m ins last_vol vol_idx="" _ln
  local re_cn="^[[:space:]]*container_name:[[:space:]]*[\"']?${NODE_CONTAINER}[\"']?[[:space:]]*(#.*)?\$"
  shopt -s nocasematch
  for ((i = 0; i < n; i++)); do
    if [[ "${_remnanode_sh_lines[i]}" =~ $re_cn ]]; then
      idx=$i
      break
    fi
  done
  shopt -u nocasematch
  [[ -n "$idx" ]] || die "Не найден container_name: $NODE_CONTAINER"

  local svc_start=""
  for ((j = idx; j >= 0; j--)); do
    if [[ "${_remnanode_sh_lines[j]}" =~ ^[[:space:]]{2}[a-zA-Z0-9_-]+:[[:space:]]*(\#.*)?$ ]]; then
      svc_start=$j
      break
    fi
  done
  [[ -n "$svc_start" ]] || die "Не удалось найти начало сервиса в YAML"

  local svc_end=$n
  for ((j = svc_start + 1; j < n; j++)); do
    if [[ "${_remnanode_sh_lines[j]}" =~ ^[[:space:]]{2}[a-zA-Z0-9_-]+:[[:space:]]*(\#.*)?$ ]]; then
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

  local insert_line="      - ${LOG_MOUNT_LINE}"
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
  say "В docker-compose.yml добавлен том: ${LOG_MOUNT_LINE}"
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
# Hysteria2: домен, DNS, Caddy, сертификаты
# =============================================================================
valid_domain() {
  local re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
  [[ "$1" =~ $re ]]
}

ask_domain() {
  local def="${1:-}" d
  while true; do
    d="$(ask_value "Домен для Hysteria2 (A-запись должна указывать на этот сервер)" "$def")"
    d="$(lower "$d")"
    d="${d#http://}"
    d="${d#https://}"
    d="${d%%/*}"
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

acme_ca_dir_name() {
  local s="${ACME_CA#*://}"
  echo "${s//\//-}"
}

cert_mode_desc() {
  case "$1" in
    1) echo "1 — только HTTP-01 (порт 80, 443/tcp свободен)" ;;
    2) echo "2 — HTTP-01 + TLS-ALPN (порты 80 и 443)" ;;
    *) echo "$1" ;;
  esac
}

ask_cert_mode() {
  local def="$1" m
  say "Как получать сертификат?"
  say "  1) Только HTTP-01 — Caddy занимает только 80/tcp, 443/tcp свободен (для VLESS Reality и т.п.)"
  say "  2) HTTP-01 + TLS-ALPN — Caddy занимает 80/tcp и 443/tcp"
  while true; do
    m="$(ask_value "Режим" "$def")"
    if [[ "$m" == "1" || "$m" == "2" ]]; then
      echo "$m"
      return 0
    fi
    warn "введите 1 или 2."
  done
}

# Режим сертификата из compose: маркер «# CERT_MODE=N», иначе по наличию 443:443.
hy2_cert_mode() {
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

# Проверить порты для Caddy. $1 — желаемый режим, $2 — текущий (если Caddy уже работает).
# stdout: итоговый режим; return 1 — продолжать нельзя.
caddy_ports_check() {
  local mode="$1" cur="${2:-}" ours=false
  container_running "$CADDY_CONTAINER" && ours=true
  if ! $ours && tcp_port_busy 80; then
    warn "порт 80/tcp занят — Caddy нужен порт 80 для получения сертификата (HTTP-01)."
    say "  Кто слушает: sudo ss -ltnp 'sport = :80'"
    return 1
  fi
  if [[ "$mode" == "2" ]] && ! { $ours && [[ "$cur" == "2" ]]; } && tcp_port_busy 443; then
    warn "порт 443/tcp занят (например, VLESS Reality) — режим 2 невозможен."
    if prompt_yes_no "Использовать режим 1 (только порт 80)?" y; then
      mode=1
    else
      return 1
    fi
  fi
  echo "$mode"
}

write_caddyfile() {
  local outfile="$1" mode="$2"
  if [[ "$mode" == "1" ]]; then
    cat >"$outfile" <<EOF
# ${HY2_MARKER}
# Режим 1: только HTTP-01 (порт 80). HTTPS Caddy слушает внутренний порт ${CADDY_INTERNAL_HTTPS_PORT}
# внутри контейнера (наружу не публикуется) — 443/tcp хоста свободен.
# Caddy только получает и продлевает сертификат, трафик не проксирует.
{
	email {\$ACME_EMAIL}
	acme_ca ${ACME_CA}
	https_port ${CADDY_INTERNAL_HTTPS_PORT}
	auto_https disable_redirects
}

http://{\$DOMAIN} {
	respond "OK"
}

{\$DOMAIN} {
	tls {
		issuer acme {
			dir ${ACME_CA}
			email {\$ACME_EMAIL}
			disable_tlsalpn_challenge
		}
	}
	respond "OK"
}
EOF
  else
    cat >"$outfile" <<EOF
# ${HY2_MARKER}
# Режим 2: HTTP-01 + TLS-ALPN (порты 80 и 443/tcp).
{
	email {\$ACME_EMAIL}
	acme_ca ${ACME_CA}
}

{\$DOMAIN} {
	# Отдельный сайт нужен только для того, чтобы Caddy получил
	# и продлевал сертификат для этого домена. Реальный трафик
	# сюда идти не обязан.
	respond "OK"
}
EOF
  fi
}

write_hy2_compose() {
  local outfile="$1" token="$2" port="$3" domain="$4" email="$5" mode="$6"
  local cadir ports443=""
  cadir="$(acme_ca_dir_name)"
  if [[ "$mode" == "2" ]]; then
    ports443=$'\n      - "443:443"'
  fi
  cat >"$outfile" <<EOF
# ${HY2_MARKER}
# CERT_MODE=${mode}
# Пути к сертификату для профиля Xray (Hysteria2) на панели:
#   "certificates": [
#     {
#       "certificateFile": "/certs/${domain}/${domain}.crt",
#       "keyFile": "/certs/${domain}/${domain}.key"
#     }
#   ]
services:
  # Caddy только выпускает и продлевает реальный TLS-сертификат для домена Hysteria2.
  # Никакого трафика он не проксирует. Hysteria2 работает на UDP — конфликта с Caddy нет.
  caddy:
    image: ${CADDY_IMAGE}
    container_name: ${CADDY_CONTAINER}
    restart: unless-stopped
    environment:
      - DOMAIN=${domain}
      - ACME_EMAIL=${email}
    ports:
      - "80:80"${ports443}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./data/config:/config
    healthcheck:
      # "Здоров" только когда Caddy реально получил сертификат для DOMAIN
      test: ["CMD-SHELL", "test -f /data/caddy/certificates/${cadir}/\$\$DOMAIN/\$\$DOMAIN.crt"]
      interval: 5s
      timeout: 3s
      retries: 60
      start_period: 10s

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
      - ./data/caddy/certificates/${cadir}:/certs:ro
      - ${LOG_MOUNT_LINE}
    depends_on:
      caddy:
        condition: service_healthy
EOF
}

# Включить/выключить публикацию 443:443 у Caddy и обновить маркер CERT_MODE.
set_hy2_mode_in_compose() {
  local file="$1" mode="$2" line indent="      " have_marker=0
  local out=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^\#\ CERT_MODE= ]]; then
      line="# CERT_MODE=${mode}"
      have_marker=1
    fi
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*[\"\']?443:443[\"\']?[[:space:]]*$ ]]; then
      continue
    fi
    out+=("$line")
    if [[ "$line" =~ ^([[:space:]]*)-[[:space:]]*[\"\']?80:80[\"\']?[[:space:]]*$ ]]; then
      indent="${BASH_REMATCH[1]}"
      if [[ "$mode" == "2" ]]; then
        out+=("${indent}- \"443:443\"")
      fi
    fi
  done <"$file"
  if ((have_marker == 0)); then
    out=("# CERT_MODE=${mode}" "${out[@]}")
  fi
  write_lines "$file" "${out[@]}"
}

wait_caddy_healthy() {
  local timeout="${1:-$CERT_WAIT_SECONDS}" t=0 st
  while ((t < timeout)); do
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CADDY_CONTAINER" 2>/dev/null || echo missing)"
    case "$st" in
      healthy) return 0 ;;
      unhealthy) return 1 ;;
    esac
    sleep 5
    t=$((t + 5))
  done
  return 1
}

caddy_failure_hints() {
  warn "Caddy не получил сертификат. Последние строки логов $CADDY_CONTAINER:"
  docker logs --tail 40 "$CADDY_CONTAINER" 2>&1 || true
  say ""
  say "Проверьте:"
  say "  • A-запись домена указывает на IP этого сервера (Cloudflare — серое облако);"
  say "  • порт 80/tcp открыт снаружи (фаервол: ufw allow 80/tcp, security group у провайдера);"
  say "  • лимиты Let's Encrypt (много попыток подряд для одного домена)."
}

print_cert_json() {
  local d="$1"
  say ""
  say "Блок для профиля Xray (inbound Hysteria2 → tlsSettings) на панели:"
  cat <<EOF
"certificates": [
  {
    "certificateFile": "/certs/${d}/${d}.crt",
    "keyFile": "/certs/${d}/${d}.key"
  }
]
EOF
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

# Тихо удалить правило для порта (при смене NODE_PORT).
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
  if kind_installed hy2; then
    fw_allow "80/tcp" "" "caddy ACME HTTP-01"
  fi
  fw_reload
}

# При установке ноды: SSH + NODE_PORT (+80 для hy2) + порты по умолчанию; предложить включить.
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
  if [[ "$kind" == "hy2" ]]; then
    fw_allow "80/tcp" "" "caddy ACME HTTP-01"
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
# Миграция старой раскладки обычной ноды
# =============================================================================
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
  say "Перенесено: $src → $dst"
}

check_legacy_on_start() {
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

migrate_and_start() {
  migrate_node_dir "$1" "$2"
  dc "$2" up -d
}

# =============================================================================
# Установка
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
  local dir compose own_port="" port domain email mode def_mode suggestion
  dir="$(hy2_node_dir)"
  compose="$dir/docker-compose.yml"

  if [[ -f "$compose" ]]; then
    own_port="$(compose_get_env NODE_PORT "$compose")"
    if ! prompt_yes_no "Нода Hysteria2 уже установлена в $dir. Переустановить (токен, порт, домен, режим; будет бэкап)?" "$DEFAULT_OVERWRITE_INSTALL"; then
      say "Отмена."
      return 0
    fi
  fi

  say ""
  say "=== Шаг 1/5: токен ==="
  read_token_input

  say ""
  say "=== Шаг 2/5: NODE_PORT ==="
  if [[ -n "$TOKEN_PANEL_PORT" ]]; then
    say "В compose из панели указан NODE_PORT=$TOKEN_PANEL_PORT (для этой ноды по умолчанию — от $DEFAULT_HY2_NODE_PORT)."
  fi
  suggestion="$(pick_free_port hy2 "$DEFAULT_HY2_NODE_PORT" "$own_port")"
  port="$(ask_node_port hy2 "$suggestion" "$own_port")"

  say ""
  say "=== Шаг 3/5: домен ==="
  domain="$(ask_domain "")"
  if ! check_domain_dns "$domain"; then
    say "Отмена."
    return 0
  fi

  say ""
  say "=== Шаг 4/5: email для Let's Encrypt ==="
  email="$(ask_email "${DEFAULT_ACME_EMAIL_PREFIX}@${domain}")"

  say ""
  say "=== Шаг 5/5: режим получения сертификата ==="
  def_mode="$DEFAULT_CERT_MODE"
  if tcp_port_busy 443 && ! container_running "$CADDY_CONTAINER"; then
    say "Порт 443/tcp на сервере уже занят — рекомендуется режим 1."
    def_mode=1
  fi
  mode="$(ask_cert_mode "$def_mode")"
  local cur_mode=""
  [[ -f "$compose" ]] && cur_mode="$(hy2_cert_mode "$compose")"
  if ! mode="$(caddy_ports_check "$mode" "$cur_mode")"; then
    die "Порты для Caddy недоступны — установка остановлена."
  fi

  mkdir -p "$dir/data"
  ensure_log_dir "$dir"
  backup_file "$compose"
  backup_file "$dir/Caddyfile"
  write_caddyfile "$dir/Caddyfile" "$mode"
  write_hy2_compose "$compose" "$TOKEN_VALUE" "$port" "$domain" "$email" "$mode"
  say "Записаны $dir/Caddyfile и $compose (режим сертификата: $(cert_mode_desc "$mode"))."

  setup_logrotate_for_dir "$dir" "$HY2_DIR_NAME" || true

  ipv6_on_install
  fw_on_install hy2 "$port" "$own_port"

  dc "$dir" config >/dev/null || die "docker compose config: проверьте синтаксис YAML."
  ensure_container_name_free "$CADDY_CONTAINER" "$dir"
  ensure_container_name_free "$HY2_CONTAINER" "$dir"

  say "Запуск. Нода стартует после получения сертификата (до ~5 минут)…"
  if ! dc "$dir" up -d; then
    caddy_failure_hints
    die "Нода не запущена: нет сертификата."
  fi
  say "Сертификат для $domain получен, нода запущена."
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
# Действия управления
# =============================================================================
action_start() {
  local kind="$1" dir
  require_installed "$kind"
  require_docker
  dir="$(kind_dir "$kind")"
  if [[ "$kind" == "hy2" ]]; then
    ensure_container_name_free "$CADDY_CONTAINER" "$dir"
    say "Запуск (нода ждёт готовности сертификата)…"
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
  [[ -n "$new_port" ]] && fw_node_port_changed "$kind" "$cur_port" "$new_port"
  post_start_check "$kind"
  [[ -n "$new_port" ]] && remind_panel_port "$new_port"
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
  say "Скачиваю новые образы…"
  dc "$dir" pull
  dc "$dir" up -d
  post_start_check "$kind"
  if prompt_yes_no "Удалить старые неиспользуемые образы (docker image prune -f)?" "$DEFAULT_PRUNE_IMAGES"; then
    docker image prune -f
  fi
  say "Обновление завершено."
}

action_change_domain() {
  require_installed hy2
  require_docker
  local dir compose old new old_email email def_email cadir old_cert_dir
  dir="$(hy2_node_dir)"
  compose="$dir/docker-compose.yml"
  old="$(compose_get_env DOMAIN "$compose")"
  old_email="$(compose_get_env ACME_EMAIL "$compose")"
  say "Текущий домен: ${old:-не задан}"

  while true; do
    new="$(ask_domain "")"
    [[ "$new" != "$old" ]] && break
    warn "домен совпадает с текущим."
  done
  if ! check_domain_dns "$new"; then
    say "Отмена."
    return 0
  fi

  if [[ -z "$old_email" || "$old_email" == "${DEFAULT_ACME_EMAIL_PREFIX}@${old}" ]]; then
    def_email="${DEFAULT_ACME_EMAIL_PREFIX}@${new}"
  else
    def_email="$old_email"
  fi
  email="$(ask_email "$def_email")"

  backup_file "$compose"
  compose_set_env DOMAIN "$new" "$compose" || die "В $compose не найдена строка DOMAIN."
  compose_set_env ACME_EMAIL "$email" "$compose" || die "В $compose не найдена строка ACME_EMAIL."
  [[ -n "$old" ]] && replace_in_comments "$compose" "$old" "$new"

  say "Перезапуск Caddy и получение сертификата для $new (до ~5 минут)…"
  dc "$dir" up -d
  if ! wait_caddy_healthy; then
    caddy_failure_hints
    warn "старый сертификат не тронут. Вернуть прежний домен: восстановите бэкап compose и выполните $(kind_cli hy2) start"
    return 1
  fi
  say "Сертификат для $new получен."
  print_cert_json "$new"
  say ""
  say "Замените пути в профиле Xray на панели на новые (выше). После сохранения профиля панель перезапустит Xray на ноде."

  cadir="$(acme_ca_dir_name)"
  old_cert_dir="$dir/data/caddy/certificates/$cadir/$old"
  if [[ -n "$old" && -n "$cadir" ]] && run_as_root test -d "$old_cert_dir"; then
    if prompt_yes_no "Удалить старый сертификат $old? (сначала поменяйте пути в профиле на панели — иначе Xray не найдёт файлы при перезапуске)" "$DEFAULT_DELETE_OLD_CERT"; then
      run_as_root rm -rf "$old_cert_dir"
      say "Удалён $old_cert_dir"
    fi
  fi
}

action_change_cert_mode() {
  require_installed hy2
  require_docker
  local dir compose cur def new
  dir="$(hy2_node_dir)"
  compose="$dir/docker-compose.yml"
  cur="$(hy2_cert_mode "$compose")"
  say "Текущий режим: $(cert_mode_desc "$cur")"
  if [[ "$cur" == "1" ]]; then def=2; else def=1; fi
  new="$(ask_cert_mode "$def")"
  if [[ "$new" == "$cur" ]]; then
    say "Режим не изменился."
    return 0
  fi
  if ! new="$(caddy_ports_check "$new" "$cur")"; then
    die "Порты для Caddy недоступны — режим не изменён."
  fi
  if [[ "$new" == "$cur" ]]; then
    say "Режим не изменился."
    return 0
  fi
  backup_file "$compose"
  backup_file "$dir/Caddyfile"
  write_caddyfile "$dir/Caddyfile" "$new"
  set_hy2_mode_in_compose "$compose" "$new"
  say "Режим: $(cert_mode_desc "$new"). Перезапуск Caddy…"
  dc "$dir" up -d --force-recreate caddy
  if wait_caddy_healthy; then
    say "Caddy работает, сертификат на месте."
  else
    caddy_failure_hints
    return 1
  fi
}

action_cert_status() {
  require_installed hy2
  local dir compose domain cadir crt health
  dir="$(hy2_node_dir)"
  compose="$dir/docker-compose.yml"
  domain="$(compose_get_env DOMAIN "$compose")"
  cadir="$(acme_ca_dir_name)"
  crt="$dir/data/caddy/certificates/$cadir/$domain/$domain.crt"
  say "Домен: $domain"
  say "Режим: $(cert_mode_desc "$(hy2_cert_mode "$compose")")"
  if command -v docker >/dev/null 2>&1; then
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}—{{end}}' "$CADDY_CONTAINER" 2>/dev/null || echo "нет контейнера")"
    say "Caddy ($CADDY_CONTAINER): $health"
  fi
  if ! run_as_root test -f "$crt"; then
    warn "файл сертификата не найден: $crt"
    return 0
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
  print_cert_json "$domain"
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
  local kind="$1" dir compose st port extra=""
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
    extra=" · $(compose_get_env DOMAIN "$compose") · режим $(hy2_cert_mode "$compose")"
  fi
  echo "${st} · порт ${port:-?}${extra}"
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
    echo " 2) Управление IPv6        [$(ipv6_status_line)]"
    echo " 3) Управление фаерволом   [$(fw_status_line)]"
    echo " 0) Выход"
    read -r -p "Выберите пункт: " c || exit 0
    case "$(trim "$c")" in
      1) menu_nodes ;;
      2) menu_ipv6 ;;
      3) menu_firewall ;;
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
    echo " 7) Открыть порты нод (SSH + NODE_PORT + 80 для Hysteria2)"
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
    echo "  9) Logrotate: установить"
    echo " 10) Logrotate: проверить"
    echo " 11) Logrotate: удалить конфиг"
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
      9) run_action cmd_logrotate_setup node ;;
      10) run_action cmd_logrotate_check node ;;
      11) run_action cmd_logrotate_revert node ;;
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
    echo "  7) Сменить домен"
    echo "  8) Сменить режим сертификата (только 80 / 80+443)"
    echo "  9) Сменить NODE_PORT"
    echo " 10) Статус сертификата"
    echo " 11) Обновить Docker-образы (node + caddy)"
    echo " 12) Logrotate: установить"
    echo " 13) Logrotate: проверить"
    echo " 14) Logrotate: удалить конфиг"
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
      7) run_action action_change_domain ;;
      8) run_action action_change_cert_mode ;;
      9) run_action action_change_port hy2 ;;
      10) run_action action_cert_status ;;
      11) run_action action_update hy2 ;;
      12) run_action cmd_logrotate_setup hy2 ;;
      13) run_action cmd_logrotate_check hy2 ;;
      14) run_action cmd_logrotate_revert hy2 ;;
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
    logrotate-setup) cmd_logrotate_setup "$kind" ;;
    logrotate-check) cmd_logrotate_check "$kind" ;;
    logrotate-revert) cmd_logrotate_revert "$kind" "${2:-}" ;;
    domain)
      [[ "$kind" == "hy2" ]] || die "Команда domain — только для hy2: $SCRIPT_NAME hy2 domain"
      action_change_domain
      ;;
    cert-mode)
      [[ "$kind" == "hy2" ]] || die "Команда cert-mode — только для hy2."
      action_change_cert_mode
      ;;
    cert | cert-status)
      [[ "$kind" == "hy2" ]] || die "Команда cert — только для hy2."
      action_cert_status
      ;;
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
