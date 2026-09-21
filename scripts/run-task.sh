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
: "${GATE_CMD:=}"
: "${PUSH_OPTS:=}"
: "${MR_DIR:=mr}"
: "${DEADLINE_SEC:=1800}"
: "${MAX_BUDGET_USD:=1.00}"
: "${REVIEW_TRACKS:=A B}"          # треки с фазой review; C (мелкая правка) идёт в MR без ревью
: "${REVIEW_DEFAULT_TRACK:=A}"     # задача без поля track — старший трек, ревью есть
: "${REVIEW_BUDGET_USD:=2.50}"     # на каждый из двух вызовов ревью: вход в контекст kingfin — ~$0.6 (проба 21.09)
: "${REVIEW_MODEL:=}"              # пусто — модель CLI по умолчанию; sonnet режет цену ревью в разы
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
  # _scratch/ — канал бота, а не правка: исключаем сами, не полагаясь на .gitignore таргета.
  # Список собирается отдельно от фильтра: `… | grep -v … || true` гасил статус всего конвейера,
  # и битый клон читался как «правок нет» (ревью 21.09).
  local listed
  listed="$({ g -C "$work/repo" diff --name-only --no-renames HEAD || exit 1
    g -C "$work/repo" ls-files --others --exclude-standard || exit 1; })" || return 1
  printf '%s\n' "$listed" | grep -v "^$(dirname "$NEEDS_OWNER_FILE")/" || true
}

