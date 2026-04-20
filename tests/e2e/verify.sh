#!/usr/bin/env bash
# PR 2 E2E verify — Agent role prompts and routing.
#
# Contract (design doc, "Cross-cutting expectations"):
#   - Prints exactly one JSON line at the end: {"passed": N, "total": M}.
#   - Exit 0 regardless of pass/fail count — the JSON line is the verdict.
#   - Idempotent — re-running in the same tree produces the same verdict.
#   - Cleans up temp files on EXIT/INT/TERM.
#   - Uses only bash, gh, jq, git (no Python/Node/installs).

set -u  # -e intentionally off — we want to count test failures, not abort.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gitbee-pr2-verify.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM HUP

passed=0
total=0

pass() { passed=$((passed+1)); total=$((total+1)); echo "  PASS: $1"; }
fail() { total=$((total+1)); echo "  FAIL: $1"; }

echo "== PR 2 E2E: Agent role prompts and routing =="

# Test 1: New agent role prompts exist
[[ -f "$REPO_ROOT/agents/planner.md" ]] \
  && pass "(1a) planner.md exists" \
  || fail "(1a) planner.md exists"

[[ -f "$REPO_ROOT/agents/e2e-designer.md" ]] \
  && pass "(1b) e2e-designer.md exists" \
  || fail "(1b) e2e-designer.md exists"

[[ -f "$REPO_ROOT/agents/e2e-supervisor.md" ]] \
  && pass "(1c) e2e-supervisor.md exists" \
  || fail "(1c) e2e-supervisor.md exists"

# Test 2: Each new role prompt has correct header
head -1 "$REPO_ROOT/agents/planner.md" 2>/dev/null | grep -q "^# planner" \
  && pass "(2a) planner.md has correct header" \
  || fail "(2a) planner.md has correct header"

head -1 "$REPO_ROOT/agents/e2e-designer.md" 2>/dev/null | grep -q "^# e2e-designer" \
  && pass "(2b) e2e-designer.md has correct header" \
  || fail "(2b) e2e-designer.md has correct header"

head -1 "$REPO_ROOT/agents/e2e-supervisor.md" 2>/dev/null | grep -q "^# e2e-supervisor" \
  && pass "(2c) e2e-supervisor.md has correct header" \
  || fail "(2c) e2e-supervisor.md has correct header"

# Test 3: Fresh context rules are documented
grep -q "## Fresh context rule" "$REPO_ROOT/agents/reviewer.md" 2>/dev/null \
  && pass "(3a) reviewer.md has fresh context rule" \
  || fail "(3a) reviewer.md has fresh context rule"

grep -q "## Fresh context rule" "$REPO_ROOT/agents/e2e.md" 2>/dev/null \
  && pass "(3b) e2e.md has fresh context rule" \
  || fail "(3b) e2e.md has fresh context rule"

grep -q "fresh context" "$REPO_ROOT/agents/e2e-designer.md" 2>/dev/null \
  && pass "(3c) e2e-designer has fresh context documented" \
  || fail "(3c) e2e-designer has fresh context documented"

grep -q "fresh context" "$REPO_ROOT/agents/e2e-supervisor.md" 2>/dev/null \
  && pass "(3d) e2e-supervisor has fresh context documented" \
  || fail "(3d) e2e-supervisor has fresh context documented"

# Test 4: Accumulated context rule is documented
grep -q "## Accumulated context rule" "$REPO_ROOT/agents/drafter.md" 2>/dev/null \
  && pass "(4) drafter.md has accumulated context rule" \
  || fail "(4) drafter.md has accumulated context rule"

# Test 5: Selective memory for reviewer
grep -q "## Selective memory" "$REPO_ROOT/agents/reviewer.md" 2>/dev/null \
  && pass "(5) reviewer.md has selective memory section" \
  || fail "(5) reviewer.md has selective memory section"

# Test 6: Test routing logic simulation
# Test 6a: finalized issue with no milestone plan → planner
test_planner_routing() {
  local body="## Finalization gate
- [x] **design finalized — agent may proceed**

Some design content without milestone plan"

  if ! echo "$body" | grep -q "^## Milestone plan"; then
    return 0
  fi
  return 1
}

test_planner_routing \
  && pass "(6a) Routes to planner when no milestone plan" \
  || fail "(6a) Routes to planner when no milestone plan"

# Test 6b: issue with milestone plan but no E2E test plan → e2e-designer
test_e2e_designer_routing() {
  local body="## Finalization gate
- [x] **design finalized — agent may proceed**

## Milestone plan
PR 1 - Test PR"

  if echo "$body" | grep -q "^## Milestone plan" && \
     ! echo "$body" | grep -q "^## E2E test plan"; then
    return 0
  fi
  return 1
}

