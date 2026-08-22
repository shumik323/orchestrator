# Имена тестов латиницей — см. комментарий в scripts/run-bats.sh.

setup() {
  ORC_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  PROBE="$ORC_ROOT/scripts/zz-temp-probe.sh"
}

teardown() {
  [ -f "$PROBE" ] && rm -f "$PROBE"
  return 0
}

@test "lint_shell_is_green_against_recorded_baseline" {
  run "$ORC_ROOT/scripts/lint-shell.sh"
  [ "$status" -eq 0 ]
}

@test "lint_shell_rejects_garbage_baseline" {
  printf 'не число\n' > "$TMP/baseline"
  run env SC_BASELINE_FILE="$TMP/baseline" "$ORC_ROOT/scripts/lint-shell.sh"
  [ "$status" -eq 2 ]
}

@test "lint_shell_rejects_missing_baseline" {
  run env SC_BASELINE_FILE="$TMP/no-such-file" "$ORC_ROOT/scripts/lint-shell.sh"
  [ "$status" -eq 2 ]
}

@test "lint_shell_turns_red_on_new_finding" {
  # ls $1 даёт SC2086. Форма с безопасным литералом (V=/tmp/x; ls $V)
  # shellcheck сознательно не флагует — такая мутация прошла бы насквозь.
  printf '%s\n' '#!/usr/bin/env bash' 'ls $1' > "$PROBE"
  run "$ORC_ROOT/scripts/lint-shell.sh"
  [ "$status" -eq 1 ]
}

@test "paths_lib_keeps_state_outside_repo" {
  run bash -c ". '$ORC_ROOT/scripts/lib/paths.sh'; orc_task_dir t1"
  [ "$status" -eq 0 ]
  case "$output" in
    "$ORC_ROOT"*) return 1 ;;
    *) return 0 ;;
  esac
}
