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
    (map(select(.status == "done" or .status == "no-change") | .id)) as $done
    | map(select(.status == "ready")
          | select((((.blocked_by // []) - $done)) | length == 0)
          | .id)
    | .[]' "$qf"
}

# Состояния Work и разрешённые переходы.
#
# Статусы различимы по тому, ЧТО делать дальше, а не по тому, где упало:
#   done            работа принята, ветка есть
#   no-change       правка не потребовалась — это исход, а не успех «ничего»
#   gate-failed     агент отработал, проверки красные → перезапуск или доработка
#   scope-violation агент вышел за границы → разбирать промпт и область
#   agent-failed    генератор упал, завис или упёрся в бюджет → перезапуск
#   blocked         системная проблема (клон, push, MR, пустой промпт) → рука человека
#
# Недопустимый переход — явная ошибка, а не тихая правка поля: состояние,
# записанное в обход автомата, делает очередь недостоверной, и дальше система
# врёт о себе молча.
QUEUE_STATES="draft ready running done no-change gate-failed scope-violation agent-failed blocked"

queue_transitions() {
  cat <<'EOF'
draft:ready
ready:running
running:done no-change gate-failed scope-violation agent-failed blocked
gate-failed:ready running
agent-failed:ready running
scope-violation:ready
blocked:ready
EOF
}

queue_status_of() {
  local qf="${1:?queue_status_of <queue-file> <id>}" id="${2:?id}"
  jq -r --arg id "$id" 'select(.id == $id) | .status // empty' "$qf" 2>/dev/null | tail -1
}

queue_is_state() {
  local st="${1:?}" known
  for known in $QUEUE_STATES; do
    [ "$st" = "$known" ] && return 0
  done
  return 1
}

# Повтор того же статуса разрешён: операция идемпотентна.
queue_transition_allowed() {
  local from="${1:?}" to="${2:?}" line allowed st
  [ "$from" = "$to" ] && return 0
  line="$(queue_transitions | grep "^${from}:" || true)"
  [ -n "$line" ] || return 1
  allowed="${line#*:}"
  for st in $allowed; do
    [ "$st" = "$to" ] && return 0
  done
  return 1
}

queue_set_status() {
  local qf="${1:?queue_set_status <queue-file> <id> <status>}"
  local id="${2:?id}" st="${3:?status}" tmp current
  if ! queue_is_state "$st"; then
    printf 'queue_set_status: неизвестный статус "%s"; известны: %s\n' "$st" "$QUEUE_STATES" >&2
    return 3
  fi
  current="$(queue_status_of "$qf" "$id")"
  if [ -z "$current" ]; then
    printf 'queue_set_status: задачи %s нет в очереди\n' "$id" >&2
    return 4
  fi
  if ! queue_transition_allowed "$current" "$st"; then
    printf 'queue_set_status: недопустимый переход %s → %s для %s\n' "$current" "$st" "$id" >&2
    return 3
  fi
  # Лок единственного писателя: read-modify-write без него терял статусы при параллельных
  # прогонах (ревью 20.09: 40 записей → выжило 6). mkdir атомарен, flock на macOS нет.
  local lock="${qf}.lock" waited=0
  until mkdir "$lock" 2>/dev/null; do
    waited=$((waited + 1))
    # Писатель держит лок миллисекунды; лок старше минуты — труп убитого раннера (Ctrl-C,
    # перезагрузка), иначе каждая запись ждала бы 10 с и падала навсегда (ревью 21.09).
    if [ "$waited" -eq 20 ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      printf 'queue_set_status: снят залипший лок %s (старше минуты)\n' "$lock" >&2
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
    if [ "$waited" -gt 100 ]; then
      printf 'queue_set_status: очередь занята дольше 10 с (%s) — запись отменена\n' "$lock" >&2
      return 5
    fi
    sleep 0.1
  done
  # текущее состояние перечитываем под локом: снаружи оно могло смениться
  current="$(queue_status_of "$qf" "$id")"
  if ! queue_transition_allowed "$current" "$st"; then
    rmdir "$lock"
    printf 'queue_set_status: недопустимый переход %s → %s для %s\n' "$current" "$st" "$id" >&2
    return 3
  fi
  tmp="$(mktemp "${qf}.XXXXXX")"
  if ! jq -c --arg id "$id" --arg st "$st" \
    'if .id == $id then .status = $st else . end' "$qf" > "$tmp"; then
      rm -f "$tmp"; rmdir "$lock"
      printf 'queue_set_status: jq не разобрал очередь, файл не изменён\n' >&2
      return 1
  fi
  mv "$tmp" "$qf"
  rmdir "$lock"
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
