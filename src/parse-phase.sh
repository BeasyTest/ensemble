#!/usr/bin/env bash
# parse-phase.sh -- Parse stream-json logs from Claude Code workers.
# Usage:
#   bash parse-phase.sh <log_file>           # output JSON summary
#   source parse-phase.sh --dry-run          # load functions only
#
# Functions: detect_phase, extract_cost, detect_completion,
#            extract_turns, extract_last_text, estimate_progress
#
# macOS compatible (bash 3.2+). Requires: jq, grep.

set -euo pipefail

# ---------------------------------------------------------------------------
# detect_phase(log_file)
#   Primary: grep for [PHASE:xxx] markers, return the LAST one found.
#   Fallback: grep for Superpowers skill names and map to phase names.
#   Default: "initializing"
# ---------------------------------------------------------------------------
detect_phase() {
  local log_file="${1:-}"

  # Handle missing or empty file
  if [ -z "$log_file" ] || [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
    echo "initializing"
    return 0
  fi

  # Primary: look for explicit [PHASE:xxx] markers
  local phase_marker=""
  phase_marker=$(grep -oE '\[PHASE:[a-z_]+\]' "$log_file" 2>/dev/null | tail -1 || true)

  if [ -n "$phase_marker" ]; then
    # Extract the phase name from [PHASE:xxx]
    local phase=""
    phase=$(echo "$phase_marker" | sed 's/\[PHASE://;s/\]//')
    echo "$phase"
    return 0
  fi

  # Fallback: detect Superpowers skill keywords
  # Check from latest to earliest in the workflow so we get the most recent phase.
  # We scan the whole file for each keyword and pick the one that appears last.
  local last_keyword=""
  local last_line=0

  local kw
  local line_num
  for kw in brainstorming writing-plans test-driven-development requesting-code-review code-reviewer finishing-a-development-branch; do
    line_num=$(grep -n "$kw" "$log_file" 2>/dev/null | tail -1 | cut -d: -f1 || true)
    if [ -n "$line_num" ] && [ "$line_num" -gt "$last_line" ]; then
      last_line="$line_num"
      last_keyword="$kw"
    fi
  done

  if [ -n "$last_keyword" ]; then
    case "$last_keyword" in
      brainstorming)                   echo "brainstorming" ;;
      writing-plans)                   echo "planning" ;;
      test-driven-development)         echo "implementing" ;;
      requesting-code-review|code-reviewer) echo "reviewing" ;;
      finishing-a-development-branch)  echo "completing" ;;
      *)                               echo "initializing" ;;
    esac
    return 0
  fi

  echo "initializing"
}

