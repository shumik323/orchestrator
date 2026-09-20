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
# shellcheck source=lib/ui.sh
. "$HERE/lib/ui.sh"

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
: "${WRITE_SCOPE:=}"
: "${SETUP_CMD:=}"
: "${SETUP_MARKER:=node_modules}"
: "${NEEDS_OWNER_FILE:=_scratch/NEEDS-OWNER.md}"
: "${COMMIT_MSG_TEMPLATE:=orc({id}): автоматическая правка}"

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
  # _scratch/ — канал бота, а не правка: исключаем сами, не полагаясь на .gitignore таргета
  { g -C "$work/repo" diff --name-only --no-renames HEAD || return 1
    g -C "$work/repo" ls-files --others --exclude-standard || return 1
  } | grep -v "^$(dirname "$NEEDS_OWNER_FILE")/" || true
}

# Инвариант обязан падать громко. Прогон не прерываем — его исход уже
# определён, а артефакты нужны для разбора, — но недопустимый переход
# попадает и в stderr, и в лог событий, а не теряется молча.
set_status() {
  [ -n "$QUEUE_FILE" ] && [ -f "$QUEUE_FILE" ] || return 0
  if ! queue_set_status "$QUEUE_FILE" "$task_id" "$1"; then
    printf 'состояние очереди не обновлено: недопустимый переход в %s\n' "$1" >&2
    log_event "$run_dir" "$task_id" state invalid-transition \
      "$(jq -cn --arg to "$1" '{to: $to}')"
  fi
  return 0
}

branch="$BRANCH_PREFIX/$task_id"

# Раннер взял задачу — с этого момента любой исход достижим. Раньше переход
# стоял перед вызовом генератора, и сбой на клоне или setup оставлял задачу
# в ready, откуда терминального статуса нет.
# Первый переход — предусловие, не исход: задача не в ready (blocked, done, running) не
# запускается вовсе. Ревью 20.09: раннер печатал invalid-transition и шёл до MR, очередь врала.
# Задачи нет в очереди вовсе — отдельный путь ниже (prompt-empty), здесь только известная задача.
if [ -n "$QUEUE_FILE" ] && [ -f "$QUEUE_FILE" ] && [ -n "$(queue_status_of "$QUEUE_FILE" "$task_id")" ] \
   && ! queue_set_status "$QUEUE_FILE" "$task_id" running; then
  log_event "$run_dir" "$task_id" state refused-start
  printf 'задача %s не в ready — прогон не начат (статус: %s)\n' \
    "$task_id" "$(queue_status_of "$QUEUE_FILE" "$task_id")" >&2
  exit 3
fi
ui_task "$task_id" "$branch → $BASE_BRANCH"
ui_phase "клон $BASE_BRANCH"
log_event "$run_dir" "$task_id" clone started
if [ ! -d "$work/repo/.git" ]; then
  g clone -q --branch "$BASE_BRANCH" "$REPO_URL" "$work/repo" || {
    log_event "$run_dir" "$task_id" clone failed
    set_status "blocked"
    exit 1
  }
fi
# Повторный прогон обязан начинаться с чистого дерева базовой ветки.
# Иначе он читает .harness.conf, который мог переписать генератор прошлого
# прогона, и наследует его незакоммиченную работу — MR появлялся там,
# где генератор не сделал ничего.
# clean без -x: игнорируемое (node_modules) переживает прогон, иначе
# повторный запуск станет дороже самого прогона.
g -C "$work/repo" fetch -q origin "$BASE_BRANCH"
g -C "$work/repo" checkout -q -B "$branch" "origin/$BASE_BRANCH"
g -C "$work/repo" reset -q --hard "origin/$BASE_BRANCH"
g -C "$work/repo" clean -qfd
# Канал бота — игнорируемый каталог, clean без -x его бережёт: старый NEEDS-OWNER.md блокировал
# бы повтор тем же вопросом после ответа владельца (ревью 20.09). Только подкаталог: dirname
# «.» означал бы весь клон.
scratch_rel="$(dirname "$NEEDS_OWNER_FILE")"
if [ "$scratch_rel" = . ] || [ -z "$scratch_rel" ]; then
  printf 'NEEDS_OWNER_FILE обязан лежать в подкаталоге (сейчас: %s)\n' "$NEEDS_OWNER_FILE" >&2
  exit 3
