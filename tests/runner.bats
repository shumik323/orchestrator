# Раннер одной задачи. Имена латиницей — см. scripts/run-bats.sh.

setup() {
  ORC_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export ORC_STATE="$TMP/state"

  # цель: bare с защищённым main и одним коммитом в нём
  "$ORC_ROOT/scripts/make-remote.sh" "$TMP/target.git" main >/dev/null
  git clone -q "$TMP/target.git" "$TMP/seed" 2>/dev/null
  cd "$TMP/seed"
  git config user.email seed@local
  git config user.name seed
  printf 'base\n' > file.txt
  git add file.txt
  git commit -qm base
  # объекты попадают в bare только через push; main защищён хуком,
  # поэтому сеем через разрешённую ветку и переставляем ref напрямую
  git push -q origin HEAD:refs/heads/seed-tmp
  git -C "$TMP/target.git" update-ref refs/heads/main "$(git rev-parse HEAD)"
  git -C "$TMP/target.git" update-ref -d refs/heads/seed-tmp

  QUEUE="$TMP/q.jsonl"
  printf '%s\n' '{"id":"t1","title":"проба","body":"добавить строку","status":"ready","blocked_by":[],"schema_version":1}' > "$QUEUE"

  CONF="$TMP/p.conf"
  cat > "$CONF" <<EOF
REPO_URL="$TMP/target.git"
BASE_BRANCH="main"
BRANCH_PREFIX="orc"
GATE_CMD="true"
MR_BACKEND="file"
PUSH_OPTS=""
MR_DIR="$TMP/mr"
QUEUE_FILE="$QUEUE"
DEADLINE_SEC="20"
EOF
}

refs_in_target() {
  git -C "$TMP/target.git" for-each-ref --format='%(refname)' 'refs/heads/orc/*'
}

@test "runner_opens_mr_when_diff_is_not_empty" {
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ -n "$(refs_in_target)" ]
  [ -f "$TMP/mr/t1.md" ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "done" ]
}

@test "runner_creates_no_mr_when_nothing_changed" {
  before="$(git -C "$TMP/target.git" rev-parse refs/heads/main)"
  run env ORC_GEN_CMD="true" "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ ! -f "$TMP/mr/t1.md" ]
  [ -z "$(refs_in_target)" ]
  [ "$(git -C "$TMP/target.git" rev-parse refs/heads/main)" = "$before" ]
  run jq -rs 'map(.event) | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"no-change"* ]]
}

@test "runner_marks_blocked_on_generator_timeout" {
  sed -i '' 's|DEADLINE_SEC="20"|DEADLINE_SEC="1"|' "$CONF"
  run env ORC_GEN_CMD="sleep 30" "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ -z "$(refs_in_target)" ]
  [ ! -f "$TMP/mr/t1.md" ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "blocked" ]
  run jq -rs 'map(.event) | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"timeout"* ]]
}

@test "runner_creates_no_mr_when_gate_is_red" {
  sed -i '' 's|GATE_CMD="true"|GATE_CMD="false"|' "$CONF"
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ -z "$(refs_in_target)" ]
  [ ! -f "$TMP/mr/t1.md" ]
  run jq -rs 'map("\(.phase):\(.event)") | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"gate:red"* ]]
}

@test "runner_keeps_work_dir_for_postmortem" {
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ -d "$ORC_STATE/runs/t1/repo" ]
  [ -f "$ORC_STATE/runs/t1/prompt.txt" ]
}

@test "runner_logs_cost_and_turns_from_generator_json" {
  # генератор отдельным файлом: так же, как поведёт себя настоящий claude -p,
  # который печатает JSON в stdout и правит файлы в рабочем дереве
  cat > "$TMP/gen.sh" <<'GEN'
#!/bin/sh
printf 'сделано\n' >> file.txt
printf '{"total_cost_usd":0.11,"num_turns":3,"is_error":false,"subtype":"success"}'
GEN
  chmod +x "$TMP/gen.sh"
  run env ORC_GEN_CMD="$TMP/gen.sh" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.event=="result").payload.cost_usd' "$ORC_STATE/logs/t1/events.jsonl")" = "0.11" ]
  [ "$(jq -r 'select(.event=="result").payload.turns' "$ORC_STATE/logs/t1/events.jsonl")" = "3" ]
}

