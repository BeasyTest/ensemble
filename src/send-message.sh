#!/usr/bin/env bash
# send-message.sh -- Cross-worker messaging via file-based queue.
# Usage:
#   bash send-message.sh <from> <to> <text> [payload-json]
#   source send-message.sh --dry-run   # load functions only
#
# macOS compatible (bash 3.2+). Requires: jq.

set -euo pipefail

ORCH_DIR="${ORCH_DIR:-${HOME}/.claude/orchestrator}"
ORCH_MESSAGES="${ORCH_DIR}/messages"
ORCH_WORKERS="${ORCH_DIR}/workers"
TMUX_SESSION="orchestra"

# ---------------------------------------------------------------------------
# send_message(from, to, text, payload_json)
#   Create or append a message to ORCH_MESSAGES/<from>-to-<to>.json.
#   Each message: {from, to, text, payload, timestamp (ISO UTC), delivered: false}.
#   If file exists, append to .messages array. If not, create new file.
#   Atomic writes: write to .tmp, then mv.
# ---------------------------------------------------------------------------
send_message() {
  local from="$1"
  local to="$2"
  local text="$3"
  local payload_json="${4:-"{}"}"

  mkdir -p "$ORCH_MESSAGES"

  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Build the message object
  local msg
  msg=$(jq -n \
    --arg from "$from" \
    --arg to "$to" \
    --arg text "$text" \
    --argjson payload "$payload_json" \
    --arg timestamp "$now" \
    '{
      from: $from,
      to: $to,
      text: $text,
      payload: $payload,
      timestamp: $timestamp,
      delivered: false
    }')

  local msg_file="${ORCH_MESSAGES}/${from}-to-${to}.json"
  local tmp_file="${msg_file}.tmp"

  if [ -f "$msg_file" ]; then
    # Append to existing .messages array
    jq --argjson new_msg "$msg" '.messages += [$new_msg]' "$msg_file" > "$tmp_file"
    mv "$tmp_file" "$msg_file"
  else
    # Create new file with messages array
    jq -n --argjson msg "$msg" '{messages: [$msg]}' > "$tmp_file"
    mv "$tmp_file" "$msg_file"
  fi
}

# ---------------------------------------------------------------------------
# get_pending_messages(to_worker)
#   Find all *-to-<to_worker>.json files, extract messages where
#   delivered=false, return combined JSON array.
# ---------------------------------------------------------------------------
get_pending_messages() {
  local to_worker="$1"

  mkdir -p "$ORCH_MESSAGES"

  local result="[]"
  local f

  for f in "$ORCH_MESSAGES"/*-to-"${to_worker}".json; do
    # Handle glob that matches nothing
    if [ ! -f "$f" ]; then
      continue
    fi
    local pending
    pending=$(jq '[.messages[] | select(.delivered == false)]' "$f" 2>/dev/null || echo "[]")
    result=$(echo "$result" "$pending" | jq -s '.[0] + .[1]')
  done

  echo "$result"
}

# ---------------------------------------------------------------------------
# mark_delivered(to_worker)
#   In all *-to-<to_worker>.json files, set all messages' delivered=true.
#   Atomic writes: write to .tmp, then mv.
# ---------------------------------------------------------------------------
mark_delivered() {
  local to_worker="$1"

  mkdir -p "$ORCH_MESSAGES"

  local f
  for f in "$ORCH_MESSAGES"/*-to-"${to_worker}".json; do
    # Handle glob that matches nothing
    if [ ! -f "$f" ]; then
      continue
    fi
    local tmp_file="${f}.tmp"
    jq '.messages = [.messages[] | .delivered = true]' "$f" > "$tmp_file"
    mv "$tmp_file" "$f"
  done
}

# ---------------------------------------------------------------------------
# deliver_messages(worker_id)
#   Get pending messages, build delivery text, send via claude -p --resume
#   (only if messages exist and tmux session is active). Mark as delivered.
# ---------------------------------------------------------------------------
deliver_messages() {
  local worker_id="$1"

  # Get pending messages
  local pending
  pending=$(get_pending_messages "$worker_id")

  local count
  count=$(echo "$pending" | jq 'length')

  # If no pending messages, return
  if [ "$count" -eq 0 ]; then
    return 0
  fi

  # Check if tmux session and window exist
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "WARNING: tmux session '$TMUX_SESSION' not found, cannot deliver messages" >&2
    return 1
  fi

  if ! tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$worker_id"; then
    echo "WARNING: tmux window '$worker_id' not found, cannot deliver messages" >&2
    return 1
  fi

  # Look up the worker's session_id from its JSON
  local worker_json="${ORCH_WORKERS}/${worker_id}.json"
  if [ ! -f "$worker_json" ]; then
    echo "WARNING: worker JSON not found: $worker_json" >&2
    return 1
  fi

  local session_id
  session_id=$(jq -r '.session_id' "$worker_json")

  # Write to temp file instead of inline quoting
  local delivery_file
  delivery_file=$(mktemp)
  echo "$pending" | jq -r '.[] | "From \(.from): \(.text)"' > "$delivery_file"

  # Use the file as the prompt
  local log_file="${ORCH_DIR}/logs/${worker_id}.log"
  tmux send-keys -t "${TMUX_SESSION}:${worker_id}" \
    "claude -p \"\$(cat '${delivery_file}')\" --resume '${session_id}' --output-format stream-json --dangerously-skip-permissions 2>&1 | tee -a '${log_file}'; rm -f '${delivery_file}'" \
    Enter

  # Mark as delivered
  mark_delivered "$worker_id"
}

# ---------------------------------------------------------------------------
# Main block: if not --dry-run and not sourced, parse args and call send_message
# ---------------------------------------------------------------------------
_send_message_main() {
  if [ $# -lt 3 ]; then
    echo "Usage: send-message.sh <from> <to> <text> [payload-json]" >&2
    return 1
  fi

  local from="$1"
  local to="$2"
  local text="$3"
  local payload="${4:-"{}"}"

  send_message "$from" "$to" "$text" "$payload"
  echo "Message sent: $from -> $to"
}

# Detect if being sourced or executed directly
# When sourced with --dry-run, just define functions and return.
# When executed directly, run main.
if [ "${1:-}" = "--dry-run" ]; then
  # Sourced with --dry-run: functions are defined, do nothing else
  :
elif [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Executed directly (not sourced)
  _send_message_main "$@"
fi
