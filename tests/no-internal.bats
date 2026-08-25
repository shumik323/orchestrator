# Гейт на внутренние имена. Имена латиницей — см. scripts/run-bats.sh.
#
# Ни одного настоящего внутреннего имени в файле нет, и ни одной постоянной
# фикстуры тоже. Причина одна и та же: любой чекер по списку запрещённых слов
# находит собственные тестовые данные. Лечится не исключением файла из
# проверки — так гейт слепнет к настоящей утечке в тесте, — а тем, что
# запрещённая строка в файле не появляется вовсе: имя-проба генерируется
# на лету, скобки викилинка собираются из кусков.
#
# Проверяется в обе стороны: ловит подложенное и не срабатывает на похожем.
# Односторонний тест («на чистом репозитории зелёный») проходил бы и у гейта,
# который вообще ничего не ищет.

setup() {
  ORC_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATE="$ORC_ROOT/scripts/check-no-internal.sh"
  PROBE="$ORC_ROOT/_internal-probe.md"
  TMP="$(mktemp -d)"
  NAME="zzprobe$$"
  printf '%s\n' "$NAME" > "$TMP/names"
  REAL_LIST="${INTERNAL_NAMES_FILE:-$HOME/.claude/internal-names}"
}

teardown() {
  [ -f "$PROBE" ] && rm -f "$PROBE"
  return 0
}

@test "gate_is_green_on_current_repository" {
  run env INTERNAL_NAMES_FILE="$TMP/names" "$GATE"
  [ "$status" -eq 0 ]
}

@test "gate_catches_private_name_in_untracked_file" {
  # git grep без --untracked слеп к новым файлам: гейт зеленел бы на пустоте
  printf 'проект %s внутри\n' "$NAME" > "$PROBE"
  run env INTERNAL_NAMES_FILE="$TMP/names" "$GATE"
  [ "$status" -eq 1 ]
}

@test "gate_catches_wikilink_but_not_bash_test_syntax" {
  br='['
  printf 'ссылка %s%sconcepts/ssot]]\n' "$br" "$br" > "$PROBE"
  run env INTERNAL_NAMES_FILE="$TMP/names" "$GATE"
  [ "$status" -eq 1 ]

  printf 'if [[ -f x ]]; then :; fi\n' > "$PROBE"
  run env INTERNAL_NAMES_FILE="$TMP/names" "$GATE"
  [ "$status" -eq 0 ]
}

@test "gate_catches_home_path" {
  printf 'путь /%s/someone/project\n' Users > "$PROBE"
  run env INTERNAL_NAMES_FILE="$TMP/names" "$GATE"
  [ "$status" -eq 1 ]
}

@test "gate_reads_names_from_external_file" {
  run grep -c "INTERNAL_NAMES_FILE" "$GATE"
  [ "$output" != "0" ]
}

@test "gate_contains_no_entry_from_the_real_list" {
  # список живёт вне репозитория: иначе гейт публикует то, что запрещает
  [ -f "$REAL_LIST" ] || skip "списка имён нет — проверять нечего"
  run bash -c "grep -vE '^[[:space:]]*(#|\$)' '$REAL_LIST' | grep -qFf - '$GATE' && printf FOUND || printf CLEAN"
  [ "$output" = "CLEAN" ]
}

@test "gate_skips_private_patterns_when_list_is_missing" {
  # у чужого клона списка нет — блокировать его незачем
  printf 'проект %s внутри\n' "$NAME" > "$PROBE"
  run env INTERNAL_NAMES_FILE="$TMP/no-such-file" "$GATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"списка имён нет"* ]]
}

@test "gate_refuses_unknown_flag_with_code_two" {
  run "$GATE" --unknown-flag
  [ "$status" -eq 2 ]
}
