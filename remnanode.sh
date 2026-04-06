#!/usr/bin/env bash
# remnanode.sh — Remnawave Node: логи на хосте в ./log → /var/log/remnanode в контейнере (Linux / macOS)
# Bash 3.2+ (macOS совместимость)

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
STATE_FILE="$SCRIPT_DIR/.remnanode_compose_dir"

LOG_MOUNT_HOST="./log"
LOG_MOUNT_CONTAINER="/var/log/remnanode"
LOG_MOUNT_LINE="${LOG_MOUNT_HOST}:${LOG_MOUNT_CONTAINER}"

# =============================================================================
# Ротация логов на хосте (access.log / error.log в каталоге ./log рядом с compose)
# Используется системный logrotate: не трогает открытые дескрипторы в контейнере
# благодаря copytruncate (копия + обнуление текущего файла).
# =============================================================================
# 1 — при setup (и по команде logrotate-setup) записать конфиг в /etc/logrotate.d/
# 0 — полностью отключить логику logrotate в скрипте
LOGROTATE_SETUP=1

# 1 — если logrotate не найден, попробовать поставить пакет (нужны apt|dnf|yum|apk и sudo)
LOGROTATE_TRY_INSTALL=1

# Имя файла правил (будет /etc/logrotate.d/$LOGROTATE_CONF_NAME)
LOGROTATE_CONF_NAME="remnanode"

# Маркер внутри файла: по нему logrotate-revert удаляет только наш конфиг, не чужой с тем же именем
LOGROTATE_FILE_MARKER="REMNANODE_SH_LOGROTATE_MANAGED"

# Ротировать, когда текущий .log вырастет до этого размера (синтаксис logrotate: 50M, 100k, 1G)
LOGROTATE_SIZE="50M"

# Сколько старых файлов хранить (access.log.1 … .N; дальше удаляются)
LOGROTATE_ROTATE=5

# 1 — gzip для архивов; 0 — только переименование без сжатия
LOGROTATE_COMPRESS=1

