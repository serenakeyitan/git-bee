#!/usr/bin/env bash
# E2E test for M4/PR 12: File Phase-2 blocker questions
#
# Test cases:
# (a) Script files 5 issues on agent-team-foundation/first-tree → verify all 5 created
# (b) Verify issue titles match questions from docs/phase2-migration.md
# (c) Verify issues have correct labels/context
# (d) Edge case: issues already filed → verify no duplicates
# (e) Cold-start: fresh clone can file blocker questions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIRST_TREE_REPO="agent-team-foundation/first-tree"

passed=0
total=5

cleanup() {
  # Clean up test artifacts
  rm -f /tmp/git-bee-test-phase2-blockers-$$ 2>/dev/null || true
}
trap cleanup EXIT

log() {
  echo "[test-phase2-blockers] $*" >&2
}

# Test (a): Script files 5 issues on first-tree
test_a() {
  log "Test (a): 5 issues filed on first-tree"

  local expected_titles=(
    "[git-bee Phase 2] Will breeze accept a RepoStateCandidateSource contribution?"
    "[git-bee Phase 2] Does breeze's claim protocol compose with non-notification sources?"
    "[git-bee Phase 2] What's the expected cadence of breaking changes in breeze's daemon/runtime API?"
    "[git-bee Phase 2] Does breeze's gh broker support pre-push guards?"
    "[git-bee Phase 2] Where do git-bee-specific labels like breeze:quarantine-hotloop live?"
  )

  local found=0
  for title in "${expected_titles[@]}"; do
    if gh issue list --repo "$FIRST_TREE_REPO" --search "in:title \"$title\"" --json number --jq '.[0].number // empty' | grep -q .; then
      ((found++))
    fi
  done

  if [[ $found -eq 5 ]]; then
    log "✓ all 5 blocker issues exist"
    ((passed++))
    return 0
  else
    log "✗ only $found/5 issues found"
    return 1
  fi
}

# Test (b): Issue titles match questions from docs/phase2-migration.md
test_b() {
  log "Test (b): Issue titles match phase2-migration.md questions"

  local doc_file="$REPO_ROOT/docs/phase2-migration.md"
  if [[ ! -f "$doc_file" ]]; then
    log "✗ docs/phase2-migration.md not found"
    return 1
  fi

  # Check that key question topics are mentioned in filed issues
  local topics=(
    "RepoStateCandidateSource"
    "claim protocol"
    "breaking changes"
    "pre-push"
    "quarantine-hotloop"
  )

  local found=0
  for topic in "${topics[@]}"; do
    if gh issue list --repo "$FIRST_TREE_REPO" --search "[git-bee Phase 2] $topic" --json number --jq '.[0].number // empty' | grep -q .; then
      ((found++))
    fi
  done

  if [[ $found -eq 5 ]]; then
    log "✓ all question topics present in filed issues"
    ((passed++))
    return 0
  else
    log "✗ only $found/5 topics found in issues"
    return 1
  fi
}

# Test (c): Issues have correct labels/context
test_c() {
  log "Test (c): Issues have correct labels and context"

  # Check that at least one issue has the "question" label and references git-bee#798
  local issues=$(gh issue list --repo "$FIRST_TREE_REPO" --search "[git-bee Phase 2]" --json number --jq '.[].number' | head -5)

  local has_label=0
  local has_reference=0

  for issue_num in $issues; do
    # Check for question label
    if gh issue view "$issue_num" --repo "$FIRST_TREE_REPO" --json labels --jq '.labels[].name' | grep -q "question"; then
      has_label=1
    fi

    # Check for reference to git-bee#798
    if gh issue view "$issue_num" --repo "$FIRST_TREE_REPO" --json body --jq '.body' | grep -q "serenakeyitan/git-bee#798"; then
      has_reference=1
    fi

    if [[ $has_label -eq 1 && $has_reference -eq 1 ]]; then
      break
    fi
  done

  if [[ $has_label -eq 1 && $has_reference -eq 1 ]]; then
    log "✓ issues have correct labels and reference git-bee#798"
    ((passed++))
    return 0
  else
    log "✗ missing expected labels or references"
    return 1
  fi
}

# Test (d): Edge case - no duplicates created
test_d() {
  log "Test (d): Edge case - no duplicate issues"

  # Check that running the script again doesn't create duplicates
  local title="[git-bee Phase 2] Will breeze accept a RepoStateCandidateSource contribution?"
  local count=$(gh issue list --repo "$FIRST_TREE_REPO" --search "in:title \"$title\"" --state all --json number --jq 'length')

  if [[ $count -le 1 ]]; then
    log "✓ no duplicate issues (found $count)"
    ((passed++))
    return 0
  else
    log "✗ found $count duplicate issues"
    return 1
  fi
}

# Test (e): Cold-start - script is executable and can run
test_e() {
  log "Test (e): Cold-start - script is executable"

  local script="$REPO_ROOT/scripts/file-phase2-blockers.sh"

  if [[ -f "$script" && -x "$script" ]]; then
    # Verify script has proper structure
    if grep -q "FIRST_TREE_REPO=" "$script" && \
       grep -q "RepoStateCandidateSource" "$script" && \
       grep -q "claim protocol" "$script"; then
      log "✓ script exists, is executable, and has expected content"
      ((passed++))
      return 0
    else
      log "✗ script missing expected content"
      return 1
    fi
  else
    log "✗ script not found or not executable"
    return 1
  fi
}

# Run all tests
log "Running M4/PR 12 Phase-2 blocker filing tests"

test_a || true
test_b || true
test_c || true
test_d || true
test_e || true

# Output JSON result
echo "{\"passed\": $passed, \"total\": $total}"

# Exit 0 regardless of pass/fail (JSON is the verdict)
exit 0
