#!/usr/bin/env bash
set -euo pipefail

# Путь для скачивания скрипта
SCRIPT_URL="https://raw.githubusercontent.com/BragiOk/scripts/main/remnanode.sh"
SCRIPT_FILE="remnanode.sh"

echo "Скачиваем скрипт Remnawave Node..."
curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_FILE"

echo "Делаем скрипт исполняемым..."
chmod +x "$SCRIPT_FILE"

echo "Запускаем скрипт..."
./"$SCRIPT_FILE"
