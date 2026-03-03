#!/usr/bin/env bash
# test-integration.sh -- End-to-end integration test for the orchestrator.
#
# Validates the full orchestrator flow: directory structure, script loading,
# worker JSON creation, log parsing, monitor cycle, dashboard rendering,
# cross-worker messaging, and tmux session management.
#
# Does NOT spawn a real Claude Code worker (that costs money).
# Instead, uses synthetic data to validate all the plumbing.
#
# Run: bash test-integration.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR_REAL="${HOME}/.claude/orchestrator"
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

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  if echo "$actual" | grep -qE "$pattern"; then
    pass "$label"
  else
    fail "$label" "'$actual' did not match pattern '$pattern'"
  fi
}

section() {
  echo ""
  echo "=== $1 ==="
}

# ---------------------------------------------------------------------------
# Setup: isolated temp directory for all runtime data
# ---------------------------------------------------------------------------
setup() {
  TMPDIR_TEST=$(mktemp -d)
  export ORCH_DIR="$TMPDIR_TEST"
  mkdir -p "$ORCH_DIR/workers"
  mkdir -p "$ORCH_DIR/logs"
  mkdir -p "$ORCH_DIR/messages"
}

teardown() {
  if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
    rm -rf "$TMPDIR_TEST"
  fi
  # Clean up any tmux session we created for testing
  tmux kill-session -t "orchestra-test" 2>/dev/null || true
}

trap teardown EXIT

setup

# ===========================================================================
# Section 1: Script Loading
# ===========================================================================
section "Script Loading"

# Verify all scripts exist
for script in spawn-worker.sh parse-phase.sh monitor.sh dashboard.sh send-message.sh; do
  if [ -f "$SCRIPT_DIR/../src/$script" ]; then
    pass "script exists: $script"
  else
    fail "script exists: $script" "file not found"
  fi
done

# Source all scripts with --dry-run to load functions
source "$SCRIPT_DIR/../src/spawn-worker.sh" --dry-run
pass "spawn-worker.sh sourced with --dry-run"

source "$SCRIPT_DIR/../src/parse-phase.sh" --dry-run
pass "parse-phase.sh sourced with --dry-run"

source "$SCRIPT_DIR/../src/send-message.sh" --dry-run
pass "send-message.sh sourced with --dry-run"

source "$SCRIPT_DIR/../src/monitor.sh" --dry-run
pass "monitor.sh sourced with --dry-run"

# Verify key functions are defined after sourcing
for func in generate_worker_id generate_session_id create_worker_json build_system_prompt ensure_tmux_session spawn_worker; do
  if [ "$(type -t "$func" 2>/dev/null)" = "function" ]; then
    pass "function defined: $func"
  else
    fail "function defined: $func" "not a function (type -t returned: $(type -t "$func" 2>/dev/null || echo 'not found'))"
  fi
done

for func in detect_phase extract_cost detect_completion extract_turns extract_last_text estimate_progress; do
  if [ "$(type -t "$func" 2>/dev/null)" = "function" ]; then
    pass "function defined: $func"
  else
    fail "function defined: $func" "not a function"
  fi
done

for func in update_worker_state check_stuck resume_worker run_cycle; do
  if [ "$(type -t "$func" 2>/dev/null)" = "function" ]; then
    pass "function defined: $func"
  else
    fail "function defined: $func" "not a function"
  fi
done

for func in send_message get_pending_messages mark_delivered deliver_messages; do
  if [ "$(type -t "$func" 2>/dev/null)" = "function" ]; then
    pass "function defined: $func"
  else
    fail "function defined: $func" "not a function"
  fi
done

# ===========================================================================
# Section 2: Worker JSON Creation (end-to-end)
# ===========================================================================
section "Worker JSON Creation"

# Generate a worker ID
WORKER_ID=$(generate_worker_id "IntegrationTest")
assert_eq "generate_worker_id output" "worker-integrationtest" "$WORKER_ID"

