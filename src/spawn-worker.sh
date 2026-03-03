#!/usr/bin/env bash
# spawn-worker.sh -- Core script that spawns a Claude Code worker in a tmux window.
# Usage:
#   bash spawn-worker.sh --name <name> --project <dir> --task <task> [--budget <usd>]
#   source spawn-worker.sh --dry-run   # load functions only
#
# macOS compatible (bash 3.2+). Requires: jq, uuidgen, tmux.

set -euo pipefail

ORCH_BASE="${HOME}/.claude/orchestrator"
ORCH_WORKERS="${ORCH_BASE}/workers"
ORCH_LOGS="${ORCH_BASE}/logs"
ORCH_TEMPLATES="${HOME}/.claude/skills/orchestrator/templates"
ORCH_SCRIPTS="${HOME}/.claude/skills/orchestrator/scripts"
TMUX_SESSION="orchestra"

# ---------------------------------------------------------------------------
# _check_deps()
#   Verify that all required external tools are available.
# ---------------------------------------------------------------------------
_check_deps() {
    local dep
    for dep in jq uuidgen tmux python3; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "ERROR: required dependency not found: $dep" >&2
            return 1
        fi
    done
}

# ---------------------------------------------------------------------------
# generate_worker_id(name)
#   Sanitize name: lowercase, replace non-alphanumeric with hyphens,
#   collapse consecutive hyphens, strip leading/trailing hyphens,
#   prefix with "worker-", max 30 chars after prefix.
# ---------------------------------------------------------------------------
generate_worker_id() {
  local name="$1"
  # lowercase
  local sanitized
  sanitized=$(echo "$name" | tr '[:upper:]' '[:lower:]')
  # replace non-alphanumeric with hyphens
  sanitized=$(echo "$sanitized" | sed 's/[^a-z0-9]/-/g')
  # collapse consecutive hyphens
  sanitized=$(echo "$sanitized" | sed 's/-\{2,\}/-/g')
  # strip leading and trailing hyphens
  sanitized=$(echo "$sanitized" | sed 's/^-//;s/-$//')
  # truncate to 30 chars
  sanitized=$(echo "$sanitized" | cut -c1-30)
  # strip trailing hyphen that may appear after truncation
  sanitized=$(echo "$sanitized" | sed 's/-$//')
  if [ -z "$sanitized" ]; then
    echo "ERROR: name produces empty worker ID after sanitization" >&2
    return 1
  fi
  echo "worker-${sanitized}"
}

# ---------------------------------------------------------------------------
# generate_session_id()
#   Produce a lowercase UUID via uuidgen.
# ---------------------------------------------------------------------------
generate_session_id() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

# ---------------------------------------------------------------------------
# create_worker_json(id, session_id, project_dir, task, budget)
#   Produce a JSON object with all required worker metadata fields.
# ---------------------------------------------------------------------------
create_worker_json() {
  local id="$1"
  local session_id="$2"
  local project_dir="$3"
  local task="$4"
  local budget="$5"

  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  jq -n \
    --arg id "$id" \
    --arg session_id "$session_id" \
    --arg project_dir "$project_dir" \
    --arg task "$task" \
    --arg phase "initializing" \
    --arg status "active" \
    --arg budget_usd "$budget" \
    --argjson spent_usd 0 \
    --arg spawned_at "$now" \
    --arg last_output_at "$now" \
    --argjson tmux_window null \
    --argjson resume_count 0 \
    --argjson progress 0 \
    --arg notes "" \
    '{
      id: $id,
      session_id: $session_id,
      project_dir: $project_dir,
      task: $task,
      phase: $phase,
      status: $status,
      budget_usd: $budget_usd,
      spent_usd: $spent_usd,
      spawned_at: $spawned_at,
      last_output_at: $last_output_at,
      tmux_window: $tmux_window,
      resume_count: $resume_count,
      progress: $progress,
      notes: $notes
    }'
}

# ---------------------------------------------------------------------------
# build_system_prompt(task, project_dir)
#   Read template from templates/worker-system-prompt.md and substitute
#   {{TASK_DESCRIPTION}} and {{PROJECT_DIR}}. Falls back to inline string
#   if template is missing.
# ---------------------------------------------------------------------------
build_system_prompt() {
  local task="$1" project_dir="$2"
  local template_file="${ORCH_TEMPLATES}/worker-system-prompt.md"

  local template
  if [ -f "$template_file" ]; then
    template=$(cat "$template_file")
  else
    template="You are an autonomous worker. Task: see below. Project: see below. Use Superpowers workflow.

Task: {{TASK_DESCRIPTION}}
Project: {{PROJECT_DIR}}"
  fi

  python3 -c "
import sys
tmpl = sys.stdin.read()
print(tmpl.replace('{{TASK_DESCRIPTION}}', sys.argv[1]).replace('{{PROJECT_DIR}}', sys.argv[2]), end='')
" "$task" "$project_dir" <<< "$template"
}

