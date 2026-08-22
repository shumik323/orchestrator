#!/usr/bin/env bash
# Раннер одной задачи: клон → генератор → гейт → ветка + MR.
#
# set -e не ставим: у раннера четыре штатных исхода, и три из них
# неуспешные (пустой вывод, таймаут, красный гейт). Падение по -e
# превратило бы их в необъяснимый сбой без записи в лог.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
. "$HERE/lib/paths.sh"
# shellcheck source=lib/queue.sh
. "$HERE/lib/queue.sh"
# shellcheck source=lib/log.sh
. "$HERE/lib/log.sh"
# shellcheck source=lib/mr.sh
. "$HERE/lib/mr.sh"
# shellcheck source=lib/watchdog.sh
. "$HERE/lib/watchdog.sh"

conf="${1:?использование: run-task.sh <project-conf> <task-id>}"
task_id="${2:?task-id}"

# shellcheck source=/dev/null
. "$conf"

: "${BASE_BRANCH:=main}"
: "${BRANCH_PREFIX:=orc}"
: "${GATE_CMD:=true}"
: "${PUSH_OPTS:=}"
: "${MR_DIR:=mr}"
: "${DEADLINE_SEC:=1800}"
: "${MAX_BUDGET_USD:=1.00}"
: "${ALLOWED_TOOLS:=Read,Edit,Bash}"
: "${QUEUE_FILE:=}"

orc_init_state
work="$(orc_task_dir "$task_id")"
run_dir="$(orc_log_dir "$task_id")"
mkdir -p "$work/nohooks" "$run_dir"

# Хуки целевого репозитория не исполняются: hooksPath уводится в пустой
# каталог на каждом вызове git, включая clone.
g() { git -c core.hooksPath="$work/nohooks" "$@"; }

set_status() {
  [ -n "$QUEUE_FILE" ] && [ -f "$QUEUE_FILE" ] && queue_set_status "$QUEUE_FILE" "$task_id" "$1"
  return 0
}

branch="$BRANCH_PREFIX/$task_id"

log_event "$run_dir" "$task_id" clone started
if [ ! -d "$work/repo/.git" ]; then
  g clone -q --branch "$BASE_BRANCH" "$REPO_URL" "$work/repo" || {
    log_event "$run_dir" "$task_id" clone failed
    set_status "blocked"
    exit 1
  }
fi
g -C "$work/repo" checkout -q -B "$branch"
g -C "$work/repo" config user.email "orchestrator@local"
g -C "$work/repo" config user.name "orchestrator"
log_event "$run_dir" "$task_id" clone finished

# Промпт — файлом на диске: он же артефакт разбора, если прогон провалится.
if [ -n "$QUEUE_FILE" ] && [ -f "$QUEUE_FILE" ]; then
  jq -r --arg id "$task_id" 'select(.id == $id) | "\(.title)\n\n\(.body)"' \
    "$QUEUE_FILE" > "$work/prompt.txt"
else
  printf 'задача %s\n' "$task_id" > "$work/prompt.txt"
fi

default_gen="claude -p --output-format json --max-budget-usd $MAX_BUDGET_USD \
--allowedTools $ALLOWED_TOOLS --permission-mode acceptEdits"
gen_cmd="${ORC_GEN_CMD:-$default_gen}"
gen_out="$(log_phase_stdout "$run_dir" implement)"

set_status "running"
log_event "$run_dir" "$task_id" implement started \
  "$(jq -cn --arg d "$DEADLINE_SEC" '{deadline_sec: $d}')"

run_with_deadline "$DEADLINE_SEC" \
  bash -c "cd '$work/repo' && $gen_cmd < '$work/prompt.txt'" > "$gen_out" 2>&1
gen_rc=$?

if [ "$gen_rc" -eq 124 ]; then
  log_event "$run_dir" "$task_id" implement timeout \
    "$(jq -cn --arg d "$DEADLINE_SEC" '{deadline_sec: $d}')"
  set_status "blocked"
  printf 'генератор не уложился в %s с — задача blocked, каталог %s оставлен\n' \
    "$DEADLINE_SEC" "$work" >&2
  exit 1
fi

log_generator_result "$run_dir" "$task_id" "$gen_out"
log_event "$run_dir" "$task_id" implement finished \
  "$(jq -cn --arg rc "$gen_rc" '{exit_code: $rc}')"

if [ -n "$(g -C "$work/repo" status --porcelain)" ]; then
  log_event "$run_dir" "$task_id" implement no-change
  set_status "done"
  printf 'правка не потребовалась — MR не создан\n'
  exit 0
fi

gate_out="$(log_phase_stdout "$run_dir" gate)"
log_event "$run_dir" "$task_id" gate started
run_with_deadline "$DEADLINE_SEC" bash -c "cd '$work/repo' && $GATE_CMD" > "$gate_out" 2>&1
gate_rc=$?

if [ "$gate_rc" -ne 0 ]; then
  log_event "$run_dir" "$task_id" gate red "$(jq -cn --arg rc "$gate_rc" '{exit_code: $rc}')"
  set_status "blocked"
  printf 'гейт красный (код %s) — MR не создаётся, разбор в %s\n' "$gate_rc" "$gate_out" >&2
  exit 1
fi
log_event "$run_dir" "$task_id" gate green

g -C "$work/repo" add -A
g -C "$work/repo" commit -qm "orc($task_id): автоматическая правка"

# PUSH_OPTS разворачивается словами намеренно: -o ci.skip это два аргумента
# shellcheck disable=SC2086
g -C "$work/repo" push --no-verify $PUSH_OPTS -q origin "$branch" || {
  log_event "$run_dir" "$task_id" push rejected
  set_status "blocked"
  printf 'push отклонён — см. гардрейл целевого репозитория\n' >&2
  exit 1
}
log_event "$run_dir" "$task_id" push finished "$(jq -cn --arg b "$branch" '{branch: $b}')"

body="$work/mr-body.md"
{
  printf 'Задача: %s\n\n' "$task_id"
  printf 'Изменения:\n\n'
  g -C "$work/repo" diff --stat "origin/$BASE_BRANCH"..HEAD
  printf '\nЛог прогона: %s\n' "$run_dir/events.jsonl"
} > "$body"

mr_path="$(mr_create "$MR_DIR" "$branch" "$BASE_BRANCH" "orc($task_id)" "$body")"
log_event "$run_dir" "$task_id" mr created "$(jq -cn --arg p "$mr_path" '{path: $p}')"
set_status "done"
printf 'MR: %s\n' "$mr_path"
