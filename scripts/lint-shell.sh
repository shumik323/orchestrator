#!/usr/bin/env bash
# Гейт: shellcheck по всем скриптам с порогом info и ratchet-порогом.
#
# Формат gcc — ровно одна находка на строку. Человекочитаемый вывод даёт ложный
# счёт: код упоминается и в футере, и внутри текста директив disable.
# Обнаружение файлов — глобом, не через git ls-files: в репозитории может не быть
# ни одного коммита, и тогда ls-files молча пуст, а гейт зелен на пустоте.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_FILE="${SC_BASELINE_FILE:-$ROOT/scripts/lint-shellcheck.baseline}"

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'ДЕГРАДАЦИЯ: shellcheck не найден в PATH, проверка не выполнена\n' >&2
  exit 1
fi

baseline="$(cat "$BASELINE_FILE" 2>/dev/null || printf '')"
case "$baseline" in
  ''|*[!0-9]*)
    printf 'порог не число: "%s" в %s\n' "$baseline" "$BASELINE_FILE" >&2
    exit 2 ;;
esac

files=""
for f in "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/*.sh "$ROOT"/hooks/*.sh; do
  [ -f "$f" ] && files="$files $f"
done

count=0
found=""
if [ -n "$files" ]; then
  # shellcheck disable=SC2086
  # список путей разворачивается словами намеренно — пробелов в путях репозитория нет
  found="$(shellcheck -x --source-path=SCRIPTDIR -S info --format=gcc $files 2>/dev/null || true)"
  # grep -c на нуле совпадений печатает 0 и выходит с 1: отсутствие находок — ответ, не ошибка
  count="$(printf '%s' "$found" | grep -c . || true)"
fi

if [ "$count" -gt "$baseline" ]; then
  printf '%s\n' "$found" >&2
  printf 'гейт красный: находок %s, порог %s\n' "$count" "$baseline" >&2
  exit 1
fi
if [ "$count" -lt "$baseline" ]; then
  printf 'порог можно опустить: находок %s < порога %s → обновить %s\n' \
    "$count" "$baseline" "$BASELINE_FILE"
fi
printf 'lint-shell: зелёный (находок %s, порог %s)\n' "$count" "$baseline"
