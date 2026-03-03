#!/usr/bin/env bash
# test-parse-phase.sh -- Tests for parse-phase.sh functions
# Run: bash test-parse-phase.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
TMPDIR_TEST=""

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1 -- $2"
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label" "expected '$expected', got '$actual'"
  fi
}

# Create a temporary directory for synthetic log files
setup() {
  TMPDIR_TEST=$(mktemp -d)
}

# Clean up temporary files
teardown() {
  if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
    rm -rf "$TMPDIR_TEST"
  fi
}

trap teardown EXIT

setup

# Source parse-phase.sh in dry-run mode (defines functions only)
source "$SCRIPT_DIR/../src/parse-phase.sh" --dry-run

echo "=== detect_phase tests ==="

# Test 1: detect_phase finds the LAST [PHASE:xxx] marker from a log with multiple markers
LOG1="${TMPDIR_TEST}/multi-phase.log"
cat > "$LOG1" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Starting work. [PHASE:brainstorming]"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Moving on. [PHASE:planning]"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Now coding. [PHASE:implementing]"}]}}
JSONL
result=$(detect_phase "$LOG1")
assert_eq "detect_phase returns LAST marker (implementing)" "implementing" "$result"

# Test 2: detect_phase falls back to Superpowers skill keywords when no explicit markers
LOG2="${TMPDIR_TEST}/keyword-phase.log"
cat > "$LOG2" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"I will use the brainstorming skill to explore."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Now using writing-plans to create a plan."}]}}
JSONL
result=$(detect_phase "$LOG2")
assert_eq "detect_phase falls back to keyword (planning)" "planning" "$result"

# Test 2b: fallback detects brainstorming keyword
LOG2B="${TMPDIR_TEST}/keyword-brainstorm.log"
cat > "$LOG2B" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"I will use the brainstorming skill."}]}}
JSONL
result=$(detect_phase "$LOG2B")
assert_eq "detect_phase fallback brainstorming" "brainstorming" "$result"

# Test 2c: fallback detects test-driven-development keyword
LOG2C="${TMPDIR_TEST}/keyword-tdd.log"
cat > "$LOG2C" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Using test-driven-development now."}]}}
JSONL
result=$(detect_phase "$LOG2C")
assert_eq "detect_phase fallback test-driven-development" "implementing" "$result"

# Test 2d: fallback detects requesting-code-review keyword
LOG2D="${TMPDIR_TEST}/keyword-review.log"
cat > "$LOG2D" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Now requesting-code-review."}]}}
JSONL
result=$(detect_phase "$LOG2D")
assert_eq "detect_phase fallback requesting-code-review" "reviewing" "$result"

# Test 2e: fallback detects finishing-a-development-branch keyword
LOG2E="${TMPDIR_TEST}/keyword-finish.log"
cat > "$LOG2E" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Using finishing-a-development-branch now."}]}}
JSONL
result=$(detect_phase "$LOG2E")
assert_eq "detect_phase fallback finishing-a-development-branch" "completing" "$result"

# Test 2f: detect_phase defaults to "initializing" when nothing matches
LOG2F="${TMPDIR_TEST}/empty-phase.log"
cat > "$LOG2F" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Hello world."}]}}
JSONL
result=$(detect_phase "$LOG2F")
assert_eq "detect_phase defaults to initializing" "initializing" "$result"

# Test 2g: detect_phase handles missing file gracefully
result=$(detect_phase "${TMPDIR_TEST}/nonexistent.log")
assert_eq "detect_phase handles missing file" "initializing" "$result"

# Test 2h: detect_phase handles empty file
LOG2H="${TMPDIR_TEST}/empty.log"
touch "$LOG2H"
result=$(detect_phase "$LOG2H")
assert_eq "detect_phase handles empty file" "initializing" "$result"

echo ""
echo "=== extract_cost tests ==="

# Test 3: extract_cost reads total_cost_usd from a result event
LOG3="${TMPDIR_TEST}/cost.log"
cat > "$LOG3" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Working..."}]}}
{"type":"result","subtype":"success","total_cost_usd":0.05,"num_turns":12,"session_id":"abc-123"}
JSONL
result=$(extract_cost "$LOG3")
assert_eq "extract_cost reads total_cost_usd" "0.05" "$result"

# Test 3b: extract_cost returns 0 when no result event
LOG3B="${TMPDIR_TEST}/no-cost.log"
cat > "$LOG3B" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Working..."}]}}
JSONL
result=$(extract_cost "$LOG3B")
assert_eq "extract_cost defaults to 0" "0" "$result"

# Test 3c: extract_cost handles missing file
result=$(extract_cost "${TMPDIR_TEST}/nonexistent-cost.log")
assert_eq "extract_cost handles missing file" "0" "$result"

echo ""
echo "=== detect_completion tests ==="

