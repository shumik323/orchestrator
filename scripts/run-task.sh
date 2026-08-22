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
# shellcheck source=lib/harness.sh
. "$HERE/lib/harness.sh"

conf="${1:?использование: run-task.sh <project-conf> <task-id>}"
task_id="${2:?task-id}"

# id уезжает в пути и в строку для bash -c: кавычка внутри него ломала команду
# и прогон завершался «правка не потребовалась», ничего не запустив
case "$task_id" in
  *[!A-Za-z0-9._-]*|'')
    printf 'run-task.sh: task-id допускает только A-Za-z0-9._- : %s\n' "$task_id" >&2
    exit 2 ;;
esac

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
: "${GATE_TEST_CMD:=}"
: "${GATE_WORKDIR:=}"
: "${READONLY_ZONES:=}"
: "${SECRET_SCAN_CMD:=}"

orc_init_state
work="$(orc_task_dir "$task_id")"
run_dir="$(orc_log_dir "$task_id")"
mkdir -p "$work/nohooks" "$run_dir"

# Хуки целевого репозитория не исполняются: hooksPath уводится в пустой
# каталог на каждом вызове git, включая clone.
g() { git -c core.hooksPath="$work/nohooks" -c core.quotePath=false "$@"; }

# Пути, тронутые генератором. Не status --porcelain: его трёхсимвольный префикс
# приходится срезать, кириллица приезжает в эскейпах, а переименование печатается
# одной строкой «старое -> новое» — три способа проскочить проверку зон.
changed_paths() {
  g -C "$work/repo" diff --name-only --no-renames HEAD || return 1
  g -C "$work/repo" ls-files --others --exclude-standard || return 1
}

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
# Шаг 1. Гейт и зоны принадлежат инстансу: держать их копию в конфиге раннера
# значит завести второй источник истины и молча разойтись с ним.
# Конфиг парсится, не сорсится — он приехал из клонированного репозитория.
inst_conf="$work/repo/.harness.conf"
if [ -f "$inst_conf" ]; then
  for key in GATE_CMD GATE_TEST_CMD GATE_WORKDIR READONLY_ZONES SECRET_SCAN_CMD; do
    val="$(harness_conf_get "$inst_conf" "$key")"
    [ -n "$val" ] && eval "$key=\"\$val\""
  done
  log_event "$run_dir" "$task_id" clone harness-conf \
    "$(jq -cn --arg g "$GATE_CMD" --arg z "$READONLY_ZONES" \
       '{gate_cmd: $g, readonly_zones: $z}')"
fi

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

