# Гардрейл push. Имена латиницей — см. scripts/run-bats.sh.
#
# Три инварианта: в защищённую ветку не пушим, ветки не удаляем,
# историю не перезаписываем. Детекция залипания сюда НЕ входит — это
# отдельный механизм (у зрелых реализаций гейт мержа и вотчдог разнесены).

setup() {
  ORC_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  "$ORC_ROOT/scripts/make-remote.sh" "$TMP/origin.git" main >/dev/null
  git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
  cd "$TMP/work"
  git config user.email orc@local
  git config user.name orc
  printf 'base\n' > a.txt
  git add a.txt
  git commit -qm base
}

@test "push_to_protected_branch_is_rejected" {
  run git push origin HEAD:refs/heads/main
  [ "$status" -ne 0 ]
  [[ "$output" == *"защищена"* ]]
}

@test "push_to_feature_branch_passes" {
  run git push origin HEAD:refs/heads/orc/t1
  [ "$status" -eq 0 ]
}

@test "bare_holds_only_feature_ref" {
  git push -q origin HEAD:refs/heads/orc/t1
  run git -C "$TMP/origin.git" for-each-ref --format='%(refname)'
  [ "$output" = "refs/heads/orc/t1" ]
}

@test "branch_deletion_is_rejected" {
  git push -q origin HEAD:refs/heads/orc/t1
  run git push origin :refs/heads/orc/t1
  [ "$status" -ne 0 ]
  [[ "$output" == *"удаление"* ]]
}

@test "force_push_over_existing_branch_is_rejected" {
  git push -q origin HEAD:refs/heads/orc/t1
  git reset -q --hard HEAD~1 2>/dev/null || git update-ref -d HEAD
  printf 'divergent\n' > b.txt
  git add b.txt
  git commit -qm divergent
  run git push --force origin HEAD:refs/heads/orc/t1
  [ "$status" -ne 0 ]
  [[ "$output" == *"fast-forward"* ]]
}

@test "protected_list_is_configurable_for_non_main_base" {
  # База проекта не обязательно main — список защищённых веток настраиваемый
  "$ORC_ROOT/scripts/make-remote.sh" "$TMP/other.git" "release/next" >/dev/null
  git remote add other "$TMP/other.git"
  run git push other HEAD:refs/heads/release/next
  [ "$status" -ne 0 ]
  run git push other HEAD:refs/heads/main
  [ "$status" -eq 0 ]
}

@test "hook_is_installed_executable" {
  [ -x "$TMP/origin.git/hooks/pre-receive" ]
}

@test "make_remote_refuses_empty_protected_list" {
  run "$ORC_ROOT/scripts/make-remote.sh" "$TMP/empty.git" ""
  [ "$status" -eq 2 ]
}

@test "hook_falls_back_when_config_value_is_empty" {
  # git config --get отдаёт пустое значение с кодом 0 — раньше это отключало хук
  git -C "$TMP/origin.git" config orc.protected ""
  run git push origin HEAD:refs/heads/main
  [ "$status" -ne 0 ]
  [[ "$output" == *"защищена"* ]]
}
