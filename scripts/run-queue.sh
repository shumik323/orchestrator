#!/usr/bin/env bash
# Прогон очереди без человека: берёт ready-задачи по одной (блокеры учитывает queue_ready),
# гоняет run-task.sh, идёт дальше. Стоп — когда ready пуст или MAX_FAILS сбоев подряд:
# серия красных гейтов почти всегда одна причина (среда, база), дальше жечь бюджет нет смысла.
#
# Usage: scripts/run-queue.sh <project-conf> [max-fails=2]
# Итог — таблица статусов в stdout и код 0 (очередь пуста) / 1 (остановлен по сбоям).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORC_ROOT="${ORC_ROOT:-$(cd "$HERE/.." && pwd)}"
export ORC_ROOT
# shellcheck source=lib/paths.sh
. "$HERE/lib/paths.sh"
# shellcheck source=lib/queue.sh
. "$HERE/lib/queue.sh"

conf="${1:?использование: run-queue.sh <project-conf> [max-fails]}"
max_fails="${2:-2}"
[ -f "$conf" ] || { printf 'run-queue: нет конфига %s\n' "$conf" >&2; exit 2; }

qf="$(sed -n 's/^QUEUE_FILE="\(.*\)"$/\1/p' "$conf" | head -n 1)"
qf="$(eval "printf '%s' \"$qf\"")"
[ -f "$qf" ] || { printf 'run-queue: нет очереди %s (QUEUE_FILE в %s)\n' "$qf" "$conf" >&2; exit 2; }

fails=0; ran=0; started="$(date +%s)"
while :; do
  next="$(queue_ready "$qf" | head -n 1)"
  [ -n "$next" ] || break
  printf '\n=== run-queue: %s (%s) ===\n' "$next" "$(date '+%H:%M:%S')"
  if bash "$HERE/run-task.sh" "$conf" "$next"; then
    fails=0
  else
    fails=$((fails + 1))
    printf 'run-queue: %s не прошёл (%d подряд)\n' "$next" "$fails" >&2
  fi
  ran=$((ran + 1))
  if [ "$fails" -ge "$max_fails" ]; then
    printf 'run-queue: %d сбоя подряд — стоп, разбор владельцем\n' "$fails" >&2
    break
  fi
done

printf '\n=== run-queue: итог, задач %d, %d мин ===\n' "$ran" "$(( ($(date +%s) - started) / 60 ))"
jq -r '[.id, .status, (.attempts // 0 | tostring)] | @tsv' "$qf" | column -t
[ "$fails" -lt "$max_fails" ]