# Generate a session ID
SESSION_ID=$(generate_session_id)
assert_match "session ID is valid UUID" "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" "$SESSION_ID"

# Create worker JSON and write it to the workers directory
WORKER_JSON=$(create_worker_json "$WORKER_ID" "$SESSION_ID" "/tmp/test-project" "Run integration tests" "3.50")
echo "$WORKER_JSON" > "$ORCH_DIR/workers/${WORKER_ID}.json"

# Verify file exists
if [ -f "$ORCH_DIR/workers/${WORKER_ID}.json" ]; then
  pass "worker JSON file created at correct location"
else
  fail "worker JSON file created" "file not found"
fi

# Verify file is valid JSON
if jq . "$ORCH_DIR/workers/${WORKER_ID}.json" >/dev/null 2>&1; then
  pass "worker JSON is valid"
else
  fail "worker JSON is valid" "jq could not parse"
fi

# Verify all required fields
assert_eq "worker id field" "$WORKER_ID" "$(jq -r '.id' "$ORCH_DIR/workers/${WORKER_ID}.json")"
assert_eq "worker session_id" "$SESSION_ID" "$(jq -r '.session_id' "$ORCH_DIR/workers/${WORKER_ID}.json")"
assert_eq "worker project_dir" "/tmp/test-project" "$(jq -r '.project_dir' "$ORCH_DIR/workers/${WORKER_ID}.json")"
assert_eq "worker task" "Run integration tests" "$(jq -r '.task' "$ORCH_DIR/workers/${WORKER_ID}.json")"
assert_eq "worker phase" "initializing" "$(jq -r '.phase' "$ORCH_DIR/workers/${WORKER_ID}.json")"
assert_eq "worker status" "active" "$(jq -r '.status' "$ORCH_DIR/workers/${WORKER_ID}.json")"
assert_eq "worker budget_usd" "3.50" "$(jq -r '.budget_usd' "$ORCH_DIR/workers/${WORKER_ID}.json")"
assert_eq "worker spent_usd" "0" "$(jq -r '.spent_usd' "$ORCH_DIR/workers/${WORKER_ID}.json")"
assert_eq "worker progress" "0" "$(jq -r '.progress' "$ORCH_DIR/workers/${WORKER_ID}.json")"

# ===========================================================================
# Section 3: Log Parsing
# ===========================================================================
section "Log Parsing"