usage() {
  cat <<'EOF'
Использование: remnanode.sh [команда]

Без команды или «setup» — мастер настройки, затем:
  docker compose up -d && docker compose logs -f -t

Команды:
  start    docker compose up -d
  stop     docker compose down
  log      docker compose logs -f -t
  du       размер каталога ./log рядом с docker-compose.yml
  logrotate-setup  установить/обновить logrotate и конфиг ротации для ./log
  logrotate-check  только проверка: синтаксис конфига и что расписание logrotate работает
  logrotate-revert [-y|--yes]  удалить конфиг /etc/logrotate.d/ от этого скрипта; -y без подтверждения; пакет logrotate не удаляется
  help     эта справка

Каталог с docker-compose.yml определяется так:
  переменная REMNANODE_COMPOSE_DIR, или файл .remnanode_compose_dir рядом со скриптом,
  или текущий каталог / каталог скрипта, если там есть docker-compose.yml.

Том ./log:/var/log/remnanode дописывается в docker-compose.yml (нода: container_name: remnanode). Рядом с compose создаётся каталог ./log.

При вставке полного docker-compose в setup: после вставки нажмите Enter, затем Ctrl+D (иначе длинная строка SECRET_KEY может не прочитаться целиком).

В конфиге Xray (профиль на панели) для записи в контейнер укажите пути логов в /var/log/remnanode/
(см. раздел Node Logs в документации Remnawave: https://remna.st/docs/install/remnawave-node ).

Ротация: при setup (если LOGROTATE_SETUP=1) настраивается logrotate; каталог логов может
отсутствовать — в конфиге указано missingok, ошибок от cron не будет.
EOF
}

die() { echo "Ошибка: $*" >&2; exit 1; }

# Выполнить команду от root при необходимости (запись в /etc).
run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# Абсолютный путь к каталогу логов на хосте (рядом с docker-compose.yml).
absolute_host_log_dir() {
  local compose_dir="$1"
  echo "$(cd "$compose_dir" && pwd -P)/${LOG_MOUNT_HOST#./}"
}

# Содержимое stanza для logrotate (пишется в /etc/logrotate.d/).
generate_logrotate_stanza() {
  local abs_logs="$1"
  {
    echo "# ${LOGROTATE_FILE_MARKER}"
    echo "# --- remnanode.sh: ротация логов ноды (access/error в контейнере → *.log здесь) ---"
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
    # noninteractive — без диалогов при автоматическом запуске
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

# Убедиться, что в PATH есть logrotate (при желании — установить).
ensure_logrotate_available() {
  command -v logrotate >/dev/null 2>&1 && return 0
  [[ "${LOGROTATE_TRY_INSTALL}" == "1" ]] || return 1
  echo "Пакет logrotate не найден, пробуем установить…" >&2
  if ! install_logrotate_package; then
    echo "Не удалось установить logrotate вручную: apt install logrotate / dnf install logrotate и т.п." >&2
    return 1
  fi
  command -v logrotate >/dev/null 2>&1
}

# Записать конфиг в /etc/logrotate.d/ для каталога логов этой ноды.
setup_logrotate_for_dir() {
  local compose_dir="$1"

  [[ "${LOGROTATE_SETUP}" == "1" ]] || return 0

  local abs_log
  abs_log="$(absolute_host_log_dir "$compose_dir")"
  local conf_path="/etc/logrotate.d/${LOGROTATE_CONF_NAME}"

  if ! ensure_logrotate_available; then
    echo "Пропуск настройки logrotate (нет пакета или sudo)." >&2
    return 0
  fi

  if [[ ! -d /etc/logrotate.d ]]; then
    echo "Нет каталога /etc/logrotate.d — типично это не Linux-сервер; пропуск." >&2
    return 0
  fi

  local tmp
  tmp="$(mktemp)" || return 0
  generate_logrotate_stanza "$abs_log" >"$tmp"

  if ! run_as_root tee "$conf_path" <"$tmp" >/dev/null; then
    echo "Не удалось записать $conf_path (нужны права root/sudo)." >&2
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  run_as_root chmod 0644 "$conf_path" 2>/dev/null || true

  echo "Logrotate: записан $conf_path для $abs_log/*.log (rotate=${LOGROTATE_ROTATE}, size=${LOGROTATE_SIZE})." >&2
  verify_logrotate_will_run "$conf_path"
  return 0
}

# Убедиться, что конфиг валиден и что по системе logrotate реально вызывается по расписанию.
verify_logrotate_will_run() {
  local conf_path="${1:-}"

  # 1) Синтаксис и применимость нашего файла (root видит тот же logrotate, что и cron)
  if [[ -n "$conf_path" && -f "$conf_path" ]]; then
    if run_as_root logrotate -d "$conf_path" >/dev/null 2>&1; then
      echo "Logrotate: проверка OK — «logrotate -d $conf_path» завершился успешно." >&2
    else
      echo "Внимание: «logrotate -d $conf_path» завершился с ошибкой — ротация может не сработать; смотрите вывод: sudo logrotate -d $conf_path" >&2
    fi
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "Logrotate (macOS): системное расписание не проверяется; при необходимости добавьте в crontab вызов logrotate с путём к конфигу." >&2
    return 0
  fi

  local scheduler_ok=0
  local timer_unit=""

  # 2) systemd: таймер logrotate (Debian 12+, Ubuntu 24+, часть RHEL/Fedora)
  if command -v systemctl >/dev/null 2>&1; then
    for timer_unit in /usr/lib/systemd/system/logrotate.timer /lib/systemd/system/logrotate.timer /etc/systemd/system/logrotate.timer; do
      if [[ -f "$timer_unit" ]]; then
        if systemctl is-enabled --quiet logrotate.timer 2>/dev/null || systemctl is-active --quiet logrotate.timer 2>/dev/null; then
          echo "Logrotate: systemd — logrotate.timer включён или сейчас активен (расписание есть)." >&2
          scheduler_ok=1
        else
          echo "Внимание: найден logrotate.timer, но unit не enabled/active. Включите: sudo systemctl enable --now logrotate.timer" >&2
        fi
        break
      fi
    done
  fi

  # 3) Классика: ежедневный cron (пакет logrotate подключает скрипт)
  if [[ -f /etc/cron.daily/logrotate ]]; then
    echo "Logrotate: найден /etc/cron.daily/logrotate (ежедневный запуск через cron)." >&2
    scheduler_ok=1
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null; then
        echo "Logrotate: сервис cron или crond сейчас active — ежедневные задания должны выполняться." >&2
      else
        echo "Внимание: cron/crond не в состоянии active — /etc/cron.daily/ может не отрабатывать. Проверьте: sudo systemctl status cron" >&2
      fi
    fi
  fi

  # 4) Alpine и подобные: busybox/openrc periodic
  if [[ -f /etc/periodic/daily/logrotate ]]; then
    echo "Logrotate: найден /etc/periodic/daily/logrotate (Alpine/periodic)." >&2
    scheduler_ok=1
  fi

  if [[ "$scheduler_ok" -eq 0 ]]; then
    echo "Внимание: не обнаружен ни logrotate.timer, ни /etc/cron.daily/logrotate, ни periodic/daily — автоматическая ротация, возможно, не настроена." >&2
    echo "  Проверьте вручную: ls /lib/systemd/system/logrotate.timer /etc/cron.daily/logrotate 2>/dev/null; sudo systemctl status logrotate.timer" >&2
  fi
}

compose_dir_from_state() {
  if [[ -n "${REMNANODE_COMPOSE_DIR:-}" ]]; then
    echo "${REMNANODE_COMPOSE_DIR}"
    return
  fi
  if [[ -f "$STATE_FILE" ]]; then
    local d
    d="$(tr -d '\r\n' <"$STATE_FILE" | sed 's/[[:space:]]*$//')"
    [[ -n "$d" ]] && echo "$d"
  fi
}

find_compose_dir() {
  local d
  d="$(compose_dir_from_state)"
  if [[ -n "$d" && -f "$d/docker-compose.yml" ]]; then
    echo "$d"
    return
  fi
  if [[ -f "$PWD/docker-compose.yml" ]]; then
    echo "$PWD"
    return
  fi
  if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    echo "$SCRIPT_DIR"
    return
  fi
  die "Не найден docker-compose.yml. Запустите: $SCRIPT_NAME setup"
}

save_compose_dir() {
  local d="$1"
  printf '%s\n' "$d" >"$STATE_FILE"
}

is_remnanode_compose_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -qiE '^[[:space:]]*container_name:[[:space:]]*["'\'']?remnanode["'\'']?[[:space:]]*(#.*)?$' "$f"
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

# Дописывает volumes в сервис с container_name: remnanode (только bash).
ensure_log_volume_in_compose() {
  local main="$1"
  has_log_mount_in_file "$main" && return 0
  is_remnanode_compose_file "$main" || die "В $main не найден container_name: remnanode — не правлю чужой compose."

  compose_load_lines "$main"
  local n=${#_remnanode_sh_lines[@]}
  ((n > 0)) || die "Пустой $main"

  local idx="" i j k m ins last_vol vol_idx="" _ln
  shopt -s nocasematch
  for ((i = 0; i < n; i++)); do
    if [[ "${_remnanode_sh_lines[i]}" =~ ^[[:space:]]*container_name:[[:space:]]*[\"']?remnanode[\"']?[[:space:]]*(#.*)?$ ]]; then
      idx=$i
      break
    fi
  done
  shopt -u nocasematch
  [[ -n "$idx" ]] || die "Не найден container_name: remnanode"

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
    ((k = vol_idx + 1))
    while ((k < svc_end)); do
      _ln="${_remnanode_sh_lines[k]}"
      if [[ "${_ln}" =~ ^[[:space:]]{4}[a-zA-Z0-9_-]+: ]]; then
        break
      fi
      if [[ "${_ln}" =~ ^[[:space:]]{6}-[[:space:]] ]]; then
        last_vol=$k
      fi
      ((k++))
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
      ((ins--)) || true
    done
    for ((m = 0; m < n; m++)); do
      new_lines+=("${_remnanode_sh_lines[m]}")
      if ((m == ins)); then
        new_lines+=("    volumes:")
        new_lines+=("$insert_line")
      fi
    done
  fi

  local tmp="${main}.tmp.$$"
  printf '%s\n' "${new_lines[@]}" >"$tmp" || die "Не удалось записать $tmp"
  mv -f "$tmp" "$main" || die "Не удалось заменить $main"
  unset _remnanode_sh_lines
  echo "В docker-compose.yml добавлен том: ${LOG_MOUNT_LINE}"
}

# Каталог логов на хосте: относительно каталога с docker-compose.yml (./log).
ensure_log_dir() {
  local base="${1:-.}"
  local path="${base}/${LOG_MOUNT_HOST#./}"
  if mkdir -p "${path}" 2>/dev/null; then
    return 0
  fi
  echo "Не удалось создать ${path}." >&2
}

looks_like_compose_yaml() {
  local t="$1"
  grep -qE '(^|[[:space:]])(services:|image:[[:space:]]*remnawave/node|remnanode:)' <<<"$t"
}

normalize_pasted_secret_or_compose() {
  local t="$1"
  if grep -qE '(^|[[:space:]])(services:|image:[[:space:]]*remnawave/node|remnanode:)' <<<"$t"; then
    printf '%s' "$t"
    return
  fi
  local flat
  flat="$(echo "$t" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ "$flat" =~ ^SECRET_KEY[[:space:]]*=[[:space:]]* ]]; then
    flat="${flat#SECRET_KEY}"
    flat="$(echo "$flat" | sed 's/^[[:space:]]*=[[:space:]]*//')"
    flat="${flat#\"}"
    flat="${flat%\"}"
    flat="${flat#\'}"
    flat="${flat%\'}"
    printf '%s\n' "$flat"
    return
  fi
  printf '%s' "$t"
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
  echo "SECRET_KEY — одна строка, затем Enter (без Ctrl+D)." >&2
  echo "Docker-compose — вставьте весь YAML (можно одним вставлением с первой строки services:)." >&2
  echo "Когда вставка закончилась, нажмите Enter и затем Ctrl+D — иначе очень длинная строка SECRET_KEY может обрезаться из‑за таймаута терминала." >&2
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

write_minimal_compose() {
  local out="$1"
  local secret="$2"
  local port="$3"
  cat >"$out" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
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
  r="$(echo "${r:-$q}" | tr '[:upper:]' '[:lower:]')"
  [[ "$r" == "y" || "$r" == "yes" || "$r" == "д" || "$r" == "да" ]]
}

setup_interactive() {
  local work_root="$PWD"
  local compose_file=""
  local target_dir=""
  local use_existing=false

  if [[ -f "$work_root/docker-compose.yml" ]]; then
    if is_remnanode_compose_file "$work_root/docker-compose.yml"; then
      if prompt_yes_no "Найден docker-compose.yml ноды Remnawave (container_name: remnanode) в $(pwd). Использовать его?" y; then
        compose_file="$work_root/docker-compose.yml"
        target_dir="$work_root"
        use_existing=true
      fi
    else
      echo "В $(pwd) есть docker-compose.yml, но без container_name: remnanode — не compose этой ноды; пропускаем." >&2
    fi
  fi

  if ! $use_existing; then
    echo "Нужен конфиг из панели Remnawave (кнопка «Copy docker-compose.yml») или только SECRET_KEY."
    local pasted
    read_secret_or_compose
    pasted="${REMNANODE_PASTED:-}"
    unset REMNANODE_PASTED
    [[ -n "${pasted//[$'\t\n\r ']/}" ]] || die "Пустой ввод."
    pasted="$(normalize_pasted_secret_or_compose "$pasted")"

    if looks_like_compose_yaml "$pasted"; then
      target_dir="$work_root/remnanode"
      mkdir -p "$target_dir"
      printf '%s\n' "$pasted" >"$target_dir/docker-compose.yml"
      compose_file="$target_dir/docker-compose.yml"
      is_remnanode_compose_file "$compose_file" || die "Вставленный YAML не похож на ноду Remnawave: нужна строка container_name: remnanode."
      echo "Записан $compose_file"
    elif looks_like_secret_only "$pasted"; then
      local sk port
      sk="$(echo "$pasted" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      read -r -p "NODE_PORT из панели [Enter — по умолчанию 2222]: " port || true
      port="$(echo "${port:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "$port" ]] || port="2222"
      target_dir="$work_root/remnanode"
      mkdir -p "$target_dir"
      # SECRET_KEY в кавычках, если пользователь не обернул
      if [[ "$sk" =~ ^\".*\"$ ]]; then
        :
      else
        sk="\"${sk//\"/\\\"}\""
      fi
      write_minimal_compose "$target_dir/docker-compose.yml" "$sk" "$port"
      compose_file="$target_dir/docker-compose.yml"
      echo "Создан минимальный $compose_file (проверьте NODE_PORT и образ при необходимости)."
    else
      die "Не удалось распознать ввод: ожидается YAML compose или одна строка SECRET_KEY."
    fi

    # Перенос скрипта в remnanode/ (если ещё не там; не создаём «лишний» compose — только из панели / SECRET_KEY)
    local src_abs
    src_abs="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)/$(basename "$SCRIPT_PATH")"
    local dest_script="$target_dir/$SCRIPT_NAME"
    if [[ "$SCRIPT_DIR" != "$target_dir" ]] && [[ "$src_abs" != "$dest_script" ]]; then
      if mv -f "$src_abs" "$dest_script" 2>/dev/null || cp -f "$src_abs" "$dest_script"; then
        chmod +x "$dest_script" 2>/dev/null || true
        echo "Скрипт перенесён в $dest_script (запускайте оттуда)."
        SCRIPT_PATH="$dest_script"
        SCRIPT_DIR="$target_dir"
        STATE_FILE="$SCRIPT_DIR/.remnanode_compose_dir"
      fi
    fi
  fi

  [[ -n "$compose_file" && -f "$compose_file" ]] || die "Нет docker-compose.yml."
  target_dir="$(cd "$(dirname "$compose_file")" && pwd -P)"

  ensure_log_dir "$target_dir"
  ensure_log_volume_in_compose "$target_dir/docker-compose.yml"
  save_compose_dir "$target_dir"

  # Ротация логов на хосте; при сбое (нет sudo и т.д.) setup всё равно продолжается
  setup_logrotate_for_dir "$target_dir" || true

  cd "$target_dir" || die "Не удалось перейти в $target_dir"
  docker compose config >/dev/null || die "docker compose config: проверьте синтаксис YAML."

  echo "Запуск: docker compose up -d && docker compose logs -f -t"
  docker compose up -d
  docker compose logs -f -t
}

cmd_start() {
  local d
  d="$(find_compose_dir)"
  cd "$d" || exit 1
  docker compose up -d
}

cmd_stop() {
  local d
  d="$(find_compose_dir)"
  cd "$d" || exit 1
  docker compose down
}

cmd_log() {
  local d
  d="$(find_compose_dir)"
  cd "$d" || exit 1
  docker compose logs -f -t
}

cmd_logrotate_setup() {
  local d
  d="$(find_compose_dir)"
  setup_logrotate_for_dir "$d" || true
}

# Повторная проверка без перезаписи /etc/logrotate.d/ (после systemctl enable и т.п.).
cmd_logrotate_check() {
  local conf_path="/etc/logrotate.d/${LOGROTATE_CONF_NAME}"
  if [[ ! -f "$conf_path" ]]; then
    echo "Нет файла $conf_path — сначала: $SCRIPT_NAME logrotate-setup" >&2
    exit 1
  fi
  verify_logrotate_will_run "$conf_path"
}

# Файл создан этим скриптом (маркер или старый комментарий до появления маркера).
logrotate_file_is_managed_by_script() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -qF "${LOGROTATE_FILE_MARKER}" "$f" 2>/dev/null && return 0
  grep -qF "remnanode.sh: ротация логов ноды" "$f" 2>/dev/null
}

# Убрать из системы единственное изменение logrotate от этого скрипта — drop-in в /etc/logrotate.d/.
# Пакет logrotate не удаляем (им могут пользоваться другие службы).
# Аргумент $1: пусто — спросить; -y или --yes — удалить без вопроса.
cmd_logrotate_revert() {
  local conf_path="/etc/logrotate.d/${LOGROTATE_CONF_NAME}"
  local force="${1:-}"

  if [[ ! -f "$conf_path" ]]; then
    echo "Файл $conf_path не найден — следов этого скрипта в logrotate.d нет." >&2
    exit 0
  fi

  if ! logrotate_file_is_managed_by_script "$conf_path"; then
    echo "Файл $conf_path не содержит маркера ${LOGROTATE_FILE_MARKER} (и не похож на старый конфиг скрипта) — удаление отменено, чтобы не снести чужой файл." >&2
    echo "Если это всё же ваш файл скрипта, удалите вручную: sudo rm $conf_path" >&2
    exit 1
  fi

  if [[ "$force" != "-y" && "$force" != "--yes" ]]; then
    if ! prompt_yes_no "Удалить $conf_path? Пакет logrotate в системе останется." n; then
      echo "Отмена." >&2
      exit 0
    fi
  fi

  if ! run_as_root rm -f "$conf_path"; then
    die "Не удалось удалить $conf_path (нужен sudo)."
  fi
  echo "Удалён $conf_path. Пакет logrotate не удалялся." >&2
}

cmd_du() {
  local d logpath
  d="$(find_compose_dir)"
  logpath="${d}/${LOG_MOUNT_HOST#./}"
  if [[ ! -d "$logpath" ]]; then
    echo "Папка логов не найдена: $logpath"
    exit 0
  fi
  echo "Каталог: $logpath"
  du -sh "$logpath" 2>/dev/null || du -sh "$logpath"
  echo "--- Файлы ---"
  du -ah "$logpath" 2>/dev/null | sort -h || true
}

main() {
  local cmd="${1:-setup}"
  case "$cmd" in
    -h|--help|help)
      usage
      ;;
    start)
      cmd_start
      ;;
    stop)
      cmd_stop
      ;;
    log|logs)
      cmd_log
      ;;
    du)
      cmd_du
      ;;
    logrotate-setup)
      cmd_logrotate_setup
      ;;
    logrotate-check)
      cmd_logrotate_check
      ;;
    logrotate-revert)
      cmd_logrotate_revert "${2:-}"
      ;;
    setup|install|"")
      setup_interactive
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
