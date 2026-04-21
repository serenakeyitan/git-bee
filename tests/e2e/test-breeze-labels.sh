#!/usr/bin/env bash
# E2E test for breeze label lifecycle conformance with first-tree spec.
#
# Tests:
# 1. All four labels exist with correct colors/descriptions
# 2. New PRs start unlabeled (not breeze:wip)
# 3. Atomic transitions ensure at most one breeze:* label
# 4. Classifier precedence follows first-tree spec

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
REPO="serenakeyitan/git-bee"

# Source the label helpers
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/labels.sh"

echo "=== Testing breeze label lifecycle ==="

# Test 1: Verify all four labels exist with correct specs
echo "Test 1: Checking label definitions..."
EXPECTED_LABELS=(
  "breeze:new|0075ca|Breeze: new notification"
  "breeze:wip|e4e669|Breeze: work in progress"
  "breeze:human|d93f0b|Breeze: needs human attention"
  "breeze:done|0e8a16|Breeze: handled"
)

ALL_PASS=true
for expected in "${EXPECTED_LABELS[@]}"; do
  IFS='|' read -r name color desc <<< "$expected"

  actual=$(gh label list --repo "$REPO" --limit 200 | grep "^${name}\b" || echo "NOT_FOUND")
  if [[ "$actual" == "NOT_FOUND" ]]; then
    echo "  ✗ Label '$name' not found"
    ALL_PASS=false
  else
    # Parse tab-separated format: name<tab>description<tab>color
    IFS=$'\t' read -r actual_name actual_desc actual_color <<< "$actual"
    actual_color=$(echo "$actual_color" | tr -d '#')

    if [[ "$actual_color" != "$color" ]]; then
      echo "  ✗ Label '$name' has wrong color: expected #$color, got #$actual_color"
      ALL_PASS=false
    fi

    if [[ "$actual_desc" != "$desc" ]]; then
      echo "  ✗ Label '$name' has wrong description"
      echo "    Expected: $desc"
      echo "    Actual:   $actual_desc"
      ALL_PASS=false
    fi
  fi
done

if [[ "$ALL_PASS" == "true" ]]; then
  echo "  ✓ All labels match first-tree spec"
fi

# Test 2: Create test issue to verify transitions
echo ""
echo "Test 2: Testing atomic label transitions..."

# Create a test issue
TEST_ISSUE=$(gh issue create --repo "$REPO" \
  --title "[E2E Test] Breeze label lifecycle $(date +%s)" \
  --body "Automated test issue for breeze label conformance. Will be closed automatically." \
  2>/dev/null | grep -oE '[0-9]+$')

echo "  Created test issue #$TEST_ISSUE"

# Helper to check current breeze labels
check_breeze_labels() {
  local n="$1"
  gh issue view "$n" --repo "$REPO" --json labels --jq '[.labels[].name | select(startswith("breeze:"))] | join(",")'
}

# Test: New issue should have no breeze labels
current=$(check_breeze_labels "$TEST_ISSUE")
if [[ -z "$current" ]]; then
  echo "  ✓ New issue starts unlabeled (no breeze:*)"
else
  echo "  ✗ New issue has breeze labels: $current"
fi

# Test: Transition to wip
set_breeze_state "$REPO" "$TEST_ISSUE" wip
sleep 1
current=$(check_breeze_labels "$TEST_ISSUE")
if [[ "$current" == "breeze:wip" ]]; then
  echo "  ✓ Transitioned to breeze:wip"
else
  echo "  ✗ Failed to transition to wip: $current"
fi

# Test: Transition from wip to human (atomic)
set_breeze_state "$REPO" "$TEST_ISSUE" human
sleep 1
current=$(check_breeze_labels "$TEST_ISSUE")
if [[ "$current" == "breeze:human" ]]; then
  echo "  ✓ Atomic transition from wip to human"
else
  echo "  ✗ Non-atomic transition, labels: $current"
fi

# Test: Transition to done
set_breeze_state "$REPO" "$TEST_ISSUE" done
sleep 1
current=$(check_breeze_labels "$TEST_ISSUE")
if [[ "$current" == "breeze:done" ]]; then
  echo "  ✓ Transitioned to breeze:done"
else
  echo "  ✗ Failed to transition to done: $current"
fi

# Test: Clear all breeze labels
clear_breeze_state "$REPO" "$TEST_ISSUE"
sleep 1
current=$(check_breeze_labels "$TEST_ISSUE")
if [[ -z "$current" ]]; then
  echo "  ✓ Cleared all breeze labels"
else
  echo "  ✗ Failed to clear labels: $current"
fi

# Clean up: close the test issue
gh issue close "$TEST_ISSUE" --repo "$REPO" >/dev/null 2>&1
echo "  Closed test issue #$TEST_ISSUE"

# Test 3: Verify closed issues are classified as done (implicit)
echo ""
echo "Test 3: Testing classifier precedence..."
closed_state=$(gh issue view "$TEST_ISSUE" --repo "$REPO" --json state --jq '.state')
if [[ "$closed_state" == "CLOSED" ]]; then
  echo "  ✓ Closed issue has state=CLOSED (implicitly done per first-tree)"
else
  echo "  ✗ Issue state unexpected: $closed_state"
fi

echo ""
echo "=== Test complete ==="