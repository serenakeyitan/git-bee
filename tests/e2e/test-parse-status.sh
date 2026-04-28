#!/usr/bin/env bash
# E2E test for parse-status.sh extraction (M4/PR 11)
#
# Test cases:
# (a) Run scripts/parse-status.sh on valid agent status line → verify parsed JSON output
# (b) Run on malformed status line → verify error handling
# (c) Run unit tests for parser → verify all tests pass
# (d) Edge case: empty input → verify graceful handling
# (e) Cold-start: fresh clone can run parser with tests

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)

# Import test helpers
source "$HERE/tick-test-helper.sh" 2>/dev/null || true

PASSED=0
TOTAL=0

echo "=== E2E Test: parse-status.sh (M4/PR 11) ==="
echo

# Test case (a): Parse valid agent status line
test_case() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  echo -n "Test $TOTAL: $name ... "
}

pass() {
  PASSED=$((PASSED + 1))
  echo "✓"
}

fail() {
  echo "✗"
  echo "  $1"
}

# (a) Valid status line parsing
test_case "Parse valid drafter status line"
result=$("$REPO_ROOT/scripts/parse-status.sh" "drafter: issue=123 action=implemented next=reviewer")
outcome=$(echo "$result" | jq -r '.outcome')
next=$(echo "$result" | jq -r '.next')
if [[ "$outcome" == "implemented" ]] && [[ "$next" == "reviewer" ]]; then
  pass
else
  fail "Expected outcome=implemented, next=reviewer; got outcome=$outcome, next=$next"
fi

# (b) Malformed status line (graceful degradation)
test_case "Handle malformed status line"
result=$("$REPO_ROOT/scripts/parse-status.sh" "garbage input without markers")
outcome=$(echo "$result" | jq -r '.outcome')
next=$(echo "$result" | jq -r '.next')
if [[ "$outcome" == "" ]] && [[ "$next" == "" ]]; then
  pass
else
  fail "Expected empty outcome/next; got outcome=$outcome, next=$next"
fi

# (c) Unit tests pass
test_case "Unit tests pass"
if "$REPO_ROOT/tests/test-parse-status.sh" >/dev/null 2>&1; then
  pass
else
  fail "Unit tests failed"
fi

# (d) Empty input handling
test_case "Handle empty input"
result=$("$REPO_ROOT/scripts/parse-status.sh" "")
outcome=$(echo "$result" | jq -r '.outcome')
next=$(echo "$result" | jq -r '.next')
if [[ "$outcome" == "" ]] && [[ "$next" == "" ]]; then
  pass
else
  fail "Expected empty outcome/next; got outcome=$outcome, next=$next"
fi

# (e) --from-file mode
test_case "Parse from file"
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT
cat > "$TEMP_FILE" <<'EOF'
Some agent output
reviewer: pr=456 verdict=approved next=e2e
More output
EOF
result=$("$REPO_ROOT/scripts/parse-status.sh" --from-file "$TEMP_FILE" "reviewer")
outcome=$(echo "$result" | jq -r '.outcome')
next=$(echo "$result" | jq -r '.next')
if [[ "$outcome" == "approved" ]] && [[ "$next" == "e2e" ]]; then
  pass
else
  fail "Expected outcome=approved, next=e2e; got outcome=$outcome, next=$next"
fi

# (f) --from-log mode
test_case "Parse from timestamped log"
TEMP_LOG=$(mktemp)
cat > "$TEMP_LOG" <<'EOF'
2026-04-28T10:00:00Z drafter: issue=789 action=claimed next=none
2026-04-28T10:05:00Z drafter: issue=789 action=implemented next=reviewer
EOF
result=$("$REPO_ROOT/scripts/parse-status.sh" --from-log "$TEMP_LOG" "drafter")
outcome=$(echo "$result" | jq -r '.outcome')
next=$(echo "$result" | jq -r '.next')
rm -f "$TEMP_LOG"
if [[ "$outcome" == "implemented" ]] && [[ "$next" == "reviewer" ]]; then
  pass
else
  fail "Expected outcome=implemented, next=reviewer; got outcome=$outcome, next=$next"
fi

# (g) Integration: tick.sh uses parse-status.sh
test_case "tick.sh calls parse-status.sh"
if grep -q "parse-status.sh" "$REPO_ROOT/scripts/tick.sh"; then
  pass
else
  fail "tick.sh doesn't call parse-status.sh"
fi

# (h) Old parsing pattern removed
test_case "Old parsing pattern removed from tick.sh"
if ! grep -q "grep -oE '(action|result|verdict)=" "$REPO_ROOT/scripts/tick.sh"; then
  pass
else
  fail "Old parsing pattern still exists in tick.sh"
fi

echo
echo "=== Results ==="
echo "Passed: $PASSED/$TOTAL"

# Output JSON for compatibility with verify.sh
printf '{"passed": %d, "total": %d}\n' "$PASSED" "$TOTAL"

if [[ $PASSED -eq $TOTAL ]]; then
  echo "✓ All E2E tests passed"
  exit 0
else
  echo "✗ Some E2E tests failed"
  exit 1
fi
