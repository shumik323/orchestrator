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
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "agent-failed" ]
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

@test "stream_json_generator_yields_cost_and_turns_from_last_line" {
  # Генератор с --output-format stream-json печатает строку на событие; результат — последняя,
  # а у первой строки свой subtype (init), который не должен читаться как ошибка.
  cat > "$TMP/gen.sh" <<'GEN'
#!/bin/sh
printf 'сделано\n' >> file.txt
printf '%s\n' '{"type":"system","subtype":"init","session_id":"s1"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"file.txt"}}]}}'
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.22,"num_turns":2,"session_id":"s1"}'
GEN
  chmod +x "$TMP/gen.sh"
  run env ORC_GEN_CMD="$TMP/gen.sh" "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.event=="result").payload.cost_usd' "$ORC_STATE/logs/t1/events.jsonl")" = "0.22" ]
  [ "$(jq -r 'select(.event=="result").payload.turns' "$ORC_STATE/logs/t1/events.jsonl")" = "2" ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "done" ]
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
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "agent-failed" ]
  run jq -rs 'map("\(.phase):\(.event)") | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"implement:failed"* ]]
}

@test "generator_nonzero_exit_without_json_is_agent_failed_not_no_change" {
  # Ревью 21.09: rate-limit подписки печатает «API Error: 429» в stderr и выходит с 1 —
  # диффа нет, и раннер считал это «править было нечего».
  run env ORC_GEN_CMD="sh -c 'echo \"API Error: 429\" >&2; exit 1'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/mr/t1.md" ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "agent-failed" ]
  run jq -rs 'map("\(.phase):\(.event)") | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"implement:failed"* ]]
}

@test "generator_crash_with_half_diff_is_agent_failed_not_done" {
  run env ORC_GEN_CMD="sh -c 'printf half >> file.txt; exit 1'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/mr/t1.md" ]
  [ -z "$(refs_in_target)" ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "agent-failed" ]
}

@test "missing_gate_cmd_everywhere_blocks_instead_of_green" {
  # Ни в conf проекта, ни в .harness.conf клона: раньше GATE_CMD молча становился true.
  grep -v '^GATE_CMD=' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/mr/t1.md" ]
  [ -z "$(refs_in_target)" ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "blocked" ]
  run jq -rs 'map(.event) | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"gate-missing"* ]]
}

@test "scratch_notes_are_copied_on_generator_timeout" {
  # faqs 20.09: бот 25 минут писал NOTES.md, упёрся в дедлайн — заметки жили только в runs/ до следующего запуска.
  sed -i '' 's|DEADLINE_SEC="20"|DEADLINE_SEC="1"|' "$CONF"
  run env ORC_GEN_CMD="sh -c 'mkdir -p _scratch; printf заметка > _scratch/NOTES.md; sleep 30'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "agent-failed" ]
  [ -f "$ORC_STATE/logs/t1/scratch/NOTES.md" ]
}

@test "broken_clone_is_git_failed_not_no_change" {
  run env ORC_GEN_CMD="sh -c 'rm -rf .git'" "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "blocked" ]
  run jq -rs 'map(.event) | join(" ")' "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == *"git-failed"* ]]
  [[ "$output" != *"no-change"* ]]
}

@test "permission_denials_in_stream_json_are_logged_not_lost" {
  # stream-json: десятки документов в файле; jq по файлу давал многострочный payload и ронял log_event.
  cat > "$TMP/gen.sh" <<'GEN'
#!/bin/sh
printf '{"type":"system","subtype":"init"}\n'
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"спрошу"}]}}\n'
printf '{"type":"result","subtype":"success","is_error":false,"permission_denials":[{"tool_name":"AskUserQuestion","tool_input":{"question":"какой копирайт?"}}],"total_cost_usd":0.1,"num_turns":1}\n'
GEN
  chmod +x "$TMP/gen.sh"
  run env ORC_GEN_CMD="$TMP/gen.sh" "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "blocked" ]
  run jq -rs 'map(select(.event=="permission-denied")) | length' "$ORC_STATE/logs/t1/events.jsonl"
  [ "$output" = "1" ]
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
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "scope-violation" ]
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

# --- setup-фаза: зависимости проекта ---
# Клон приходит в каталог задачи, поэтому у соседней задачи дерево пустое.
# Гейт в таком клоне краснеет на отсутствии инструмента, а не на работе генератора.

@test "runner_runs_setup_when_marker_is_missing" {
  printf 'SETUP_CMD="mkdir -p node_modules && printf ok > node_modules/.stamp"\n' >> "$CONF"
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ -f "$ORC_STATE/runs/t1/repo/node_modules/.stamp" ]
  # порядок фаз: setup обязан лечь до генератора, иначе генератор
  # запускается в дереве без зависимостей и делает пустой диф
  run jq -rs 'map(select(.phase=="setup" or .phase=="implement") | .phase + ":" + .event) | join(" ")' \
    "$ORC_STATE/logs/t1/events.jsonl"
  [[ "$output" == "setup:started setup:finished implement:started"* ]]
}

