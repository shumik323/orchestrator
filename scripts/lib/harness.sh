#!/usr/bin/env bash
# Контракт .harness.conf инстанса харнесса: чтение значений и readonly-зоны.
#
# Конфиг ПАРСИТСЯ, а не сорсится. Он лежит в клонированном репозитории, и
# source исполнил бы любой его код, включая подстановки, ещё до первой
# проверки. Сам шаблон свой конфиг сорсит — и это нормально: он работает
# в своём репозитории, а раннер клонирует чужие.
#
# Гейт и его команды принадлежат инстансу: держать их копию в конфиге
# раннера значит завести второй источник истины и разойтись с ним молча.

harness_conf_get() {
  local file="${1:?harness_conf_get <файл> <ключ>}" key="${2:?ключ}" line val
  [ -f "$file" ] || return 0
  # последнее вхождение побеждает — так же, как повторное присваивание при source
  line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -1)"
  [ -n "$line" ] || return 0
  val="${line#*=}"
  # три формы записи. Раньше разбиралась только первая, и значение в одинарных
  # кавычках молча превращалось в пустое — а пустой GATE_CMD подменялся дефолтом
  # раннера `true`, то есть гейт зеленел, ничего не проверив.
  case "$val" in
    \"*) val="${val#\"}"; val="${val%%\"*}" ;;
    \'*) val="${val#\'}"; val="${val%%\'*}" ;;
    *)   val="${val%%[[:space:]]#*}"
         # обрезать хвостовые пробелы у bare-значения
         while [ "$val" != "${val%[[:space:]]}" ]; do val="${val%[[:space:]]}"; done ;;
  esac
  printf '%s\n' "$val"
}

# Объявлен ли ключ вообще — отличать «инстанс молчит» от «объявил пустым».
harness_conf_has() {
  local file="${1:?}" key="${2:?}"
  [ -f "$file" ] || return 1
  grep -qE "^[[:space:]]*${key}=" "$file"
}

# Пути из stdin → те из них, что лежат в readonly-зонах.
# Зоны — пробел-разделённый список имён каталогов, как их пишет bootstrap.
harness_readonly_violations() {
  local zones="${1:-}" path zone
  # быстрый путь, не проверка: без зон цикл ниже всё равно ничего не найдёт,
  # но так функция не вычитывает stdin впустую
  [ -n "$zones" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # список зон разворачивается словами намеренно
    # shellcheck disable=SC2086
    for zone in $zones; do
      case "$path" in
        "$zone"/*|*/"$zone"/*)
          printf '%s\n' "$path"
          break
          ;;
      esac
    done
  done
}

# Пути из stdin → те, что лежат ВНЕ разрешённой области.
# Зеркало readonly-зон: там «куда нельзя», здесь «где только и можно».
# Нужно, когда у модуля есть граница по договорённости, но линтер её не держит:
# агент правит один bounded context, всё остальное для него чужое.
harness_scope_violations() {
  local allowed="${1:-}" path prefix ok
  [ -n "$allowed" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    ok=""
    # список префиксов разворачивается словами намеренно
    # shellcheck disable=SC2086
    for prefix in $allowed; do
      case "$path" in
        "$prefix"|"$prefix"/*) ok=1; break ;;
      esac
    done
    [ -n "$ok" ] || printf '%s\n' "$path"
  done
}
