# Лог прогона. Имена латиницей — см. scripts/run-bats.sh.
#
# Три последних кейса — про документированный отказ: claude -p, запущенный
# из долгоживущего процесса, умеет не отдать ни байта (issue #56268), а в
# stream-json умеет не завершиться после финального result (#25629).
# Значит «нет вывода» и «вывод не разбирается» — штатные исходы, не исключения.

setup() {
  ORC_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  LIB="$ORC_ROOT/scripts/lib/log.sh"
  RUN="$TMP/run"
}

@test "log_event_writes_schema_versioned_line" {
  run bash -c ". '$LIB'; log_event '$RUN' t1 implement started '{\"attempt\":1}'"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.schema_version' "$RUN/events.jsonl")" = "1" ]
  [ "$(jq -r '.payload.attempt' "$RUN/events.jsonl")" = "1" ]
  [ "$(jq -r '.author' "$RUN/events.jsonl")" = "orchestrator" ]
}

@test "log_event_defaults_payload_to_empty_object" {
  bash -c ". '$LIB'; log_event '$RUN' t1 gate green"
  [ "$(jq -r '.payload | type' "$RUN/events.jsonl")" = "object" ]
}

@test "events_are_appended_not_overwritten" {
  bash -c ". '$LIB'
    log_event '$RUN' t1 implement started
    log_event '$RUN' t1 implement finished
    log_event '$RUN' t1 gate green"
  [ "$(wc -l < "$RUN/events.jsonl" | tr -d ' ')" = "3" ]
}

@test "timeline_is_assembled_by_jq_without_reading_prose" {
  bash -c ". '$LIB'
    log_event '$RUN' t1 implement started
    log_event '$RUN' t1 implement finished
    log_event '$RUN' t1 gate green"
  run jq -rs 'map("\(.phase):\(.event)") | join(" ")' "$RUN/events.jsonl"
  [ "$output" = "implement:started implement:finished gate:green" ]
}

@test "phase_stdout_goes_to_file_not_into_jsonl" {
  out="$(bash -c ". '$LIB'; log_phase_stdout '$RUN' implement")"
  printf 'много строк вывода генератора\n' > "$out"
  [ -f "$out" ]
  bash -c ". '$LIB'; log_event '$RUN' t1 implement finished"
  run grep -c "много строк" "$RUN/events.jsonl"
  [ "$output" = "0" ]
}

@test "generator_result_extracts_cost_and_turns" {
  printf '%s\n' '{"total_cost_usd":0.42,"num_turns":7,"session_id":"abc","subtype":"success"}' \
    > "$TMP/result.json"
  run bash -c ". '$LIB'; log_generator_result '$RUN' t1 '$TMP/result.json'"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.event=="result").payload.cost_usd' "$RUN/events.jsonl")" = "0.42" ]
  [ "$(jq -r 'select(.event=="result").payload.turns' "$RUN/events.jsonl")" = "7" ]
  [ "$(jq -r 'select(.event=="result").payload.subtype' "$RUN/events.jsonl")" = "success" ]
}

@test "generator_result_tolerates_missing_fields" {
  printf '%s\n' '{"result":"ок, но без метрик"}' > "$TMP/result.json"
  run bash -c ". '$LIB'; log_generator_result '$RUN' t1 '$TMP/result.json'"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.event=="result").payload.cost_usd' "$RUN/events.jsonl")" = "null" ]
}

@test "generator_result_marks_unparseable_output" {
  printf 'Segmentation fault\n' > "$TMP/result.json"
  run bash -c ". '$LIB'; log_generator_result '$RUN' t1 '$TMP/result.json'"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.event=="result-unparseable").phase' "$RUN/events.jsonl")" = "implement" ]
}

@test "generator_result_marks_empty_output" {
  : > "$TMP/result.json"
  run bash -c ". '$LIB'; log_generator_result '$RUN' t1 '$TMP/result.json'"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.event=="result-empty").phase' "$RUN/events.jsonl")" = "implement" ]
}

@test "generator_result_preserves_false_is_error" {
  # Оператор // в jq считает false пустым: `.is_error // null` терял штатный false
  printf '%s\n' '{"is_error":false,"num_turns":2}' > "$TMP/result.json"
  bash -c ". '$LIB'; log_generator_result '$RUN' t1 '$TMP/result.json'"
  [ "$(jq -r 'select(.event=="result").payload.is_error' "$RUN/events.jsonl")" = "false" ]
}

# Живой прогон 25.08: claude печатает в stdout предупреждение о недоверенном
# workspace ДО json, а хук инстанса — сообщение ПОСЛЕ. Разбор файла целиком дал
# result-unparseable, и стоимость прогона в лог не попала.
@test "generator_result_finds_json_line_among_noise" {
  {
    printf 'Ignoring 11 permissions.allow entries: workspace has not been trusted\n'
    printf '%s\n' '{"total_cost_usd":0.88,"num_turns":11,"is_error":false,"subtype":"success"}'
    printf 'SessionEnd hook failed: not supported outside REPL\n'
  } > "$TMP/result.json"
  run bash -c ". '$LIB'; log_generator_result '$RUN' t1 '$TMP/result.json'"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.event=="result").payload.cost_usd' "$RUN/events.jsonl")" = "0.88" ]
  [ "$(jq -r 'select(.event=="result").payload.turns' "$RUN/events.jsonl")" = "11" ]
  [ "$(jq -r 'select(.event=="result").payload.is_error' "$RUN/events.jsonl")" = "false" ]
  run grep -c 'result-unparseable' "$RUN/events.jsonl"
  [ "$output" = "0" ]
}

# Мусор без единой json-строки обязан остаться unparseable: иначе провал генератора
# начнёт читаться как успешный прогон без метрик.
@test "generator_result_stays_unparseable_without_any_json_line" {
  printf 'Segmentation fault\nsome trailing noise\n' > "$TMP/result.json"
  run bash -c ". '$LIB'; log_generator_result '$RUN' t1 '$TMP/result.json'"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.event=="result-unparseable").phase' "$RUN/events.jsonl")" = "implement" ]
}