# ---------------------------------------------------------------------------
# ensure_tmux_session()
#   Create tmux session "orchestra" if it doesn't exist. First window named
#   "status". If dashboard.sh exists, start watch in it.
# ---------------------------------------------------------------------------
ensure_tmux_session() {
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux new-session -d -s "$TMUX_SESSION" -n "status"
    local dashboard="${ORCH_SCRIPTS}/dashboard.sh"
    if [ -x "$dashboard" ]; then
      tmux send-keys -t "${TMUX_SESSION}:status" "watch -n 5 '${dashboard}'" Enter
    fi
  fi
}

# ---------------------------------------------------------------------------
# spawn_worker(name, project_dir, task, budget)
#   The main function that creates everything and launches the worker.
# ---------------------------------------------------------------------------
spawn_worker() {
  _check_deps || return 1

  local name="$1"
  local project_dir="$2"
  local task="$3"
  local budget="${4:-10}"

  # Validate budget is a positive decimal number
  if ! printf '%s' "$budget" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
    echo "ERROR: budget must be a positive number, got: $budget" >&2
    return 1
  fi

  # 1. Validate project_dir exists
  if [ ! -d "$project_dir" ]; then
    echo "ERROR: project directory does not exist: $project_dir" >&2
    return 1
  fi

  # 2. Generate worker_id and session_id
  local worker_id
  worker_id=$(generate_worker_id "$name")
  local session_id
  session_id=$(generate_session_id)

  # 3. Check for duplicate active worker with same name
  mkdir -p "$ORCH_WORKERS"
  local existing
  existing=$(find "$ORCH_WORKERS" -name "${worker_id}.json" -print -quit 2>/dev/null || true)
  if [ -n "$existing" ]; then
    local existing_status
    existing_status=$(jq -r '.status' "$existing" 2>/dev/null || echo "unknown")
    if [ "$existing_status" = "active" ]; then
      echo "ERROR: active worker with name '${worker_id}' already exists" >&2
      return 1
    fi
  fi

  # 4. Write worker JSON
  local worker_json_file="${ORCH_WORKERS}/${worker_id}.json"
  create_worker_json "$worker_id" "$session_id" "$project_dir" "$task" "$budget" \
    > "$worker_json_file"

  # 5. Build system prompt, write to file
  local sysprompt_file="${ORCH_WORKERS}/${worker_id}.sysprompt"
  build_system_prompt "$task" "$project_dir" > "$sysprompt_file"

  # 6. Write task to prompt file
  local prompt_file="${ORCH_WORKERS}/${worker_id}.prompt"
  echo "$task" > "$prompt_file"

  # 7. Ensure tmux session exists
  ensure_tmux_session

  # 8. Kill any existing window with this name, then create fresh
  if tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$worker_id"; then
    tmux kill-window -t "${TMUX_SESSION}:${worker_id}" 2>/dev/null || true
  fi
  tmux new-window -t "$TMUX_SESSION" -n "$worker_id" -d -c "$project_dir"
  tmux set-option -t "${TMUX_SESSION}:${worker_id}" remain-on-exit on

  # Sleep briefly to avoid macOS race condition
  sleep 0.3

  # 9. Send claude -p command via tmux send-keys
  local log_file="${ORCH_LOGS}/${worker_id}.log"
  mkdir -p "$ORCH_LOGS"

  tmux send-keys -t "${TMUX_SESSION}:${worker_id}" \
    "claude -p \"\$(cat '${prompt_file}')\" --append-system-prompt-file '${sysprompt_file}' --session-id '${session_id}' --output-format stream-json --dangerously-skip-permissions --max-budget-usd ${budget} 2>&1 | tee '${log_file}'; tmux wait-for -S '${worker_id}-done'" \
    Enter

  # 10. Update worker JSON with tmux window index
  local window_index
  window_index=$(tmux list-windows -t "$TMUX_SESSION" -F '#{window_name} #{window_index}' \
    | grep "^${worker_id} " | awk '{print $2}')
  if [ -n "$window_index" ]; then
    local tmp_json
    tmp_json=$(jq --argjson idx "$window_index" '.tmux_window = $idx' "$worker_json_file")
    echo "$tmp_json" > "$worker_json_file"
  fi

  # 11. Echo worker_id
  echo "$worker_id"
}

# ---------------------------------------------------------------------------
# Main block: if not --dry-run and not sourced, parse args and call spawn_worker
# ---------------------------------------------------------------------------
_spawn_worker_main() {
  _check_deps || return 1

  local name=""
  local project=""
  local task=""
  local budget="10"

  while [ $# -gt 0 ]; do
    case "$1" in
      --name)     name="$2";    shift 2 ;;
      --project)  project="$2"; shift 2 ;;
      --task)     task="$2";    shift 2 ;;
      --budget)   budget="$2";  shift 2 ;;
      *)          echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  if [ -z "$name" ] || [ -z "$project" ] || [ -z "$task" ]; then
    echo "Usage: spawn-worker.sh --name <name> --project <dir> --task <task> [--budget <usd>]" >&2
    return 1
  fi

  spawn_worker "$name" "$project" "$task" "$budget"
}

# Detect if being sourced or executed directly
# When sourced with --dry-run, just define functions and return.
# When executed directly, run main.
if [ "${1:-}" = "--dry-run" ]; then
  # Sourced with --dry-run: functions are defined, do nothing else
  :
elif [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Executed directly (not sourced)
  _spawn_worker_main "$@"
fi
