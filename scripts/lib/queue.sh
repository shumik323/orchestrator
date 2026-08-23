#!/usr/bin/env bash
# Состояние очереди. Библиотека: при source ничего не выполняет.
#
# Единственный писатель — оркестратор. Любая запись идёт через временный файл
# и mv: читатель видит либо старую версию целиком, либо новую, но никогда
# полуобновлённую. Правка строки на месте такого свойства не даёт.
#
# jq лежит в /usr/bin и доступен даже при PATH=/usr/bin:/bin — guard не нужен.

# shellcheck source=paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

# Готовые к работе: статус ready и все блокеры уже закрыты.
queue_ready() {
  local qf="${1:?queue_ready <queue-file>}"
  jq -rs '
    (map(select(.status == "done") | .id)) as $done
    | map(select(.status == "ready")
          | select((((.blocked_by // []) - $done)) | length == 0)
          | .id)
    | .[]' "$qf"
}

queue_set_status() {
  local qf="${1:?queue_set_status <queue-file> <id> <status>}"
  local id="${2:?id}" st="${3:?status}" tmp
  tmp="$(mktemp "${qf}.XXXXXX")"
  jq -c --arg id "$id" --arg st "$st" \
    'if .id == $id then .status = $st else . end' "$qf" > "$tmp" || {
      rm -f "$tmp"
      printf 'queue_set_status: jq не разобрал очередь, файл не изменён\n' >&2
      return 1
    }
  mv "$tmp" "$qf"
}

# Счётчик попыток. Отсутствующее поле считается нулём: задачи, положенные
# руками, поля attempts не имеют.
queue_bump_attempts() {
  local qf="${1:?queue_bump_attempts <queue-file> <id>}"
  local id="${2:?id}" tmp
  tmp="$(mktemp "${qf}.XXXXXX")"
  jq -c --arg id "$id" \
    'if .id == $id then .attempts = ((.attempts // 0) + 1) else . end' "$qf" > "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  mv "$tmp" "$qf"
}

# Добавление с защитой от дублей по хэшу промпта.
# Дубль ищется только среди незакрытых задач: повторить однажды закрытую
# работу — законно, а вот положить ту же задачу дважды в один прогон — нет.
# Практика: у единственного близкого по стеку раннера дедуп сделан так же.
queue_add() {
  local qf="${1:?queue_add <queue-file> <id> <title> <body>}"
  local id="${2:?id}" title="${3:?title}" body="${4:?body}"
  local hash existing tmp
  hash="$(printf '%s\n%s' "$title" "$body" | orc_prompt_hash)"

  existing="$(jq -rs --arg h "$hash" '
    map(select((.prompt_hash // "") == $h)
        | select(.status == "ready" or .status == "running" or .status == "blocked")
        | .id)
    | .[]' "$qf" 2>/dev/null || printf '')"

  if [ -n "$existing" ]; then
    printf 'дубль промпта: задача %s уже в очереди (hash %s)\n' "$existing" "$hash" >&2
    return 3
  fi

  tmp="$(mktemp "${qf}.XXXXXX")"
  cat "$qf" > "$tmp"
  jq -cn --arg id "$id" --arg t "$title" --arg b "$body" --arg h "$hash" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{id: $id, title: $t, body: $b, status: "ready", blocked_by: [],
      attempts: 0, prompt_hash: $h, schema_version: 1, created: $ts}' >> "$tmp"
  mv "$tmp" "$qf"
  printf '%s\n' "$id"
}