# Заметки бота (_scratch/*.md) уносятся в лог прогона при ЛЮБОМ исходе — и при таймауте, и при
# ошибке генератора: следующий запуск сносит каталог, а бот мог 25 минут писать NOTES.md (faqs 20.09).
copy_scratch() {
  local scratch_dir
  scratch_dir="$work/repo/$(dirname "$NEEDS_OWNER_FILE")"
  [ -d "$scratch_dir" ] && [ -n "$(find "$scratch_dir" -mindepth 1 -print -quit 2>/dev/null)" ] || return 0
  mkdir -p "$run_dir/scratch"
  cp -R "$scratch_dir"/. "$run_dir/scratch/"
  log_event "$run_dir" "$task_id" implement scratch \
    "$(cd "$scratch_dir" && find . -mindepth 1 -maxdepth 1 | sed 's#^\./##' | jq -Rcs '{files: (split("\n") | map(select(length > 0)))}')"
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

# Гейт обязателен. Раньше пустой GATE_CMD молча становился `true`: ветка без единой проверки
# уходила в MR, а «гейт зелёный» читалось как результат (ревью 21.09: репо без .harness.conf).
if [ -z "$GATE_CMD" ]; then
  ui_outcome "blocked" "гейт не задан: нет GATE_CMD ни в conf проекта, ни в .harness.conf клона"
  log_event "$run_dir" "$task_id" clone gate-missing '{}'
  set_status "blocked"
  printf 'гейт не задан — задача blocked, каталог %s оставлен\n' "$work" >&2
  exit 1
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
  log_generator_result "$run_dir" "$task_id" "$gen_out"
  log_event "$run_dir" "$task_id" implement timeout \
    "$(jq -cn --arg d "$DEADLINE_SEC" '{deadline_sec: $d}')"
  copy_scratch
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
# Код выхода без JSON-строки результата — rate-limit, «Not logged in», крэш CLI. Пустой дифф при
# этом читался как no-change, полдиффа — как done (ревью 21.09, замер на симуляции).
if [ -z "$gen_err" ] && [ "$gen_rc" -ne 0 ]; then
  gen_err="exit-$gen_rc"
fi
if [ -n "$gen_err" ]; then
  ui_outcome "agent-failed" "генератор завершился ошибкой: $gen_err"
  log_event "$run_dir" "$task_id" implement failed \
    "$(jq -cn --arg s "$gen_err" '{subtype: $s}')"
  copy_scratch
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
copy_scratch

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
# Из строки result, не из файла: у stream-json в файле десятки JSON-документов, и jq печатал
# столько же строк — многострочный payload ронял log_event, событие терялось (ревью 21.09).
all_denials="$(printf '%s' "$gen_result" | jq -r '(.permission_denials // []) | map(.tool_name // .tool // "?") | join(", ")' 2>/dev/null || true)"
[ -n "$all_denials" ] && log_event "$run_dir" "$task_id" implement denials-seen \
  "$(jq -cn --arg d "$all_denials" '{tools: $d}')"
denials="$(printf '%s' "$gen_result" | jq -r '(.permission_denials // []) | map(select((.tool_name // .tool // "") == "AskUserQuestion")) | map(.tool_name) | join(", ")' 2>/dev/null || true)"
if [ -n "$denials" ]; then
  ui_outcome "blocked" "бот пытался спросить, вызов отклонён: $denials"
  log_event "$run_dir" "$task_id" implement permission-denied \
    "$(printf '%s' "$gen_result" | jq -c '{denials: (.permission_denials // [])}' 2>/dev/null || printf '{}')"
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

# Фаза review (решение владельца 21.09, вариант «ревьюер → опровергатель»): два чистых вызова
# `claude -p` без истории генератора — иначе ревью наследует его рационализации (false consensus,
# Qiu & Gill 2026). Маршрут по треку задачи (`track` в строке очереди, methodology-routing: A/B/C):
# треки из REVIEW_TRACKS идут на ревью, остальные — сразу в MR. Подтверждённая P1 — blocked с
# таблицей вместо MR; P2/P3 — MR с таблицей. Ревью не правит дерево: изменённое дерево — отказ.
task_track="$(jq -r --arg id "$task_id" 'select(.id == $id) | .track // empty' "${QUEUE_FILE:-/dev/null}" 2>/dev/null || true)"
[ -n "$task_track" ] || task_track="$REVIEW_DEFAULT_TRACK"
review_wanted=0
for tr in $REVIEW_TRACKS; do [ "$tr" = "$task_track" ] && review_wanted=1; done
if [ "$review_wanted" -eq 1 ]; then
  review_dir="$run_dir/review"; mkdir -p "$review_dir"
  ui_phase "ревью (трек $task_track): ревьюер → опровергатель"
  log_event "$run_dir" "$task_id" review started "$(jq -cn --arg t "$task_track" '{track: $t}')"
  g -C "$work/repo" add -A -- . ":(exclude)$scratch_rel"
  g -C "$work/repo" diff --cached > "$review_dir/diff.patch"
  tree_before="$(g -C "$work/repo" diff --cached | shasum | cut -c1-40)|$(g -C "$work/repo" status --porcelain --untracked-files=all | grep -v "^?? $scratch_rel/" | shasum | cut -c1-40)"
  review_tools="--tools Read,Grep,Glob,Bash --disallowedTools Edit,Write,MultiEdit,NotebookEdit \
--settings '{\"disableAllHooks\": true}' --strict-mcp-config --mcp-config '$work/mcp-empty.json' \
--max-budget-usd $REVIEW_BUDGET_USD --output-format json --permission-mode acceptEdits${REVIEW_MODEL:+ --model $REVIEW_MODEL}"
  default_reviewer="claude -p $review_tools --allowedTools 'Read,Grep,Glob,Bash(git diff*),Bash(git log*),Bash(git show*),Bash(cat *),Bash(ls*)' --json-schema '$(cat "$ORC_ROOT/prompts/review-reviewer.schema.json")'"
  default_challenger="claude -p $review_tools --allowedTools 'Read,Grep,Glob,Bash' --json-schema '$(cat "$ORC_ROOT/prompts/review-challenger.schema.json")'"
  review_call() {  # <role> <cmd> <prompt-file> → JSON findings в stdout, лог в review/<role>.log
    local role="$1" cmd="$2" prompt="$3" out rc result
    out="$review_dir/$role.log"
    run_with_deadline "$DEADLINE_SEC" bash -c "cd '$work/repo' && $cmd < '$prompt'" > "$out" 2>&1
    rc=$?
    result="$(last_json_line "$out")"
    if [ "$rc" -ne 0 ] || [ -z "$result" ] || [ "$(printf '%s' "$result" | jq -r '.is_error // false')" = "true" ]; then
      return 1
    fi
    printf '%s' "$result" | jq -c '.structured_output // .' > "$review_dir/$role.json" || return 1
    printf '%s' "$result" | jq -r '.total_cost_usd // empty'
  }
  task_body="$(jq -r --arg id "$task_id" 'select(.id == $id) | .body // ""' "$QUEUE_FILE" 2>/dev/null | head -c 20000)"
  # shellcheck disable=SC2016  # обратные кавычки markdown в printf, не подстановка
  { cat "$ORC_ROOT/prompts/review-reviewer.md"; printf '\n## Задача\n\n%s\n\n## Дифф\n\n```diff\n' "$task_body"; cat "$review_dir/diff.patch"; printf '```\n'; } > "$review_dir/reviewer.prompt"
  rev_cost="$(review_call reviewer "${ORC_REVIEW_CMD:-$default_reviewer}" "$review_dir/reviewer.prompt")" || {
    ui_outcome "blocked" "ревьюер не отработал, разбор в $review_dir/reviewer.log"
    log_event "$run_dir" "$task_id" review failed '{"role":"reviewer"}'
    set_status "blocked"
    printf 'ревьюер не отработал — задача blocked, лог %s\n' "$review_dir/reviewer.log" >&2
    exit 1
  }
  n_found="$(jq -r '.findings | length' "$review_dir/reviewer.json")"
  log_event "$run_dir" "$task_id" review reviewer-finished "$(jq -cn --arg c "${rev_cost:-}" --argjson n "$n_found" '{findings: $n, cost_usd: ($c | if . == "" then null else tonumber end)}')"
  ui_info "ревьюер: находок $n_found${rev_cost:+, $rev_cost USD}"
  # shellcheck disable=SC2016  # обратные кавычки markdown в printf, не подстановка
  { cat "$ORC_ROOT/prompts/review-challenger.md"; printf '\n## Задача\n\n%s\n\n## Находки первого ревьюера\n\n```json\n' "$task_body"; cat "$review_dir/reviewer.json"; printf '\n```\n\n## Дифф\n\n```diff\n'; cat "$review_dir/diff.patch"; printf '```\n'; } > "$review_dir/challenger.prompt"
  ch_cost="$(review_call challenger "${ORC_CHALLENGE_CMD:-$default_challenger}" "$review_dir/challenger.prompt")" || {
    ui_outcome "blocked" "опровергатель не отработал, разбор в $review_dir/challenger.log"
    log_event "$run_dir" "$task_id" review failed '{"role":"challenger"}'
    set_status "blocked"
    printf 'опровергатель не отработал — задача blocked, лог %s\n' "$review_dir/challenger.log" >&2
    exit 1
  }
  tree_after="$(g -C "$work/repo" diff --cached | shasum | cut -c1-40)|$(g -C "$work/repo" status --porcelain --untracked-files=all | grep -v "^?? $scratch_rel/" | shasum | cut -c1-40)"
  if [ "$tree_before" != "$tree_after" ]; then
    ui_outcome "blocked" "ревью изменило рабочее дерево — так нельзя"
    log_event "$run_dir" "$task_id" review tree-modified
    set_status "blocked"
    printf 'ревью изменило рабочее дерево — задача blocked, каталог %s оставлен\n' "$work" >&2
    exit 1
  fi
  # Свод: находка без вердикта опровергателя считается подтверждённой (консервативно); extra — его.
  jq -s '
    (.[0].findings // []) as $r | (.[1].findings // []) as $c | (.[1].extra // []) as $x
    | ($c | map({key: .id, value: .}) | from_entries) as $v
    | [ $r[] | . + {verdict: ($v[.id].verdict // "confirmed"), evidence: ($v[.id].evidence // "опровергатель не высказался")} ]
      + [ $x[] | . + {verdict: "confirmed", evidence: "находка опровергателя"} ]
  ' "$review_dir/reviewer.json" "$review_dir/challenger.json" > "$review_dir/merged.json"
  n_conf="$(jq '[.[] | select(.verdict == "confirmed")] | length' "$review_dir/merged.json")"
  n_ref="$(jq '[.[] | select(.verdict == "refuted")] | length' "$review_dir/merged.json")"
  n_p1="$(jq '[.[] | select(.verdict == "confirmed" and .severity == "P1")] | length' "$review_dir/merged.json")"
  {
    printf '## Ревью: подтверждено %s, опровергнуто %s, P1 подтверждено %s\n\n' "$n_conf" "$n_ref" "$n_p1"
    printf '| # | P | AC | место | сценарий отказа | опровергатель |\n|---|---|---|---|---|---|\n'
    jq -r '.[] | "| \(.id) | \(.severity) | \(.ac // "—") | `\(.place)` | \(.scenario | gsub("\n"; " ") | gsub("\\|"; "/")) | \(.verdict): \(.evidence | gsub("\n"; " ") | gsub("\\|"; "/")) |"' "$review_dir/merged.json"
  } > "$review_dir/review.md"
  log_event "$run_dir" "$task_id" review challenger-finished "$(jq -cn --arg c "${ch_cost:-}" --argjson a "$n_conf" --argjson b "$n_ref" '{confirmed: $a, refuted: $b, cost_usd: ($c | if . == "" then null else tonumber end)}')"
  if [ "$n_p1" -gt 0 ]; then
    ui_outcome "blocked" "ревью: подтверждено P1 — $n_p1, таблица $review_dir/review.md"
    log_event "$run_dir" "$task_id" review red "$(jq -cn --argjson p "$n_p1" --argjson c "$n_conf" '{p1: $p, confirmed: $c}')"
    mkdir -p "$run_dir/scratch"
    { printf 'NEEDS-OWNER: ревью подтвердило P1 (%s), MR не открыт\n\n' "$n_p1"; cat "$review_dir/review.md"; } > "$run_dir/scratch/NEEDS-OWNER.md"
    set_status "blocked"
    printf 'ревью подтвердило P1 — задача blocked, таблица %s\n' "$review_dir/review.md" >&2
    exit 1
  fi
  ui_ok "ревью: подтверждено $n_conf, опровергнуто $n_ref, P1 нет"
  log_event "$run_dir" "$task_id" review green "$(jq -cn --argjson c "$n_conf" --argjson r "$n_ref" '{confirmed: $c, refuted: $r}')"
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
  # Таблица ревью — в MR: владелец чинит подтверждённое при мерже, а не ищет её в логах.
  [ -f "$run_dir/review/review.md" ] && { printf '\n'; cat "$run_dir/review/review.md"; }
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
