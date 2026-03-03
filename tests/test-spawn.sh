#!/usr/bin/env bash
# test-spawn.sh -- Tests for spawn-worker.sh functions
# Run: bash test-spawn.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

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

# Source spawn-worker.sh in dry-run mode (defines functions only)
source "$SCRIPT_DIR/../src/spawn-worker.sh" --dry-run

# Override template path to use repo templates (not installed path)
ORCH_TEMPLATES="$SCRIPT_DIR/../templates"

echo "=== generate_worker_id tests ==="

# Test 1: basic name
id=$(generate_worker_id "MyFeature")
assert_match "lowercase conversion" "^worker-myfeature$" "$id"

# Test 2: special characters replaced with hyphens
id=$(generate_worker_id "fix/bug#123")
assert_match "special chars to hyphens" "^worker-fix-bug-123$" "$id"

# Test 3: leading/trailing hyphens stripped from name portion
id=$(generate_worker_id "---hello---")
assert_match "strip leading/trailing hyphens" "^worker-hello$" "$id"

# Test 4: multiple consecutive hyphens collapsed
id=$(generate_worker_id "a!!!b")
assert_match "collapse consecutive hyphens" "^worker-a-b$" "$id"

# Test 5: prefix is worker-
id=$(generate_worker_id "test")
assert_match "worker- prefix" "^worker-" "$id"

# Test 6: only lowercase alphanumeric + hyphens (after prefix)
id=$(generate_worker_id "TeSt_NaMe!@#")
assert_match "valid chars only" "^worker-[a-z0-9-]+$" "$id"

# Test 7: max 30 chars after prefix
id=$(generate_worker_id "this-is-a-very-long-name-that-should-be-truncated-at-thirty-characters")
name_part="${id#worker-}"
if [ "${#name_part}" -le 30 ]; then
  pass "max 30 chars after prefix (got ${#name_part})"
else
  fail "max 30 chars after prefix" "name part is ${#name_part} chars"
fi

echo ""
echo "=== generate_session_id tests ==="

# Test 8: produces a valid lowercase UUID
sid=$(generate_session_id)
assert_match "UUID format" "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" "$sid"

# Test 9: two calls produce different UUIDs
sid2=$(generate_session_id)
if [ "$sid" != "$sid2" ]; then
  pass "UUIDs are unique"
else
  fail "UUIDs are unique" "got same UUID twice: $sid"
fi

echo ""
echo "=== create_worker_json tests ==="

json=$(create_worker_json "worker-test" "sess-123" "/tmp/project" "Do a thing" "5.00")

# Test 10: valid JSON (parseable by jq)
if echo "$json" | jq . >/dev/null 2>&1; then
  pass "JSON is valid (parseable by jq)"
else
  fail "JSON is valid" "jq could not parse output"
fi

# Test 11-16: required fields present
for field in id session_id project_dir task phase status budget_usd; do
  val=$(echo "$json" | jq -r ".$field")
  if [ "$val" != "null" ] && [ -n "$val" ]; then
    pass "field '$field' present (value: $val)"
  else
    fail "field '$field' present" "missing or null"
  fi
done

# Test 17: phase defaults to "initializing"
assert_eq "phase is initializing" "initializing" "$(echo "$json" | jq -r '.phase')"

# Test 18: status defaults to "active"
assert_eq "status is active" "active" "$(echo "$json" | jq -r '.status')"

# Test 19: spent_usd is 0
assert_eq "spent_usd is 0" "0" "$(echo "$json" | jq -r '.spent_usd')"

# Test 20: resume_count is 0
assert_eq "resume_count is 0" "0" "$(echo "$json" | jq -r '.resume_count')"

# Test 21: progress is 0
assert_eq "progress is 0" "0" "$(echo "$json" | jq -r '.progress')"

# Test 22: spawned_at is ISO-8601 UTC
spawned_at=$(echo "$json" | jq -r '.spawned_at')
assert_match "spawned_at is ISO-8601" "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}" "$spawned_at"

# Test 23: notes is empty string
assert_eq "notes is empty" "" "$(echo "$json" | jq -r '.notes')"

# Test 24: tmux_window is null
assert_eq "tmux_window is null" "null" "$(echo "$json" | jq -r '.tmux_window')"

echo ""
echo "=== build_system_prompt tests ==="

prompt=$(build_system_prompt "Build the widget" "/tmp/myproject")

# Test 25: task description substituted
if echo "$prompt" | grep -q "Build the widget"; then
  pass "task description substituted"
else
  fail "task description substituted" "task not found in prompt"
fi

# Test 26: project dir substituted
if echo "$prompt" | grep -q "/tmp/myproject"; then
  pass "project dir substituted"
else
  fail "project dir substituted" "project dir not found in prompt"
fi

# Test 27: no leftover placeholders
if echo "$prompt" | grep -q '{{'; then
  fail "no leftover placeholders" "found {{ in prompt"
else
  pass "no leftover placeholders"
fi

echo ""
echo "=== build_system_prompt generic template tests ==="
USE_SUPERPOWERS=false
prompt=$(build_system_prompt "Build a REST API" "/tmp/project")

# Test: generic template is used (contains "Brainstorm" but not "superpowers:")
echo "$prompt" | grep -q "Brainstorm" && pass "generic template contains Brainstorm" || fail "generic template missing Brainstorm" "Brainstorm not found in prompt"
echo "$prompt" | grep -q "superpowers:" && fail "generic template should not reference superpowers" "found superpowers: in prompt" || pass "generic template has no superpowers references"

# Test: placeholders still substituted
echo "$prompt" | grep -q "Build a REST API" && pass "generic task description substituted" || fail "generic task description not substituted" "task not found in prompt"
echo "$prompt" | grep -q "/tmp/project" && pass "generic project dir substituted" || fail "generic project dir not substituted" "project dir not found in prompt"

# Reset for any subsequent tests
USE_SUPERPOWERS=true

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  echo "All tests passed."
  exit 0
fi
