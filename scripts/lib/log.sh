#!/usr/bin/env bash
# Лог прогона: событие — строка JSONL, тяжёлый вывод — отдельным файлом.
#
# schema_version в каждой строке: формат будет меняться, а разбор старых
# прогонов ломаться не должен.
#
# Метрики генератора читаются защитно (// null). По документации в JSON есть
# total_cost_usd, num_turns, session_id и subtype, но живым вызовом состав
# не проверялся — отсутствующее поле не повод ронять прогон.

log_event() {
  local run_dir="${1:?log_event <run_dir> <task_id> <phase> <event> [payload-json]}"
  local task="${2:?task_id}" phase="${3:?phase}" event="${4:?event}" payload="${5:-}"
  [ -n "$payload" ] || payload='{}'
  mkdir -p "$run_dir"
  jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg task "$task" --arg phase "$phase" --arg event "$event" \
    --argjson payload "$payload" \
    '{ts: $ts, task_id: $task, phase: $phase, event: $event,
      schema_version: 1, author: "orchestrator", payload: $payload}' \
    >> "$run_dir/events.jsonl"
}

# Путь под полный stdout фазы. В JSONL уходит путь, не содержимое:
# вывод генератора бывает мегабайтами, а лог должен оставаться разбираемым.
log_phase_stdout() {
  local run_dir="${1:?log_phase_stdout <run_dir> <phase>}" phase="${2:?phase}"
  mkdir -p "$run_dir/stdout"
  printf '%s\n' "$run_dir/stdout/$phase.log"
}

# Разбор результата генератора. Три исхода вместо одного:
# пустой вывод, неразбираемый вывод, разобранные метрики.
# Пустота — документированный отказ headless-режима, а не аномалия.
log_generator_result() {
  local run_dir="${1:?log_generator_result <run_dir> <task_id> <result-file> [phase]}"
  local task="${2:?task_id}" file="${3:?result-file}" phase="${4:-implement}"
  local payload

  if [ ! -s "$file" ]; then
    payload="$(jq -cn --arg p "$file" '{path: $p}')"
    log_event "$run_dir" "$task" "$phase" result-empty "$payload"
    return 0
  fi

  if ! jq -e . "$file" >/dev/null 2>&1; then
    payload="$(jq -cn --arg p "$file" \
      --arg head "$(head -c 200 "$file" | tr -d '\000')" \
      '{path: $p, head: $head}')"
    log_event "$run_dir" "$task" "$phase" result-unparseable "$payload"
    return 0
  fi

  payload="$(jq -c '{cost_usd: (.total_cost_usd // null),
                     turns: (.num_turns // null),
                     session_id: (.session_id // null),
                     subtype: (.subtype // null),
                     is_error: (.is_error // null)}' "$file")"
  log_event "$run_dir" "$task" "$phase" result "$payload"
}
