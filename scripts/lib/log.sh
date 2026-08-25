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

  # Файл целиком парсится не всегда: живой прогон 25.08 показал, что
  # claude печатает предупреждение о недоверенном workspace ДО json, а хук
  # инстанса — сообщение ПОСЛЕ. Строка результата при этом на месте, и вместе
  # с ней терялась стоимость прогона. Берём последнюю json-строку файла.
  local json_line="" line
  if ! jq -e . "$file" >/dev/null 2>&1; then
    while IFS= read -r line; do
      # отсев по первому символу: гонять jq на каждой строке лога дороже
      case "$line" in
        '{'*) printf '%s' "$line" | jq -e . >/dev/null 2>&1 && json_line="$line" ;;
      esac
    done < "$file"
    # Ни одной json-строки — генератор упал, и это не «успех без метрик».
    if [ -z "$json_line" ]; then
      payload="$(jq -cn --arg p "$file" \
        --arg head "$(head -c 200 "$file" | tr -d '\000')" \
        '{path: $p, head: $head}')"
      log_event "$run_dir" "$task" "$phase" result-unparseable "$payload"
      return 0
    fi
  fi

  # Плейн-доступ, не оператор //: jq считает false пустым значением, и
  # `.is_error // null` превратил бы штатный false в null. Отсутствующий ключ
  # jq и без оператора отдаёт null.
  local expr='{cost_usd: .total_cost_usd,
               turns: .num_turns,
               session_id: .session_id,
               subtype: .subtype,
               is_error: .is_error}'
  if [ -n "$json_line" ]; then
    # noisy_stdout остаётся в записи: зашумлённый вывод — сам по себе находка
    # про среду прогона, и молча вычищать её из лога нельзя.
    payload="$(printf '%s' "$json_line" | jq -c "$expr + {noisy_stdout: true}")"
  else
    payload="$(jq -c "$expr" "$file")"
  fi
  log_event "$run_dir" "$task" "$phase" result "$payload"
}
