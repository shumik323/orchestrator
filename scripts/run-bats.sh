#!/usr/bin/env bash
# Поведенческий слой гейта.
#
# Имена тестов в .bats — только латиницей: bats строит имя shell-функции из
# заголовка @test и на кириллице печатает "Executed 0 instead of N",
# то есть прогон выглядит успешным, не выполнив ни одного кейса.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v bats >/dev/null 2>&1; then
  printf 'ДЕГРАДАЦИЯ: bats не найден в PATH, поведение не проверено\n' >&2
  exit 1
fi

set -- "$ROOT"/tests/*.bats
if [ ! -f "$1" ]; then
  printf 'ДЕГРАДАЦИЯ: в tests/ нет ни одного .bats\n' >&2
  exit 1
fi

bats "$@"