@test "runner_skips_setup_when_marker_exists" {
  # file.txt лежит в базовой ветке, то есть маркер на месте с первого клона
  printf 'SETUP_MARKER="file.txt"\nSETUP_CMD="exit 7"\n' >> "$CONF"
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  run jq -rs 'map(select(.phase=="setup") | .event) | join(" ")' \
    "$ORC_STATE/logs/t1/events.jsonl"
  [ "$output" = "skipped" ]
}

@test "runner_blocks_when_setup_fails" {
  printf 'SETUP_CMD="exit 3"\n' >> "$CONF"
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 1 ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "blocked" ]
  [ ! -f "$TMP/mr/t1.md" ]
  [ -z "$(refs_in_target)" ]
  # генератор не должен был запуститься вовсе
  run jq -rs 'map(select(.phase=="implement")) | length' "$ORC_STATE/logs/t1/events.jsonl"
  [ "$output" = "0" ]
}

# Хуки инстанса не гейтятся доверием к каталогу: прогон 25.08 поймал падение
# SessionEnd-хука целевого репозитория внутри задачи. Гасим их флагом, но НЕ через
# --setting-sources: тот унёс бы вместе с настройками и CLAUDE.md репозитория.
@test "runner_disables_instance_hooks_in_generator_call" {
  bin="$TMP/bin"; mkdir -p "$bin"
  # стаб перехватывает аргументы: настоящий claude в тестах не запускается
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s/claude-args.txt"\nprintf "{}"\n' \
    "$TMP" > "$bin/claude"
  chmod +x "$bin/claude"
  run env PATH="$bin:$PATH" "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ -f "$TMP/claude-args.txt" ]
  run grep -F 'disableAllHooks' "$TMP/claude-args.txt"
  [ "$status" -eq 0 ]
  # источник project остаётся: без него уедет CLAUDE.md проекта
  run grep -F 'setting-sources' "$TMP/claude-args.txt"
  [ "$status" -ne 0 ]
}

# Репозиторий инстанса несёт свои процессные правила, и генератор их исполняет:
# прогон 25.08 потерял готовую правку из-за строки, дописанной в буфер наблюдений
# по правилу проекта. Границы прогона дописываются к каждой задаче.
@test "runner_appends_process_boundaries_to_prompt" {
  bin="$TMP/bin"; mkdir -p "$bin"
  # стаб сохраняет полученный промпт: он приходит генератору на stdin
  printf '#!/usr/bin/env bash\ncat > "%s/prompt-seen.txt"\nprintf "{}"\n' "$TMP" > "$bin/claude"
  chmod +x "$bin/claude"
  run env PATH="$bin:$PATH" "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ -f "$TMP/prompt-seen.txt" ]
  # тело задачи на месте
  run grep -F 'добавить строку' "$TMP/prompt-seen.txt"
  [ "$status" -eq 0 ]
  # и границы поверх него
  run grep -F 'Буферы наблюдений' "$TMP/prompt-seen.txt"
  [ "$status" -eq 0 ]
  # и адрес для записей вне задачи — каталог из NEEDS_OWNER_FILE
  run grep -F '_scratch/NOTES.md' "$TMP/prompt-seen.txt"
  [ "$status" -eq 0 ]
  run grep -F 'Ничего не коммить' "$TMP/prompt-seen.txt"
  [ "$status" -eq 0 ]
}

# Границы не должны оживлять пустой промпт: задача, которой нет в очереди,
# обязана блокироваться, а не уходить генератору с одними границами.
@test "runner_still_blocks_when_task_is_absent_from_queue" {
  run "$ORC_ROOT/scripts/run-task.sh" "$CONF" nosuchtask
  [ "$status" -eq 1 ]
  run jq -rs 'map(select(.event=="prompt-empty")) | length' "$ORC_STATE/logs/nosuchtask/events.jsonl"
  [ "$output" = "1" ]
}

# Канал «сделал, но с вопросом»: файл в рабочем каталоге, не текст result.
# Прогон 18.09 (kingfin): бот выдумал копирайт, признался в result, а раннер читал только дифф и гейт.
@test "needs_owner_file_blocks_task_before_gate_and_push" {
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt; mkdir -p _scratch; printf \"NEEDS-OWNER: нет копирайта, чей текст?\" > _scratch/NEEDS-OWNER.md'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ -z "$(refs_in_target)" ]
  [ ! -f "$TMP/mr/t1.md" ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "blocked" ]
  run jq -rs 'map(select(.event=="needs-owner")) | .[0].payload.question' "$ORC_STATE/logs/t1/events.jsonl"
  [ "$output" = "NEEDS-OWNER: нет копирайта, чей текст?" ]
  [ -s "$ORC_STATE/logs/t1/scratch/NEEDS-OWNER.md" ]
}