# Create a synthetic stream-json log for our worker
LOG_FILE="$ORCH_DIR/logs/${WORKER_ID}.log"
cat > "$LOG_FILE" <<'JSONL'
{"type":"system","subtype":"init","session_id":"test-session"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Starting work. [PHASE:brainstorming] Let me think about the approach."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"[PHASE:planning] I have a plan now. Let me write it out."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"[PHASE:implementing] Now coding the solution."}]}}
JSONL

# Test detect_phase picks up the LAST phase marker
phase=$(detect_phase "$LOG_FILE")
assert_eq "detect_phase finds last marker (implementing)" "implementing" "$phase"

# Test detect_completion for a running worker (no result event yet)
completion=$(detect_completion "$LOG_FILE")
assert_eq "detect_completion returns running (no result)" "running" "$completion"

# Test extract_cost when no result event
cost=$(extract_cost "$LOG_FILE")
assert_eq "extract_cost returns 0 (no result)" "0" "$cost"

# Test estimate_progress
progress=$(estimate_progress "implementing")
assert_eq "estimate_progress for implementing" "60" "$progress"

progress=$(estimate_progress "brainstorming")
assert_eq "estimate_progress for brainstorming" "15" "$progress"

progress=$(estimate_progress "completing")
assert_eq "estimate_progress for completing" "95" "$progress"

# Now add a result event to simulate completion
cat >> "$LOG_FILE" <<'JSONL'
{"type":"result","subtype":"success","total_cost_usd":1.75,"num_turns":12,"session_id":"test-session"}
JSONL

# Re-test with result event
completion=$(detect_completion "$LOG_FILE")
assert_eq "detect_completion returns success after result" "success" "$completion"

cost=$(extract_cost "$LOG_FILE")
assert_eq "extract_cost returns 1.75 after result" "1.75" "$cost"

turns=$(extract_turns "$LOG_FILE")
assert_eq "extract_turns returns 12" "12" "$turns"

# Test fallback keyword detection (no [PHASE:] markers)
FALLBACK_LOG="$ORCH_DIR/logs/fallback-test.log"
cat > "$FALLBACK_LOG" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"text","text":"Using brainstorming skill"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Now using test-driven-development approach"}]}}
JSONL

fallback_phase=$(detect_phase "$FALLBACK_LOG")
assert_eq "detect_phase fallback keyword (test-driven-development)" "implementing" "$fallback_phase"

# Test with empty/missing file
empty_phase=$(detect_phase "/nonexistent/file.log")
assert_eq "detect_phase returns initializing for missing file" "initializing" "$empty_phase"

# ===========================================================================
# Section 4: Monitor Cycle
# ===========================================================================
section "Monitor Cycle"

# Reset the worker log to an in-progress state (remove the result line)
cat > "$LOG_FILE" <<'JSONL'
{"type":"system","subtype":"init","session_id":"test-session"}
{"type":"assistant","message":{"content":[{"type":"text","text":"[PHASE:brainstorming] Thinking..."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"[PHASE:implementing] Now coding."}]}}
JSONL

# Reset worker JSON to initial state
echo "$WORKER_JSON" > "$ORCH_DIR/workers/${WORKER_ID}.json"

# Run update_worker_state
update_worker_state "$WORKER_ID"

# Verify phase was updated
updated_phase=$(jq -r '.phase' "$ORCH_DIR/workers/${WORKER_ID}.json")
assert_eq "monitor updated phase to implementing" "implementing" "$updated_phase"

# Verify progress was updated
updated_progress=$(jq -r '.progress' "$ORCH_DIR/workers/${WORKER_ID}.json")
assert_eq "monitor updated progress to 60" "60" "$updated_progress"

# Verify status is still active (no result event)
updated_status=$(jq -r '.status' "$ORCH_DIR/workers/${WORKER_ID}.json")
assert_eq "monitor keeps status active (no result)" "active" "$updated_status"

# Now add a result event and run update again
cat >> "$LOG_FILE" <<'JSONL'
{"type":"result","subtype":"success","total_cost_usd":2.10,"num_turns":8,"session_id":"test-session"}
JSONL

update_worker_state "$WORKER_ID"

# Verify status changed to done
final_status=$(jq -r '.status' "$ORCH_DIR/workers/${WORKER_ID}.json")
assert_eq "monitor sets status to done after success result" "done" "$final_status"

# Verify cost was updated
final_cost=$(jq -r '.spent_usd' "$ORCH_DIR/workers/${WORKER_ID}.json")
# jq may preserve trailing zeros (2.10 vs 2.1), so compare numerically
if [ "$(echo "$final_cost == 2.10" | bc -l)" = "1" ]; then
  pass "monitor updated spent_usd to 2.10"
else
  fail "monitor updated spent_usd to 2.10" "got '$final_cost'"
fi

# Test check_stuck with a stale worker
STUCK_WORKER="worker-stuck-test"
old_epoch=$(( $(date +%s) - 600 ))
old_iso=$(date -u -r "$old_epoch" +"%Y-%m-%dT%H:%M:%SZ")
cat > "$ORCH_DIR/workers/${STUCK_WORKER}.json" <<EOF
{
  "id": "$STUCK_WORKER",
  "session_id": "sess-stuck",
  "project_dir": "/tmp/proj",
  "task": "stuck task",
  "phase": "implementing",
  "status": "active",
  "budget_usd": "5.00",
  "spent_usd": 0,
  "spawned_at": "2026-01-01T00:00:00Z",
  "last_output_at": "$old_iso",
  "tmux_window": null,
  "resume_count": 0,
  "progress": 60,
  "notes": ""
}
EOF

stuck_result=$(check_stuck "$STUCK_WORKER" 300)
assert_eq "check_stuck detects stale worker" "true" "$stuck_result"

# Test run_cycle processes multiple workers
# Create a second active worker
WORKER_B="worker-integ-b"
cat > "$ORCH_DIR/workers/${WORKER_B}.json" <<EOF
{
  "id": "$WORKER_B",
  "session_id": "sess-b",
  "project_dir": "/tmp/proj-b",
  "task": "task b",
  "phase": "initializing",
  "status": "active",
  "budget_usd": "5.00",
  "spent_usd": 0,
  "spawned_at": "2026-01-01T00:00:00Z",
  "last_output_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "tmux_window": null,
  "resume_count": 0,
  "progress": 0,
  "notes": ""
}
EOF
cat > "$ORCH_DIR/logs/${WORKER_B}.log" <<'JSONL'
{"type":"system","subtype":"init","session_id":"sess-b"}
{"type":"assistant","message":{"content":[{"type":"text","text":"[PHASE:reviewing] Checking code."}]}}
JSONL

run_cycle
rc=$?
assert_eq "run_cycle exits with 0" "0" "$rc"

phase_b=$(jq -r '.phase' "$ORCH_DIR/workers/${WORKER_B}.json")
assert_eq "run_cycle updated worker-integ-b phase to reviewing" "reviewing" "$phase_b"

# ===========================================================================
# Section 5: Dashboard Rendering
# ===========================================================================
section "Dashboard Rendering"

# The dashboard reads from ~/.claude/orchestrator/workers/ (hardcoded DATA_DIR).
# We need at least one worker JSON there. We temporarily create a synthetic one
# in the real directory, run dashboard, then clean up.

DASHBOARD_WORKER="worker-dashboard-integ-test"
REAL_WORKER_FILE="${ORCH_DIR_REAL}/workers/${DASHBOARD_WORKER}.json"
now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "${ORCH_DIR_REAL}/workers"
cat > "$REAL_WORKER_FILE" <<EOF
{
  "id": "$DASHBOARD_WORKER",
  "session_id": "sess-dashboard-test",
  "project_dir": "/tmp/integ-test",
  "task": "dashboard integration test",
  "phase": "implementing",
  "status": "active",
  "budget_usd": "5.00",
  "spent_usd": 1.25,
  "spawned_at": "$now_iso",
  "last_output_at": "$now_iso",
  "tmux_window": null,
  "resume_count": 0,
  "progress": 60,
  "notes": "Integration test worker"
}
EOF

# Run dashboard, capture exit code (suppress output; it renders to terminal)
# Set WATCH_INTERVAL to skip the clear command
if WATCH_INTERVAL=5 bash "$SCRIPT_DIR/../src/dashboard.sh" >/dev/null 2>&1; then
  pass "dashboard.sh exits with 0"
else
  fail "dashboard.sh exits with 0" "exit code: $?"
fi

# Verify dashboard produces output (at least the header)
dashboard_output=$(WATCH_INTERVAL=5 bash "$SCRIPT_DIR/../src/dashboard.sh" 2>/dev/null || true)
if echo "$dashboard_output" | grep -q "ORCHESTRATOR"; then
  pass "dashboard renders header"
else
  fail "dashboard renders header" "ORCHESTRATOR not found in output"
fi

if echo "$dashboard_output" | grep -q "$DASHBOARD_WORKER"; then
  pass "dashboard shows synthetic worker"
else
  fail "dashboard shows synthetic worker" "worker ID not in output"
fi

# Clean up the temporary real worker file
rm -f "$REAL_WORKER_FILE"

# ===========================================================================
# Section 6: Cross-Worker Messaging
# ===========================================================================
section "Cross-Worker Messaging"

# Send a message from worker-alpha to worker-beta
send_message "worker-alpha" "worker-beta" "API schema ready" '{"schema_version":2}'

# Verify message file was created
MSG_FILE="$ORCH_DIR/messages/worker-alpha-to-worker-beta.json"
if [ -f "$MSG_FILE" ]; then
  pass "message file created"
else
  fail "message file created" "file not found: $MSG_FILE"
fi

# Verify message is valid JSON with correct fields
msg_from=$(jq -r '.messages[0].from' "$MSG_FILE")
assert_eq "message from field" "worker-alpha" "$msg_from"

msg_to=$(jq -r '.messages[0].to' "$MSG_FILE")
assert_eq "message to field" "worker-beta" "$msg_to"

msg_text=$(jq -r '.messages[0].text' "$MSG_FILE")
assert_eq "message text field" "API schema ready" "$msg_text"

msg_payload=$(jq -r '.messages[0].payload.schema_version' "$MSG_FILE")
assert_eq "message payload field" "2" "$msg_payload"

msg_delivered=$(jq '.messages[0].delivered' "$MSG_FILE")
assert_eq "message delivered is false" "false" "$msg_delivered"

# Send a second message to same recipient
send_message "worker-alpha" "worker-beta" "Schema updated" '{}'

msg_count=$(jq '.messages | length' "$MSG_FILE")
assert_eq "second message appended (count=2)" "2" "$msg_count"

# Send a message from a different sender to same recipient
send_message "worker-gamma" "worker-beta" "Tests pass" '{}'

# Get pending messages for worker-beta (should be 3 total from 2 files)
pending=$(get_pending_messages "worker-beta")
pending_count=$(echo "$pending" | jq 'length')
assert_eq "get_pending_messages returns 3 for worker-beta" "3" "$pending_count"

# All pending messages should have delivered=false
all_undelivered=$(echo "$pending" | jq '[.[] | .delivered] | all(. == false)')
assert_eq "all pending messages undelivered" "true" "$all_undelivered"

# Mark messages as delivered for worker-beta
mark_delivered "worker-beta"

# After marking, pending should be 0
pending_after=$(get_pending_messages "worker-beta")
pending_after_count=$(echo "$pending_after" | jq 'length')
assert_eq "pending messages 0 after mark_delivered" "0" "$pending_after_count"

# Verify the file still has 2 messages, all delivered
delivered_count=$(jq '[.messages[] | select(.delivered == true)] | length' "$MSG_FILE")
assert_eq "all messages in file marked delivered" "2" "$delivered_count"

# ===========================================================================
# Section 7: tmux Session (optional)
# ===========================================================================
section "tmux Session"

if command -v tmux >/dev/null 2>&1; then
  # Use a test-specific session name to avoid interfering with real sessions
  ORIG_TMUX_SESSION="$TMUX_SESSION"
  TMUX_SESSION="orchestra-test"

  # ensure_tmux_session should create the session
  ensure_tmux_session
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    pass "ensure_tmux_session creates tmux session"
  else
    fail "ensure_tmux_session creates tmux session" "session not found"
  fi

  # Calling it again should be idempotent (no error)
  ensure_tmux_session
  pass "ensure_tmux_session is idempotent"

  # Verify the status window exists
  windows=$(tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null || true)
  if echo "$windows" | grep -q "status"; then
    pass "tmux session has 'status' window"
  else
    fail "tmux session has 'status' window" "windows: $windows"
  fi

  # Clean up test session
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  TMUX_SESSION="$ORIG_TMUX_SESSION"
else
  echo "  SKIP: tmux not available"
fi

# ===========================================================================
# Section 8: Full Pipeline (synthetic end-to-end)
# ===========================================================================
section "Full Pipeline (synthetic end-to-end)"

# This section simulates the full lifecycle of a worker without spawning claude:
# 1. Create worker -> 2. Write log -> 3. Monitor updates -> 4. Send message -> 5. Verify

PIPELINE_WORKER="worker-pipeline"
PIPELINE_SESSION=$(generate_session_id)
PIPELINE_JSON=$(create_worker_json "$PIPELINE_WORKER" "$PIPELINE_SESSION" "/tmp/pipeline" "Full pipeline test" "10.00")
echo "$PIPELINE_JSON" > "$ORCH_DIR/workers/${PIPELINE_WORKER}.json"

# Step 1: Verify initial state
p_status=$(jq -r '.status' "$ORCH_DIR/workers/${PIPELINE_WORKER}.json")
assert_eq "pipeline: initial status is active" "active" "$p_status"

# Step 2: Write a log simulating brainstorming phase
PIPELINE_LOG="$ORCH_DIR/logs/${PIPELINE_WORKER}.log"
cat > "$PIPELINE_LOG" <<'JSONL'
{"type":"system","subtype":"init","session_id":"pipeline-session"}
{"type":"assistant","message":{"content":[{"type":"text","text":"[PHASE:brainstorming] Exploring options."}]}}
JSONL

# Step 3: Run monitor update
update_worker_state "$PIPELINE_WORKER"
p_phase=$(jq -r '.phase' "$ORCH_DIR/workers/${PIPELINE_WORKER}.json")
assert_eq "pipeline: phase updated to brainstorming" "brainstorming" "$p_phase"
p_progress=$(jq -r '.progress' "$ORCH_DIR/workers/${PIPELINE_WORKER}.json")
assert_eq "pipeline: progress at 15" "15" "$p_progress"

# Step 4: Simulate phase progression
cat >> "$PIPELINE_LOG" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"text","text":"[PHASE:planning] Writing plan."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"[PHASE:implementing] Building it."}]}}
JSONL
update_worker_state "$PIPELINE_WORKER"
p_phase=$(jq -r '.phase' "$ORCH_DIR/workers/${PIPELINE_WORKER}.json")
assert_eq "pipeline: phase progressed to implementing" "implementing" "$p_phase"
p_progress=$(jq -r '.progress' "$ORCH_DIR/workers/${PIPELINE_WORKER}.json")
assert_eq "pipeline: progress at 60" "60" "$p_progress"

