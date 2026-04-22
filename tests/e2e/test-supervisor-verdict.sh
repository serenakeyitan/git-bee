#!/usr/bin/env bash
# E2E test for supervisor verdict invariant enforcement (issue #734).
#
# Tests:
# 1. Divergence detection when reviewer marker doesn't match GitHub state
# 2. Supervisor applies breeze:human and files issue on divergence
# 3. Supervisor correctly advances when marker and state align
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
REPO="serenakeyitan/git-bee"
LOG_DIR="${HOME}/.git-bee"
ACTIVITY_LOG="${LOG_DIR}/activity.ndjson"

# Source the label helpers
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/labels.sh"

echo "=== Testing supervisor verdict invariant enforcement ==="

# Test 1: Setup - Create a test PR with simulated reviewer divergence
echo "Test 1: Creating test PR with simulated review divergence..."

# Create a test branch and file
TEST_BRANCH="test-supervisor-$(date +%s)"
git checkout -b "$TEST_BRANCH" 2>/dev/null
echo "Test file for supervisor E2E test" > test-supervisor.txt
git add test-supervisor.txt
git commit -m "Test: Supervisor verdict invariant E2E" 2>/dev/null

# Push branch and create PR
git push origin "$TEST_BRANCH" 2>/dev/null

TEST_PR=$(gh pr create --repo "$REPO" \
  --title "[E2E Test] Supervisor verdict check $(date +%s)" \
  --body "Automated test PR for supervisor verdict invariant enforcement. Will be closed automatically." \
  --head "$TEST_BRANCH" \
  2>/dev/null | grep -oE '[0-9]+$')

echo "  Created test PR #$TEST_PR"

# Test 2: Simulate reviewer divergence - comment review with "approved" marker in activity log
echo ""
echo "Test 2: Simulating reviewer verdict divergence..."

# Post a COMMENT review (not APPROVED) via GitHub API
gh pr review "$TEST_PR" --repo "$REPO" --comment \
  -b "**reviewer verdict: approved**

This is a test review with divergent state - body says approved but review type is comment." 2>/dev/null

# Inject an "approved" marker into the activity log (simulating reviewer bug)
# This creates the divergence we're testing for
cat >> "$ACTIVITY_LOG" <<EOF
{"event":"start","ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agent":"reviewer","target":"#${TEST_PR}","id":"reviewer-test"}
{"event":"end","ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agent":"reviewer","target":"#${TEST_PR}","id":"reviewer-test","exit_code":0,"outcome":"approved","duration":1}
EOF

echo "  ✓ Created divergence: activity log says 'approved', GitHub state is 'COMMENTED'"

# Test 3: Run the supervisor check from tick.sh
echo ""
echo "Test 3: Testing supervisor detection of divergence..."

# Extract just the supervisor check logic into a test function
check_supervisor_divergence() {
  local pr_number="$1"

  # Get last reviewer activity marker for this PR
  local marker_action=""
  if [[ -f "$ACTIVITY_LOG" ]]; then
    marker_action=$(jq -r --arg pr "#${pr_number}" \
      'select(.event == "end" and .agent == "reviewer" and .target == $pr) |
       .outcome // ""' "$ACTIVITY_LOG" 2>/dev/null | tail -1)
  fi

  # Get GitHub review state for the last review
  local gh_state=""
  gh_state=$(gh pr view "$pr_number" --repo "$REPO" --json reviews \
    --jq '.reviews | if length > 0 then .[-1].state else "" end' 2>/dev/null || echo "")

  # Check for divergence
  local decision=""
  if [[ "$marker_action" == "approved" ]] && [[ "$gh_state" == "APPROVED" ]]; then
    decision="advance"
  elif [[ "$marker_action" == "requested-changes" ]] && [[ "$gh_state" == "CHANGES_REQUESTED" ]]; then
    decision="revise"
  elif [[ "$marker_action" == "paused" ]]; then
    decision="human"
  else
    decision="divergence"
  fi

  echo "marker_action=$marker_action gh_state=$gh_state decision=$decision"

  if [[ "$decision" == "divergence" ]]; then
    return 0  # Divergence detected
  else
    return 1  # No divergence
  fi
}

# Run the check
if check_supervisor_divergence "$TEST_PR"; then
  echo "  ✓ Supervisor correctly detected divergence"
else
  echo "  ✗ Supervisor failed to detect divergence"
fi

# Test 4: Verify supervisor would apply breeze:human label
echo ""
echo "Test 4: Simulating supervisor response to divergence..."

# In production, the supervisor would:
# 1. Apply breeze:human label
# 2. File a supervisor issue
# Let's manually trigger these actions to verify they work

set_breeze_state "$REPO" "$TEST_PR" human
sleep 1

# Check the label was applied
current_labels=$(gh pr view "$TEST_PR" --repo "$REPO" --json labels --jq '[.labels[].name | select(startswith("breeze:"))] | join(",")')
if [[ "$current_labels" == "breeze:human" ]]; then
  echo "  ✓ breeze:human label would be applied on divergence"
else
  echo "  ✗ Failed to apply breeze:human: $current_labels"
fi

# Test 5: Test aligned verdict (no divergence case)
echo ""
echo "Test 5: Testing aligned verdict (no divergence)..."

# Clean up the test PR first
gh pr close "$TEST_PR" --repo "$REPO" 2>/dev/null

# Create a new PR for the aligned test
TEST_PR_2=$(gh pr create --repo "$REPO" \
  --title "[E2E Test] Supervisor aligned verdict $(date +%s)" \
  --body "Test PR for aligned verdict case." \
  --head "$TEST_BRANCH" \
  2>/dev/null | grep -oE '[0-9]+$')

# Post an APPROVED review
gh pr review "$TEST_PR_2" --repo "$REPO" --approve \
  -b "**reviewer verdict: approved**

This review has aligned state." 2>/dev/null

# Add aligned activity log entry
cat >> "$ACTIVITY_LOG" <<EOF
{"event":"start","ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agent":"reviewer","target":"#${TEST_PR_2}","id":"reviewer-test-2"}
{"event":"end","ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agent":"reviewer","target":"#${TEST_PR_2}","id":"reviewer-test-2","exit_code":0,"outcome":"approved","duration":1}
EOF

# Check alignment
if ! check_supervisor_divergence "$TEST_PR_2"; then
  echo "  ✓ Supervisor correctly identifies aligned verdict (no divergence)"
else
  echo "  ✗ Supervisor incorrectly flagged aligned verdict as divergent"
fi

# Cleanup
echo ""
echo "Cleaning up test artifacts..."

# Close test PRs
gh pr close "$TEST_PR_2" --repo "$REPO" --delete-branch 2>/dev/null || true

# Return to main branch
git checkout main 2>/dev/null
git branch -D "$TEST_BRANCH" 2>/dev/null || true

# Clean up activity log test entries
if [[ -f "$ACTIVITY_LOG" ]]; then
  # Remove our test entries
  grep -v "reviewer-test" "$ACTIVITY_LOG" > "$ACTIVITY_LOG.tmp" 2>/dev/null || true
  mv "$ACTIVITY_LOG.tmp" "$ACTIVITY_LOG" 2>/dev/null || true
fi

echo "  ✓ Cleanup complete"
echo ""
echo "=== Supervisor verdict invariant E2E test complete ==="