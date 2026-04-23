#!/usr/bin/env bash
# Unit tests for pr_pipeline_position() in scripts/tick.sh.
# Covers the #809 regression (stale E2E → should route to e2e, not reviewer)
# plus 9 other routing positions.
#
# Usage: tests/test-pr-pipeline-position.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
TICK="$REPO_ROOT/scripts/tick.sh"

# Stub the two helpers pr_pipeline_position calls (both live elsewhere in tick.sh
# but pulling the whole file would trigger top-level side effects).
has_human_approval() {
  local pr_json="$1"
  echo "$pr_json" | jq -e '.has_approval_marker // false' >/dev/null
}
has_human_revision_request() {
  local pr_json="$1"
  echo "$pr_json" | jq -e '.has_revision_marker // false' >/dev/null
}

# Extract just pr_pipeline_position from tick.sh and source it.
_extracted=$(mktemp)
awk '/^pr_pipeline_position\(\) \{/{p=1} p; p && /^\}$/{exit}' "$TICK" > "$_extracted"
# shellcheck disable=SC1090
source "$_extracted"
rm -f "$_extracted"

pass=0; fail=0
assert_position() {
  local name="$1" json="$2" expected="$3"
  local actual
  actual=$(pr_pipeline_position "$json")
  if [[ "$actual" == "$expected" ]]; then
    echo "  ✓ $name → $actual"
    pass=$((pass+1))
  else
    echo "  ✗ $name → got '$actual', expected '$expected'"
    fail=$((fail+1))
  fi
}

# Test 1: the #804/#809 bug — approved via marker, E2E traces at OLD sha only
assert_position "#809 bug: approved, E2E stale" '{
  "number": 804,
  "headRefOid": "5e254188bd271e31962140ae0b5de6f0b6b6b42f",
  "mergeable": "MERGEABLE",
  "labels": [],
  "has_approval_marker": true,
  "reviewDecision": "",
  "reviews": [{"state": "COMMENTED", "commit": {"oid": "5e254188bd271e31962140ae0b5de6f0b6b6b42f"}}],
  "comments": [{"body": "**E2E trace (pass)** at 03ee32f"}]
}' "approved-e2e-stale"

# Test 2: approved + E2E pass at current HEAD → merger
assert_position "approved + E2E pass at HEAD" '{
  "number": 100, "headRefOid": "abcdef1234567890", "mergeable": "MERGEABLE",
  "labels": [], "has_approval_marker": true, "reviewDecision": "",
  "reviews": [], "comments": [{"body": "**E2E trace (pass)** at abcdef1 run 1"}]
}' "ready-to-merge"

# Test 3: approved + E2E trace at HEAD but no pass → supervisor
assert_position "approved + E2E fail at HEAD" '{
  "number": 101, "headRefOid": "abcdef1234567890", "mergeable": "MERGEABLE",
  "labels": [], "has_approval_marker": true, "reviewDecision": "",
  "reviews": [], "comments": [{"body": "**E2E trace (fail)** at abcdef1 run 1"}]
}' "approved-e2e-failed"

# Test 4: merge conflict → drafter (conflict wins over everything)
assert_position "conflict wins over approval" '{
  "number": 102, "headRefOid": "abcdef1234567890", "mergeable": "CONFLICTING",
  "labels": [], "has_approval_marker": true, "reviewDecision": "APPROVED",
  "reviews": [], "comments": [{"body": "**E2E trace (pass)** at abcdef1"}]
}' "conflicted"

# Test 5: breeze:quarantine-hotloop → skip entirely
assert_position "quarantine wins" '{
  "number": 103, "headRefOid": "abcdef1234567890", "mergeable": "MERGEABLE",
  "labels": [{"name": "breeze:quarantine-hotloop"}], "has_approval_marker": true,
  "reviewDecision": "APPROVED", "reviews": [], "comments": [{"body": "**E2E trace (pass)** at abcdef1"}]
}' "quarantined"

# Test 6: revision request marker wins over approval
assert_position "revision marker → drafter" '{
  "number": 104, "headRefOid": "abcdef1234567890", "mergeable": "MERGEABLE",
  "labels": [], "has_revision_marker": true, "has_approval_marker": true,
  "reviewDecision": "APPROVED", "reviews": [], "comments": [{"body": "**E2E trace (pass)** at abcdef1"}]
}' "needs-drafter-feedback"

# Test 7: unreviewed PR, no approval → needs-review
assert_position "fresh PR → needs-review" '{
  "number": 105, "headRefOid": "abcdef1234567890", "mergeable": "MERGEABLE",
  "labels": [], "reviewDecision": "", "reviews": [], "comments": []
}' "needs-review"

# Test 8: reviewer already at HEAD, no approval/no request → skip
# (ball in human's court to post a marker; re-dispatching reviewer is pointless)
assert_position "reviewed-at-HEAD no verdict → skip" '{
  "number": 106, "headRefOid": "abcdef1234567890", "mergeable": "MERGEABLE",
  "labels": [], "reviewDecision": "",
  "reviews": [{"state": "COMMENTED", "commit": {"oid": "abcdef1234567890"}}],
  "comments": []
}' "skip"

# Test 9: CHANGES_REQUESTED at HEAD → drafter
assert_position "changes-requested → drafter" '{
  "number": 107, "headRefOid": "abcdef1234567890", "mergeable": "MERGEABLE",
  "labels": [], "reviewDecision": "CHANGES_REQUESTED",
  "reviews": [{"state": "CHANGES_REQUESTED", "commit": {"oid": "abcdef1234567890"}}],
  "comments": []
}' "needs-drafter-review"

# Test 10: breeze:wip → skip (another agent owns it)
assert_position "wip → skip" '{
  "number": 108, "headRefOid": "abcdef1234567890", "mergeable": "MERGEABLE",
  "labels": [{"name": "breeze:wip"}], "has_approval_marker": true,
  "reviewDecision": "APPROVED", "reviews": [], "comments": [{"body": "**E2E trace (pass)** at abcdef1"}]
}' "wip"

echo
echo "=== $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
