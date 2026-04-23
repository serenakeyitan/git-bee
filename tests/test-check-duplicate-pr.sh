#!/bin/bash
# Test suite for check-duplicate-pr.sh

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/check-duplicate-pr.sh"

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
    # Command succeeded
    if [[ "$expected_result" == "success" ]] || [[ "$actual_result" == "$expected_result" ]]; then
      echo -e "${GREEN}✓${NC} $test_name"
      PASSED=$((PASSED + 1))
    else
      echo -e "${RED}✗${NC} $test_name"
      echo "  Expected: $expected_result"
      echo "  Got: $actual_result"
    fi
  else
    # Command failed
    if [[ "$expected_result" == "error" ]]; then
      echo -e "${GREEN}✓${NC} $test_name"
      PASSED=$((PASSED + 1))
    else
      echo -e "${RED}✗${NC} $test_name (command failed)"
    fi
  fi
}

echo "Testing check-duplicate-pr.sh..."
echo

# Test 1: Missing arguments
run_test "Missing arguments should error" "error" "$SCRIPT"

# Test 2: Only repo provided
run_test "Only repo provided should error" "error" "$SCRIPT" "serenakeyitan/git-bee"

# Test 3: Valid arguments but no duplicate (using a high issue number unlikely to exist)
run_test "No duplicate for non-existent issue" "" "$SCRIPT" "serenakeyitan/git-bee" "999999"

# Test 4: Check script is executable
if [[ -x "$SCRIPT" ]]; then
  echo -e "${GREEN}✓${NC} Script is executable"
  PASSED=$((PASSED + 1))
else
  echo -e "${RED}✗${NC} Script is not executable"
fi
TESTS=$((TESTS + 1))

echo
echo "Results: $PASSED/$TESTS tests passed"

if [[ $PASSED -eq $TESTS ]]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}Some tests failed${NC}"
  exit 1
fi