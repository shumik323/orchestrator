#!/usr/bin/env bash
# Единственная точка входа проверки репозитория оркестратора.
# Репозиторий подчиняется тому же гейту, который сам применяет к чужому коду.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

"$HERE/lint-shell.sh" || rc=1
"$HERE/run-bats.sh"   || rc=1

if [ "$rc" -eq 0 ]; then
  printf 'verify-all: зелёный\n'
else
  printf 'verify-all: красный\n' >&2
fi
exit "$rc"
