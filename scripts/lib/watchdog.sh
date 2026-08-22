#!/usr/bin/env bash
# Дедлайн на внешнюю команду. Своя реализация, потому что утилиты timeout
# в системе нет — ни timeout, ни gtimeout, ни flock.
#
# Ожидание идёт по файлу с кодом возврата, а не по `kill -0 $pid`: незажатый
# зомби-процесс отвечает на kill -0 успехом до того, как оболочка его пожнёт,
# и опрос по pid давал бы ложный таймаут.
#
# Возврат 124 на истечении дедлайна — как у утилиты timeout, чтобы вызывающий
# отличал «не успел» от любого кода самой команды.

run_with_deadline() {
  local deadline="${1:?run_with_deadline <секунды> <команда...>}"
  shift
  local rcfile pid waited=0 rc
  rcfile="$(mktemp)"

  ( "$@"; printf '%s' "$?" > "$rcfile" ) &
  pid=$!

  while [ ! -s "$rcfile" ]; do
    if [ "$waited" -ge "$deadline" ]; then
      # сначала внуки, потом сам подшелл: claude -p живёт грандчайлдом,
      # и убитый только подшелл оставил бы его держать каталог и квоту
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$rcfile"
      return 124
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done

  wait "$pid" 2>/dev/null || true
  rc="$(cat "$rcfile")"
  rm -f "$rcfile"
  return "$rc"
}
