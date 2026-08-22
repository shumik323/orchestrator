#!/usr/bin/env bash
# Серверная сторона запрета. Инструкция в промпте обходится инъекцией или
# спутавшимся контекстом, настройка на стороне git-сервера — нет.
#
# Три инварианта: защищённая ветка не принимает push, ветка не удаляется,
# история не перезаписывается. Детекция залипания здесь НЕ живёт — у зрелых
# реализаций гейт пуша и вотчдог разнесены по разным компонентам.
#
# set -e не ставим: в хуке штатно-неуспешные команды (merge-base) — это ответ,
# а не ошибка, и падение по -e превратило бы отказ в непонятный сбой.
set -u

protected="$(git config --get orc.protected 2>/dev/null || printf '')"
# git config --get отдаёт пустую строку с кодом 0, поэтому проверять надо
# значение, а не код возврата: иначе пустой конфиг = отключённый хук
[ -n "$protected" ] || protected="main master"
status=0

# Нулевой хэш означает создание или удаление ссылки. Длина хэша не фиксируется:
# репозиторий может быть на sha256, где нулей 64, а не 40.
is_zero() {
  case "$1" in
    *[!0]*) return 1 ;;
    *) return 0 ;;
  esac
}

while read -r old new ref; do
  short="${ref#refs/heads/}"

  # список ветвей разворачивается словами намеренно
  # shellcheck disable=SC2086
  for p in $protected; do
    if [ "$short" = "$p" ]; then
      printf 'pre-receive: ветка %s защищена — раннер открывает MR, а не пушит в базу\n' "$short" >&2
      status=1
    fi
  done

  if is_zero "$new"; then
    printf 'pre-receive: удаление ветки %s запрещено\n' "$short" >&2
    status=1
    continue
  fi

  if ! is_zero "$old" && ! git merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
    printf 'pre-receive: push не fast-forward в %s запрещён — история не перезаписывается\n' "$short" >&2
    status=1
  fi
done

exit "$status"
