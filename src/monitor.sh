#!/usr/bin/env bash
# monitor.sh -- Background monitor for worker health and state updates.
# Usage:
#   bash monitor.sh              # run one cycle
#   bash monitor.sh --loop [N]   # run continuously every N seconds (default 10)
#   source monitor.sh --dry-run  # load functions only
#
# Functions: update_worker_state, check_stuck, resume_worker, run_cycle
#
# macOS compatible (bash 3.2+). Requires: jq, date.
# Depends on: parse-phase.sh (detect_phase, extract_cost, detect_completion, estimate_progress)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ORCH_DIR can be overridden via env var (for testing)
ORCH_DIR="${ORCH_DIR:-${HOME}/.claude/orchestrator}"
ORCH_WORKERS="${ORCH_DIR}/workers"
ORCH_LOGS="${ORCH_DIR}/logs"
TMUX_SESSION="ensemble"

# Source parse-phase.sh for log-parsing functions
if ! type detect_phase >/dev/null 2>&1; then
  source "$SCRIPT_DIR/parse-phase.sh" --dry-run
fi

# ---------------------------------------------------------------------------
# _iso_to_epoch(iso_string)
#   Convert ISO 8601 date (2026-01-01T00:00:00Z) to epoch seconds.
#   macOS compatible: uses date -j -f.
# ---------------------------------------------------------------------------
_iso_to_epoch() {
  local iso_str="$1"
  local cleaned
  cleaned=$(echo "$iso_str" | sed 's/Z$//' | sed 's/+00:00$//')
  if [[ "$OSTYPE" == "darwin"* ]]; then
    TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$cleaned" +"%s" 2>/dev/null || echo "0"
  else
    date -u -d "${cleaned}" +"%s" 2>/dev/null || echo "0"
  fi
}

# ---------------------------------------------------------------------------
# update_worker_state(worker_id)
#   Read worker log, detect phase/cost/completion via parse-phase.sh functions,
#   update worker JSON with new phase/cost/progress/status/last_output_at.
#   Skip completed workers. Use atomic write (tmp file + mv).
# ---------------------------------------------------------------------------
update_worker_state() {
  local worker_id="${1:-}"
  if [ -z "$worker_id" ]; then
    echo "ERROR: update_worker_state requires worker_id" >&2
    return 1
  fi

  local worker_json="${ORCH_WORKERS}/${worker_id}.json"
  if [ ! -f "$worker_json" ]; then
    echo "ERROR: worker JSON not found: $worker_json" >&2
    return 1
  fi

  # Skip completed workers
  local current_status
  current_status=$(jq -r '.status // "unknown"' "$worker_json")
  if [ "$current_status" = "completed" ]; then
    return 0
  fi

  local log_file="${ORCH_LOGS}/${worker_id}.log"

  # Detect phase, cost, completion, progress from the log
  local phase cost completion progress
  phase=$(detect_phase "$log_file")
  cost=$(extract_cost "$log_file")
  completion=$(detect_completion "$log_file")
  progress=$(estimate_progress "$phase")

  # Determine new status based on completion
  local new_status="$current_status"
  if [ "$completion" = "success" ]; then
    new_status="completed"
  elif echo "$completion" | grep -q "^error"; then
    new_status="crashed"
  fi

  # Determine last_output_at from log file mtime (macOS: stat -f '%m')
  local last_output_at
  if [ -f "$log_file" ] && [ -s "$log_file" ]; then
    local mtime_epoch
    if [[ "$OSTYPE" == "darwin"* ]]; then
      mtime_epoch=$(stat -f '%m' "$log_file" 2>/dev/null || echo "0")
    else
      mtime_epoch=$(stat -c '%Y' "$log_file" 2>/dev/null || echo "0")
    fi
    if [ "$mtime_epoch" != "0" ]; then
      if [[ "$OSTYPE" == "darwin"* ]]; then
        last_output_at=$(date -u -r "$mtime_epoch" +"%Y-%m-%dT%H:%M:%SZ")
      else
        last_output_at=$(date -u -d "@${mtime_epoch}" +"%Y-%m-%dT%H:%M:%SZ")
      fi
    else
      last_output_at=$(jq -r '.last_output_at' "$worker_json")
    fi
  else
    last_output_at=$(jq -r '.last_output_at' "$worker_json")
  fi

  # Atomic update: write to tmp file, then mv
  local tmp_file="${worker_json}.tmp"
  jq \
    --arg phase "$phase" \
    --argjson cost "$cost" \
    --argjson progress "$progress" \
    --arg status "$new_status" \
    --arg last_output_at "$last_output_at" \
    '.phase = $phase | .spent_usd = $cost | .progress = $progress | .status = $status | .last_output_at = $last_output_at' \
    "$worker_json" > "$tmp_file"
  mv "$tmp_file" "$worker_json"
}

# ---------------------------------------------------------------------------
# check_stuck(worker_id, threshold)
#   Read last_output_at from worker JSON, compare to now.
#   If age > threshold (default 300s = 5min), return "true".
#   Returns "false" for completed/done workers.
#   Uses macOS-compatible date parsing.
# ---------------------------------------------------------------------------
check_stuck() {
  local worker_id="${1:-}"
  local threshold="${2:-300}"

  if [ -z "$worker_id" ]; then
    echo "false"
    return 0
  fi

  local worker_json="${ORCH_WORKERS}/${worker_id}.json"
  if [ ! -f "$worker_json" ]; then
    echo "false"
    return 0
  fi

  # Don't check stuck for completed workers
  local status
  status=$(jq -r '.status // "unknown"' "$worker_json")
  if [ "$status" = "completed" ]; then
    echo "false"
    return 0
  fi

  local last_output_at
  last_output_at=$(jq -r '.last_output_at // ""' "$worker_json")

  if [ -z "$last_output_at" ]; then
    echo "false"
    return 0
  fi

  local last_epoch now_epoch age
  last_epoch=$(_iso_to_epoch "$last_output_at")
  now_epoch=$(date +%s)
  age=$(( now_epoch - last_epoch ))

  if [ "$age" -gt "$threshold" ]; then
    echo "true"
  else
    echo "false"
  fi
}

