#!/usr/bin/env bash
# E2E test for M3/PR 7: Planner roadmap-driven backlog maintenance
#
# Test cases:
# (a) Planner prompt includes ROADMAP.md parsing logic
# (b) Mode 2 (roadmap maintenance) is defined
# (c) Milestone completion checks exist
# (d) Roadmap-related action types are defined
# (e) source:roadmap label is included

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

passed=0
total=5

cleanup() {
  # Clean up test artifacts
  rm -f /tmp/git-bee-test-planner-roadmap-$$ 2>/dev/null || true
}
trap cleanup EXIT

log() {
  echo "[test-planner-roadmap] $*" >&2
}

# Test (a): Planner prompt includes ROADMAP.md parsing logic
test_a() {
  log "Test (a): Planner prompt includes ROADMAP.md parsing logic"

  if grep -q "ROADMAP.md" "$REPO_ROOT/agents/planner.md"; then
    log "✓ planner.md references ROADMAP.md"
    ((passed++))
    return 0
  else
    log "✗ planner.md missing ROADMAP.md parsing logic"
    return 1
  fi
}

# Test (b): Mode 2 (roadmap maintenance) is defined
test_b() {
  log "Test (b): Mode 2 (roadmap maintenance) is defined"

  if grep -q "Mode 2:" "$REPO_ROOT/agents/planner.md"; then
    log "✓ planner.md defines Mode 2"
    ((passed++))
    return 0
  else
    log "✗ planner.md missing Mode 2 definition"
    return 1
  fi
}

# Test (c): Milestone completion checks exist
test_c() {
  log "Test (c): Milestone completion checks exist"

  # Check for milestone parsing pattern (vX.Y.Z format)
  if grep -qE "v[0-9]+\.[0-9]+\.[0-9]+" "$REPO_ROOT/agents/planner.md"; then
    log "✓ planner.md includes milestone version pattern"
    ((passed++))
    return 0
  else
    log "✗ planner.md missing milestone version pattern"
    return 1
  fi
}

# Test (d): Roadmap-related action types are defined
test_d() {
  log "Test (d): Roadmap-related action types are defined"

  local required_actions=(
    "filed-roadmap-issue"
    "roadmap-complete"
    "no-roadmap"
  )

  local missing=0
  for action in "${required_actions[@]}"; do
    if ! grep -q "$action" "$REPO_ROOT/agents/planner.md"; then
      log "✗ missing action type: $action"
      missing=$((missing + 1))
    fi
  done

  if [[ $missing -eq 0 ]]; then
    log "✓ all roadmap action types defined"
    ((passed++))
    return 0
  else
    log "✗ $missing action type(s) missing"
    return 1
  fi
}

# Test (e): source:roadmap label is included
test_e() {
  log "Test (e): source:roadmap label is included"

  if grep -q "source:roadmap" "$REPO_ROOT/agents/planner.md"; then
    log "✓ planner.md includes source:roadmap label"
    ((passed++))
    return 0
  else
    log "✗ planner.md missing source:roadmap label"
    return 1
  fi
}

# Run all tests
log "Running M3/PR 7 planner roadmap tests"

test_a || true
test_b || true
test_c || true
test_d || true
test_e || true

# Output JSON result
echo "{\"passed\": $passed, \"total\": $total}"

# Exit 0 regardless of pass/fail (JSON is the verdict)
exit 0
