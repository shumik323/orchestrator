# MR-адаптер. Имена латиницей — см. scripts/run-bats.sh.
# Слой 0 использует бэкенд file: настоящая ветка в bare, MR — файлом .md.

setup() {
  ORC_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  LIB="$ORC_ROOT/scripts/lib/mr.sh"
  printf 'тело описания\n' > "$TMP/body.md"
}

@test "file_backend_writes_markdown_with_branch_and_base" {
  run bash -c ". '$LIB'; MR_BACKEND=file mr_create '$TMP/mr' 'orc/t1' 'main' 'orc(t1)' '$TMP/body.md'"
  [ "$status" -eq 0 ]
  [ -f "$TMP/mr/t1.md" ]
  grep -q 'orc/t1' "$TMP/mr/t1.md"
  grep -q 'main' "$TMP/mr/t1.md"
  grep -q 'тело описания' "$TMP/mr/t1.md"
}

@test "file_backend_prints_path_for_the_caller" {
  out="$(bash -c ". '$LIB'; MR_BACKEND=file mr_create '$TMP/mr' 'orc/t1' 'main' 'orc(t1)' '$TMP/body.md'")"
  [ "$out" = "$TMP/mr/t1.md" ]
}

@test "default_backend_is_file" {
  run bash -c ". '$LIB'; unset MR_BACKEND; mr_create '$TMP/mr' 'orc/t2' 'main' 'orc(t2)' '$TMP/body.md'"
  [ "$status" -eq 0 ]
  [ -f "$TMP/mr/t2.md" ]
}

@test "unknown_backend_is_refused_not_silently_skipped" {
  run bash -c ". '$LIB'; MR_BACKEND=carrier-pigeon mr_create '$TMP/mr' 'orc/t3' 'main' 'x' '$TMP/body.md'"
  [ "$status" -eq 2 ]
}

@test "missing_body_file_is_refused" {
  run bash -c ". '$LIB'; MR_BACKEND=file mr_create '$TMP/mr' 'orc/t4' 'main' 'x' '$TMP/no-such-body.md'"
  [ "$status" -eq 3 ]
  [ ! -f "$TMP/mr/t4.md" ]
}
