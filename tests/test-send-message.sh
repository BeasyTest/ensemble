#!/usr/bin/env bash
# test-send-message.sh -- Tests for send-message.sh functions
# Run: bash test-send-message.sh

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

# Create a temporary directory and override ORCH_DIR
setup() {
  TMPDIR_TEST=$(mktemp -d)
  export ORCH_DIR="$TMPDIR_TEST"
  mkdir -p "$ORCH_DIR/messages"
  mkdir -p "$ORCH_DIR/workers"
}

# Clean up temporary files
teardown() {
  if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
    rm -rf "$TMPDIR_TEST"
  fi
}

trap teardown EXIT

setup

# Create fake worker JSONs so deliver_messages could find them (not tested live)
cat > "$ORCH_DIR/workers/worker-backend.json" <<'JSON'
{
  "id": "worker-backend",
  "session_id": "sess-backend-111",
  "status": "active"
}
JSON

cat > "$ORCH_DIR/workers/worker-frontend.json" <<'JSON'
{
  "id": "worker-frontend",
  "session_id": "sess-frontend-222",
  "status": "active"
}
JSON

# Source send-message.sh in dry-run mode (defines functions only)
source "$SCRIPT_DIR/../src/send-message.sh" --dry-run

echo "=== send_message tests ==="

# Test 1: send_message creates a message file with correct JSON
send_message "worker-backend" "worker-frontend" "API schema is ready" '{"schema_url":"/tmp/schema.json"}'

MSG_FILE="$ORCH_DIR/messages/worker-backend-to-worker-frontend.json"
if [ -f "$MSG_FILE" ]; then
  pass "message file created"
else
  fail "message file created" "file not found: $MSG_FILE"
fi

# Test 2: message file is valid JSON
if jq . "$MSG_FILE" >/dev/null 2>&1; then
  pass "message file is valid JSON"
else
  fail "message file is valid JSON" "jq could not parse"
fi

# Test 3: messages array has exactly 1 element
count=$(jq '.messages | length' "$MSG_FILE")
assert_eq "messages array length is 1" "1" "$count"

# Test 4: message has correct 'from' field
from_val=$(jq -r '.messages[0].from' "$MSG_FILE")
assert_eq "message from field" "worker-backend" "$from_val"

# Test 5: message has correct 'to' field
to_val=$(jq -r '.messages[0].to' "$MSG_FILE")
assert_eq "message to field" "worker-frontend" "$to_val"

# Test 6: message has correct 'text' field
text_val=$(jq -r '.messages[0].text' "$MSG_FILE")
assert_eq "message text field" "API schema is ready" "$text_val"

# Test 7: message has correct 'payload' field
payload_val=$(jq -r '.messages[0].payload.schema_url' "$MSG_FILE")
assert_eq "message payload field" "/tmp/schema.json" "$payload_val"

# Test 8: message has ISO-8601 timestamp
ts_val=$(jq -r '.messages[0].timestamp' "$MSG_FILE")
if echo "$ts_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'; then
  pass "message timestamp is ISO-8601"
else
  fail "message timestamp is ISO-8601" "got: $ts_val"
fi

# Test 9: message delivered defaults to false
delivered_val=$(jq '.messages[0].delivered' "$MSG_FILE")
assert_eq "message delivered is false" "false" "$delivered_val"

echo ""
echo "=== send_message append test ==="

# Test 10: second message appends to same file (array length = 2)
send_message "worker-backend" "worker-frontend" "Schema updated" '{}'

count=$(jq '.messages | length' "$MSG_FILE")
assert_eq "messages array length is 2 after append" "2" "$count"

# Test 11: second message text is correct
text_val2=$(jq -r '.messages[1].text' "$MSG_FILE")
assert_eq "second message text" "Schema updated" "$text_val2"

echo ""
echo "=== send_message default payload test ==="

# Test 12: payload defaults to {} if not provided
send_message "worker-frontend" "worker-backend" "Need help"

MSG_FILE2="$ORCH_DIR/messages/worker-frontend-to-worker-backend.json"
payload_default=$(jq '.messages[0].payload' "$MSG_FILE2")
assert_eq "default payload is empty object" "{}" "$payload_default"

echo ""
echo "=== get_pending_messages tests ==="

# Test 13: get_pending_messages returns undelivered messages for worker-frontend
pending=$(get_pending_messages "worker-frontend")

if echo "$pending" | jq . >/dev/null 2>&1; then
  pass "get_pending_messages returns valid JSON"
else
  fail "get_pending_messages returns valid JSON" "got: $pending"
fi

# Test 14: pending messages count is 2 (the two messages from backend to frontend)
pending_count=$(echo "$pending" | jq 'length')
assert_eq "pending messages count for worker-frontend" "2" "$pending_count"

# Test 15: all pending messages have delivered=false
all_undelivered=$(echo "$pending" | jq '[.[] | .delivered] | all(. == false)')
assert_eq "all pending messages undelivered" "true" "$all_undelivered"

# Test 16: get_pending_messages for worker-backend returns 1 message
pending_backend=$(get_pending_messages "worker-backend")
pending_backend_count=$(echo "$pending_backend" | jq 'length')
assert_eq "pending messages count for worker-backend" "1" "$pending_backend_count"

echo ""
echo "=== mark_delivered tests ==="

# Test 17: mark_delivered sets all messages to delivered=true
mark_delivered "worker-frontend"

delivered_count=$(jq '[.messages[] | select(.delivered == true)] | length' "$MSG_FILE")
assert_eq "mark_delivered sets delivered=true (count)" "2" "$delivered_count"

# Test 18: all messages in file are now delivered
all_delivered=$(jq '[.messages[] | .delivered] | all(. == true)' "$MSG_FILE")
assert_eq "all messages marked delivered" "true" "$all_delivered"

echo ""
echo "=== get_pending_messages after mark_delivered ==="

# Test 19: get_pending_messages returns empty array after mark_delivered
pending_after=$(get_pending_messages "worker-frontend")
pending_after_count=$(echo "$pending_after" | jq 'length')
assert_eq "pending messages empty after mark_delivered" "0" "$pending_after_count"

# Test 20: worker-backend messages are still pending (unaffected by frontend mark)
pending_backend_still=$(get_pending_messages "worker-backend")
pending_backend_still_count=$(echo "$pending_backend_still" | jq 'length')
assert_eq "worker-backend messages still pending" "1" "$pending_backend_still_count"

echo ""
echo "=== main block CLI test ==="

# Test 21: running send-message.sh directly sends a message
bash "$SCRIPT_DIR/../src/send-message.sh" "worker-alpha" "worker-beta" "Hello from CLI" '{"key":"val"}'

MSG_FILE3="$ORCH_DIR/messages/worker-alpha-to-worker-beta.json"
if [ -f "$MSG_FILE3" ]; then
  pass "CLI mode creates message file"
else
  fail "CLI mode creates message file" "file not found: $MSG_FILE3"
fi

cli_text=$(jq -r '.messages[0].text' "$MSG_FILE3")
assert_eq "CLI message text" "Hello from CLI" "$cli_text"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  echo "All tests passed."
  exit 0
fi