@test "hooks_path_override_prevents_repo_hook_execution" {
  # Проверка самой техники, не раннера: если флаг назван неверно,
  # хук чужого репозитория исполнится при коммите.
  git init -q "$TMP/hooked"
  cd "$TMP/hooked"
  git config user.email h@local
  git config user.name h
  mkdir -p .git/hooks
  printf '%s\n' '#!/bin/sh' "printf x > $TMP/hook-ran" > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  mkdir -p "$TMP/nohooks"
  printf 'a\n' > a.txt
  git -c core.hooksPath="$TMP/nohooks" add a.txt
  git -c core.hooksPath="$TMP/nohooks" commit -qm no-hooks
  [ ! -f "$TMP/hook-ran" ]
}

@test "runner_blocks_when_generator_reports_error_even_with_diff" {
  # Прогон 22.08: упор в бюджет дал is_error=true и пустой диф, а задача
  # уехала в done. Здесь диф ЕСТЬ — MR всё равно не должен появиться.
  cat > "$TMP/gen.sh" <<'GEN'
#!/bin/sh
printf 'половина работы\n' >> file.txt
printf '{"is_error":true,"subtype":"error_max_budget_usd","total_cost_usd":0.53,"num_turns":4}'
GEN
  chmod +x "$TMP/gen.sh"
  run env ORC_GEN_CMD="$TMP/gen.sh" "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/mr/t1.md" ]
  [ -z "$(refs_in_target)" ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "blocked" ]
  run jq -rs 'map("\(.phase):\(.event)") | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"implement:failed"* ]]
}

# .harness.conf кладётся в целевой репозиторий: так же, как его туда положит
# bootstrap.sh настоящего инстанса харнесса.
seed_conf() {
  cd "$TMP/seed"
  cat > .harness.conf
  git add .harness.conf
  git commit -qm conf
  git push -q origin HEAD:refs/heads/seed-conf
  git -C "$TMP/target.git" update-ref refs/heads/main "$(git rev-parse HEAD)"
  git -C "$TMP/target.git" update-ref -d refs/heads/seed-conf
}

@test "gate_cmd_comes_from_instance_conf_not_from_project_conf" {
  seed_conf <<EOF
GATE_CMD="touch $TMP/gate-from-instance"
EOF
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ -f "$TMP/gate-from-instance" ]
}

@test "readonly_zone_change_is_blocked_before_gate" {
  seed_conf <<EOF
READONLY_ZONES="dist"
GATE_CMD="true"
EOF
  run env ORC_GEN_CMD="sh -c 'mkdir -p dist && printf x > dist/app.js'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/mr/t1.md" ]
  [ -z "$(refs_in_target)" ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "blocked" ]
  run jq -rs 'map("\(.phase):\(.event)") | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"scope:readonly-violation"* ]]
}

@test "secret_scan_red_blocks_push_and_mr" {
  seed_conf <<EOF
GATE_CMD="true"
SECRET_SCAN_CMD="false"
EOF
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ -z "$(refs_in_target)" ]
  [ ! -f "$TMP/mr/t1.md" ]
  run jq -rs 'map("\(.phase):\(.event)") | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"secret-scan:red"* ]]
}

@test "instance_conf_is_parsed_not_sourced_by_runner" {
  seed_conf <<EOF
GATE_CMD="true"
touch "$TMP/conf-was-sourced"
EOF
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ ! -f "$TMP/conf-was-sourced" ]
}

@test "gate_test_cmd_from_instance_runs_before_push" {
  seed_conf <<EOF
GATE_CMD="true"
GATE_TEST_CMD="touch $TMP/full-tests-ran"
EOF
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ -f "$TMP/full-tests-ran" ]
  [ -f "$TMP/mr/t1.md" ]
}

