#!/usr/bin/env bash
# Раскладка каркаса. Библиотека: при source ничего не выполняет.
#
# Конфиг, очередь и тесты живут в репозитории; состояние прогонов — вне git-дерева.
# Так сходится у четырёх независимых проектов (orchestrator-sh, crew,
# claude-code-merge-queue, gastown): рабочие каталоги задач не должны попадать
# ни в git status, ни под уборку самого репозитория.

ORC_ROOT="${ORC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ORC_STATE="${ORC_STATE:-$HOME/.orchestrator}"

orc_init_state() {
  mkdir -p "$ORC_STATE/runs" "$ORC_STATE/logs" "$ORC_STATE/projects"
}

orc_task_dir()       { printf '%s\n' "$ORC_STATE/runs/${1:?task-id}"; }
orc_log_dir()        { printf '%s\n' "$ORC_STATE/logs/${1:?task-id}"; }
orc_project_mirror() { printf '%s\n' "$ORC_STATE/projects/${1:?project}.git"; }

# Хэш промпта для дедупликации задач. shasum есть даже при PATH=/usr/bin:/bin,
# в отличие от md5sum и sha256sum — те лежат в /sbin.
orc_prompt_hash() { shasum -a 256 | cut -c1-16; }