fi
rm -rf "${work:?}/repo/$scratch_rel"
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
  ui_info "из .harness.conf: гейт [${GATE_CMD}], зоны [${READONLY_ZONES:-нет}]"
  log_event "$run_dir" "$task_id" clone harness-conf \
    "$(jq -cn --arg g "$GATE_CMD" --arg z "$READONLY_ZONES" \
       '{gate_cmd: $g, readonly_zones: $z}')"
fi

ui_ok "клон"
log_event "$run_dir" "$task_id" clone finished

# Шаг 1а. Зависимости проекта ставятся до генератора, а не до гейта: генератор
# сам запускает тесты, и клон без них учит его, что проверка недоступна.
# Каталог клона свой у каждой задачи, поэтому clean без -x бережёт установленное
# только между повторами ОДНОЙ задачи — соседняя приходит в пустое дерево.
# Маркер вместо безусловного вызова: npm ci сносит и ставит дерево заново,
# и повтор задачи стоил бы дороже самого прогона.
if [ -n "$SETUP_CMD" ] && [ ! -e "$work/repo/$SETUP_MARKER" ]; then
  setup_out="$(log_phase_stdout "$run_dir" setup)"
  ui_phase "зависимости: $SETUP_CMD"
  log_event "$run_dir" "$task_id" setup started \
    "$(jq -cn --arg c "$SETUP_CMD" --arg m "$SETUP_MARKER" '{cmd: $c, marker: $m}')"
  run_with_deadline "$DEADLINE_SEC" \
    bash -c "cd '$work/repo' && $SETUP_CMD" > "$setup_out" 2>&1
  setup_rc=$?
  # Провал установки читался бы как «править было нечего»: генератор в дереве
  # без зависимостей делает пустой диф, а не работу.
  if [ "$setup_rc" -ne 0 ]; then
    ui_fail "зависимости не встали (код $setup_rc)"
    log_event "$run_dir" "$task_id" setup failed \
      "$(jq -cn --arg rc "$setup_rc" '{exit_code: $rc}')"
    set_status "blocked"
    printf 'setup провалился (код %s) — генератор не запускался, разбор в %s\n' \
      "$setup_rc" "$setup_out" >&2
    exit 1
  fi
  ui_ok "зависимости"
  log_event "$run_dir" "$task_id" setup finished
elif [ -n "$SETUP_CMD" ]; then
  ui_info "зависимости на месте ($SETUP_MARKER), setup пропущен"
  log_event "$run_dir" "$task_id" setup skipped \
    "$(jq -cn --arg m "$SETUP_MARKER" '{marker: $m}')"
fi

# Промпт — файлом на диске: он же артефакт разбора, если прогон провалится.
if [ -n "$QUEUE_FILE" ] && [ -f "$QUEUE_FILE" ]; then
  jq -r --arg id "$task_id" 'select(.id == $id) | "\(.title)\n\n\(.body)"' \
    "$QUEUE_FILE" > "$work/prompt.txt"
else
  printf 'задача %s\n' "$task_id" > "$work/prompt.txt"
fi

# Границы прогона дописываются к КАЖДОЙ задаче. Репозиторий инстанса несёт свои
# правила ведения работы — буфер наблюдений, лог сессии, порядок коммитов — и
# генератор читает их вместе с CLAUDE.md, потому что источник project мы намеренно
# оставляем. Дальше он их честно исполняет, а для петли запись в такой файл это
# выход за область и потеря всей сделанной работы.
# Прогон 25.08: готовая правка на $1.89 заблокирована одной строкой, дописанной
# в .claude/PENDING-NOTES.md по правилу репозитория. Прогон 18.09: с запретом «не заводи файлы»
# бот оставил два наблюдения в итоговом ответе, который раннер не читает, — отсюда _scratch/.
# Дописываются ПОСЛЕ тела задачи: последняя инструкция весит больше в длинном промпте.
if [ -s "$work/prompt.txt" ]; then
  {
    printf '\n\n---\n\n'
    printf 'Границы прогона. Это указания раннера, и они сильнее процессных правил репозитория:\n'
    printf -- '- Буферы наблюдений и логи проекта не трогай: запись туда попадает в дифф и отменяет прогон.\n'
    printf -- '- Ничего не коммить и не пушить: ветку и коммит делает раннер сам.\n'
    printf -- '- Правь только файлы, названные в задаче. Один лишний файл в диффе отменяет весь прогон.\n'
    printf -- '- Единственное место для записей вне задачи — каталог %s/ (в дифф не попадает, раннер уносит его в лог прогона):\n' "$scratch_rel"
    printf -- '  заметки по ходу — %s/NOTES.md, по строке на заметку; нужен ответ владельца — %s, первая строка «NEEDS-OWNER: чего не хватает», тогда файлы задачи не правь.\n' "$scratch_rel" "$NEEDS_OWNER_FILE"
    printf -- '- Итоговый ответ раннер не читает: что не записано в %s/, человек не увидит.\n' "$scratch_rel"
  } >> "$work/prompt.txt"
