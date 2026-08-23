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

@test "queue_set_status_changes_one_line_and_keeps_count" {
  run bash -c ". '$LIB'; queue_set_status '$Q' t4 done"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$Q" | tr -d ' ')" = "5" ]
  [ "$(jq -r 'select(.id=="t4").status' "$Q")" = "done" ]
  [ "$(jq -r 'select(.id=="t2").status' "$Q")" = "ready" ]
}

@test "queue_set_status_is_idempotent" {
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
