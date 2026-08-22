#!/usr/bin/env bash
# Адаптер MR. Слой 0 работает бэкендом file: ветка в bare-репозитории
# настоящая, а сам MR — файл .md для человека.
#
# Целевые репозитории живут на разных платформах, поэтому бэкенд — параметр,
# а не константа.
# Неизвестное значение — отказ, а не молчаливый пропуск: MR, который
# «как будто создан», хуже отсутствующего.

mr_create() {
  local mr_dir="${1:?mr_create <mr_dir> <branch> <base> <title> <body-file>}"
  local branch="${2:?branch}" base="${3:?base}" title="${4:?title}" body="${5:?body-file}"

  if [ ! -f "$body" ]; then
    printf 'mr_create: файла описания нет: %s\n' "$body" >&2
    return 3
  fi

  case "${MR_BACKEND:-file}" in
    file)
      mkdir -p "$mr_dir"
      local out="$mr_dir/${branch##*/}.md"
      # heredoc, а не серия printf: формат, начинающийся с дефиса, printf
      # принимает за флаг и молча не печатает строку, вернув при этом успех
      cat > "$out" <<EOF
# $title

- ветка: \`$branch\`
- база: \`$base\`
- создан: $(date -u +%Y-%m-%dT%H:%M:%SZ)

EOF
      cat "$body" >> "$out"
      printf '%s\n' "$out"
      ;;
    glab)
      glab mr create --source-branch "$branch" --target-branch "$base" \
        --title "$title" --description "$(cat "$body")" --draft --yes
      ;;
    gh)
      gh pr create --head "$branch" --base "$base" \
        --title "$title" --body-file "$body" --draft
      ;;
    *)
      printf 'mr_create: неизвестный MR_BACKEND: %s\n' "${MR_BACKEND:-}" >&2
      return 2
      ;;
  esac
}