# ---------------------------------------------------------------------------
# resume_worker(worker_id)
#   Read session_id and resume_count from worker JSON. If resume_count >= 2,
#   return error. Increment resume_count, set status to "active", send
#   claude -p --resume command via tmux send-keys.
# ---------------------------------------------------------------------------
resume_worker() {
  local worker_id="${1:-}"
  if [ -z "$worker_id" ]; then
    echo "ERROR: resume_worker requires worker_id" >&2
    return 1
  fi

  local worker_json="${ORCH_WORKERS}/${worker_id}.json"
  if [ ! -f "$worker_json" ]; then
    echo "ERROR: worker JSON not found: $worker_json" >&2
    return 1
  fi

  local session_id resume_count
  session_id=$(jq -r '.session_id // ""' "$worker_json")
  resume_count=$(jq -r '.resume_count // 0' "$worker_json")

  if [ "$resume_count" -ge 2 ]; then
    echo "ERROR: worker $worker_id has been resumed $resume_count times (max 2)" >&2
    return 1
  fi

  # Increment resume_count, set status to active
  local new_resume_count=$(( resume_count + 1 ))
  local tmp_file="${worker_json}.tmp"
  jq \
    --argjson rc "$new_resume_count" \
    '.resume_count = $rc | .status = "active"' \
    "$worker_json" > "$tmp_file"
  mv "$tmp_file" "$worker_json"

  # Read budget and log path for the resume command
  local budget
  budget=$(jq -r '.budget_usd // "5.00"' "$worker_json")
  local log_file="${ORCH_LOGS}/${worker_id}.log"
  local prompt_file="${ORCH_WORKERS}/${worker_id}.prompt"
  local sysprompt_file="${ORCH_WORKERS}/${worker_id}.sysprompt"
  local project_dir
  project_dir=$(jq -r '.project_dir // "."' "$worker_json")

  # Send resume command via tmux
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    # Try to send to existing window, or create new one
    if ! tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$worker_id"; then
      tmux new-window -t "$TMUX_SESSION" -n "$worker_id" -d -c "$project_dir"
      tmux set-option -t "${TMUX_SESSION}:${worker_id}" remain-on-exit on
      sleep 0.3
    fi

    tmux send-keys -t "${TMUX_SESSION}:${worker_id}" \
      "claude -p 'Continue your previous work. Resume from where you left off.' --resume '${session_id}' --append-system-prompt-file '${sysprompt_file}' --output-format stream-json --dangerously-skip-permissions --max-budget-usd ${budget} 2>&1 | tee -a '${log_file}'; tmux wait-for -S '${worker_id}-done'" \
      Enter

    echo "Resumed worker $worker_id (attempt $new_resume_count)"
  else
    echo "ERROR: tmux session '$TMUX_SESSION' not found, cannot resume" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# run_cycle()
#   Iterate all worker JSONs in ORCH_WORKERS. For each:
#     1. update_worker_state
#     2. check_stuck (mark as "stuck" if true)
#     3. auto-resume crashed workers (if resume_count < 2)
# ---------------------------------------------------------------------------
run_cycle() {
  if [ ! -d "$ORCH_WORKERS" ]; then
    return 0
  fi

  local worker_json worker_id
  for worker_json in "$ORCH_WORKERS"/*.json; do
    # Handle case where glob matches nothing
    [ -f "$worker_json" ] || continue

    # Extract worker_id from filename (strip path and .json)
    worker_id=$(basename "$worker_json" .json)

    # 1. Update worker state from log
    update_worker_state "$worker_id" || true

    # Re-read status after update
    local status
    status=$(jq -r '.status // "unknown"' "$worker_json")

    # Skip completed workers for stuck check
    if [ "$status" = "completed" ]; then
      continue
    fi

    # 2. Check if stuck
    local is_stuck
    is_stuck=$(check_stuck "$worker_id")
    if [ "$is_stuck" = "true" ]; then
      # Mark as stuck
      local tmp_file="${worker_json}.tmp"
      jq '.status = "stuck"' "$worker_json" > "$tmp_file"
      mv "$tmp_file" "$worker_json"
    fi

    # 3. Auto-resume crashed workers (status=crashed and resume_count < 2)
    # Re-read status after potential stuck update
    status=$(jq -r '.status // "unknown"' "$worker_json")
    if [ "$status" = "crashed" ]; then
      local resume_count
      resume_count=$(jq -r '.resume_count // 0' "$worker_json")
      if [ "$resume_count" -lt 2 ]; then
        resume_worker "$worker_id" 2>/dev/null || true
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Main block
# ---------------------------------------------------------------------------
_monitor_main() {
  local mode="${1:-}"

  if [ "$mode" = "--loop" ]; then
    local interval="${2:-10}"
    echo "Monitor running (interval: ${interval}s). Press Ctrl+C to stop."
    while true; do
      run_cycle
      sleep "$interval"
    done
  else
    run_cycle
  fi
}

# Detect if being sourced or executed directly
if [ "${1:-}" = "--dry-run" ]; then
  # Sourced with --dry-run: functions are defined, do nothing else
  :
elif [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Executed directly (not sourced)
  _monitor_main "$@"
fi
