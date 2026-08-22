#!/usr/bin/env bash
# Локальный bare-remote с гардрейлом push.
#
# Заменяет protected branch платформы на время слоя 0: тот же наблюдаемый
# эффект, ноль токенов и ноль сети. Чего мок не проверяет — токены, rate limit,
# секретную поверхность CI — записано в плане слоя 0, раздел «Долг мока».
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dest="${1:-}"
if [ -z "$dest" ]; then
  printf 'использование: make-remote.sh <путь-к-bare> [защищённая-ветка...]\n' >&2
  exit 2
fi
shift

if [ "$#" -gt 0 ]; then
  protected="$*"
  # пустая строка аргументом обнуляла список, и хук пропускал push в main:
  # git config --get отдаёт пустое значение с кодом 0, фолбэк не срабатывал
  if [ -z "$(printf '%s' "$protected" | tr -d '[:space:]')" ]; then
    printf 'make-remote.sh: список защищённых веток пуст — так гардрейл выключается молча\n' >&2
    exit 2
  fi
else
  protected="main master"
fi

git init --bare -q "$dest"
install -m 0755 "$HERE/../hooks/pre-receive.sh" "$dest/hooks/pre-receive"
git -C "$dest" config orc.protected "$protected"

printf 'bare создан: %s (защищено: %s)\n' "$dest" "$protected"