@test "gate_test_cmd_red_blocks_push_and_mr" {
  seed_conf <<EOF
GATE_CMD="true"
GATE_TEST_CMD="false"
EOF
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ -z "$(refs_in_target)" ]
  [ ! -f "$TMP/mr/t1.md" ]
  run jq -rs 'map("\(.phase):\(.event)") | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"gate-test:red"* ]]
}

@test "task_id_with_shell_metacharacters_is_refused" {
  run "$ORC_ROOT/scripts/run-task.sh" "$CONF" "x'\$(printf ВЗЛОМ > $TMP/pwned)'y"
  [ "$status" -eq 2 ]
  [ ! -f "$TMP/pwned" ]
}

@test "readonly_zone_is_enforced_for_non_ascii_filename" {
  seed_conf <<EOF
READONLY_ZONES="dist"
GATE_CMD="true"
EOF
  run env ORC_GEN_CMD="sh -c 'mkdir -p dist && printf x > dist/файл.js'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ -z "$(refs_in_target)" ]
  run jq -rs 'map("\(.phase):\(.event)") | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"scope:readonly-violation"* ]]
}

@test "readonly_zone_is_enforced_for_rename_into_zone" {
  seed_conf <<EOF
READONLY_ZONES="dist"
GATE_CMD="true"
EOF
  run env ORC_GEN_CMD="sh -c 'mkdir -p dist && git mv file.txt dist/file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ -z "$(refs_in_target)" ]
}

@test "mr_backend_failure_blocks_instead_of_reporting_done" {
  sed -i '' 's|MR_BACKEND="file"|MR_BACKEND="carrier-pigeon"|' "$CONF"
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "blocked" ]
  run jq -rs 'map("\(.phase):\(.event)") | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"mr:failed"* ]]
}

@test "unknown_task_id_is_blocked_before_generator_runs" {
  run env ORC_GEN_CMD="touch $TMP/generator-ran" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t99
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/generator-ran" ]
  run jq -rs 'map(.event) | join(" ")' "$ORC_STATE/logs/t99/events.jsonl"
  [[ "$output" == *"prompt-empty"* ]]
}

@test "repeat_run_starts_from_clean_base_not_from_previous_leftovers" {
  seed_conf <<EOF
GATE_CMD="grep -q правка file.txt"
EOF
  # прогон 1: генератор пишет мимо гейта и подменяет конфиг инстанса
  run env ORC_GEN_CMD="sh -c 'printf мимо >> file.txt; printf %s \"GATE_CMD=true\" > .harness.conf'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  # прогон 2: генератор не делает ничего — унаследованной работы быть не должно
  jq -c '.status="ready"' "$QUEUE" > "$QUEUE.2" && mv "$QUEUE.2" "$QUEUE"
  run env ORC_GEN_CMD="true" "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ ! -f "$TMP/mr/t1.md" ]
  [ -z "$(refs_in_target)" ]
  run jq -rs 'map(.event) | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"no-change"* ]]
}

@test "write_scope_blocks_change_outside_the_area" {
  printf 'WRITE_SCOPE="allowed"\n' >> "$CONF"
  run env ORC_GEN_CMD="sh -c 'mkdir -p allowed other && printf x > allowed/ok.ts && printf x > other/bad.ts'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ -z "$(refs_in_target)" ]
  [ ! -f "$TMP/mr/t1.md" ]
  run jq -rs 'map("\(.phase):\(.event)") | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"scope:out-of-scope"* ]]
}

@test "write_scope_allows_change_inside_the_area" {
  printf 'WRITE_SCOPE="allowed"\n' >> "$CONF"
  run env ORC_GEN_CMD="sh -c 'mkdir -p allowed && printf x > allowed/ok.ts'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ -f "$TMP/mr/t1.md" ]
}

@test "scope_declared_in_task_overrides_project_conf" {
  printf 'WRITE_SCOPE="allowed"\n' >> "$CONF"
  # у задачи своя область — она точнее конфига проекта
  jq -c '. + {scope:"other"}' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
  run env ORC_GEN_CMD="sh -c 'mkdir -p other && printf x > other/ok.ts'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ -f "$TMP/mr/t1.md" ]
}
