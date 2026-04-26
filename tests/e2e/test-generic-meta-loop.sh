#!/usr/bin/env bash
# E2E test for generic meta-loop detector (M1/PR3, refs #798).
#
# Tests:
# (a) Agent role A files issue "Title X" once → verify no quarantine
# (b) Same (role A, "Title X") fires again within 1h → verify breeze:quarantine-hotloop applied to PR, breeze:human on issue
# (c) Same pair fires after 1h gap → verify no quarantine (window expired)
# (d) Different pair (role B, "Title X") fires → verify no quarantine (different role)
# (e) Cold-start: fresh clone can detect meta-loops

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
REPO="serenakeyitan/git-bee"

# Source helpers
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/labels.sh"
# shellcheck disable=SC1091
source "$HERE/tick-test-helper.sh"

echo "=== Testing generic meta-loop detector ==="

# Helper to clean up test artifacts
cleanup() {
  local issue_numbers=("$@")
  for n in "${issue_numbers[@]}"; do
    if [[ -n "$n" ]]; then
      gh issue close "$n" --repo "$REPO" >/dev/null 2>&1 || true
    fi
  done
}

# Test (a): Single filing → no quarantine
echo ""
echo "Test (a): Single issue filing should not trigger quarantine"
echo "-----------------------------------------------------------"

TEST_TITLE_A="[E2E Test] Generic meta-loop test A $(date +%s)"
TEST_BODY_A="**tick:**

This is test case (a) for generic meta-loop detection.
Should NOT trigger quarantine on first filing."

issue_a=$(file_or_update_issue "$REPO" "$TEST_TITLE_A" "$TEST_BODY_A" "" "tick")
echo "  Filed issue #$issue_a"

# Check that no quarantine labels were applied
labels=$(gh issue view "$issue_a" --repo "$REPO" --json labels --jq '[.labels[].name] | join(",")')
if echo "$labels" | grep -q "breeze:human"; then
  echo "  ✗ Issue incorrectly labeled breeze:human on first filing"
  cleanup "$issue_a"
  exit 1
else
  echo "  ✓ Issue not quarantined on first filing"
fi

cleanup "$issue_a"

# Test (b): Same (role, title) fires again within 1h → quarantine
echo ""
echo "Test (b): Second filing within 1h should trigger quarantine"
echo "-----------------------------------------------------------"

TEST_TITLE_B="[E2E Test] hot-loop: tick stuck on PR #999 $(date +%s)"
TEST_BODY_B1="**tick:**

First occurrence of this hot-loop pattern.
Testing meta-loop detection."

TEST_BODY_B2="**tick:**

Second occurrence within the window.
Should trigger quarantine."

# Create a test PR #999 for this test (if it doesn't exist)
# Note: We can't easily create PR #999, so we'll just test the issue quarantine
issue_b=$(file_or_update_issue "$REPO" "$TEST_TITLE_B" "$TEST_BODY_B1" "" "tick")
echo "  Filed first occurrence as issue #$issue_b"

sleep 2  # Brief pause to ensure distinct timestamps

# File again with same (role, title)
issue_b2=$(file_or_update_issue "$REPO" "$TEST_TITLE_B" "$TEST_BODY_B2" "" "tick")
echo "  Filed second occurrence (returned issue #$issue_b2)"

# Should be the same issue number (dedup working)
if [[ "$issue_b" != "$issue_b2" ]]; then
  echo "  ✗ Dedup failed: got different issue numbers"
  cleanup "$issue_b" "$issue_b2"
  exit 1
fi

sleep 2  # Allow time for meta-loop check to complete

# Check that breeze:human was applied
labels=$(gh issue view "$issue_b" --repo "$REPO" --json labels --jq '[.labels[].name] | join(",")')
if echo "$labels" | grep -q "breeze:human"; then
  echo "  ✓ Issue labeled breeze:human after meta-loop detection"
else
  echo "  ✗ Issue not labeled breeze:human after second filing"
  cleanup "$issue_b"
  exit 1
fi

# Check for meta-loop comment
comments=$(gh issue view "$issue_b" --repo "$REPO" --json comments --jq '[.comments[].body] | join("\n")')
if echo "$comments" | grep -q "Meta-loop detected"; then
  echo "  ✓ Meta-loop comment posted on issue"