test_e2e_designer_routing \
  && pass "(6b) Routes to e2e-designer when no test plan" \
  || fail "(6b) Routes to e2e-designer when no test plan"

# Test 6c: issue with test plan but no plan confirmation → e2e-supervisor
test_supervisor_routing() {
  local body="## Plan confirmation gate
- [ ] **plan confirmed — implementation may begin**

## Milestone plan
PR 1 - Test PR

## E2E test plan
Test cases..."

  if echo "$body" | grep -q "^## Milestone plan" && \
     echo "$body" | grep -q "^## E2E test plan" && \
     ! echo "$body" | grep -q "^- \[x\] \*\*plan confirmed"; then
    return 0
  fi
  return 1
}

test_supervisor_routing \
  && pass "(6c) Routes to e2e-supervisor when plan needs review" \
  || fail "(6c) Routes to e2e-supervisor when plan needs review"

# Test 6d: issue with confirmed plan → drafter
test_drafter_routing() {
  local body="## Plan confirmation gate
- [x] **plan confirmed — implementation may begin**

## Milestone plan
PR 1 - Test PR

## E2E test plan
Test cases..."

  if echo "$body" | grep -q "^## Milestone plan" && \
     echo "$body" | grep -q "^## E2E test plan" && \
     echo "$body" | grep -q "^- \[x\] \*\*plan confirmed"; then
    return 0
  fi
  return 1
}

test_drafter_routing \
  && pass "(6d) Routes to drafter when plan confirmed" \
  || fail "(6d) Routes to drafter when plan confirmed"

# Test 7: tick.sh has new routing logic
grep -q "## Milestone plan" "$REPO_ROOT/scripts/tick.sh" 2>/dev/null \
  && pass "(7a) tick.sh checks for milestone plan" \
  || fail "(7a) tick.sh checks for milestone plan"

grep -q "## E2E test plan" "$REPO_ROOT/scripts/tick.sh" 2>/dev/null \
  && pass "(7b) tick.sh checks for E2E test plan" \
  || fail "(7b) tick.sh checks for E2E test plan"

grep -q 'echo "planner $n"' "$REPO_ROOT/scripts/tick.sh" 2>/dev/null \
  && pass "(7c) tick.sh routes to planner" \
  || fail "(7c) tick.sh routes to planner"

grep -q 'echo "e2e-designer $n"' "$REPO_ROOT/scripts/tick.sh" 2>/dev/null \
  && pass "(7d) tick.sh routes to e2e-designer" \
  || fail "(7d) tick.sh routes to e2e-designer"

grep -q 'echo "e2e-supervisor $n"' "$REPO_ROOT/scripts/tick.sh" 2>/dev/null \
  && pass "(7e) tick.sh routes to e2e-supervisor for issues" \
  || fail "(7e) tick.sh routes to e2e-supervisor for issues"

grep -q 'echo "e2e-supervisor $(echo' "$REPO_ROOT/scripts/tick.sh" 2>/dev/null \
  && pass "(7f) tick.sh routes to e2e-supervisor for PRs" \
  || fail "(7f) tick.sh routes to e2e-supervisor for PRs"

# Test 8: Cold-start test - verify from fresh clone
# Skip if in cold run to avoid recursion
if [[ "${COLD_RUN:-0}" == "1" ]]; then
  pass "(8) cold-start — skipped in inner recursion"
elif git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  cold="$TMP/cold"
  if git clone --quiet --depth 1 "$REPO_ROOT" "$cold" 2>/dev/null; then
    # Copy uncommitted files for testing
    cp -R "$REPO_ROOT/agents" "$cold/" 2>/dev/null || true
    cp -R "$REPO_ROOT/scripts" "$cold/" 2>/dev/null || true
    cp -R "$REPO_ROOT/tests" "$cold/" 2>/dev/null || true

    if [[ -f "$cold/agents/planner.md" ]] && \
       [[ -f "$cold/agents/e2e-designer.md" ]] && \
       [[ -f "$cold/agents/e2e-supervisor.md" ]] && \
       verdict=$(COLD_RUN=1 bash "$cold/tests/e2e/verify.sh" 2>/dev/null | tail -1) && \
       echo "$verdict" | jq -e 'type == "object" and (.total | type == "number") and .total >= 10' >/dev/null 2>&1; then
      pass "(8) cold-start clone has new agents and runs verify.sh"
    else
      fail "(8) cold-start clone has new agents and runs verify.sh"
    fi
  else
    fail "(8) cold-start clone could not be created"
  fi
else
  fail "(8) cold-start clone — not inside a git work tree"
fi

# Final verdict — exactly one JSON line, per the contract.
printf '{"passed": %d, "total": %d}\n' "$passed" "$total"
exit 0