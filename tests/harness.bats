# Контракт .harness.conf. Имена латиницей — см. scripts/run-bats.sh.
#
# Конфиг приходит из клонированного репозитория, поэтому он ПАРСИТСЯ, а не
# сорсится: source исполнил бы любой его код ещё до первой проверки.
# Сам шаблон свой конфиг сорсит — но он работает в своём репозитории,
# а раннер клонирует чужие.

setup() {
  ORC_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  LIB="$ORC_ROOT/scripts/lib/harness.sh"
  CONF="$TMP/.harness.conf"
  cat > "$CONF" <<EOF
# Сгенерировано bootstrap.sh
WATCH_DIR="src"
TEST_CMD="uv run pytest -q"
READONLY_ZONES="dist bin obj"
GATE_CMD="turbo type-check lint build"
GATE_TEST_CMD="npm run test:run"
GATE_WORKDIR=""
SECRET_SCAN_CMD=""
EOF
}

@test "conf_get_reads_quoted_value" {
  run bash -c ". '$LIB'; harness_conf_get '$CONF' GATE_CMD"
  [ "$output" = "turbo type-check lint build" ]
}

@test "conf_get_returns_empty_for_missing_key" {
  run bash -c ". '$LIB'; harness_conf_get '$CONF' NO_SUCH_KEY"
  [ -z "$output" ]
}

@test "conf_get_returns_empty_for_empty_value" {
  run bash -c ". '$LIB'; harness_conf_get '$CONF' GATE_WORKDIR"
  [ -z "$output" ]
}

@test "conf_get_ignores_commented_line" {
  printf '#GATE_CMD="закомментировано"\n' >> "$CONF"
  run bash -c ". '$LIB'; harness_conf_get '$CONF' GATE_CMD"
  [ "$output" = "turbo type-check lint build" ]
}

@test "conf_get_does_not_execute_conf_contents" {
  printf 'touch "%s/sourced-marker"\n' "$TMP" >> "$CONF"
  printf 'EVIL="$(touch %s/subst-marker)"\n' "$TMP" >> "$CONF"
  run bash -c ". '$LIB'; harness_conf_get '$CONF' GATE_CMD"
  [ "$output" = "turbo type-check lint build" ]
  [ ! -f "$TMP/sourced-marker" ]
  [ ! -f "$TMP/subst-marker" ]
}

@test "readonly_violations_flags_path_inside_zone" {
  run bash -c "printf 'dist/app.js\nsrc/ok.ts\n' | { . '$LIB'; harness_readonly_violations 'dist bin obj'; }"
  [ "$output" = "dist/app.js" ]
}

@test "readonly_violations_flags_nested_zone" {
  run bash -c "printf 'packages/ui/dist/x.js\n' | { . '$LIB'; harness_readonly_violations 'dist'; }"
  [ "$output" = "packages/ui/dist/x.js" ]
}

@test "readonly_violations_silent_when_clean" {
  run bash -c "printf 'src/a.ts\ndocs/b.md\n' | { . '$LIB'; harness_readonly_violations 'dist bin'; }"
  [ -z "$output" ]
}

@test "readonly_violations_does_not_match_partial_name" {
  # distribution — не dist
  run bash -c "printf 'distribution/a.ts\nbins/b.ts\n' | { . '$LIB'; harness_readonly_violations 'dist bin'; }"
  [ -z "$output" ]
}

@test "readonly_violations_empty_zones_flags_nothing" {
  run bash -c "printf 'dist/app.js\n' | { . '$LIB'; harness_readonly_violations ''; }"
  [ -z "$output" ]
}

@test "conf_get_last_assignment_wins_like_source_would" {
  printf 'GATE_CMD="переопределено ниже"\n' >> "$CONF"
  run bash -c ". '$LIB'; harness_conf_get '$CONF' GATE_CMD"
  [ "$output" = "переопределено ниже" ]
}

@test "conf_get_reads_single_quoted_value" {
  printf "GATE_CMD='в одинарных кавычках'\n" >> "$CONF"
  run bash -c ". '$LIB'; harness_conf_get '$CONF' GATE_CMD"
  [ "$output" = "в одинарных кавычках" ]
}

@test "conf_get_reads_bare_value_without_trailing_comment_or_spaces" {
  printf 'GATE_CMD=bare-значение   # хвостовой комментарий\n' >> "$CONF"
  run bash -c ". '$LIB'; harness_conf_get '$CONF' GATE_CMD"
  [ "$output" = "bare-значение" ]
}

@test "conf_has_tells_declared_empty_from_absent" {
  run bash -c ". '$LIB'; harness_conf_has '$CONF' GATE_WORKDIR"
  [ "$status" -eq 0 ]
  run bash -c ". '$LIB'; harness_conf_has '$CONF' NO_SUCH_KEY"
  [ "$status" -ne 0 ]
}

@test "scope_violations_allows_paths_inside_area" {
  run bash -c "printf 'src/features/x/a.ts\nsrc/features/x/ui/b.vue\n' | { . '$LIB'; harness_scope_violations 'src/features/x'; }"
  [ -z "$output" ]
}

@test "scope_violations_flags_paths_outside_area" {
  run bash -c "printf 'src/features/x/a.ts\nsrc/shared/util.ts\n' | { . '$LIB'; harness_scope_violations 'src/features/x'; }"
  [ "$output" = "src/shared/util.ts" ]
}

@test "scope_violations_does_not_match_sibling_with_same_prefix" {
  run bash -c "printf 'src/features/xyz/a.ts\n' | { . '$LIB'; harness_scope_violations 'src/features/x'; }"
  [ "$output" = "src/features/xyz/a.ts" ]
}

@test "scope_violations_empty_area_allows_everything" {
  run bash -c "printf 'anywhere/a.ts\n' | { . '$LIB'; harness_scope_violations ''; }"
  [ -z "$output" ]
}