# Step 5: Send a message from orchestrator to the worker
send_message "orchestrator" "$PIPELINE_WORKER" "Priority increased" '{"priority":"high"}'
pending_p=$(get_pending_messages "$PIPELINE_WORKER")
pending_p_count=$(echo "$pending_p" | jq 'length')
assert_eq "pipeline: worker has 1 pending message" "1" "$pending_p_count"

# Step 6: Simulate completion
cat >> "$PIPELINE_LOG" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"text","text":"[PHASE:completing] Finishing up."}]}}
{"type":"result","subtype":"success","total_cost_usd":4.50,"num_turns":20,"session_id":"pipeline-session"}
JSONL
update_worker_state "$PIPELINE_WORKER"
p_status=$(jq -r '.status' "$ORCH_DIR/workers/${PIPELINE_WORKER}.json")
assert_eq "pipeline: status is done after completion" "done" "$p_status"
p_cost=$(jq -r '.spent_usd' "$ORCH_DIR/workers/${PIPELINE_WORKER}.json")
# jq may preserve trailing zeros (4.50 vs 4.5), so compare numerically
if [ "$(echo "$p_cost == 4.50" | bc -l)" = "1" ]; then
  pass "pipeline: spent_usd is 4.50"
else
  fail "pipeline: spent_usd is 4.50" "got '$p_cost'"
fi

# Step 7: Verify completed worker is skipped on next cycle
update_worker_state "$PIPELINE_WORKER"
p_status2=$(jq -r '.status' "$ORCH_DIR/workers/${PIPELINE_WORKER}.json")
assert_eq "pipeline: completed worker stays done" "done" "$p_status2"

# ===========================================================================
# Cleanup
# ===========================================================================
# teardown trap handles TMPDIR_TEST removal
# Real worker file already removed after dashboard test

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "All integration tests passed."
