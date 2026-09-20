# Сервер дашборда: статика + два действия. Имена латиницей — см. scripts/run-bats.sh.

setup() {
  ORC_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export ORC_STATE="$TMP/state"

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
  printf '%s\n' '{"id":"t1","title":"проба","body":"добавить строку","status":"ready","schema_version":1}' \
                '{"id":"t2","title":"стоп","body":"x","status":"blocked","schema_version":1}' \
                '{"id":"t3","title":"готово","body":"x","status":"done","schema_version":1}' > "$QUEUE"

  # conf обязан лежать под projects/ репозитория: сервер принимает только такие пути
  CONF_NAME="_bats-$$-$RANDOM.local.conf"
  CONF="projects/$CONF_NAME"
  cat > "$ORC_ROOT/$CONF" <<EOC
REPO_URL="$TMP/target.git"
BASE_BRANCH="main"
BRANCH_PREFIX="orc"
GATE_CMD="true"
MR_BACKEND="file"
PUSH_OPTS=""
MR_DIR="$TMP/mr"
QUEUE_FILE="$QUEUE"
DEADLINE_SEC="20"
EOC

  command -v curl >/dev/null || skip "нет curl"
  PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  ORC_GEN_CMD="sh -c 'printf сделано >> file.txt'" python3 "$ORC_ROOT/scripts/dashboard-server.py" "$PORT" \
    > "$TMP/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/dashboard/" && break
    sleep 0.3
  done
}

teardown() {
  kill "$SERVER_PID" 2>/dev/null || true
  rm -f "$ORC_ROOT/$CONF"
}

post() {  # $1 action, $2 id, $3 extra curl args
  curl -s -o "$TMP/body" -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/$1" \
    -H 'Content-Type: application/json' $3 --data "{\"conf\":\"$CONF\",\"id\":\"$2\"}"
}

@test "dashboard_page_is_served" {
  run curl -s "http://127.0.0.1:$PORT/dashboard/"
  [ "$status" -eq 0 ]
  [[ "$output" == *"orchestrator"* ]]
}

@test "post_without_x_orc_header_is_forbidden" {
  [ "$(post ready t2 '')" = "403" ]
  [ "$(jq -r 'select(.id=="t2").status' "$QUEUE")" = "blocked" ]
}

@test "api_ready_moves_blocked_task_and_refuses_done" {
  [ "$(post ready t2 '-H X-Orc:1')" = "200" ]
  [ "$(jq -r 'select(.id=="t2").status' "$QUEUE")" = "ready" ]
  [ "$(post ready t3 '-H X-Orc:1')" = "409" ]
  [ "$(jq -r 'select(.id=="t3").status' "$QUEUE")" = "done" ]
}

@test "api_run_starts_runner_and_task_reaches_done" {
  [ "$(post run t1 '-H X-Orc:1')" = "202" ]
  for _ in $(seq 1 40); do
    [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "done" ] && break
    sleep 0.5
  done
  [ "$(jq -r 'select(.id=="t1").status' "$QUEUE")" = "done" ]
  [ -n "$(git -C "$TMP/target.git" for-each-ref 'refs/heads/orc/*')" ]
  [ -f "$ORC_STATE/logs/t1/dashboard-run.log" ]
}

@test "api_rejects_conf_outside_projects_and_bad_id" {
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/run" -H 'X-Orc: 1' \
    --data '{"conf":"../etc/passwd","id":"t1"}')"
  [ "$code" = "400" ]
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/run" -H 'X-Orc: 1' \
    --data "{\"conf\":\"$CONF\",\"id\":\"../t1\"}")"
  [ "$code" = "400" ]
}

# Ревью 20.09: статика из корня отдавала /.git, клоны с промптами и локальные конфиги.
@test "server_hides_git_state_runs_and_scripts" {
  for p in /.git/HEAD /state/runs/ /scripts/run-task.sh /README.md /projects/../README.md; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$p")"
    [ "$code" = "404" ] || [ "$code" = "400" ] || { echo "$p → $code"; false; }
  done
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/queue/")" = "200" ]
}

@test "server_rejects_foreign_host_header" {
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "http://127.0.0.1:$PORT/dashboard/")" = "403" ]
}

@test "malformed_json_body_is_400_not_crash" {
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/ready" -H 'X-Orc: 1' --data '[1]')"
  [ "$code" = "400" ]
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/ready" -H 'X-Orc: 1' --data "{\"conf\":\"$CONF\",\"id\":5}")"
  [ "$code" = "400" ]
}