@test "empty_needs_owner_file_is_not_a_question" {
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt; mkdir -p _scratch; : > _scratch/NEEDS-OWNER.md'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ -n "$(refs_in_target)" ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "done" ]
}

# Вторичный сигнал: AskUserQuestion в -p отклоняется молча и оседает в permission_denials result.
@test "permission_denials_in_result_blocks_task" {
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt; printf \"%s\" \"{\\\"result\\\":\\\"готово\\\",\\\"permission_denials\\\":[{\\\"tool_name\\\":\\\"AskUserQuestion\\\"}]}\"'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -ne 0 ]
  [ -z "$(refs_in_target)" ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "blocked" ]
  run jq -rs 'map(select(.event=="permission-denied")) | .[0].payload.denials[0].tool_name' "$ORC_STATE/logs/t1/events.jsonl"
  [ "$output" = "AskUserQuestion" ]
}

# Заметки бота уносятся в лог прогона при любом исходе, не только при вопросе владельцу.
@test "scratch_notes_are_copied_to_run_log_on_done" {
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt; mkdir -p _scratch; printf \"%s\" \"- заметка бота\" > _scratch/NOTES.md'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "done" ]
  [ "$(cat "$ORC_STATE/logs/t1/scratch/NOTES.md")" = "- заметка бота" ]
  run jq -rs 'map(select(.event=="scratch")) | .[0].payload.files | join(",")' "$ORC_STATE/logs/t1/events.jsonl"
  [ "$output" = "NOTES.md" ]
}

# Ревью 20.09: старый NEEDS-OWNER.md переживал clean без -x, повтор снова вставал тем же вопросом.
@test "stale_scratch_is_removed_before_rerun" {
  run env ORC_GEN_CMD="sh -c 'mkdir -p _scratch; printf \"%s\" \"NEEDS-OWNER: вопрос\" > _scratch/NEEDS-OWNER.md'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "blocked" ]
  . "$ORC_ROOT/scripts/lib/queue.sh"; queue_set_status "$QUEUE" t1 ready
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "done" ]
}

# Ревью 20.09: отказ перехода → running не останавливал прогон; задача в blocked доходила до MR.
@test "runner_refuses_to_start_task_not_in_ready" {
  printf '%s\n' '{"id":"t9","title":"x","body":"x","status":"blocked","schema_version":1}' >> "$QUEUE"
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" "$ORC_ROOT/scripts/run-task.sh" "$CONF" t9
  [ "$status" -eq 3 ]
  [ -z "$(git -C "$TMP/target.git" for-each-ref 'refs/heads/orc/t9')" ]
  [ ! -f "$TMP/mr/t9.md" ]
  [ "$(jq -r 'select(.id=="t9").status' "$QUEUE")" = "blocked" ]
}

# _scratch/ — канал, не правка: в ветку не попадает даже без .gitignore у таргета.
@test "scratch_dir_is_neither_scope_violation_nor_committed" {
  cat >> "$CONF" <<EOC
WRITE_SCOPE="file.txt"
EOC
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt; mkdir -p _scratch; printf \"%s\" \"- заметка\" > _scratch/NOTES.md'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "done" ]
  run git -C "$TMP/target.git" ls-tree -r --name-only refs/heads/orc/t1
  [[ "$output" != *"_scratch"* ]]
}

@test "runner_passes_strict_mcp_config_to_generator" {
  bin="$TMP/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s/claude-args.txt"\nprintf "{}"\n' "$TMP" > "$bin/claude"
  chmod +x "$bin/claude"
  run env PATH="$bin:$PATH" "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  run grep -F -- '--strict-mcp-config' "$TMP/claude-args.txt"
  [ "$status" -eq 0 ]
}

# Только AskUserQuestion — вопрос владельцу; отказ другого тула (WebFetch) в статус не идёт.
@test "other_permission_denials_do_not_block" {
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt; printf \"%s\" \"{\\\"result\\\":\\\"ok\\\",\\\"permission_denials\\\":[{\\\"tool_name\\\":\\\"WebFetch\\\"}]}\"'" \
    "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "done" ]
}

# Сообщение коммита — из конфига проекта: у инстансов свои хуки формата, в клон они не приезжают.
@test "commit_message_follows_project_template" {
  printf 'COMMIT_MSG_TEMPLATE="MD-0000: {title} [{id}]"\n' >> "$CONF"
  run env ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" "$ORC_ROOT/scripts/run-task.sh" "$CONF" t1
  [ "$status" -eq 0 ]
  run git -C "$TMP/target.git" log -1 --format=%s refs/heads/orc/t1
  [ "$output" = "MD-0000: проба [t1]" ]
}
