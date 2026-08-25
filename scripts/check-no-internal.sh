#!/usr/bin/env bash
# Гейт: внутренние имена не должны уезжать в публичный репозиторий.
#
# Артефакты прогонов ловит .gitignore, а имя проекта в комментарии к коду —
# ничто, кроме поиска по содержимому: это обычная строка в файле, который
# в репозитории быть обязан.
#
# Сам список имён здесь НЕ хранится. Список запрещённых слов, лежащий
# в публичном репозитории, и есть публикация этих слов. Он живёт отдельным
# файлом вне репозиториев: INTERNAL_NAMES_FILE, по умолчанию
# ~/.claude/internal-names. Формат: одна регулярка ERE на строку, # — комментарий.
#
# set -e не ставим: grep без совпадений — ответ «чисто», а не ошибка.
set -uo pipefail

DEPENDENCIES=(git grep)

usage() {
  cat <<EOF
${0##*/} — искать внутренние имена и личные пути в репозитории

Использование: ${0##*/} [путь]

  путь          что проверять, по умолчанию корень репозитория
  -h, --help    показать справку

Переменные:
  INTERNAL_NAMES_FILE   список имён, по умолчанию ~/.claude/internal-names

Коды выхода: 0 чисто · 1 найдено · 2 неверное использование
EOF
}

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

check_deps() {
  local missing="" dep
  for dep in ${DEPENDENCIES[@]+"${DEPENDENCIES[@]}"}; do
    command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
  done
  [ -z "$missing" ] || die "нет зависимостей:$missing"
}

names_file() { printf '%s\n' "${INTERNAL_NAMES_FILE:-$HOME/.claude/internal-names}"; }

# Общие шаблоны живут в репозитории: они ничего не выдают. Викилинк ловится
# по букве сразу после скобок, иначе совпадает bash-условие `[[ -f x ]]`.
generic_patterns() {
  printf '%s\n' \
    'викилинк:\[\[[A-Za-zА-Яа-я][^]]*\]\]' \
    'домашний путь:/Users/[a-z]'
}

# Имена из внешнего файла. Файла нет — эти шаблоны пропускаются: у чужого
# клона списка и не должно быть, блокировать его незачем.
private_patterns() {
  local list
  list="$(names_file)"
  [ -f "$list" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$list" 2>/dev/null | sed 's|^|внутреннее имя:|'
}

scan() {
  local root="$1" found=0 entry label pattern hits list
  list="$(names_file)"
  [ -f "$list" ] || printf 'списка имён нет (%s) — проверка только по общим шаблонам\n' "$list"

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    label="${entry%%:*}"
    pattern="${entry#*:}"
    hits="$(cd "$root" && git grep --untracked -nIE -- "$pattern" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      printf '\n%s (%s):\n' "$label" "$pattern" >&2
      printf '%s\n' "$hits" | sed 's/^/  /' >&2
      found=1
    fi
  done <<EOF
$(generic_patterns; private_patterns)
EOF

  return "$found"
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -*) printf '%s: неизвестный флаг: %s\n' "${0##*/}" "$1" >&2; usage >&2; exit 2 ;;
      *) break ;;
    esac
  done

  check_deps
  local root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  [ -d "$root/.git" ] || die "не репозиторий: $root"

  if scan "$root"; then
    printf 'внутренних имён не найдено\n'
    exit 0
  fi
  printf '\nнайдены внутренние имена — репозиторий публичный\n' >&2
  exit 1
}

main "$@"
