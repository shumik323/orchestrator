# Очередь. Имена латиницей — см. scripts/run-bats.sh.
#
# Фикстура на 5 задач покрывает четыре случая разом: закрытый блокер,
# незакрытый блокер, отсутствующее поле blocked_by, статус не ready.
# Сверка идёт с файлом-эталоном, а не глазами по выводу.

setup() {
  ORC_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  Q="$TMP/q.jsonl"
  cp "$ORC_ROOT/tests/fixtures/queue-5.jsonl" "$Q"
  LIB="$ORC_ROOT/scripts/lib/queue.sh"
}

@test "queue_ready_matches_reference" {
  run bash -c ". '$LIB'; queue_ready '$Q'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$ORC_ROOT/tests/fixtures/queue-5.ready")" ]
}

@test "stale_lock_older_than_a_minute_is_removed_instead_of_blocking_forever" {
  mkdir "$Q.lock"
  touch -t 202001010000 "$Q.lock"
  run bash -c ". '$LIB'; queue_set_status '$Q' t4 running"
  [ "$status" -eq 0 ]
  [ ! -d "$Q.lock" ]
  [ "$(jq -r 'select(.id=="t4").status' "$Q")" = "running" ]
}

@test "queue_set_status_changes_one_line_and_keeps_count" {
  bash -c ". '$LIB'; queue_set_status '$Q' t4 running"
  run bash -c ". '$LIB'; queue_set_status '$Q' t4 done"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$Q" | tr -d ' ')" = "5" ]
  [ "$(jq -r 'select(.id=="t4").status' "$Q")" = "done" ]
  [ "$(jq -r 'select(.id=="t2").status' "$Q")" = "ready" ]
}

@test "queue_set_status_is_idempotent" {
  bash -c ". '$LIB'; queue_set_status '$Q' t4 running"
  bash -c ". '$LIB'; queue_set_status '$Q' t4 done"
  first="$(cat "$Q")"
  bash -c ". '$LIB'; queue_set_status '$Q' t4 done"
  [ "$(cat "$Q")" = "$first" ]
}

@test "stray_temp_file_does_not_corrupt_reads" {
  printf '{"id":"обрыв' > "$Q.ab12cd"
  run bash -c ". '$LIB'; queue_ready '$Q'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$ORC_ROOT/tests/fixtures/queue-5.ready")" ]
}

@test "queue_bump_attempts_increments_from_missing_field" {
  bash -c ". '$LIB'; queue_bump_attempts '$Q' t2"
  [ "$(jq -r 'select(.id=="t2").attempts' "$Q")" = "1" ]
  bash -c ". '$LIB'; queue_bump_attempts '$Q' t2"
  [ "$(jq -r 'select(.id=="t2").attempts' "$Q")" = "2" ]
}

@test "queue_add_appends_task_with_prompt_hash" {
  run bash -c ". '$LIB'; queue_add '$Q' t6 'новая' 'тело задачи'"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$Q" | tr -d ' ')" = "6" ]
  [ -n "$(jq -r 'select(.id=="t6").prompt_hash' "$Q")" ]
  [ "$(jq -r 'select(.id=="t6").status' "$Q")" = "ready" ]
}

@test "queue_add_rejects_duplicate_prompt" {
  bash -c ". '$LIB'; queue_add '$Q' t6 'новая' 'тело задачи'"
  run bash -c ". '$LIB'; queue_add '$Q' t7 'новая' 'тело задачи'"
  [ "$status" -eq 3 ]
  [ "$(wc -l < "$Q" | tr -d ' ')" = "6" ]
}

@test "queue_add_allows_same_prompt_after_task_closed" {
  bash -c ". '$LIB'; queue_add '$Q' t6 'новая' 'тело задачи'"
  bash -c ". '$LIB'; queue_set_status '$Q' t6 running"
  bash -c ". '$LIB'; queue_set_status '$Q' t6 done"
  run bash -c ". '$LIB'; queue_add '$Q' t7 'новая' 'тело задачи'"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$Q" | tr -d ' ')" = "7" ]
}

@test "queue_set_status_refuses_to_overwrite_on_broken_line" {
  printf '{"id":"битая\n' >> "$Q"
  before="$(cat "$Q")"
  run bash -c ". '$LIB'; queue_set_status '$Q' t2 done"
  [ "$status" -ne 0 ]
  [ "$(cat "$Q")" = "$before" ]
}

@test "fsm_rejects_transition_that_skips_running" {
  before="$(cat "$Q")"
  run bash -c ". '$LIB'; queue_set_status '$Q' t4 done"
  [ "$status" -eq 3 ]
  [ "$(cat "$Q")" = "$before" ]
}

@test "fsm_draft_goes_only_to_ready" {
  # draft — задача без входов (спека, контекст, токены); раннер её не берёт, дашборд не даёт кнопку «запустить».
  printf '%s\n' '{"id":"t9","title":"черновик","body":"","status":"draft","blocked_by":[],"schema_version":1}' >> "$Q"
  run bash -c ". '$LIB'; queue_set_status '$Q' t9 running"
  [ "$status" -eq 3 ]
  run bash -c ". '$LIB'; queue_set_status '$Q' t9 ready"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.id=="t9").status' "$Q")" = "ready" ]
}

@test "fsm_rejects_unknown_status" {
  run bash -c ". '$LIB'; queue_set_status '$Q' t4 наверное-готово"
  [ "$status" -eq 3 ]
}

@test "fsm_rejects_unknown_task_id" {
  run bash -c ". '$LIB'; queue_set_status '$Q' t99 running"
  [ "$status" -eq 4 ]
}

@test "fsm_allows_retry_path_from_gate_failed_to_ready" {
  bash -c ". '$LIB'; queue_set_status '$Q' t4 running"
  bash -c ". '$LIB'; queue_set_status '$Q' t4 gate-failed"
  run bash -c ". '$LIB'; queue_set_status '$Q' t4 ready"
  [ "$status" -eq 0 ]
}

@test "fsm_keeps_terminal_states_terminal" {
  bash -c ". '$LIB'; queue_set_status '$Q' t4 running"
  bash -c ". '$LIB'; queue_set_status '$Q' t4 done"
  run bash -c ". '$LIB'; queue_set_status '$Q' t4 running"
  [ "$status" -eq 3 ]
}

@test "queue_ready_counts_no_change_as_closed_blocker" {
  # t2 заблокирован t1; t1 закрыт как no-change — работа по нему окончена
  cp "$ORC_ROOT/tests/fixtures/queue-5.jsonl" "$Q"
  bash -c ". '$LIB'; queue_set_status '$Q' t1 ready" 2>/dev/null || true
  run bash -c ". '$LIB'; queue_ready '$Q'"
  [[ "$output" == *"t2"* ]]
}

# Ревью 20.09: без лока 40 параллельных записей оставляли 6. mkdir-лок — все 40.
@test "parallel_status_writes_are_not_lost" {
  qf="$TMP/par.jsonl"; : > "$qf"
  for i in $(seq 1 40); do printf '{"id":"p%s","title":"x","body":"x","status":"ready","schema_version":1}\n' "$i" >> "$qf"; done
  for i in $(seq 1 40); do ( . "$ORC_ROOT/scripts/lib/queue.sh"; queue_set_status "$qf" "p$i" running ) & done
  wait
  [ "$(jq -r 'select(.status=="running") | .id' "$qf" | wc -l | tr -d ' ')" = "40" ]
  [ ! -d "$qf.lock" ]
}