fi

# Пустой промпт означает, что задачи с таким id в очереди нет. Запускать
# на этом генератор — прогон модели без задания за деньги подписки.
# Проверка идёт ПОСЛЕ дописывания границ, но смотрит на исходное тело: границы
# добавляются только к непустому промпту, иначе они сами сделали бы файл непустым.
if [ ! -s "$work/prompt.txt" ]; then
  ui_outcome "blocked" "промпт пуст: задачи $task_id нет в очереди"
  log_event "$run_dir" "$task_id" implement prompt-empty
  set_status "blocked"
  exit 1
fi

task_scope="$(jq -r --arg id "$task_id" 'select(.id == $id) | .scope // empty' \
  "${QUEUE_FILE:-/dev/null}" 2>/dev/null || true)"
[ -n "$task_scope" ] && WRITE_SCOPE="$task_scope"

# disableAllHooks: хуки инстанса не гейтятся доверием к каталогу и в headless
# отрабатывают всегда — прогон 25.08 поймал падение SessionEnd-хука целевого репозитория прямо
# внутри задачи. Ярус «проверка на конце хода» раннер и так вызывает сам, поэтому
# хуки клонированного репозитория здесь только мешают.
# Гасится ИМЕННО так, а не через --setting-sources: тот исключил бы источник
# project целиком, а вместе с ним CLAUDE.md репозитория — правила проекта боту
# нужны. Замер 25.08: с этим флагом ошибка SessionEnd исчезает, а ответ про
# правила проекта приходит без единого обращения к файлам.
# --strict-mcp-config с пустым конфигом: MCP-серверы из ~/.claude.json пользователя (у владельца
# четыре) грузили бы схемы тулов в контекст каждого прогона; боту они недоступны и не нужны.
printf '{"mcpServers":{}}' > "$work/mcp-empty.json"
# stream-json: строка на событие, результат последней строкой — дашборд читает ходы по мере записи
# (замер 20.09: файл растёт построчно, без --verbose поток в -p не работает). Поля result те же.
default_gen="claude -p --output-format stream-json --verbose --max-budget-usd $MAX_BUDGET_USD \
--allowedTools $ALLOWED_TOOLS --permission-mode acceptEdits \
--settings '{\"disableAllHooks\": true}' --strict-mcp-config --mcp-config '$work/mcp-empty.json'"
gen_cmd="${ORC_GEN_CMD:-$default_gen}"
gen_out="$(log_phase_stdout "$run_dir" implement)"

ui_phase "генератор, дедлайн ${DEADLINE_SEC}с"
log_event "$run_dir" "$task_id" implement started \
  "$(jq -cn --arg d "$DEADLINE_SEC" '{deadline_sec: $d}')"

run_with_deadline "$DEADLINE_SEC" \
  bash -c "cd '$work/repo' && $gen_cmd < '$work/prompt.txt'" > "$gen_out" 2>&1
gen_rc=$?

if [ "$gen_rc" -eq 124 ]; then
  ui_outcome "agent-failed" "генератор не уложился в ${DEADLINE_SEC}с"
  log_event "$run_dir" "$task_id" implement timeout \
    "$(jq -cn --arg d "$DEADLINE_SEC" '{deadline_sec: $d}')"
  set_status "agent-failed"
  printf 'генератор не уложился в %s с — задача blocked, каталог %s оставлен\n' \
    "$DEADLINE_SEC" "$work" >&2
  exit 1
fi

