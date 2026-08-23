#!/usr/bin/env bash
# Живой вывод раннера.
#
# Прогресс идёт в stderr, а не в stdout: stdout остаётся машиночитаемым —
# там только «MR: путь». Цвет гаснет, когда stderr не терминал: иначе
# escape-последовательности уезжают в лог, и разбор провала читает мусор.
#
# Время фаз — из $SECONDS, а не date +%N: под урезанным PATH BSD-date
# отдаёт литерал N вместо наносекунд.

# NO_COLOR — стандартный опт-аут пользователя, он сильнее принудительного
# включения. UI_FORCE_COLOR нужен, когда stderr не терминал, но цвет всё равно
# уместен: вывод в less -R, цветной CI, тест на само включение.
if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ]; then
  UI_RESET='' UI_DIM='' UI_BOLD='' UI_RED='' UI_GREEN='' UI_YELLOW=''
elif [ -n "${UI_FORCE_COLOR:-}" ] || [ -t 2 ]; then
  UI_RESET=$'\033[0m'
  UI_DIM=$'\033[2m'
  UI_BOLD=$'\033[1m'
  UI_RED=$'\033[31m'
  UI_GREEN=$'\033[32m'
  UI_YELLOW=$'\033[33m'
else
  UI_RESET='' UI_DIM='' UI_BOLD='' UI_RED='' UI_GREEN='' UI_YELLOW=''
fi

UI_T0="$SECONDS"
UI_PHASE_T0="$SECONDS"

ui_task() {
  UI_T0="$SECONDS"
  printf '%s▶ задача %s%s  %s%s%s\n' \
    "$UI_BOLD" "${1:-?}" "$UI_RESET" "$UI_DIM" "${2:-}" "$UI_RESET" >&2
}

ui_phase() {
  UI_PHASE_T0="$SECONDS"
  printf '%s  ├─ %s …%s\n' "$UI_DIM" "${1:-фаза}" "$UI_RESET" >&2
}

ui_ok() {
  printf '%s  │  ✓%s %s %s(%sс)%s\n' \
    "$UI_GREEN" "$UI_RESET" "${1:-}" "$UI_DIM" "$((SECONDS - UI_PHASE_T0))" "$UI_RESET" >&2
}

ui_info() {
  printf '%s  │  ·%s %s\n' "$UI_DIM" "$UI_RESET" "${1:-}" >&2
}

ui_warn() {
  printf '%s  │  !%s %s\n' "$UI_YELLOW" "$UI_RESET" "${1:-}" >&2
}

ui_fail() {
  printf '%s  ╰─ ✗ %s%s %s(всего %sс)%s\n' \
    "$UI_RED" "${1:-}" "$UI_RESET" "$UI_DIM" "$((SECONDS - UI_T0))" "$UI_RESET" >&2
}

ui_done() {
  printf '%s  ╰─ ✓ %s%s %s(всего %sс)%s\n' \
    "$UI_GREEN" "${1:-}" "$UI_RESET" "$UI_DIM" "$((SECONDS - UI_T0))" "$UI_RESET" >&2
}
