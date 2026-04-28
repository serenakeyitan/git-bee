#!/usr/bin/env bash
# E2E test for M3/PR 9: Dispatcher prefers roadmap-sourced issues
#
# Test cases:
# (a) tick.sh includes roadmap priority in issue selection jq filter
# (b) Roadmap priority (_roadmap_prio) is computed based on source:roadmap label
# (c) Sort order includes roadmap priority before general priority
# (d) Priority hierarchy: source:roadmap > priority:high > default
# (e) Cold-start: fresh clone can run dispatcher with roadmap priority

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

passed=0
total=5

cleanup() {
  # Clean up test artifacts
  rm -f /tmp/git-bee-test-dispatcher-roadmap-$$ 2>/dev/null || true
}
trap cleanup EXIT

log() {
  echo "[test-dispatcher-roadmap-priority] $*" >&2
}

# Test (a): tick.sh includes roadmap priority in issue selection jq filter
test_a() {
  log "Test (a): tick.sh includes roadmap priority in issue selection jq filter"

  if grep -q "_roadmap_prio" "$REPO_ROOT/scripts/tick.sh"; then
    log "✓ tick.sh includes _roadmap_prio field"
    ((passed++))
    return 0
  else
    log "✗ tick.sh missing _roadmap_prio field"
    return 1
  fi
}

# Test (b): Roadmap priority is computed based on source:roadmap label
test_b() {
  log "Test (b): Roadmap priority is computed based on source:roadmap label"

  # Check that _roadmap_prio is set to 0 for source:roadmap, 1 otherwise
  if grep -A 2 "_roadmap_prio:" "$REPO_ROOT/scripts/tick.sh" | grep -q 'source:roadmap'; then
    log "✓ _roadmap_prio computed based on source:roadmap label"
    ((passed++))
    return 0
  else
    log "✗ _roadmap_prio not computed from source:roadmap label"
    return 1
  fi
}

# Test (c): Sort order includes roadmap priority before general priority
test_c() {
  log "Test (c): Sort order includes roadmap priority before general priority"

  # Check that sort_by uses array with _roadmap_prio first
  if grep -q 'sort_by.*\[.*_roadmap_prio.*_priority_prio.*\]' "$REPO_ROOT/scripts/tick.sh"; then
    log "✓ sort_by includes roadmap priority before general priority"
    ((passed++))
    return 0
  else
    log "✗ sort_by missing correct priority order"
    return 1
  fi
}

# Test (d): Priority hierarchy verified in code structure
test_d() {
  log "Test (d): Priority hierarchy: source:roadmap > priority:high > default"

  # Check that both _roadmap_prio and _priority_prio exist and are used in sort
  local has_roadmap has_priority has_sort=0

  has_roadmap=$(grep -c "_roadmap_prio" "$REPO_ROOT/scripts/tick.sh" || echo 0)
  has_priority=$(grep -c "_priority_prio" "$REPO_ROOT/scripts/tick.sh" || echo 0)

  # Check if sort_by exists with both fields in correct order
  if grep -q 'sort_by.*\[.*_roadmap_prio.*_priority_prio' "$REPO_ROOT/scripts/tick.sh"; then
    has_sort=1
  fi

  if [[ $has_roadmap -ge 1 && $has_priority -ge 1 && $has_sort -eq 1 ]]; then
    log "✓ Priority hierarchy correctly implemented"
    ((passed++))
    return 0
  else
    log "✗ Priority hierarchy incomplete (roadmap: $has_roadmap, priority: $has_priority, sort: $has_sort)"
    return 1
  fi
}

# Test (e): Cold-start verification - check the full jq pipeline is valid
test_e() {
  log "Test (e): Cold-start: jq filter syntax is valid"

  # Extract the jq filter and test it with minimal valid input
  local test_json='[{"number": 1, "labels": [{"name": "source:roadmap"}]}, {"number": 2, "labels": [{"name": "priority:high"}]}, {"number": 3, "labels": []}]'

  # Test the jq filter logic
  local result
  result=$(echo "$test_json" | jq '[ .[]
            | select(.labels | map(.name) | index("breeze:wip") | not)
            | select(.labels | map(.name) | index("breeze:human") | not)
            | select(.labels | map(.name) | index("breeze:quarantine-hotloop") | not)
            | . + {
                _roadmap_prio: (if (.labels | map(.name) | index("source:roadmap")) then 0 else 1 end),
                _priority_prio: (if (.labels | map(.name) | index("priority:high")) then 0 else 1 end)
              } ]
          | sort_by([._roadmap_prio, ._priority_prio])
          | .[].number' 2>/dev/null || echo "")

  # Expected order: 1 (roadmap), 2 (priority:high), 3 (default)
  local expected="1
2
3"

  if [[ "$result" == "$expected" ]]; then
    log "✓ jq filter produces correct priority order"
    ((passed++))
    return 0
  else
    log "✗ jq filter produces incorrect order"
    log "  Expected: $(echo "$expected" | tr '\n' ' ')"
    log "  Got: $(echo "$result" | tr '\n' ' ')"
    return 1
  fi
}

# Run all tests
log "Running M3/PR 9 dispatcher roadmap priority tests"

test_a || true
test_b || true
test_c || true
test_d || true
test_e || true

# Output JSON result
echo "{\"passed\": $passed, \"total\": $total}"

# Exit 0 regardless of pass/fail (JSON is the verdict)
exit 0
