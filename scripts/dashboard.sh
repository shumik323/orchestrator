#!/bin/sh
# Живой дашборд прогонов: страница + scripts/dashboard-server.py (статика из корня репозитория и
# два действия: запустить задачу, вернуть в ready).
# Данные — queue/*.jsonl, mr/*.md и state/ (симлинк на $ORC_STATE, по умолчанию ~/.orchestrator):
# страница опрашивает их раз в 2 с. Кнопки бьют в /api/run и /api/ready того же сервера.
# Использование: ./scripts/dashboard.sh [порт]   (по умолчанию 8765)
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
state="${ORC_STATE:-$HOME/.orchestrator}"
port="${1:-8765}"
[ -e "$root/state" ] || ln -s "$state" "$root/state"
[ "$(readlink "$root/state")" = "$state" ] || { printf 'dashboard: %s/state указывает не на %s\n' "$root" "$state" >&2; exit 1; }
command -v python3 >/dev/null || { printf 'dashboard: нужен python3\n' >&2; exit 1; }
exec python3 "$root/scripts/dashboard-server.py" "$port"