# Ошибка генератора не должна читаться как «править было нечего».
# Живой прогон 22.08: упор в --max-budget-usd на 4-м ходу дал пустой диф,
# и задача была помечена done — успех, за которым нет работы.
gen_err="$(jq -r '
  if (.is_error == true) or (((.subtype // "") | startswith("error")))
  then (.subtype // "error") else empty end' "$gen_out" 2>/dev/null || true)"
if [ -n "$gen_err" ]; then
  log_event "$run_dir" "$task_id" implement failed \
    "$(jq -cn --arg s "$gen_err" '{subtype: $s}')"
  set_status "blocked"
  printf 'генератор завершился ошибкой (%s) — задача blocked, каталог %s оставлен\n' \
    "$gen_err" "$work" >&2
  exit 1
fi

changed="$(changed_paths)" || {
  log_event "$run_dir" "$task_id" implement git-failed
  set_status "blocked"
  printf 'git не смог перечислить изменения — задача blocked, каталог %s оставлен\n' "$work" >&2
  exit 1
}

if [ -z "$changed" ]; then
  log_event "$run_dir" "$task_id" implement no-change
  set_status "done"
  printf 'правка не потребовалась — MR не создан\n'
  exit 0
fi

# Шаг 2. Область работы: промпт просит не трогать лишнее, эта проверка запрещает.
# Префикс из трёх символов у status --porcelain отрезается: нужен путь, не статус.
if [ -n "$READONLY_ZONES" ]; then
  viol="$(printf '%s\n' "$changed" | harness_readonly_violations "$READONLY_ZONES")"
  if [ -n "$viol" ]; then
    log_event "$run_dir" "$task_id" scope readonly-violation \
      "$(printf '%s' "$viol" | jq -Rcs '{paths: split("\n")}')"
    set_status "blocked"
    printf 'дифф трогает readonly-зоны — задача blocked:\n%s\n' "$viol" >&2
    exit 1
  fi
fi

gate_out="$(log_phase_stdout "$run_dir" gate)"
log_event "$run_dir" "$task_id" gate started
gate_dir="$work/repo${GATE_WORKDIR:+/$GATE_WORKDIR}"
run_with_deadline "$DEADLINE_SEC" bash -c "cd '$gate_dir' && $GATE_CMD" > "$gate_out" 2>&1
gate_rc=$?

if [ "$gate_rc" -ne 0 ]; then
  log_event "$run_dir" "$task_id" gate red "$(jq -cn --arg rc "$gate_rc" '{exit_code: $rc}')"
  set_status "blocked"
  printf 'гейт красный (код %s) — MR не создаётся, разбор в %s\n' "$gate_rc" "$gate_out" >&2
  exit 1
fi
log_event "$run_dir" "$task_id" gate green

# Полный прогон тестов инстанса. У шаблона это Ярус 3: гоняется только перед
# push, а не на каждой правке — дорого. Пусто → инстанс его не объявил.
if [ -n "$GATE_TEST_CMD" ]; then
  test_out="$(log_phase_stdout "$run_dir" gate-test)"
  log_event "$run_dir" "$task_id" gate-test started
  run_with_deadline "$DEADLINE_SEC" bash -c "cd '$gate_dir' && $GATE_TEST_CMD" \
    > "$test_out" 2>&1
  test_rc=$?
  if [ "$test_rc" -ne 0 ]; then
    log_event "$run_dir" "$task_id" gate-test red \
      "$(jq -cn --arg rc "$test_rc" '{exit_code: $rc}')"
    set_status "blocked"
    printf 'полный прогон тестов красный (код %s) — разбор в %s\n' \
      "$test_rc" "$test_out" >&2
    exit 1
  fi
  log_event "$run_dir" "$task_id" gate-test green
fi

# Шаг 3. Секрет, уехавший в MR, дороже красного гейта. Скан задаёт инстанс.
if [ -n "$SECRET_SCAN_CMD" ]; then
  scan_out="$(log_phase_stdout "$run_dir" secret-scan)"
  log_event "$run_dir" "$task_id" secret-scan started
  run_with_deadline "$DEADLINE_SEC" bash -c "cd '$work/repo' && $SECRET_SCAN_CMD" \
    > "$scan_out" 2>&1
  scan_rc=$?
  if [ "$scan_rc" -ne 0 ]; then
    log_event "$run_dir" "$task_id" secret-scan red \
      "$(jq -cn --arg rc "$scan_rc" '{exit_code: $rc}')"
    set_status "blocked"
    printf 'секрет-скан красный (код %s) — push не делается, разбор в %s\n' \
      "$scan_rc" "$scan_out" >&2
    exit 1
  fi
  log_event "$run_dir" "$task_id" secret-scan green
fi

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

mr_path="$(mr_create "$MR_DIR" "$branch" "$BASE_BRANCH" "orc($task_id)" "$body")" || mr_path=""
if [ -z "$mr_path" ]; then
  log_event "$run_dir" "$task_id" mr failed
  set_status "blocked"
  printf 'MR не создан, а ветка уже запушена — задача blocked, разбирать вручную\n' >&2
  exit 1
fi
log_event "$run_dir" "$task_id" mr created "$(jq -cn --arg p "$mr_path" '{path: $p}')"
set_status "done"
printf 'MR: %s\n' "$mr_path"