log_generator_result "$run_dir" "$task_id" "$gen_out"
ui_ok "генератор"
gen_result="$(last_json_line "$gen_out")"
gen_cost="$(printf '%s' "$gen_result" | jq -r '.total_cost_usd // empty' 2>/dev/null || true)"
gen_turns="$(printf '%s' "$gen_result" | jq -r '.num_turns // empty' 2>/dev/null || true)"
[ -n "$gen_cost" ] && ui_info "стоимость $gen_cost USD, ходов ${gen_turns:-?}"
log_event "$run_dir" "$task_id" implement finished \
  "$(jq -cn --arg rc "$gen_rc" '{exit_code: $rc}')"

# Ошибка генератора не должна читаться как «править было нечего».
# Живой прогон 22.08: упор в --max-budget-usd на 4-м ходу дал пустой диф,
# и задача была помечена done — успех, за которым нет работы.
gen_err="$(printf '%s' "$gen_result" | jq -r '
  if (.is_error == true) or (((.subtype // "") | startswith("error")))
  then (.subtype // "error") else empty end' 2>/dev/null || true)"
if [ -n "$gen_err" ]; then
  ui_outcome "agent-failed" "генератор завершился ошибкой: $gen_err"
  log_event "$run_dir" "$task_id" implement failed \
    "$(jq -cn --arg s "$gen_err" '{subtype: $s}')"
  set_status "agent-failed"
  printf 'генератор завершился ошибкой (%s) — задача blocked, каталог %s оставлен\n' \
    "$gen_err" "$work" >&2
  exit 1
fi

# Канал «сделал, но с вопросом». Бот пишет вопрос в файл рабочего каталога, раннер читает файл —
# не текст result: формат вывода у генераторов разный, а файл один на всех. Прогон 18.09 (kingfin,
# задача без копирайта): бот выдумал текст и признался в итоговом сообщении, но дифф и гейт были
# зелёные, и задача ушла в done с MR. Файл копируется в лог прогона: записи из веток стекаются в
# одно место без конфликтов. Пустой файл — не вопрос.
# Заметки бота по ходу (_scratch/*.md, каталог в .gitignore инстанса) уносятся в лог прогона
# целиком и при любом исходе: записи из веток стекаются в одно место без конфликтов, владелец
# разбирает их в /end-session вместе со своим буфером. В дифф каталог не попадает.
scratch_dir="$work/repo/$(dirname "$NEEDS_OWNER_FILE")"
if [ -d "$scratch_dir" ] && [ -n "$(find "$scratch_dir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  mkdir -p "$run_dir/scratch"
  cp -R "$scratch_dir"/. "$run_dir/scratch/"
  log_event "$run_dir" "$task_id" implement scratch \
    "$(cd "$scratch_dir" && find . -mindepth 1 -maxdepth 1 | sed 's#^\./##' | jq -Rcs '{files: (split("\n") | map(select(length > 0)))}')"
fi

if [ -s "$work/repo/$NEEDS_OWNER_FILE" ]; then
  question="$(head -c 2000 "$work/repo/$NEEDS_OWNER_FILE")"
  ui_outcome "blocked" "бот ждёт владельца: $NEEDS_OWNER_FILE"
  log_event "$run_dir" "$task_id" implement needs-owner \
    "$(jq -cn --arg p "$NEEDS_OWNER_FILE" --arg q "$question" '{path: $p, question: $q}')"
  set_status "blocked"
  printf 'бот ждёт владельца — задача blocked, вопрос в %s/scratch/, каталог %s оставлен\n%s\n' \
    "$run_dir" "$work" "$question" >&2
  exit 1
fi

# Вторичный сигнал того же класса: бот вызвал AskUserQuestion, а в -p без хоста вызов отклоняется
# молча и оседает в permission_denials итогового result (дока headless, 18.09.2026). Файл ловит
# «знаю о пробеле и говорю словами», это поле — «попытался спросить и не смог». Поля нет → 0.
all_denials="$(jq -r '(.permission_denials // []) | map(.tool_name // .tool // "?") | join(", ")' "$gen_out" 2>/dev/null || true)"
[ -n "$all_denials" ] && log_event "$run_dir" "$task_id" implement denials-seen \
  "$(jq -cn --arg d "$all_denials" '{tools: $d}')"
denials="$(jq -r '(.permission_denials // []) | map(select((.tool_name // .tool // "") == "AskUserQuestion")) | map(.tool_name) | join(", ")' "$gen_out" 2>/dev/null || true)"
if [ -n "$denials" ]; then
  ui_outcome "blocked" "бот пытался спросить, вызов отклонён: $denials"
  log_event "$run_dir" "$task_id" implement permission-denied \
    "$(jq -c '{denials: (.permission_denials // [])}' "$gen_out" 2>/dev/null || printf '{}')"
  set_status "blocked"
  printf 'бот пытался спросить владельца (%s), в headless вызов отклонён — задача blocked, каталог %s оставлен\n' \
    "$denials" "$work" >&2
  exit 1
fi

changed="$(changed_paths)" || {
  log_event "$run_dir" "$task_id" implement git-failed
  set_status "blocked"
  printf 'git не смог перечислить изменения — задача blocked, каталог %s оставлен\n' "$work" >&2
  exit 1
}

if [ -z "$changed" ]; then
  ui_outcome "no-change" "правка не потребовалась, MR не создан"
  log_event "$run_dir" "$task_id" implement no-change
  set_status "no-change"
  printf 'правка не потребовалась — MR не создан\n'
  exit 0
fi

# Шаг 2. Область работы: промпт просит не трогать лишнее, эта проверка запрещает.
# Префикс из трёх символов у status --porcelain отрезается: нужен путь, не статус.
if [ -n "$READONLY_ZONES" ]; then
  viol="$(printf '%s\n' "$changed" | harness_readonly_violations "$READONLY_ZONES")"
  if [ -n "$viol" ]; then
    ui_outcome "scope-violation" "дифф трогает readonly-зоны"
    log_event "$run_dir" "$task_id" scope readonly-violation \
      "$(printf '%s' "$viol" | jq -Rcs '{paths: split("\n")}')"
    set_status "scope-violation"
    printf 'дифф трогает readonly-зоны — задача blocked:\n%s\n' "$viol" >&2
    exit 1
  fi
fi

# Граница области работы. Промпт просит держаться модуля, эта проверка обязывает.
if [ -n "$WRITE_SCOPE" ]; then
  out_of_scope="$(printf '%s\n' "$changed" | harness_scope_violations "$WRITE_SCOPE")"
  if [ -n "$out_of_scope" ]; then
    ui_outcome "scope-violation" "дифф вышел за область [$WRITE_SCOPE]"
    log_event "$run_dir" "$task_id" scope out-of-scope \
      "$(printf '%s' "$out_of_scope" | jq -Rcs '{paths: split("\n"), allowed: "'"$WRITE_SCOPE"'"}')"
    set_status "scope-violation"
    printf 'дифф вышел за разрешённую область [%s]:\n%s\n' "$WRITE_SCOPE" "$out_of_scope" >&2
    exit 1
  fi
fi

gate_out="$(log_phase_stdout "$run_dir" gate)"
ui_phase "гейт: $GATE_CMD"
log_event "$run_dir" "$task_id" gate started
gate_dir="$work/repo${GATE_WORKDIR:+/$GATE_WORKDIR}"
run_with_deadline "$DEADLINE_SEC" bash -c "cd '$gate_dir' && $GATE_CMD" > "$gate_out" 2>&1
gate_rc=$?

if [ "$gate_rc" -ne 0 ]; then
  ui_outcome "gate-failed" "гейт красный (код $gate_rc)"
  log_event "$run_dir" "$task_id" gate red "$(jq -cn --arg rc "$gate_rc" '{exit_code: $rc}')"
  set_status "gate-failed"
  printf 'гейт красный (код %s) — MR не создаётся, разбор в %s\n' "$gate_rc" "$gate_out" >&2
  exit 1
fi
ui_ok "гейт"
log_event "$run_dir" "$task_id" gate green

# Полный прогон тестов инстанса. У шаблона это Ярус 3: гоняется только перед
# push, а не на каждой правке — дорого. Пусто → инстанс его не объявил.
if [ -n "$GATE_TEST_CMD" ]; then
  test_out="$(log_phase_stdout "$run_dir" gate-test)"
  ui_phase "полный прогон тестов: $GATE_TEST_CMD"
  log_event "$run_dir" "$task_id" gate-test started
  run_with_deadline "$DEADLINE_SEC" bash -c "cd '$gate_dir' && $GATE_TEST_CMD" \
    > "$test_out" 2>&1
  test_rc=$?
  if [ "$test_rc" -ne 0 ]; then
    ui_outcome "gate-failed" "полный прогон тестов красный (код $test_rc)"
    log_event "$run_dir" "$task_id" gate-test red \
      "$(jq -cn --arg rc "$test_rc" '{exit_code: $rc}')"
    set_status "gate-failed"
    printf 'полный прогон тестов красный (код %s) — разбор в %s\n' \
      "$test_rc" "$test_out" >&2
    exit 1
  fi
  ui_ok "полный прогон тестов"
  log_event "$run_dir" "$task_id" gate-test green
fi

# Шаг 3. Секрет, уехавший в MR, дороже красного гейта. Скан задаёт инстанс.
if [ -n "$SECRET_SCAN_CMD" ]; then
  scan_out="$(log_phase_stdout "$run_dir" secret-scan)"
  ui_phase "секрет-скан"
  log_event "$run_dir" "$task_id" secret-scan started
  run_with_deadline "$DEADLINE_SEC" bash -c "cd '$work/repo' && $SECRET_SCAN_CMD" \
    > "$scan_out" 2>&1
  scan_rc=$?
  if [ "$scan_rc" -ne 0 ]; then
    ui_outcome "blocked" "секрет-скан красный (код $scan_rc)"
    log_event "$run_dir" "$task_id" secret-scan red \
      "$(jq -cn --arg rc "$scan_rc" '{exit_code: $rc}')"
    set_status "blocked"
    printf 'секрет-скан красный (код %s) — push не делается, разбор в %s\n' \
      "$scan_rc" "$scan_out" >&2
    exit 1
  fi
  ui_ok "секрет-скан"
  log_event "$run_dir" "$task_id" secret-scan green
fi

# _scratch/ — канал, не правка: в коммит не идёт даже без .gitignore у таргета.
# Длинная форма :(exclude): короткая «:!_scratch» падает — git читает «_» как magic-букву.
g -C "$work/repo" add -A -- . ":(exclude)$scratch_rel"
# Сообщение коммита — из конфига проекта: у kingfin хук commit-msg требует «MD-NNNN: …», а хуки
# в клон не приезжают (§11 gotchas kingfin). {id} и {title} подставляются из задачи.
task_title=""
[ -n "$QUEUE_FILE" ] && [ -f "$QUEUE_FILE" ] && \
  task_title="$(jq -r --arg id "$task_id" 'select(.id == $id) | .title // ""' "$QUEUE_FILE" 2>/dev/null | head -n 1)"
commit_msg="${COMMIT_MSG_TEMPLATE//\{id\}/$task_id}"
commit_msg="${commit_msg//\{title\}/$task_title}"
# Неудачный коммит (нечего стейджить, пустое сообщение) раньше проглатывался, и push уходил с базой.
g -C "$work/repo" commit -qm "$commit_msg" || {
  ui_outcome "blocked" "коммит не создан"
  log_event "$run_dir" "$task_id" push commit-failed
  set_status "blocked"
  printf 'коммит не создан — задача blocked, каталог %s оставлен\n' "$work" >&2
  exit 1
}

# PUSH_OPTS разворачивается словами намеренно: -o ci.skip это два аргумента
# shellcheck disable=SC2086
g -C "$work/repo" push --no-verify $PUSH_OPTS -q origin "$branch" || {
  log_event "$run_dir" "$task_id" push rejected
  set_status "blocked"
  printf 'push отклонён — см. гардрейл целевого репозитория\n' >&2
  exit 1
}
ui_ok "push $branch"
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
  ui_outcome "blocked" "MR не создан, а ветка уже запушена"
  log_event "$run_dir" "$task_id" mr failed
  set_status "blocked"
  printf 'MR не создан, а ветка уже запушена — задача blocked, разбирать вручную\n' >&2
  exit 1
fi
ui_outcome "done" "MR: $mr_path"
log_event "$run_dir" "$task_id" mr created "$(jq -cn --arg p "$mr_path" '{path: $p}')"
set_status "done"
printf 'MR: %s\n' "$mr_path"
