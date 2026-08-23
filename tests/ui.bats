# Живой вывод. Имена латиницей — см. scripts/run-bats.sh.
#
# Два инварианта важнее косметики: прогресс не попадает в stdout (иначе
# ломается разбор «MR: путь») и цвет гаснет вне терминала.

setup() {
  ORC_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  LIB="$ORC_ROOT/scripts/lib/ui.sh"
}

@test "progress_goes_to_stderr_not_stdout" {
  bash -c ". '$LIB'; ui_task t1 orc/t1; ui_phase клон; ui_ok клон; ui_done готово" \
    > "$TMP/out" 2> "$TMP/err"
  [ ! -s "$TMP/out" ]
  [ -s "$TMP/err" ]
}

@test "no_escape_codes_when_stderr_is_not_a_terminal" {
  bash -c ". '$LIB'; ui_ok проверка" 2> "$TMP/err"
  run bash -c "LC_ALL=C grep -c \$'\033' '$TMP/err' || true"
  [ "$output" = "0" ]
}

@test "escape_codes_appear_when_color_is_forced" {
  # Раньше здесь был прогон под pty через script — он оказался флейки
  # (один провал на четыре прогона). Флейк в гейте учит игнорировать красное,
  # поэтому включение цвета проверяется явным переключателем, а путь с pty
  # проверен руками: escape-байты в выводе есть.
  UI_FORCE_COLOR=1 bash -c ". '$LIB'; ui_ok цвет" 2> "$TMP/err"
  run bash -c "LC_ALL=C grep -c \$'\033' '$TMP/err' || true"
  [ "$output" != "0" ]
}

@test "no_color_beats_forced_color" {
  NO_COLOR=1 UI_FORCE_COLOR=1 bash -c ". '$LIB'; ui_ok проверка" 2> "$TMP/err"
  run bash -c "LC_ALL=C grep -c \$'\033' '$TMP/err' || true"
  [ "$output" = "0" ]
}

@test "phase_line_reports_elapsed_seconds" {
  bash -c ". '$LIB'; ui_phase пауза; sleep 1; ui_ok пауза" 2> "$TMP/err"
  run grep -c "(1с)" "$TMP/err"
  [ "$output" = "1" ]
}

@test "failure_line_reports_total_time_of_task" {
  bash -c ". '$LIB'; ui_task t1; sleep 1; ui_fail упало" 2> "$TMP/err"
  run grep -c "всего 1с" "$TMP/err"
  [ "$output" = "1" ]
}