# ---------------------------------------------------------------------------
# extract_cost(log_file)
#   Grep for "type":"result" line, use jq to extract .total_cost_usd.
#   Default: "0"
# ---------------------------------------------------------------------------
extract_cost() {
  local log_file="${1:-}"

  if [ -z "$log_file" ] || [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
    echo "0"
    return 0
  fi

  local result_line=""
  result_line=$(grep '"type":"result"' "$log_file" 2>/dev/null | tail -1 || true)

  if [ -z "$result_line" ]; then
    # Also try with spaces after colons (flexible JSON formatting)
    result_line=$(grep '"type" *: *"result"' "$log_file" 2>/dev/null | tail -1 || true)
  fi

  if [ -n "$result_line" ]; then
    local cost=""
    cost=$(echo "$result_line" | jq -r '.total_cost_usd // 0' 2>/dev/null || true)
    if [ -n "$cost" ] && [ "$cost" != "null" ]; then
      echo "$cost"
      return 0
    fi
  fi

  echo "0"
}

# ---------------------------------------------------------------------------
# detect_completion(log_file)
#   Grep for "type":"result" line, use jq to extract .subtype.
#   Returns "running" if no result event found, "success" or "error_*" otherwise.
# ---------------------------------------------------------------------------
detect_completion() {
  local log_file="${1:-}"

  if [ -z "$log_file" ] || [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
    echo "running"
    return 0
  fi

  local result_line=""
  result_line=$(grep '"type":"result"' "$log_file" 2>/dev/null | tail -1 || true)

  if [ -z "$result_line" ]; then
    result_line=$(grep '"type" *: *"result"' "$log_file" 2>/dev/null | tail -1 || true)
  fi

  if [ -n "$result_line" ]; then
    local subtype=""
    subtype=$(echo "$result_line" | jq -r '.subtype // "unknown"' 2>/dev/null || true)
    if [ -n "$subtype" ] && [ "$subtype" != "null" ]; then
      echo "$subtype"
      return 0
    fi
  fi

  echo "running"
}

# ---------------------------------------------------------------------------
# extract_turns(log_file)
#   From result event, extract .num_turns. Default: "0"
# ---------------------------------------------------------------------------
extract_turns() {
  local log_file="${1:-}"

  if [ -z "$log_file" ] || [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
    echo "0"
    return 0
  fi

  local result_line=""
  result_line=$(grep '"type":"result"' "$log_file" 2>/dev/null | tail -1 || true)

  if [ -z "$result_line" ]; then
    result_line=$(grep '"type" *: *"result"' "$log_file" 2>/dev/null | tail -1 || true)
  fi

  if [ -n "$result_line" ]; then
    local turns=""
    turns=$(echo "$result_line" | jq -r '.num_turns // 0' 2>/dev/null || true)
    if [ -n "$turns" ] && [ "$turns" != "null" ]; then
      echo "$turns"
      return 0
    fi
  fi

  echo "0"
}

# ---------------------------------------------------------------------------
# extract_last_text(log_file, n)
#   Grep for "type":"assistant" lines, tail -n, extract text content via jq.
# ---------------------------------------------------------------------------
extract_last_text() {
  local log_file="${1:-}"
  local n="${2:-1}"

  if [ -z "$log_file" ] || [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
    echo ""
    return 0
  fi

  local assistant_lines=""
  assistant_lines=$(grep '"type":"assistant"' "$log_file" 2>/dev/null | tail -"$n" || true)

  if [ -z "$assistant_lines" ]; then
    assistant_lines=$(grep '"type" *: *"assistant"' "$log_file" 2>/dev/null | tail -"$n" || true)
  fi

  if [ -n "$assistant_lines" ]; then
    echo "$assistant_lines" | while IFS= read -r line; do
      echo "$line" | jq -r '.message.content[]? | select(.type == "text") | .text' 2>/dev/null || true
    done
  fi
}

# ---------------------------------------------------------------------------
# estimate_progress(phase)
#   Case statement mapping phase names to percentages.
# ---------------------------------------------------------------------------
estimate_progress() {
  local phase="${1:-}"
  case "$phase" in
    initializing)  echo "5" ;;
    brainstorming) echo "15" ;;
    planning)      echo "30" ;;
    implementing)  echo "60" ;;
    reviewing)     echo "85" ;;
    completing)    echo "95" ;;
    done)          echo "100" ;;
    *)             echo "0" ;;
  esac
}

# ---------------------------------------------------------------------------
# Main block: parse a log file and output JSON with {phase, cost, status, progress}
# ---------------------------------------------------------------------------
_parse_phase_main() {
  local log_file="${1:-}"

  if [ -z "$log_file" ]; then
    echo "Usage: parse-phase.sh <log_file>" >&2
    return 1
  fi

  local phase cost status progress
  phase=$(detect_phase "$log_file")
  cost=$(extract_cost "$log_file")
  status=$(detect_completion "$log_file")
  progress=$(estimate_progress "$phase")

  jq -n \
    --arg phase "$phase" \
    --argjson cost "${cost:-0}" \
    --arg status "$status" \
    --arg progress "$progress" \
    '{phase: $phase, cost: $cost, status: $status, progress: ($progress | tonumber)}'
}

# Detect if being sourced or executed directly
# When sourced with --dry-run, just define functions and return.
# When executed directly, run main.
if [ "${1:-}" = "--dry-run" ]; then
  # Sourced with --dry-run: functions are defined, do nothing else
  :
elif [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Executed directly (not sourced)
  _parse_phase_main "$@"
fi
