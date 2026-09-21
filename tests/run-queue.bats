# Имена тестов латиницей — см. комментарий в scripts/run-bats.sh.

setup() {
  ORC_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export ORC_STATE="$TMP/state"
  export ORC_GEN_CMD="false" ORC_REVIEW_CMD="false" ORC_CHALLENGE_CMD="false"

  "$ORC_ROOT/scripts/make-remote.sh" "$TMP/target.git" main >/dev/null
  git clone -q "$TMP/target.git" "$TMP/seed" 2>/dev/null
  cd "$TMP/seed"
  git config user.email seed@local
  git config user.name seed
  printf 'base\n' > file.txt
  git add file.txt
  git commit -qm base
  git push -q origin HEAD:refs/heads/seed-tmp
  git -C "$TMP/target.git" update-ref refs/heads/main "$(git rev-parse HEAD)"
  git -C "$TMP/target.git" update-ref -d refs/heads/seed-tmp

  QUEUE="$TMP/q.jsonl"
  CONF="$TMP/p.conf"
  {
    printf 'REPO_URL="%s"\n' "$TMP/target.git"
    printf 'BASE_BRANCH="main"\nBRANCH_PREFIX="orc"\nGATE_CMD="true"\nMR_BACKEND="file"\nPUSH_OPTS=""\n'
    printf 'MR_DIR="%s"\nQUEUE_FILE="%s"\nDEADLINE_SEC="20"\nREVIEW_TRACKS=""\n' "$TMP/mr" "$QUEUE"
  } > "$CONF"
  # генератор-заглушка: пишет строку в file.txt — диф не пуст, задача уходит в done
  GEN="$TMP/gen.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "x\n" >> file.txt' 'printf "{\"result\":\"ok\",\"is_error\":false}\n"' > "$GEN"
  chmod +x "$GEN"
}

task_line() {
  printf '{"id":"%s","title":"проба","body":"добавить строку","status":"%s","blocked_by":[%s],"schema_version":1}\n' "$1" "$2" "${3:-}"
}

@test "run_queue_drains_ready_tasks_in_order_and_exits_zero" {
  { task_line t1 ready; task_line t2 ready; } > "$QUEUE"
  run env ORC_GEN_CMD="$GEN" "$ORC_ROOT/scripts/run-queue.sh" "$CONF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run-queue: t1"* ]]
  [[ "$output" == *"run-queue: t2"* ]]
  [ "$(jq -r 'select(.id=="t1") | .status' "$QUEUE")" = "done" ]
  [ "$(jq -r 'select(.id=="t2") | .status' "$QUEUE")" = "done" ]
}

@test "run_queue_respects_blocked_by_and_runs_dependent_after_blocker" {
  { task_line t2 ready '"t1"'; task_line t1 ready; } > "$QUEUE"
  run env ORC_GEN_CMD="$GEN" "$ORC_ROOT/scripts/run-queue.sh" "$CONF"
  [ "$status" -eq 0 ]
  first="$(printf '%s' "$output" | grep -oE 'run-queue: t[12]' | head -n 1)"
  [ "$first" = "run-queue: t1" ]
  [ "$(jq -r 'select(.id=="t2") | .status' "$QUEUE")" = "done" ]
}

@test "run_queue_stops_after_max_fails_in_a_row" {
  { task_line t1 ready; task_line t2 ready; task_line t3 ready; } > "$QUEUE"
  # ORC_GEN_CMD=false → генератор падает → agent-failed на каждой задаче
  run "$ORC_ROOT/scripts/run-queue.sh" "$CONF" 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 сбоя подряд"* ]]
  [ "$(jq -r 'select(.id=="t3") | .status' "$QUEUE")" = "ready" ]
}

@test "run_queue_with_empty_ready_exits_zero_without_running" {
  task_line t1 done > "$QUEUE"
  run "$ORC_ROOT/scripts/run-queue.sh" "$CONF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"задач 0"* ]]
}
