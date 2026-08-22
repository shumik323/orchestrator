# Вотчдог. Имена латиницей — см. scripts/run-bats.sh.
#
# Утилиты timeout в системе нет (ни timeout, ни gtimeout), поэтому дедлайн
# свой. Проверяется не только код возврата, но и то, что внук реально убит:
# claude -p умеет висеть, не отдав ни байта, и оставленный процесс держал бы
# рабочий каталог и квоту.

setup() {
  ORC_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  LIB="$ORC_ROOT/scripts/lib/watchdog.sh"
}

@test "fast_command_returns_its_own_zero" {
  run bash -c ". '$LIB'; run_with_deadline 5 true"
  [ "$status" -eq 0 ]
}

@test "fast_command_propagates_nonzero_exit" {
  run bash -c ". '$LIB'; run_with_deadline 5 sh -c 'exit 7'"
  [ "$status" -eq 7 ]
}

@test "slow_command_returns_124_on_deadline" {
  run bash -c ". '$LIB'; run_with_deadline 1 sleep 10"
  [ "$status" -eq 124 ]
}

@test "grandchild_is_killed_not_left_running" {
  run bash -c ". '$LIB'; run_with_deadline 1 sh -c 'sleep 4; printf x > \"$TMP/marker\"'"
  [ "$status" -eq 124 ]
  sleep 5
  [ ! -f "$TMP/marker" ]
}

@test "command_output_reaches_caller" {
  run bash -c ". '$LIB'; run_with_deadline 5 printf 'вывод\n'"
  [ "$output" = "вывод" ]
}
