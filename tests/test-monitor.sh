#!/usr/bin/env bash
# test-monitor.sh -- Tests for monitor.sh functions
# Run: bash test-monitor.sh

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

# Create a temporary directory for fake worker data
setup() {
  TMPDIR_TEST=$(mktemp -d)
  export ORCH_DIR="$TMPDIR_TEST"
  mkdir -p "$ORCH_DIR/workers"
  mkdir -p "$ORCH_DIR/logs"
}

# Clean up temporary files
teardown() {
  if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
    rm -rf "$TMPDIR_TEST"
  fi
}

trap teardown EXIT

setup

# Source parse-phase.sh (dependency)
source "$SCRIPT_DIR/../src/parse-phase.sh" --dry-run

# Source monitor.sh in dry-run mode (defines functions only)
source "$SCRIPT_DIR/../src/monitor.sh" --dry-run

echo "=== update_worker_state tests ==="

# Test 1: update_worker_state updates phase from log with [PHASE:implementing]
WORKER1="worker-test-phase"
cat > "$ORCH_DIR/workers/${WORKER1}.json" <<EOF
{
  "id": "$WORKER1",
  "session_id": "sess-111",
  "project_dir": "/tmp/proj",
  "task": "do stuff",
  "phase": "initializing",
  "status": "active",
  "budget_usd": "5.00",
  "spent_usd": 0,
  "spawned_at": "2026-01-01T00:00:00Z",
  "last_output_at": "2026-01-01T00:00:00Z",
  "tmux_window": null,
  "resume_count": 0,
  "progress": 0,
  "notes": ""
}
EOF
cat > "$ORCH_DIR/logs/${WORKER1}.log" <<'JSONL'
{"type":"system","subtype":"init","session_id":"sess-111"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Starting. [PHASE:implementing]"}]}}
JSONL
update_worker_state "$WORKER1"
updated_phase=$(jq -r '.phase' "$ORCH_DIR/workers/${WORKER1}.json")
assert_eq "update_worker_state sets phase to implementing" "implementing" "$updated_phase"

updated_progress=$(jq -r '.progress' "$ORCH_DIR/workers/${WORKER1}.json")
assert_eq "update_worker_state sets progress to 60" "60" "$updated_progress"

# Verify last_output_at was updated (should not still be 2026-01-01)
updated_last=$(jq -r '.last_output_at' "$ORCH_DIR/workers/${WORKER1}.json")
if [ "$updated_last" != "2026-01-01T00:00:00Z" ]; then
  pass "update_worker_state updates last_output_at"
else
  fail "update_worker_state updates last_output_at" "still at old value"
fi

# Test 2: update_worker_state picks up cost from result event
WORKER2="worker-test-cost"
cat > "$ORCH_DIR/workers/${WORKER2}.json" <<EOF
{
  "id": "$WORKER2",
  "session_id": "sess-222",
  "project_dir": "/tmp/proj",
  "task": "do stuff",
  "phase": "initializing",
  "status": "active",
  "budget_usd": "5.00",
  "spent_usd": 0,
  "spawned_at": "2026-01-01T00:00:00Z",
  "last_output_at": "2026-01-01T00:00:00Z",
  "tmux_window": null,
  "resume_count": 0,
  "progress": 0,
  "notes": ""
}
EOF
cat > "$ORCH_DIR/logs/${WORKER2}.log" <<'JSONL'
{"type":"system","subtype":"init","session_id":"sess-222"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Working. [PHASE:reviewing]"}]}}
{"type":"result","subtype":"success","total_cost_usd":1.23,"num_turns":15,"session_id":"sess-222"}
JSONL
update_worker_state "$WORKER2"
updated_cost=$(jq -r '.spent_usd' "$ORCH_DIR/workers/${WORKER2}.json")
assert_eq "update_worker_state sets spent_usd" "1.23" "$updated_cost"

updated_status=$(jq -r '.status' "$ORCH_DIR/workers/${WORKER2}.json")
assert_eq "update_worker_state marks completed worker" "completed" "$updated_status"

# Test 3: update_worker_state skips already-completed workers
WORKER3="worker-test-skip"
cat > "$ORCH_DIR/workers/${WORKER3}.json" <<EOF
{
  "id": "$WORKER3",
  "session_id": "sess-333",
  "project_dir": "/tmp/proj",
  "task": "do stuff",
  "phase": "completing",
  "status": "completed",
  "budget_usd": "5.00",
  "spent_usd": 2.50,
  "spawned_at": "2026-01-01T00:00:00Z",
  "last_output_at": "2026-01-01T00:00:00Z",
  "tmux_window": null,
  "resume_count": 0,
  "progress": 100,
  "notes": ""
}
EOF
cat > "$ORCH_DIR/logs/${WORKER3}.log" <<'JSONL'
{"type":"system","subtype":"init","session_id":"sess-333"}
{"type":"result","subtype":"success","total_cost_usd":2.50,"num_turns":20,"session_id":"sess-333"}
JSONL
update_worker_state "$WORKER3"
skip_status=$(jq -r '.status' "$ORCH_DIR/workers/${WORKER3}.json")
assert_eq "update_worker_state skips completed workers" "completed" "$skip_status"

skip_progress=$(jq -r '.progress' "$ORCH_DIR/workers/${WORKER3}.json")
assert_eq "update_worker_state preserves progress on completed" "100" "$skip_progress"

echo ""
echo "=== check_stuck tests ==="

# Test 4: check_stuck returns "true" for old last_output_at
WORKER4="worker-test-stuck"
# Set last_output_at to 10 minutes ago
old_epoch=$(( $(date +%s) - 600 ))
old_iso=$(date -u -r "$old_epoch" +"%Y-%m-%dT%H:%M:%SZ")
cat > "$ORCH_DIR/workers/${WORKER4}.json" <<EOF
{
  "id": "$WORKER4",
  "session_id": "sess-444",
  "project_dir": "/tmp/proj",
  "task": "do stuff",
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
result=$(check_stuck "$WORKER4" 300)
assert_eq "check_stuck returns true for old worker" "true" "$result"

# Test 5: check_stuck returns "false" for recent last_output_at
WORKER5="worker-test-fresh"
now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$ORCH_DIR/workers/${WORKER5}.json" <<EOF
{
  "id": "$WORKER5",
  "session_id": "sess-555",
  "project_dir": "/tmp/proj",
  "task": "do stuff",
  "phase": "implementing",
  "status": "active",
  "budget_usd": "5.00",
  "spent_usd": 0,
  "spawned_at": "2026-01-01T00:00:00Z",
  "last_output_at": "$now_iso",
  "tmux_window": null,
  "resume_count": 0,
  "progress": 60,
  "notes": ""
}
EOF
result=$(check_stuck "$WORKER5" 300)
assert_eq "check_stuck returns false for fresh worker" "false" "$result"

# Test 6: check_stuck returns "false" for completed workers
WORKER6="worker-test-done-stuck"
cat > "$ORCH_DIR/workers/${WORKER6}.json" <<EOF
{
  "id": "$WORKER6",
  "session_id": "sess-666",
  "project_dir": "/tmp/proj",
  "task": "do stuff",
  "phase": "completing",
  "status": "completed",
  "budget_usd": "5.00",
  "spent_usd": 3.00,
  "spawned_at": "2026-01-01T00:00:00Z",
  "last_output_at": "$old_iso",
  "tmux_window": null,
  "resume_count": 0,
  "progress": 100,
  "notes": ""
}
EOF
result=$(check_stuck "$WORKER6" 300)
assert_eq "check_stuck returns false for completed worker" "false" "$result"

echo ""
echo "=== run_cycle tests ==="

# Test 7: run_cycle processes all workers without error
# Reset: create 2 active workers with logs
WORKER7A="worker-cycle-a"
cat > "$ORCH_DIR/workers/${WORKER7A}.json" <<EOF
{
  "id": "$WORKER7A",
  "session_id": "sess-7a",
  "project_dir": "/tmp/proj",
  "task": "task a",
  "phase": "initializing",
  "status": "active",
  "budget_usd": "5.00",
  "spent_usd": 0,
  "spawned_at": "2026-01-01T00:00:00Z",
  "last_output_at": "$now_iso",
  "tmux_window": null,
  "resume_count": 0,
  "progress": 0,
  "notes": ""
}
EOF
cat > "$ORCH_DIR/logs/${WORKER7A}.log" <<'JSONL'
{"type":"system","subtype":"init","session_id":"sess-7a"}
{"type":"assistant","message":{"content":[{"type":"text","text":"[PHASE:planning] Planning..."}]}}
JSONL

WORKER7B="worker-cycle-b"
cat > "$ORCH_DIR/workers/${WORKER7B}.json" <<EOF
{
  "id": "$WORKER7B",
  "session_id": "sess-7b",
  "project_dir": "/tmp/proj",
  "task": "task b",
  "phase": "initializing",
  "status": "active",
  "budget_usd": "5.00",
  "spent_usd": 0,
  "spawned_at": "2026-01-01T00:00:00Z",
  "last_output_at": "$now_iso",
  "tmux_window": null,
  "resume_count": 0,
  "progress": 0,
  "notes": ""
}
EOF
cat > "$ORCH_DIR/logs/${WORKER7B}.log" <<'JSONL'
{"type":"system","subtype":"init","session_id":"sess-7b"}
{"type":"assistant","message":{"content":[{"type":"text","text":"[PHASE:implementing] Coding..."}]}}
JSONL

run_cycle
rc_status=$?
assert_eq "run_cycle exits with 0" "0" "$rc_status"

phase_a=$(jq -r '.phase' "$ORCH_DIR/workers/${WORKER7A}.json")
assert_eq "run_cycle updated worker-cycle-a phase" "planning" "$phase_a"

phase_b=$(jq -r '.phase' "$ORCH_DIR/workers/${WORKER7B}.json")
assert_eq "run_cycle updated worker-cycle-b phase" "implementing" "$phase_b"

# Test 8: run_cycle marks stuck worker
WORKER8="worker-cycle-stuck"
cat > "$ORCH_DIR/workers/${WORKER8}.json" <<EOF
{
  "id": "$WORKER8",
  "session_id": "sess-8",
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
cat > "$ORCH_DIR/logs/${WORKER8}.log" <<'JSONL'
{"type":"system","subtype":"init","session_id":"sess-8"}
{"type":"assistant","message":{"content":[{"type":"text","text":"[PHASE:implementing] Working..."}]}}
JSONL
# Touch the log to set its mtime to the old time too
touch -t "$(date -r "$old_epoch" +%Y%m%d%H%M.%S)" "$ORCH_DIR/logs/${WORKER8}.log"

run_cycle
stuck_status=$(jq -r '.status' "$ORCH_DIR/workers/${WORKER8}.json")
assert_eq "run_cycle marks stuck worker" "stuck" "$stuck_status"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  echo "All tests passed."
  exit 0
fi