# Test 4: detect_completion returns "success" for a successful result event
LOG4="${TMPDIR_TEST}/success.log"
cat > "$LOG4" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}
{"type":"result","subtype":"success","total_cost_usd":0.05,"num_turns":12,"session_id":"abc-123"}
JSONL
result=$(detect_completion "$LOG4")
assert_eq "detect_completion success" "success" "$result"

# Test 5: detect_completion returns "error_max_budget_usd" for a budget error
LOG5="${TMPDIR_TEST}/budget-error.log"
cat > "$LOG5" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Working..."}]}}
{"type":"result","subtype":"error_max_budget_usd","total_cost_usd":5.01,"num_turns":50,"session_id":"abc-123"}
JSONL
result=$(detect_completion "$LOG5")
assert_eq "detect_completion budget error" "error_max_budget_usd" "$result"

# Test 6: detect_completion returns "running" when no result event exists
LOG6="${TMPDIR_TEST}/running.log"
cat > "$LOG6" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Still going..."}]}}
JSONL
result=$(detect_completion "$LOG6")
assert_eq "detect_completion running" "running" "$result"

# Test 6b: detect_completion handles missing file
result=$(detect_completion "${TMPDIR_TEST}/nonexistent-status.log")
assert_eq "detect_completion handles missing file" "running" "$result"

echo ""
echo "=== extract_turns tests ==="

# Test: extract_turns from result event
LOG_TURNS="${TMPDIR_TEST}/turns.log"
cat > "$LOG_TURNS" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"result","subtype":"success","total_cost_usd":0.05,"num_turns":12,"session_id":"abc-123"}
JSONL
result=$(extract_turns "$LOG_TURNS")
assert_eq "extract_turns reads num_turns" "12" "$result"

# Test: extract_turns defaults to 0
LOG_TURNS_NONE="${TMPDIR_TEST}/no-turns.log"
cat > "$LOG_TURNS_NONE" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
JSONL
result=$(extract_turns "$LOG_TURNS_NONE")
assert_eq "extract_turns defaults to 0" "0" "$result"

echo ""
echo "=== extract_last_text tests ==="

# Test: extract_last_text gets text from last assistant message
LOG_TEXT="${TMPDIR_TEST}/text.log"
cat > "$LOG_TEXT" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"First message."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Second message."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Third message."}]}}
JSONL
result=$(extract_last_text "$LOG_TEXT" 1)
assert_eq "extract_last_text gets last message" "Third message." "$result"

# Test: extract_last_text with n=2 gets last 2 messages
result=$(extract_last_text "$LOG_TEXT" 2)
if echo "$result" | grep -q "Second message." && echo "$result" | grep -q "Third message."; then
  pass "extract_last_text n=2 gets last 2 messages"
else
  fail "extract_last_text n=2" "did not contain expected messages, got: $result"
fi

echo ""
echo "=== estimate_progress tests ==="

# Test 7: estimate_progress maps phases to expected percentages
assert_eq "estimate_progress initializing" "5" "$(estimate_progress "initializing")"
assert_eq "estimate_progress brainstorming" "15" "$(estimate_progress "brainstorming")"
assert_eq "estimate_progress planning" "30" "$(estimate_progress "planning")"
assert_eq "estimate_progress implementing" "60" "$(estimate_progress "implementing")"
assert_eq "estimate_progress reviewing" "85" "$(estimate_progress "reviewing")"
assert_eq "estimate_progress completing" "95" "$(estimate_progress "completing")"
assert_eq "estimate_progress done" "100" "$(estimate_progress "done")"
assert_eq "estimate_progress unknown" "0" "$(estimate_progress "unknown_phase")"

echo ""
echo "=== main output tests ==="

# Test: main block outputs valid JSON with expected fields
LOG_MAIN="${TMPDIR_TEST}/main.log"
cat > "$LOG_MAIN" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123"}
{"type":"assistant","message":{"content":[{"type":"text","text":"[PHASE:implementing] Writing code now."}]}}
{"type":"result","subtype":"success","total_cost_usd":0.12,"num_turns":8,"session_id":"abc-123"}
JSONL
main_output=$(bash "$SCRIPT_DIR/../src/parse-phase.sh" "$LOG_MAIN")
if echo "$main_output" | jq . >/dev/null 2>&1; then
  pass "main output is valid JSON"
else
  fail "main output is valid JSON" "got: $main_output"
fi

phase_val=$(echo "$main_output" | jq -r '.phase')
assert_eq "main output phase" "implementing" "$phase_val"

cost_val=$(echo "$main_output" | jq -r '.cost')
assert_eq "main output cost" "0.12" "$cost_val"

status_val=$(echo "$main_output" | jq -r '.status')
assert_eq "main output status" "success" "$status_val"

progress_val=$(echo "$main_output" | jq -r '.progress')
assert_eq "main output progress" "60" "$progress_val"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  echo "All tests passed."
  exit 0
fi
