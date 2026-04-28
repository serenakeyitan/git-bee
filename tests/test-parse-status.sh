#!/bin/bash
# Test suite for parse-status.sh

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/parse-status.sh"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Test counter
TESTS=0
PASSED=0

# Test function
run_test() {
  local test_name="$1"
  local expected_result="$2"
  shift 2
  local actual_result

  TESTS=$((TESTS + 1))

  # Run the command and capture output
  if actual_result=$("$@" 2>/dev/null); then
    # Normalize JSON (remove whitespace differences)
    actual_result=$(echo "$actual_result" | tr -d ' \n')
    expected_result=$(echo "$expected_result" | tr -d ' \n')

    if [[ "$actual_result" == "$expected_result" ]]; then
      echo -e "${GREEN}✓${NC} $test_name"
      PASSED=$((PASSED + 1))
    else
      echo -e "${RED}✗${NC} $test_name"
      echo "  Expected: $expected_result"
      echo "  Got: $actual_result"
    fi
  else
    echo -e "${RED}✗${NC} $test_name (command failed)"
  fi
}

echo "Testing parse-status.sh..."
echo

# Test 1: Parse status line with action= and next=
run_test "Parse action=approved next=e2e" \
  '{"outcome": "approved", "next": "e2e"}' \
  "$SCRIPT" "reviewer: issue=123 action=approved next=e2e"

# Test 2: Parse status line with result= and next=
run_test "Parse result=passed next=merger" \
  '{"outcome": "passed", "next": "merger"}' \
  "$SCRIPT" "e2e: pr=456 result=passed next=merger"

# Test 3: Parse status line with verdict= and next=
run_test "Parse verdict=changes-requested next=drafter" \
  '{"outcome": "changes-requested", "next": "drafter"}' \
  "$SCRIPT" "reviewer: pr=789 verdict=changes-requested next=drafter"

# Test 4: Parse status line with only action=, no next=
run_test "Parse action only (no next)" \
  '{"outcome": "implemented", "next": ""}' \
  "$SCRIPT" "drafter: issue=111 action=implemented"

# Test 5: Parse status line with only next=, no outcome
run_test "Parse next only (no outcome)" \
  '{"outcome": "", "next": "reviewer"}' \
  "$SCRIPT" "drafter: issue=222 next=reviewer"

# Test 6: Parse empty status line
run_test "Parse empty status line" \
  '{"outcome": "", "next": ""}' \
  "$SCRIPT" ""

# Test 7: Parse status line with action=implemented-tiny
run_test "Parse action=implemented-tiny next=merger" \
  '{"outcome": "implemented-tiny", "next": "merger"}' \
  "$SCRIPT" "drafter: issue=333 action=implemented-tiny next=merger"

# Test 8: Parse status line with dashes in values
run_test "Parse action=no-op-waiting" \
  '{"outcome": "no-op-waiting", "next": "none"}' \
  "$SCRIPT" "drafter: issue=444 action=no-op-waiting next=none"

# Test 9: --from-file with non-existent file
run_test "--from-file with missing file" \
  '{"outcome": "", "next": ""}' \
  "$SCRIPT" --from-file "/tmp/nonexistent-$$.txt" "drafter"

# Test 10: --from-file with actual file
TEMP_FILE=$(mktemp)
cat > "$TEMP_FILE" <<'EOF'
Some output here
drafter: issue=555 action=implemented next=reviewer
More output
EOF
run_test "--from-file with valid file" \
  '{"outcome": "implemented", "next": "reviewer"}' \
  "$SCRIPT" --from-file "$TEMP_FILE" "drafter"
rm -f "$TEMP_FILE"

# Test 11: --from-file with multiple status lines (should take last)
TEMP_FILE=$(mktemp)
cat > "$TEMP_FILE" <<'EOF'
drafter: issue=666 action=claimed next=none
drafter: issue=666 action=implemented next=reviewer
EOF
run_test "--from-file takes last status line" \
  '{"outcome": "implemented", "next": "reviewer"}' \
  "$SCRIPT" --from-file "$TEMP_FILE" "drafter"
rm -f "$TEMP_FILE"

# Test 12: --from-log with timestamped entries
TEMP_LOG=$(mktemp)
cat > "$TEMP_LOG" <<'EOF'
2026-04-28T10:00:00Z drafter: issue=777 action=claimed next=none
2026-04-28T10:05:00Z reviewer: pr=778 verdict=approved next=e2e
2026-04-28T10:10:00Z drafter: issue=777 action=implemented next=reviewer
EOF
run_test "--from-log parses timestamped log" \
  '{"outcome": "implemented", "next": "reviewer"}' \
  "$SCRIPT" --from-log "$TEMP_LOG" "drafter"
rm -f "$TEMP_LOG"

# Test 13: --from-log with non-existent file
run_test "--from-log with missing file" \
  '{"outcome": "", "next": ""}' \
  "$SCRIPT" --from-log "/tmp/nonexistent-log-$$.txt" "e2e"

# Test 14: Check script is executable
if [[ -x "$SCRIPT" ]]; then
  echo -e "${GREEN}✓${NC} Script is executable"
  PASSED=$((PASSED + 1))
else
  echo -e "${RED}✗${NC} Script is not executable"
fi
TESTS=$((TESTS + 1))

echo
echo "Results: $PASSED/$TESTS tests passed"

# Output JSON for E2E test compatibility
printf '{"passed": %d, "total": %d}\n' "$PASSED" "$TESTS"

if [[ $PASSED -eq $TESTS ]]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}Some tests failed${NC}"
  exit 1
fi