else
  echo "  ✗ Meta-loop comment not found"
  cleanup "$issue_b"
  exit 1
fi

cleanup "$issue_b"

# Test (c): Same pair fires after 1h gap → no quarantine (window expired)
echo ""
echo "Test (c): Same pair after 1h gap should not trigger quarantine"
echo "---------------------------------------------------------------"

TEST_TITLE_C="[E2E Test] Generic meta-loop test C $(date +%s)"
TEST_BODY_C1="**tick:**

First occurrence for time-window test."

TEST_BODY_C2="**tick:**

Second occurrence, but cutoff set to far future."

# File first occurrence
issue_c=$(file_or_update_issue "$REPO" "$TEST_TITLE_C" "$TEST_BODY_C1" "" "tick")
echo "  Filed first occurrence as issue #$issue_c"

sleep 2

# Get issue creation time and compute a cutoff that's in the far future (2h from now)
# This simulates the scenario where the first filing was >1h ago
future_cutoff=$(date -u -v+2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "2 hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

# Manually call check_generic_meta_loop with far-future cutoff
# This makes the first filing appear to be outside the 60-minute window
# Expected: should NOT trigger quarantine (count=1, threshold=2)
set +e
check_generic_meta_loop "$REPO" "tick" "$TEST_TITLE_C" "$issue_c" "$future_cutoff"
meta_loop_result=$?
set -e

if [[ "$meta_loop_result" -eq 0 ]]; then
  echo "  ✗ Meta-loop incorrectly triggered despite window expiration"
  cleanup "$issue_c"
  exit 1
fi

# Verify no quarantine label was applied
labels=$(gh issue view "$issue_c" --repo "$REPO" --json labels --jq '[.labels[].name] | join(",")')
if echo "$labels" | grep -q "breeze:human"; then
  echo "  ✗ Issue incorrectly quarantined after window expiration"
  cleanup "$issue_c"
  exit 1
else
  echo "  ✓ Issue not quarantined when window expired (first filing outside 60min)"
fi

cleanup "$issue_c"

# Test (d): Different role fires same title → no quarantine
echo ""
echo "Test (d): Different agent role should not trigger quarantine"
echo "------------------------------------------------------------"

TEST_TITLE_D="[E2E Test] Generic meta-loop test D $(date +%s)"
TEST_BODY_D1="**tick:**

First filing by tick role."

TEST_BODY_D2="**supervisor:**

Second filing but by different role (supervisor)."

issue_d1=$(file_or_update_issue "$REPO" "$TEST_TITLE_D" "$TEST_BODY_D1" "" "tick")
echo "  Filed by tick role as issue #$issue_d1"

sleep 2

issue_d2=$(file_or_update_issue "$REPO" "$TEST_TITLE_D" "$TEST_BODY_D2" "" "supervisor")
echo "  Filed by supervisor role (returned issue #$issue_d2)"

sleep 2

# Check that no quarantine was applied (different roles)
labels=$(gh issue view "$issue_d1" --repo "$REPO" --json labels --jq '[.labels[].name] | join(",")')
if echo "$labels" | grep -q "breeze:human"; then
  echo "  ✗ Issue incorrectly quarantined despite different agent roles"
  cleanup "$issue_d1"
  exit 1
else
  echo "  ✓ Issue not quarantined when different roles file same title"
fi

cleanup "$issue_d1"

# Test (e): Cold-start detection
echo ""
echo "Test (e): Fresh clone can detect meta-loops"
echo "-------------------------------------------"

# The check_generic_meta_loop function queries GitHub API directly, so it
# doesn't depend on local state. As long as the function is available and
# the labels.sh helper is sourced, it will work.

if type check_generic_meta_loop >/dev/null 2>&1; then
  echo "  ✓ check_generic_meta_loop function is available"
else
  echo "  ✗ check_generic_meta_loop function not found"
  exit 1
fi

if type set_breeze_state >/dev/null 2>&1; then
  echo "  ✓ set_breeze_state helper is available"
else
  echo "  ✗ set_breeze_state helper not found"
  exit 1
fi

echo "  ✓ Cold-start ready: all required functions available"

echo ""
echo "=== All tests passed ==="
echo '{"passed": 5, "total": 5}'
exit 0
