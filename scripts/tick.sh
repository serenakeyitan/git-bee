#!/usr/bin/env bash
# git-bee tick: one pass of the scheduler.
#
# Guards (in order):
#   1. Local PID lock — if an agent is already running on this machine, exit.
#   2. GitHub state — find the oldest open issue/PR without a fresh breeze:wip.
#   3. If no unclaimed open items exist, project is finalized. Exit quietly.
#
# Invoked by launchd every 5 minutes (StartInterval=300).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/claim.sh"
# shellcheck disable=SC1091
source "$HERE/labels.sh"

REPO="serenakeyitan/git-bee"
LOCK="/tmp/git-bee-agent.pid"
LOG_DIR="${HOME}/.git-bee"
LOG="${LOG_DIR}/tick.log"
TICK_HISTORY="${LOG_DIR}/tick-history.log"
ROLLBACK_MARKER="${LOG_DIR}/ROLLBACK"
mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# Last-failure persistence functions (issue #751)
FAILURE_DIR="${LOG_DIR}/last-failure"

# Capture failure information when agent fails
capture_failure_info() {
  local role="$1" target="$2" exit_code="$3" outcome="${4:-unknown}"

  mkdir -p "$FAILURE_DIR"
  local failure_file="${FAILURE_DIR}/${role}-${target}.md"

  # Extract last 50 lines from log
  local last_lines
  last_lines=$(tail -n 50 "$LOG" 2>/dev/null || echo "No log available")

  # Infer failure cause from log patterns
  local inferred_cause="unknown"
  if echo "$last_lines" | grep -qiE "(network|timeout|connection|refused|reset)"; then
    inferred_cause="network"
  elif echo "$last_lines" | grep -qiE "(conflict|merge|diverged|fast-forward)"; then
    inferred_cause="conflict"
  elif echo "$last_lines" | grep -qiE "(tool|error|exception|traceback|failed|invalid)"; then
    inferred_cause="tool-error"
  fi

  # Write failure file
  cat > "$failure_file" <<EOF
timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
role: $role
target: #$target
exit_code: $exit_code
outcome: $outcome
inferred_cause: $inferred_cause
---
Last 50 lines of output:
$last_lines
EOF

  log "wrote failure info to $failure_file (cause: $inferred_cause)"
}

# Check if outcome is null/failed-* and capture failure
check_and_capture_outcome_failure() {
  local role="$1" target="$2"

  # Get the last activity log entry for this run
  local activity_log="${LOG_DIR}/activity.ndjson"
  if [[ ! -f "$activity_log" ]]; then
    return
  fi

  # Get the outcome from the most recent end event for this agent/target
  local outcome
  outcome=$(jq -r --arg agent "$role" --arg target "#${target}" '
    select(.event == "end" and .agent == $agent and .target == $target) |
    .outcome // "null"
  ' "$activity_log" 2>/dev/null | tail -1)

  # Capture failure if outcome is null or starts with "failed-"
  if [[ "$outcome" == "null" ]] || [[ "$outcome" == failed-* ]]; then
    log "outcome is $outcome, capturing failure info"
    capture_failure_info "$role" "$target" "0" "$outcome"
  else
    # Success - clean up any existing failure file
    local failure_file="${FAILURE_DIR}/${role}-${target}.md"
    if [[ -f "$failure_file" ]]; then
      rm -f "$failure_file"
      log "removed failure file after successful run: $failure_file"
    fi
  fi
}

# Clean up old failure files (older than 24 hours)
cleanup_old_failures() {
  if [[ -d "$FAILURE_DIR" ]]; then
    find "$FAILURE_DIR" -name "*.md" -mtime +1 -delete 2>/dev/null || true
  fi
}

# First-line logging - before any guards
# Detect if this was fired by launchd or self-triggered
LAUNCHD_FIRE="no"
if [[ "${PPID:-0}" == "1" ]] || ps -p "${PPID:-0}" 2>/dev/null | grep -q launchd; then
  LAUNCHD_FIRE="yes"
fi
log "tick start (pid=$$ launchd_fire=$LAUNCHD_FIRE)"

# Ensure breeze labels exist with correct colors/descriptions (idempotent).
if [[ -x "$HERE/ensure-labels.sh" ]]; then
  "$HERE/ensure-labels.sh" "$REPO" >/dev/null 2>&1 || true
fi

# EXIT trap for tick history logging
TICK_START_SHA=""
record_tick_exit() {
  local exit_code=$?
  if [[ -n "$TICK_START_SHA" ]]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $exit_code $TICK_START_SHA" >> "$TICK_HISTORY"

    # Log rotation at 1000 lines
    if [[ -f "$TICK_HISTORY" ]] && (( $(wc -l < "$TICK_HISTORY") > 1000 )); then
      tail -n 1000 "$TICK_HISTORY" > "$TICK_HISTORY.tmp"
      mv "$TICK_HISTORY.tmp" "$TICK_HISTORY"
    fi
  fi
}
trap record_tick_exit EXIT

# Capture current SHA at start
TICK_START_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Guard -0: 3-consecutive-crash detector
if [[ -f "$TICK_HISTORY" ]]; then
  # Count non-zero exits in last 3 ticks (Guard 0 exits with 0 by design)
  crashes=$(tail -n 3 "$TICK_HISTORY" 2>/dev/null | awk '$2 != 0' | wc -l | xargs)

  if [[ "$crashes" == "3" ]]; then
    log "ROLLBACK: 3 consecutive crashes detected"

    # Find the most recent known-good SHA (last exit 0)
    last_good=$(awk '$2 == 0 {sha=$3} END {print sha}' "$TICK_HISTORY" 2>/dev/null || echo "")

    if [[ -n "$last_good" && "$last_good" != "unknown" ]]; then
      log "Rolling back to last known-good SHA: $last_good"
      git -C "$REPO_ROOT" checkout "$last_good" 2>&1 | tee -a "$LOG"

      # Write ROLLBACK marker
      cat > "$ROLLBACK_MARKER" <<EOF
Automatic rollback triggered at $(date -u +%Y-%m-%dT%H:%M:%SZ)
Reason: 3 consecutive non-zero tick exits
Rolled back to: $last_good
Remove this file to resume normal operation.
EOF

      # Create breeze:human issue
      issue_body=$(cat <<EOF
**Automatic rollback triggered**

The git-bee tick loop detected 3 consecutive crashes and rolled back to the last known-good commit.

- **Time**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- **Rolled back to**: $last_good
- **Current SHA before rollback**: $TICK_START_SHA

**Action required**:
1. Investigate the crashes in \`~/.git-bee/tick.log\`
2. Fix the underlying issue
3. Remove \`~/.git-bee/ROLLBACK\` to resume the tick loop

The tick loop is now paused and will not dispatch agents until the ROLLBACK marker is removed.
EOF
)

      # Create the issue and apply breeze:human via the labeling helper.
      # We don't set priority:high — per AGENTS.md no auto-priority labels.
      local new_issue_url
      new_issue_url=$(gh issue create --repo "$REPO" \
        --title "Automatic rollback: 3 consecutive tick crashes detected" \
        --body "$issue_body" 2>&1 | tee -a "$LOG" | tail -1 || true)
      local new_issue_n
      new_issue_n=$(echo "$new_issue_url" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+' || echo "")
      if [[ -n "$new_issue_n" ]]; then
        set_breeze_state "$REPO" "$new_issue_n" human
      fi
    else
      log "ERROR: Could not find a known-good SHA in tick history — filing alert issue"

      # Write ROLLBACK marker to pause the loop even without a rollback target
      cat > "$ROLLBACK_MARKER" <<EOF
Automatic pause triggered at $(date -u +%Y-%m-%dT%H:%M:%SZ)
Reason: 3 consecutive non-zero tick exits with no known-good SHA available
Current SHA: $TICK_START_SHA
Remove this file to resume normal operation.
EOF

      # Create breeze:human issue to alert the user
      issue_body=$(cat <<EOF
**Tick loop crashing — no rollback target available**

The git-bee tick loop detected 3 consecutive crashes but could not find a known-good SHA to roll back to.

- **Time**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- **Current SHA**: $TICK_START_SHA
- **Tick history has no exit-0 rows**

**Action required**:
1. Investigate the crashes in \`~/.git-bee/tick.log\`
2. Manually fix the issue or checkout a known-good commit
3. Remove \`~/.git-bee/ROLLBACK\` to resume the tick loop

The tick loop is now paused and will not dispatch agents until the ROLLBACK marker is removed.
EOF
)

      # Create the issue and apply breeze:human via the labeling helper.
      local new_issue_url
      new_issue_url=$(gh issue create --repo "$REPO" \
        --title "Tick crashing with no rollback target available" \
        --body "$issue_body" 2>&1 | tee -a "$LOG" | tail -1 || true)
      local new_issue_n
      new_issue_n=$(echo "$new_issue_url" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+' || echo "")
      if [[ -n "$new_issue_n" ]]; then
        set_breeze_state "$REPO" "$new_issue_n" human
      fi
    fi
  fi
fi

# Guard -1: ROLLBACK marker — if it exists, exit early without dispatching
if [[ -f "$ROLLBACK_MARKER" ]]; then
  log "ROLLBACK marker exists — ticks paused. Remove $ROLLBACK_MARKER to resume."
  log "tick end (pid=$$ exit=rollback-marker)"
  exit 0
fi

# Guard 0: credential healthcheck. A tick that runs with expired gh auth
# produces the same "idle: nothing to do" log line as a finalized project,
# which silently breaks the loop. Fail loudly and exit instead.
if ! gh auth status >/dev/null 2>&1; then
  log "CREDENTIAL EXPIRED — gh auth status failed; skipping tick. Run 'gh auth login'."
  log "tick end (pid=$$ exit=gh-auth-fail)"
  exit 0
fi

# Guard 1: local PID lock
# Runs before the notification scanner so that a running agent blocks scanning
# too — the scanner makes GitHub API calls we don't want piled on an already-
# busy tick, and any issues it creates would sit behind the current agent's
# claim anyway.
if [[ -f "$LOCK" ]]; then
  pid=$(cat "$LOCK" 2>/dev/null || echo "")
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    log "skip: agent already running (pid=$pid)"
    log "tick end (pid=$$ exit=lock-held)"
    exit 0
  fi
  log "stale lock (pid=$pid), removing"
  rm -f "$LOCK"
fi

# Guard 1b: reset working tree to origin/main.
# ~/git-bee is shared state between the cron and the running agents. Agents
# check out feature branches to do drafter/merger work and sometimes exit
# without restoring main. The next tick would then run whatever scripts are
# on that feature branch — which may be a buggy older version. On 2026-04-20
# this caused notification-scanner to create 127 junk issues (#576–#702).
# The lock guard above proves no agent is running, so it's safe to checkout.
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  current_branch=$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo "DETACHED")
  if [[ "$current_branch" != "main" ]]; then
    log "working tree on '$current_branch', resetting to origin/main"
  fi
  git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true
  git -C "$REPO_ROOT" checkout main --quiet 2>/dev/null || true
  git -C "$REPO_ROOT" reset --hard origin/main --quiet 2>/dev/null || true
fi

# Run notification scanner after the lock guard. No-op by default (empty
# watchlist); only fires for repos the user explicitly added via `bee watch`.
if [[ -x "$HERE/notification-scanner.sh" ]]; then
  log "running notification scanner"
  "$HERE/notification-scanner.sh" 2>&1 | tee -a "$LOG" || log "notification scanner failed (rc=$?)"
fi

# Check if a PR qualifies for tiny-fix fast path
# Returns 0 if PR qualifies, 1 otherwise
check_tiny_fix() {
  local pr_number="$1"

  # Get PR details
  local pr_data
  pr_data=$(gh pr view "$pr_number" --repo "$REPO" --json headRefName,baseRefName,files,labels,additions,deletions,body 2>/dev/null || echo "{}")

  # Check if linked issue has size:tiny label
  local issue_number
  issue_number=$(echo "$pr_data" | jq -r '.body' | grep -oE '(Fixes|Closes|Resolves) #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")
  local has_size_tiny=0
  if [[ -n "$issue_number" ]]; then
    local issue_labels
    issue_labels=$(gh issue view "$issue_number" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
    if echo "$issue_labels" | grep -q "^size:tiny$"; then
      has_size_tiny=1
    fi
  fi

  # Check if drafter emitted action=implemented-tiny
  local has_implemented_tiny=0
  local drafter_comments
  drafter_comments=$(gh pr view "$pr_number" --repo "$REPO" --json comments --jq '.comments[].body' 2>/dev/null || echo "")
  if echo "$drafter_comments" | grep -q "drafter: issue=.* action=implemented-tiny"; then
    has_implemented_tiny=1
  fi

  # Must have either size:tiny label or implemented-tiny marker
  if [[ "$has_size_tiny" == "0" && "$has_implemented_tiny" == "0" ]]; then
    return 1
  fi

  # Calculate total LoC changed
  local additions=$(echo "$pr_data" | jq -r '.additions // 0')
  local deletions=$(echo "$pr_data" | jq -r '.deletions // 0')
  local total_loc=$((additions + deletions))

  if [[ "$total_loc" -gt 20 ]]; then
    return 1
  fi

  # Check file patterns - all files must match allowed patterns
  local files
  files=$(echo "$pr_data" | jq -r '.files[].path' 2>/dev/null || echo "")

  if [[ -z "$files" ]]; then
    return 1
  fi

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue

    # Exclude changes to scripts/tick.sh itself (safety carve-out)
    if [[ "$file" == "scripts/tick.sh" ]]; then
      return 1
    fi

    # Check if file matches allowed patterns: *.sh, *.md, agents/*, docs/*
    if [[ "$file" == *.sh ]] || [[ "$file" == *.md ]] || \
       [[ "$file" == agents/* ]] || [[ "$file" == docs/* ]]; then
      continue
    else
      # File doesn't match allowed patterns
      return 1
    fi
  done <<< "$files"

  # All checks passed
  return 0
}

# Guard 2: find work
# Priority order (PRs beat issues — if an issue already has a linked PR,
# the PR is the next actionable step):
#   1. approved PRs → e2e agent
#   2. unreviewed open PRs → reviewer agent
#   3. issues with NO linked open PR and no breeze:wip → drafter agent
# Returns 0 if PR has valid human approval (GitHub APPROVED review OR
# bee:approved-for-e2e marker in any review/comment authored at/after HEAD SHA timestamp).
has_human_approval() {
  local pr_json="$1"
  local pr_head_sha="$2"

  # Extract HEAD commit timestamp
  local head_timestamp
  head_timestamp=$(git -C "$REPO_ROOT" show -s --format=%ct "$pr_head_sha" 2>/dev/null || echo "0")

  # Check for GitHub APPROVED review decision
  local has_github_approval
  has_github_approval=$(echo "$pr_json" | jq -r '.reviewDecision == "APPROVED"' 2>/dev/null || echo "false")

  if [[ "$has_github_approval" == "true" ]]; then
    return 0
  fi

  # Check for bee:approved-for-e2e marker in reviews at/after HEAD timestamp
  local has_marker_in_reviews
  has_marker_in_reviews=$(echo "$pr_json" | jq --arg head_ts "$head_timestamp" '
    any(.reviews[]?;
      (.body // "" | contains("<!-- bee:approved-for-e2e -->")) and
      ((.submittedAt // "" | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= ($head_ts | tonumber))
    )
  ' 2>/dev/null || echo "false")

  if [[ "$has_marker_in_reviews" == "true" ]]; then
    return 0
  fi

  # Check for bee:approved-for-e2e marker in comments at/after HEAD timestamp
  local has_marker_in_comments
  has_marker_in_comments=$(echo "$pr_json" | jq --arg head_ts "$head_timestamp" '
    any(.comments[]?;
      (.body // "" | contains("<!-- bee:approved-for-e2e -->")) and
      ((.createdAt // "" | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= ($head_ts | tonumber))
    )
  ' 2>/dev/null || echo "false")

  if [[ "$has_marker_in_comments" == "true" ]]; then
    return 0
  fi

  return 1
}

pick_target() {
  # Emits "<kind> <number>" to stdout, nothing if idle.
  # Note: --state open excludes MERGED/CLOSED PRs per first-tree classifier precedence.

  local pr_basics
  pr_basics=$(gh pr list --repo "$REPO" --state open --search "sort:created-asc" --limit 50 \
    --json number,reviewDecision,labels,reviews,comments,headRefOid,mergeable,mergeStateStatus 2>/dev/null || echo "[]")
  # Priority sort: priority:high first, then original (created-asc) order.
  pr_basics=$(echo "$pr_basics" | jq '[ .[] | . as $p | $p + {_prio: (if ($p.labels | map(.name) | index("priority:high")) then 0 else 1 end)} ] | sort_by(._prio) | map(del(._prio))')

  # 1. Approved PRs that also have a passing E2E trace → merger.
  # "Approved" = reviewDecision == APPROVED OR a review body contains the marker.
  # "E2E pass" = any PR issue-comment contains "**E2E trace (pass)**".
  local mergeable_prs=""
  local pr
  while IFS= read -r pr; do
    [[ -z "$pr" ]] && continue
    local pr_num=$(echo "$pr" | jq -r '.number')
    local pr_sha=$(echo "$pr" | jq -r '.headRefOid')
    local has_wip=$(echo "$pr" | jq -r '.labels | map(.name) | index("breeze:wip") // false' 2>/dev/null || echo "false")
    local has_human=$(echo "$pr" | jq -r '.labels | map(.name) | index("breeze:human") // false' 2>/dev/null || echo "false")
    local has_quarantine=$(echo "$pr" | jq -r '.labels | map(.name) | index("breeze:quarantine-hotloop") // false' 2>/dev/null || echo "false")
    local is_conflicting=$(echo "$pr" | jq -r '.mergeable == "CONFLICTING" or .mergeStateStatus == "DIRTY"' 2>/dev/null || echo "false")
    local has_e2e_pass=$(echo "$pr" | jq -r --arg sha "${pr_sha:0:7}" '
      any(.comments[]?.body // ""; (contains("**E2E trace (pass)**") and contains($sha)))' 2>/dev/null || echo "false")

    if [[ "$has_wip" == "false" && "$has_human" == "false" && "$has_quarantine" == "false" && "$is_conflicting" == "false" && "$has_e2e_pass" == "true" ]]; then
      if has_human_approval "$pr" "$pr_sha"; then
        mergeable_prs="${mergeable_prs}${pr_num}"$'\n'
      fi
    fi
  done < <(echo "$pr_basics" | jq -c '.[]' 2>/dev/null)
  if [[ -n "$mergeable_prs" ]]; then
    echo "merger $(echo "$mergeable_prs" | head -1)"
    return
  fi

  # 1a'. Approved PRs with passing E2E but merge conflicts → drafter for rebase
  # These PRs are ready to merge except they have conflicts with main
  local conflicted_prs
  conflicted_prs=$(echo "$pr_basics" | jq -r '
    .[]
    | . as $pr
    | select(.labels | map(.name) | index("breeze:wip") | not)
    | select(.labels | map(.name) | index("breeze:human") | not)
    | select(.labels | map(.name) | index("breeze:quarantine-hotloop") | not)
    | select(.mergeable == "CONFLICTING" or .mergeStateStatus == "DIRTY")
    | select(
        .reviewDecision == "APPROVED"
        or any(.reviews[]?.body // ""; contains("<!-- bee:approved-for-e2e -->"))
        or any(.comments[]?.body // ""; contains("<!-- bee:approved-for-e2e -->"))
      )
    | select(any(.comments[]?.body // "";
        (contains("**E2E trace (pass)**") and contains($pr.headRefOid[0:7]))))
    | .number
  ' 2>/dev/null || true)
  if [[ -n "$conflicted_prs" ]]; then
    echo "drafter $(echo "$conflicted_prs" | head -1)"
    return
  fi

  # 1b. PRs with E2E trace that needs supervisor classification
  local traced_prs
  traced_prs=$(echo "$pr_basics" | jq -r '
    .[]
    | . as $pr
    | select(.labels | map(.name) | index("breeze:wip") | not)
    | select(.labels | map(.name) | index("breeze:human") | not)
    | select(.labels | map(.name) | index("breeze:quarantine-hotloop") | not)
    | select(any(.comments[]?.body // "";
        (contains("**E2E trace") and contains($pr.headRefOid[0:7]))))
    | select(any(.comments[]?.body // ""; contains("**E2E trace (pass)**")) | not)
    | select(any(.comments[]?.body // ""; contains("**e2e-supervisor:")) | not)
    | .number
  ' 2>/dev/null || true)
  if [[ -n "$traced_prs" ]]; then
    echo "e2e-supervisor $(echo "$traced_prs" | head -1)"
    return
  fi

  # 1b'. PRs with a supervisor verdict — route based on the verdict. The
  # `pass` verdict is covered by the approved+E2E-trace-pass route above,
  # so here we only need to handle the five non-pass outcomes.
  #
  # A verdict is STALE if drafter or e2e has posted a comment after it — that
  # means the bug was already addressed and we need a fresh E2E run to judge
  # the new state, not to re-trigger the same role on every tick (hot-loop).
  local supervised
  supervised=$(echo "$pr_basics" | jq -r '
    .[]
    | . as $pr
    | select($pr.labels | map(.name) | index("breeze:wip") | not)
    | select($pr.labels | map(.name) | index("breeze:human") | not)
    | select($pr.labels | map(.name) | index("breeze:quarantine-hotloop") | not)
    | ([$pr.comments[]? | select(.body // "" | test("\\*\\*e2e-supervisor: (pass|lazy-run|code-bug|test-bug|design-trivial|design-conflicting)\\*\\*"))]
        | sort_by(.createdAt) | last) as $v
    | select($v != null)
    | ([$pr.comments[]? | select(.createdAt > $v.createdAt) | select(.body // "" | test("^\\*\\*(drafter|e2e):"))] | length) as $followups
    | select($followups == 0)
    | ($v.body | capture("\\*\\*e2e-supervisor: (?<verdict>pass|lazy-run|code-bug|test-bug|design-trivial|design-conflicting)\\*\\*").verdict) as $vd
    | "\($pr.number) \($vd)"
  ' 2>/dev/null || true)
  if [[ -n "$supervised" ]]; then
    while IFS= read -r row; do
      [[ -z "$row" ]] && continue
      local pr_n="${row%% *}" vd="${row##* }"
      case "$vd" in
        lazy-run)  echo "e2e $pr_n"; return ;;
        code-bug)  echo "drafter $pr_n"; return ;;
        test-bug)  echo "e2e-designer $pr_n"; return ;;
        design-conflicting)
          # Belt-and-suspenders: supervisor should have applied breeze:human,
          # but ensure it's labeled so this tick never re-dispatches.
          set_breeze_state "$REPO" "$pr_n" human
          log "skip: #$pr_n design-conflicting — labeled breeze:human, held for human"
          ;;
        design-trivial|pass) : ;;  # handled elsewhere / nothing to do
      esac
    done <<< "$supervised"
  fi

  # 1c. Approved PRs without an E2E trace yet → E2E.
  local approved_prs=""
  while IFS= read -r pr; do
    [[ -z "$pr" ]] && continue
    local pr_num=$(echo "$pr" | jq -r '.number')
    local pr_sha=$(echo "$pr" | jq -r '.headRefOid')
    local has_wip=$(echo "$pr" | jq -r '.labels | map(.name) | index("breeze:wip") // false' 2>/dev/null || echo "false")
    local has_human=$(echo "$pr" | jq -r '.labels | map(.name) | index("breeze:human") // false' 2>/dev/null || echo "false")
    local has_quarantine=$(echo "$pr" | jq -r '.labels | map(.name) | index("breeze:quarantine-hotloop") // false' 2>/dev/null || echo "false")
    local has_e2e_trace=$(echo "$pr" | jq -r --arg sha "${pr_sha:0:7}" '
      any(.comments[]?.body // ""; (contains("**E2E trace") and contains($sha)))' 2>/dev/null || echo "false")

    if [[ "$has_wip" == "false" && "$has_human" == "false" && "$has_quarantine" == "false" && "$has_e2e_trace" == "false" ]]; then
      if has_human_approval "$pr" "$pr_sha"; then
        approved_prs="${approved_prs}${pr_num}"$'\n'
      fi
    fi
  done < <(echo "$pr_basics" | jq -c '.[]' 2>/dev/null)
  if [[ -n "$approved_prs" ]]; then
    local pr_number=$(echo "$approved_prs" | head -1)

    # Supervisor consistency check for reviewer verdict invariant (issue #734)
    # Check alignment between activity log marker and GitHub review state
    local activity_log="${LOG_DIR}/activity.ndjson"
    local marker_action=""
    if [[ -f "$activity_log" ]]; then
      # Get last reviewer activity marker for this PR
      marker_action=$(jq -r --arg pr "#${pr_number}" \
        'select(.event == "end" and .agent == "reviewer" and .target == $pr) |
         .outcome // ""' "$activity_log" 2>/dev/null | tail -1)
    fi

    # Get GitHub review state for the last review
    local gh_state=""
    gh_state=$(gh pr view "$pr_number" --repo "$REPO" --json reviews \
      --jq '.reviews | if length > 0 then .[-1].state else "" end' 2>/dev/null || echo "")

    # Log supervisor decision
    local decision=""
    local should_dispatch=1

    # Check acceptable pairings
    if [[ "$marker_action" == "approved" ]] && [[ "$gh_state" == "APPROVED" ]]; then
      decision="advance"
    elif [[ "$marker_action" == "paused" ]]; then
      decision="human"
      should_dispatch=0
      # breeze:human should already be set, but ensure it
      set_breeze_state "$REPO" "$pr_number" human
    else
      # Divergence detected - flag for human review
      decision="divergence"
      should_dispatch=0
      set_breeze_state "$REPO" "$pr_number" human

      # File supervisor issue
      local issue_body
      issue_body=$(printf '%s\n' \
        "**Supervisor: Reviewer verdict divergence detected**" \
        "" \
        "The supervisor detected a mismatch between the reviewer's activity marker and GitHub review state for PR #${pr_number}." \
        "" \
        "- **Activity marker action**: \`${marker_action:-"(none)"}\`" \
        "- **GitHub review state**: \`${gh_state:-"(none)"}\`" \
        "- **Expected**: These should align (approved/APPROVED, requested-changes/CHANGES_REQUESTED, or paused)" \
        "" \
        "This indicates the reviewer agent has diverged sources of truth for its verdict. Applied \`breeze:human\` label to PR #${pr_number} pending investigation." \
        "" \
        "See issue #734 for context on this invariant enforcement.")

      gh issue create --repo "$REPO" \
        --title "Supervisor: Reviewer verdict divergence on PR #${pr_number}" \
        --body "$issue_body" 2>&1 | tee -a "$LOG" || true
    fi

    # Log supervisor decision
    log "supervisor: pr=${pr_number} reviewer_marker=${marker_action:-null} gh_state=${gh_state:-null} decision=${decision}"

    if [[ "$should_dispatch" == "1" ]]; then
      echo "e2e $pr_number"
      return
    fi
  fi

  # 2. PRs needing a reviewer — no review yet at current HEAD SHA.
  # We inspect reviews, not reviewDecision: "COMMENTED" still leaves
  # reviewDecision empty, but means a review exists.
  # Skip dispatch if PR has a bee:approved-for-e2e marker in comments.
  local pr_rows
  pr_rows=$(gh pr list --repo "$REPO" --state open --search "sort:created-asc" --limit 50 \
    --json number,reviewDecision,labels,reviews,headRefOid,comments 2>/dev/null || echo "[]")
  pr_rows=$(echo "$pr_rows" | jq '[ .[] | . as $p | $p + {_prio: (if ($p.labels | map(.name) | index("priority:high")) then 0 else 1 end)} ] | sort_by(._prio) | map(del(._prio))')

  local unreviewed_prs=""
  while IFS= read -r pr; do
    [[ -z "$pr" ]] && continue
    local pr_num=$(echo "$pr" | jq -r '.number')
    local pr_sha=$(echo "$pr" | jq -r '.headRefOid')
    local has_wip=$(echo "$pr" | jq -r '.labels | map(.name) | index("breeze:wip") // false' 2>/dev/null || echo "false")
    local has_human=$(echo "$pr" | jq -r '.labels | map(.name) | index("breeze:human") // false' 2>/dev/null || echo "false")
    local has_quarantine=$(echo "$pr" | jq -r '.labels | map(.name) | index("breeze:quarantine-hotloop") // false' 2>/dev/null || echo "false")
    local reviews_at_head=$(echo "$pr" | jq -r --arg sha "$pr_sha" '[$pr.reviews[]? | select(.commit.oid == $sha)] | length' 2>/dev/null || echo "0")

    if [[ "$has_wip" == "false" && "$has_human" == "false" && "$has_quarantine" == "false" && "$reviews_at_head" == "0" ]]; then
      # Skip if PR already has human approval via escape hatch
      if ! has_human_approval "$pr" "$pr_sha"; then
        unreviewed_prs="${unreviewed_prs}${pr_num}"$'\n'
      fi
    fi
  done < <(echo "$pr_rows" | jq -c '.[]' 2>/dev/null)
  if [[ -n "$unreviewed_prs" ]]; then
    local pr_to_check=$(echo "$unreviewed_prs" | head -1)

    # Check if this PR qualifies for tiny-fix fast path
    if check_tiny_fix "$pr_to_check"; then
      log "tiny-fix detected: PR #$pr_to_check skipping reviewer+e2e, routing to merger"
      echo "merger $pr_to_check"
      return
    fi

    echo "reviewer $pr_to_check"
    return
  fi

  # 2b. PRs with a review at HEAD but not approved + no e2e marker → drafter.
  # Guard against re-dispatching drafter on a PR it just updated:
  # only match if no approval marker is present AND a review at HEAD exists.
  # Also skip if there's a bee:approved-for-e2e marker in comments.
  local feedback_prs=""
  while IFS= read -r pr; do
    [[ -z "$pr" ]] && continue
    local pr_num=$(echo "$pr" | jq -r '.number')
    local pr_sha=$(echo "$pr" | jq -r '.headRefOid')
    local has_wip=$(echo "$pr" | jq -r '.labels | map(.name) | index("breeze:wip") // false' 2>/dev/null || echo "false")
    local has_human=$(echo "$pr" | jq -r '.labels | map(.name) | index("breeze:human") // false' 2>/dev/null || echo "false")
    local has_quarantine=$(echo "$pr" | jq -r '.labels | map(.name) | index("breeze:quarantine-hotloop") // false' 2>/dev/null || echo "false")
    local reviews_at_head=$(echo "$pr" | jq -r --arg sha "$pr_sha" '[.reviews[]? | select(.commit.oid == $sha)] | length' 2>/dev/null || echo "0")

    if [[ "$has_wip" == "false" && "$has_human" == "false" && "$has_quarantine" == "false" && "$reviews_at_head" -gt "0" ]]; then
      # Only dispatch drafter if PR doesn't have human approval
      if ! has_human_approval "$pr" "$pr_sha"; then
        feedback_prs="${feedback_prs}${pr_num}"$'\n'
      fi
    fi
  done < <(echo "$pr_rows" | jq -c '.[]' 2>/dev/null)
  if [[ -n "$feedback_prs" ]]; then
    echo "drafter $(echo "$feedback_prs" | head -1)"
    return
  fi

  # 3. issues with no linked OPEN PR and no breeze:wip
  # We detect linkage by scanning open PR bodies for "Fixes #N" / "Closes #N".
  # Note: --state open already excludes closed issues per first-tree classifier.
  local open_pr_bodies
  open_pr_bodies=$(gh pr list --repo "$REPO" --state open --limit 50 \
    --json body --jq '.[].body' 2>/dev/null || true)

  local all_open_issues
  all_open_issues=$(gh issue list --repo "$REPO" --state open --search "sort:created-asc" --limit 50 \
    --json number,labels \
    --jq '[ .[]
            | select(.labels | map(.name) | index("breeze:wip") | not)
            | select(.labels | map(.name) | index("breeze:human") | not)
            | select(.labels | map(.name) | index("breeze:quarantine-hotloop") | not)
            | . + {_prio: (if (.labels | map(.name) | index("priority:high")) then 0 else 1 end)} ]
          | sort_by(._prio)
          | .[].number' 2>/dev/null || true)

  for n in $all_open_issues; do
    if echo "$open_pr_bodies" | grep -qiE "(fixes|closes|resolves)[[:space:]]+#${n}\b"; then
      continue
    fi
    # Mechanical finalization-gate check (design-doc issues only).
    # Exit 0 = gate open, 1 = closed, 2 = ticked by non-owner, 3 = not a design doc.
    # We silently skip (1) and (2); (3) means the gate doesn't apply and we dispatch.
    if [[ -x "$HERE/gate-check.sh" ]]; then
      set +e
      "$HERE/gate-check.sh" "$REPO" "$n" >/dev/null 2>&1
      gate_rc=$?
      set -e
      if [[ "$gate_rc" == "1" || "$gate_rc" == "2" ]]; then
        log "skip: #$n gate-check rc=$gate_rc (closed or non-owner tick)"
        continue
      fi
      # If gate is open (rc=0), check for Phase 2 routing
      if [[ "$gate_rc" == "0" ]]; then
        local issue_body
        issue_body=$(gh issue view "$n" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")

        # Check for milestone plan
        if ! echo "$issue_body" | grep -q "^## Milestone plan"; then
          echo "planner $n"
          return
        fi

        # Check for E2E test plan
        if ! echo "$issue_body" | grep -q "^## E2E test plan"; then
          echo "e2e-designer $n"
          return
        fi

        # Check if plan confirmation gate is checked
        if echo "$issue_body" | grep -q "^- \[x\] \*\*plan confirmed"; then
          # If every PR number enumerated in the milestone plan is merged, route
          # to the auditor. Otherwise continue with drafter.
          # grep returns 1 when no match; under `set -euo pipefail` that aborts
          # the whole function silently. Wrap so an empty plan list is a valid
          # "no PRs enumerated" signal, not a fatal error.
          local plan_prs
          plan_prs=$({ echo "$issue_body" | awk '/^## Milestone plan/,/^## /' \
            | grep -oE '^### PR [0-9]+' | grep -oE '[0-9]+' | sort -u; } || true)
          if [[ -n "$plan_prs" ]]; then
            local all_merged=1
            local any_pr=0
            while IFS= read -r pr_ref; do
              [[ -z "$pr_ref" ]] && continue
              any_pr=1
              # Look for a merged PR whose body contains "PR <ref>" heading or
              # whose title starts with "PR <ref>". We approximate by checking
              # that SOME merged PR references this milestone slot via its
              # linked issue body — cheap heuristic: scan closed PRs' titles.
              local slot_hit
              slot_hit=$(gh pr list --repo "$REPO" --state merged --search "PR $pr_ref in:title" --json number --jq 'length' 2>/dev/null || echo 0)
              if [[ "$slot_hit" == "0" ]]; then
                all_merged=0
                break
              fi
            done <<< "$plan_prs"
            if [[ "$any_pr" == "1" && "$all_merged" == "1" ]]; then
              echo "auditor $n"
              return
            fi
          fi
          # Plan is confirmed, proceed to drafter
          echo "drafter $n"
          return
        else
          # Has test plan but needs supervisor review
          echo "e2e-supervisor $n"
          return
        fi
      fi
    fi
    # Guard: check if this issue already has an open PR linked to it
    # If it does, skip dispatching drafter and log warning
    local linked_pr
    linked_pr=$(gh pr list --repo "$REPO" --state open --search "$n in:body" --json number --jq '.[0].number' 2>/dev/null || echo "")
    if [[ -n "$linked_pr" ]]; then
      log "ERROR: issue #$n already has open PR #$linked_pr linked to it — dispatcher should have picked PR for revision, not issue"
      continue  # Skip to next issue
    fi
    echo "drafter $n"
    return
  done
}

# Hot loop detector — check if the same agent has been dispatched N times
# with exit_code=0 and outcome=null or refused-by-guard outcomes to the same
# target within a time window.
# Returns 0 if hot loop detected (should skip dispatch), 1 otherwise.
check_hot_loop() {
  local agent="$1" number="$2"
  local threshold=2 window_minutes=5  # Tightened: 2 iterations within 5min
  local activity_log="${LOG_DIR}/activity.ndjson"

  # No activity log means no hot loop
  [[ ! -f "$activity_log" ]] && return 1

  # Time window: now - 5 minutes
  local now_ts=$(date +%s)
  local window_start=$((now_ts - window_minutes * 60))

  # Count consecutive runs with exit_code=0 and outcome=null or refused-by-guard
  # outcomes for this agent+target within the time window.
  # Refused-by-guard outcomes: skipped-stale-e2e, skipped-already-reviewed, etc.
  local count
  count=$(jq -r --arg agent "$agent" \
    --arg target "#${number}" \
    --arg window_start "$window_start" \
    'select(.event == "end" and
            .agent == $agent and
            .target == $target and
            .exit_code == 0 and
            (.outcome == null or
             (.outcome // "" | startswith("skipped-")))) |
     .ts | fromdateiso8601 |
     select(. >= ($window_start | tonumber))' \
    "$activity_log" 2>/dev/null | wc -l | xargs)

  if [[ "$count" -ge "$threshold" ]]; then
    log "hot-loop: pr=$number role=$agent iterations=$count window=${window_minutes}min → applying breeze:quarantine-hotloop"
    return 0
  fi

  return 1
}

# Check if drafter recently closed a PR it was dispatched on.
# Returns 0 if drafter closed this PR within the last hour (should skip dispatch), 1 otherwise.
check_drafter_closed_pr() {
  local number="$1"
  local window_minutes=60

  # Only check for PRs, not issues
  if ! gh pr view "$number" --repo "$REPO" --json number >/dev/null 2>&1; then
    return 1  # Not a PR, allow dispatch
  fi

  # Check if PR is closed
  local pr_state
  pr_state=$(gh pr view "$number" --repo "$REPO" --json state --jq '.state' 2>/dev/null || echo "")
  if [[ "$pr_state" != "CLOSED" ]]; then
    return 1  # PR is not closed, allow dispatch
  fi

  # Check when PR was closed
  local closed_at
  closed_at=$(gh pr view "$number" --repo "$REPO" --json closedAt --jq '.closedAt' 2>/dev/null || echo "")
  if [[ -z "$closed_at" ]]; then
    return 1  # Can't determine close time, allow dispatch
  fi

  # Convert ISO8601 to timestamp using a more portable method
  # Use jq to parse the ISO date as it's more portable than date -j
  local closed_ts
  closed_ts=$(printf '"%s"' "$closed_at" | jq -r 'fromdateiso8601' 2>/dev/null || echo "0")
  local now_ts=$(date +%s)
  local window_start=$((now_ts - window_minutes * 60))

  if [[ "$closed_ts" -lt "$window_start" ]]; then
    return 1  # Closed more than an hour ago, allow dispatch
  fi

  # Check if drafter was dispatched on this PR before it was closed
  local activity_log="${LOG_DIR}/activity.ndjson"
  [[ ! -f "$activity_log" ]] && return 1

  local drafter_dispatched
  drafter_dispatched=$(jq -r --arg target "#${number}" \
    --arg closed_ts "$closed_ts" \
    'select(.event == "start" and
            .agent == "drafter" and
            .target == $target) |
     .ts | fromdateiso8601 |
     select(. < ($closed_ts | tonumber))' \
    "$activity_log" 2>/dev/null | head -1)

  if [[ -n "$drafter_dispatched" ]]; then
    log "DRAFTER CLOSED PR: refusing to re-dispatch drafter on #$number (closed within last hour after drafter dispatch)"
    return 0
  fi

  return 1
}

# Check for next-role hint from the last agent that finished on this target.
# Returns the next role to dispatch, or empty string if no hint or hint is "none".
check_next_hint() {
  local number="$1"
  local activity_log="${LOG_DIR}/activity.ndjson"

  [[ ! -f "$activity_log" ]] && { echo ""; return; }

  # Get the last end event for this target with a non-null next field
  local next_role
  next_role=$(jq -r --arg target "#${number}" '
    select(.event == "end" and .target == $target and .next != null) |
    .next
  ' "$activity_log" 2>/dev/null | tail -1)

  echo "$next_role"
}

# File a hot-loop bug issue with details about the stuck agent/PR
file_hotloop_bug() {
  local agent="$1" number="$2"
  local activity_log="${LOG_DIR}/activity.ndjson"

  # Check if a hot-loop issue already exists for this agent/PR
  local existing_issue
  existing_issue=$(gh issue list --repo "$REPO" --state open \
    --search "hot-loop: $agent stuck on PR #$number in:title" \
    --json number --jq '.[0].number' 2>/dev/null || echo "")

  # Get recent activity log excerpt for this agent/target
  local log_excerpt=""
  if [[ -f "$activity_log" ]]; then
    log_excerpt=$(jq -r --arg agent "$agent" \
      --arg target "#${number}" \
      'select(.event == "end" and
              .agent == $agent and
              .target == $target and
              .exit_code == 0 and
              (.outcome == null or
               (.outcome // "" | startswith("skipped-")))) |
       "\(.ts) agent=\(.agent) target=\(.target) outcome=\(.outcome // "null")"' \
      "$activity_log" 2>/dev/null | tail -5 || echo "No activity log available")
  fi

  if [[ -n "$existing_issue" ]]; then
    # Update existing issue with new occurrence
    local update_comment="**Hot-loop detected again**

Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Recent activity log:
\`\`\`
$log_excerpt
\`\`\`

The quarantine remains in effect."

    gh issue comment "$existing_issue" --repo "$REPO" --body "$update_comment" 2>&1 | tee -a "$LOG" || true
    log "updated existing hot-loop issue #$existing_issue with new occurrence"
  else
    # Create new hot-loop bug issue
    local issue_body="**Hot-loop detected**

The git-bee tick loop detected an infinite dispatch loop.

- **Agent**: $agent
- **Target**: PR #$number
- **Time**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- **Pattern**: 2+ consecutive dispatches with null/refused-by-guard outcome within 5 minutes

**Recent activity log**:
\`\`\`
$log_excerpt
\`\`\`

**Action taken**:
- Applied \`breeze:quarantine-hotloop\` label to PR #$number
- Tick loop will skip quarantined items until fixed

**To investigate**:
1. Check why $agent exits with outcome=null on PR #$number
2. Review the agent's logic for this specific case
3. Fix the underlying issue
4. Remove \`breeze:quarantine-hotloop\` label from PR #$number to resume

The quarantine will auto-release when PR #$number gets new commits (HEAD SHA changes)."

    # Create the issue and apply priority:high + breeze:human
    local new_issue_url
    new_issue_url=$(gh issue create --repo "$REPO" \
      --title "hot-loop: $agent stuck on PR #$number" \
      --body "$issue_body" \
      --label "priority:high" 2>&1 | tee -a "$LOG" | tail -1 || true)

    local new_issue_n
    new_issue_n=$(echo "$new_issue_url" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+' || echo "")
    if [[ -n "$new_issue_n" ]]; then
      set_breeze_state "$REPO" "$new_issue_n" human
      log "filed hot-loop bug issue #$new_issue_n"
    fi
  fi
}

# Check if we should skip the hint to prevent same-role loops.
# Returns 0 if we should skip (same role hinted twice in a row), 1 otherwise.
check_hint_loop() {
  local hint_role="$1" number="$2"
  local activity_log="${LOG_DIR}/activity.ndjson"

  [[ ! -f "$activity_log" ]] && return 1

  # Get the last two end events for this target with non-null next hints
  local last_two_hints
  last_two_hints=$(jq -r --arg target "#${number}" '
    select(.event == "end" and .target == $target and .next != null) |
    "\(.agent):\(.next)"
  ' "$activity_log" 2>/dev/null | tail -2)

  # If we have exactly 2 hints and both point to the same role, skip the hint
  local hint_count=$(echo "$last_two_hints" | wc -l | xargs)
  if [[ "$hint_count" == "2" ]]; then
    local prev_hint=$(echo "$last_two_hints" | head -1 | cut -d: -f2)
    local curr_hint=$(echo "$last_two_hints" | tail -1 | cut -d: -f2)
    if [[ "$prev_hint" == "$hint_role" && "$curr_hint" == "$hint_role" ]]; then
      log "ANTI-LOOP: same role '$hint_role' hinted twice for #$number, falling back to pick_target"
      return 0
    fi
  fi

  return 1
}

# First check for next-role hint before running pick_target
target=""
hint_target=""

# Get all open issues and PRs that might need work
all_targets=$(( \
  gh issue list --repo "$REPO" --state open --limit 50 --json number --jq '.[].number' 2>/dev/null; \
  gh pr list --repo "$REPO" --state open --limit 50 --json number --jq '.[].number' 2>/dev/null \
) | sort -u)

# Check each target for a next-role hint
for t in $all_targets; do
  # Skip if target has breeze:wip, breeze:human, or breeze:quarantine-hotloop
  labels=$(gh issue view "$t" --repo "$REPO" --json labels --jq '.labels | map(.name) | join(",")' 2>/dev/null || echo "")
  if echo "$labels" | grep -qE "breeze:(wip|human|quarantine-hotloop)"; then
    continue
  fi

  hint=$(check_next_hint "$t")
  if [[ -n "$hint" && "$hint" != "none" ]]; then
    # Check anti-loop safety
    if ! check_hint_loop "$hint" "$t"; then
      hint_target="$hint $t"
      log "dispatch: using hint from activity log - $hint on #$t"
      break
    fi
  fi
done

# If we have a hint, use it; otherwise fall back to pick_target
if [[ -n "$hint_target" ]]; then
  target="$hint_target"
  log "dispatch: kind=${hint_target%% *} target=#${hint_target##* } source=hint"
else
  target=$(pick_target)
  if [[ -n "$target" ]]; then
    log "dispatch: kind=${target%% *} target=#${target##* } source=pick_target"
  fi
fi

if [[ -z "$target" ]]; then
  # Pause-don't-stop: distinguish "all open work paused on human" from
  # genuine "nothing to do", so the tick log makes it visible when the
  # loop is blocked on human action rather than finalized.
  paused_count=$(gh issue list --repo "$REPO" --state open --label "breeze:human" --json number --jq 'length' 2>/dev/null || echo 0)
  paused_count=$(( paused_count + $(gh pr list --repo "$REPO" --state open --label "breeze:human" --json number --jq 'length' 2>/dev/null || echo 0) ))
  if (( paused_count > 0 )); then
    log "idle: all open work paused on human (${paused_count} item(s) with breeze:human)"
  else
    log "idle: no unclaimed open items — project finalized or nothing to do"
  fi
  log "tick end (pid=$$ exit=idle)"
  exit 0
fi

kind="${target%% *}"
number="${target##* }"

# E2E skip logic for script/docs-only PRs (issue #749)
if [[ "$kind" == "e2e" ]]; then
  # Get the list of changed files in the PR
  changed_files=$(gh pr view "$number" --repo "$REPO" --json files --jq '.files[].path' 2>/dev/null || echo "")

  if [[ -n "$changed_files" ]]; then
    # Check if ALL changed files match the skip patterns
    should_skip=1

    while IFS= read -r file_path; do
      [[ -z "$file_path" ]] && continue

      # Critical scripts that MUST still run e2e
      if [[ "$file_path" == "scripts/tick.sh" ||
            "$file_path" == "scripts/bee" ||
            "$file_path" == "scripts/notification-scanner.sh" ]]; then
        should_skip=0
        break
      fi

      # Check if file matches allowed skip patterns
      if [[ ! "$file_path" =~ \.(sh|md)$ ]] &&
         [[ ! "$file_path" =~ ^agents/ ]] &&
         [[ ! "$file_path" =~ ^docs/ ]] &&
         [[ ! "$file_path" =~ ^tests/ ]]; then
        # File doesn't match skip patterns, must run e2e
        should_skip=0
        break
      fi
    done <<< "$changed_files"

    if [[ "$should_skip" == "1" ]]; then
      log "e2e: pr=$number result=skipped-scripts-only (only touches *.sh/*.md/agents/docs/tests)"

      # Post comment on PR with synthetic e2e marker
      pr_head_sha=$(gh pr view "$number" --repo "$REPO" --json headRefOid --jq '.headRefOid[0:7]' 2>/dev/null || echo "unknown")
      comment_body="**E2E trace (pass)** for commit $pr_head_sha

Sandbox: skipped-scripts-only (PR only modifies scripts/docs/agents/tests)

This PR only modifies non-runtime files:
$(echo "$changed_files" | sed 's/^/- /')

E2E sandbox run skipped as these changes don't affect runtime behavior. Automatically proceeding to merger."

      gh issue comment "$number" --repo "$REPO" --body "$comment_body" 2>&1 | tee -a "$LOG" || true

      # Update activity log with synthetic e2e outcome
      "$REPO_ROOT/scripts/activity.sh" start "$REPO" "e2e" "$number" "e2e-synthetic" 2>/dev/null || true
      "$REPO_ROOT/scripts/activity.sh" end "$REPO" "e2e" "$number" "e2e-synthetic" 0 0 "skipped-scripts-only" 2>/dev/null || true

      # Switch to merger dispatch
      kind="merger"
      log "switching dispatch: e2e→merger for scripts-only PR #$number"
    fi
  fi
fi

# Check if quarantine should be auto-released (new commits pushed)
check_quarantine_release() {
  local number="$1"

  # Check if target has quarantine label
  local has_quarantine
  has_quarantine=$(gh issue view "$number" --repo "$REPO" --json labels \
    --jq '.labels | map(.name) | index("breeze:quarantine-hotloop") // false' 2>/dev/null || echo "false")

  if [[ "$has_quarantine" == "false" ]]; then
    return  # No quarantine to release
  fi

  # Get the HEAD SHA when quarantine was applied from activity log
  local activity_log="${LOG_DIR}/activity.ndjson"
  if [[ ! -f "$activity_log" ]]; then
    return  # Can't determine quarantine SHA
  fi

  # Find the last hot-loop event for this target (when quarantine was applied)
  # We look for a tick log entry about hot-loop detection
  local quarantine_time
  quarantine_time=$(grep "hot loop detected.*#$number" "$LOG" 2>/dev/null | tail -1 | awk '{print $1"T"$2}' || echo "")

  if [[ -z "$quarantine_time" ]]; then
    return  # Can't find when quarantine was applied
  fi

  # Check if PR exists and get current HEAD SHA
  local current_sha=""
  if gh pr view "$number" --repo "$REPO" --json headRefOid >/dev/null 2>&1; then
    current_sha=$(gh pr view "$number" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")
  fi

  if [[ -z "$current_sha" ]]; then
    return  # Can't get current SHA
  fi

  # Get the SHA at time of quarantine by checking git log
  # This is approximate - we check what HEAD was around that time
  local quarantine_ts
  quarantine_ts=$(printf '"%s"' "$quarantine_time" | jq -r 'sub("Z$"; "+00:00") | fromdateiso8601' 2>/dev/null || echo "0")

  # Check if any commits were pushed after quarantine time
  local pr_branch
  pr_branch=$(gh pr view "$number" --repo "$REPO" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")

  if [[ -n "$pr_branch" ]]; then
    # Fetch the branch to ensure we have latest commits
    git fetch origin "$pr_branch" --quiet 2>/dev/null || true

    # Check if there are commits after quarantine time
    local newer_commits
    newer_commits=$(git log "origin/$pr_branch" --since="@{$quarantine_ts}" --format="%H" 2>/dev/null | head -1 || echo "")

    if [[ -n "$newer_commits" ]]; then
      log "auto-releasing quarantine on #$number (new commits detected)"

      # Remove quarantine label
      gh issue edit "$number" --repo "$REPO" --remove-label "breeze:quarantine-hotloop" 2>&1 | tee -a "$LOG" || true

      # Post comment about auto-release
      local release_comment="**tick:**

Quarantine auto-released: New commits detected on PR #$number since quarantine was applied.

The \`breeze:quarantine-hotloop\` label has been removed and normal dispatch can resume."

      gh issue comment "$number" --repo "$REPO" --body "$release_comment" 2>&1 | tee -a "$LOG" || true
    fi
  fi
}

# Check for quarantine auto-release before dispatch
if [[ -n "$target" ]]; then
  check_quarantine_release "$number"
fi

# Check for hot loop before dispatching
if check_hot_loop "$kind" "$number"; then
  # Apply breeze:quarantine-hotloop label to break the loop
  gh issue edit "$number" --repo "$REPO" --add-label "breeze:quarantine-hotloop" 2>&1 | tee -a "$LOG" || true

  # File a hot-loop bug issue
  file_hotloop_bug "$kind" "$number"

  # Post explanatory comment on the issue/PR
  comment_body="**tick:**

Hot loop detected: $kind agent dispatched 2+ times to this target with null or refused-by-guard outcome within 5 minutes.

Applied \`breeze:quarantine-hotloop\` label to quarantine this item. The tick loop will skip quarantined items until fixed.

A bug issue has been filed to investigate why the agent is repeatedly unable to make progress. The quarantine will auto-release when new commits are pushed to this PR.

Check \`~/.git-bee/activity.ndjson\` for dispatch history."

  gh issue comment "$number" --repo "$REPO" --body "$comment_body" 2>&1 | tee -a "$LOG" || true

  log "skip: hot loop detected for $kind on #$number — labeled breeze:quarantine-hotloop"
  log "tick end (pid=$$ exit=hot-loop-detected)"
  exit 0
fi

# Check if drafter closed this PR recently (issue #719 prevention)
if [[ "$kind" == "drafter" ]] && check_drafter_closed_pr "$number"; then
  # Apply breeze:human label to prevent re-dispatch
  set_breeze_state "$REPO" "$number" human

  # Post explanatory comment on the PR
  comment_body="**tick:**

Refusing to re-dispatch drafter on PR #$number that was closed within the last hour after a drafter dispatch.

The drafter is forbidden from closing PRs it was dispatched to work on (see #719). Applied \`breeze:human\` label to prevent automatic re-dispatch. Human intervention required to determine why the PR was closed and whether it should be reopened or a new approach is needed."

  gh issue comment "$number" --repo "$REPO" --body "$comment_body" 2>&1 | tee -a "$LOG" || true

  log "skip: drafter closed PR #$number recently — labeled breeze:human"
  log "tick end (pid=$$ exit=drafter-closed-pr)"
  exit 0
fi

# Dispatch source was already logged when target was selected
DISPATCH_START_TS=$SECONDS

# Acquire claim BEFORE spawning, so concurrent ticks don't dispatch twice
agent_id="${kind}-$(hostname -s)"
if ! claim_acquire "$REPO" "$number" "$agent_id"; then
  log "lost race to acquire claim on #$number, exiting"
  log "tick end (pid=$$ exit=claim-race-lost)"
  exit 0
fi

# Write the PID lock BEFORE spawning so an unexpected failure can't orphan
# the GitHub claim without also showing on the local filesystem. The release
# trap takes both down together.
echo $$ > "$LOCK"
release_all() {
  # Keep the label to prevent churn if the item is still open (common case)
  # Only explicit "done" paths should remove the label
  claim_release "$REPO" "$number" "$agent_id" "true" 2>/dev/null || true
  rm -f "$LOCK"
}
# EXIT fires for normal and non-zero exits. Trap SIGINT/TERM/HUP explicitly so
# a Ctrl-C or launchd stop doesn't orphan `breeze:wip` + the PID lock; SIGKILL
# can't be trapped (stale claims then clear on the next tick via
# claim_check's TTL path).
trap release_all EXIT INT TERM HUP

role_prompt_file="$REPO_ROOT/agents/${kind}.md"
if [[ ! -f "$role_prompt_file" ]]; then
  log "ERROR: no role prompt at $role_prompt_file"
  log "tick end (pid=$$ exit=no-role-prompt)"
  exit 1
fi

# Clean up old failure files periodically (issue #751)
cleanup_old_failures

# Check for last failure and set env var if exists (issue #751)
FAILURE_FILE="${FAILURE_DIR}/${kind}-${number}.md"
if [[ -f "$FAILURE_FILE" ]]; then
  # Check if file is less than 24 hours old
  if [[ $(find "$FAILURE_FILE" -mtime -1 2>/dev/null | wc -l) -gt 0 ]]; then
    export GIT_BEE_LAST_FAILURE="$FAILURE_FILE"
    log "found recent failure file, passing as GIT_BEE_LAST_FAILURE=$FAILURE_FILE"
  else
    rm -f "$FAILURE_FILE"
    log "removed stale failure file (>24h old): $FAILURE_FILE"
  fi
fi

# Runtime: claude -p in bypass mode. Set CLAUDE_BIN env to override.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

prompt=$(cat <<PROMPT_EOF
You are acting in the role defined by @${role_prompt_file}.

Your target is ${REPO}#${number}.
Your agent id for this run is ${agent_id}.

Read the role prompt, read the target issue/PR, and do the work described there.
When you finish (or give up), exit cleanly. The tick wrapper will release the
claim automatically on exit.

CRITICAL — never push to main. All code lands via PRs on feature branches.
If you run any 'git push' in a Bash tool call, source the guard first:
  source ${REPO_ROOT}/scripts/preflight-push.sh && git push ...
The guard hard-refuses pushes whose target ref is 'main' or 'master'.
Using 'Closes #<pr>' in a commit body that lands directly on main will
auto-close the PR without merging it. This happened on PR #551 — see #555.
PROMPT_EOF
)

# macOS notifier — no-op on non-Darwin or if osascript is missing. Never
# fails the tick (|| true at call sites).
notify() {
  command -v osascript >/dev/null 2>&1 || return 0
  local title="$1" body="$2"
  osascript -e "display notification \"${body//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1 || true
}

log "spawning ${CLAUDE_BIN} for role=${kind} target=#${number}"
"$REPO_ROOT/scripts/activity.sh" start "$REPO" "$kind" "$number" "$agent_id" 2>/dev/null || true

# Check for tmux UI mode
if [[ "${GIT_BEE_UI:-}" == "tmux" ]] && command -v tmux >/dev/null 2>&1 && tmux has-session -t git-bee 2>/dev/null; then
  # Dispatch to tmux window in existing git-bee session
  log "dispatching ${kind} to tmux window '${kind}-#${number}'"

  # Write prompt to temp file to avoid shell escaping issues
  local prompt_file="/tmp/git-bee-prompt-${kind}-${number}.txt"
  echo "$prompt" > "$prompt_file"

  # Create new window and run claude with the prompt file
  # Note: self-triggering happens at the end of the tmux command via tick.sh call
  tmux new-window -t git-bee: -n "${kind}-#${number}" \
    "cd '$REPO_ROOT' && '$CLAUDE_BIN' -p \"\$(cat '$prompt_file')\" --permission-mode bypassPermissions 2>&1 | tee -a '$LOG'; exit_code=\$?; rm -f '$prompt_file'; echo ''; echo \"Agent exited with code \$exit_code\"; '$REPO_ROOT/scripts/activity.sh' end '$REPO' '$kind' '$number' '$agent_id' \$exit_code \$(( SECONDS - $DISPATCH_START_TS )) 2>/dev/null || true; sleep 2; echo 'Self-triggering next tick (issue #724)'; '$HERE/tick.sh' 2>&1 | tail -5; sleep 3; exit \$exit_code"

  # Run janitor to clean up old windows
  if [[ -x "$HERE/tmux-janitor.sh" ]]; then
    "$HERE/tmux-janitor.sh" 2>/dev/null || true
  fi

  # Wait briefly to confirm dispatch succeeded
  sleep 1
  log "dispatched ${kind} in tmux window '${kind}-#${number}'"
  # Don't self-trigger here since tmux window will handle it
else
  # Original headless mode
  "$CLAUDE_BIN" -p "$prompt" --permission-mode bypassPermissions 2>&1 | tee -a "$LOG" || {
    exit_code=$?
    log "agent exited non-zero (${exit_code}) for #${number}"

    # Capture failure information (issue #751)
    capture_failure_info "$kind" "$number" "$exit_code" "failed-nonzero"

    "$REPO_ROOT/scripts/activity.sh" end "$REPO" "$kind" "$number" "$agent_id" "$exit_code" "$(( SECONDS - DISPATCH_START_TS ))" 2>/dev/null || true
    notify "🐝 ${kind} failed" "#${number} exited ${exit_code} after $(( (SECONDS - DISPATCH_START_TS) / 60 ))m$(( (SECONDS - DISPATCH_START_TS) % 60 ))s"

    # Self-trigger the next tick even on failure (issue #724)
    log "self-triggering next tick after agent failure"
    log "tick end (pid=$$ exit=dispatched-${kind})"
    release_all  # Must release before exec (exec prevents EXIT trap from running)
    exec "$HERE/tick.sh"
  }
fi

log "agent exited cleanly for #${number}"
"$REPO_ROOT/scripts/activity.sh" end "$REPO" "$kind" "$number" "$agent_id" 0 "$(( SECONDS - DISPATCH_START_TS ))" 2>/dev/null || true

# Check if outcome is null or failed-* even though exit code is 0 (issue #751)
check_and_capture_outcome_failure "$kind" "$number"

notify "🐝 ${kind} done" "#${number} finished in $(( (SECONDS - DISPATCH_START_TS) / 60 ))m$(( (SECONDS - DISPATCH_START_TS) % 60 ))s"

# Self-trigger the next tick (issue #724: reduce latency between agent-done and next-agent-start)
# The PID lock ensures at-most-one concurrent agent, making this safe.
# We exec to replace this process, avoiding a recursive call stack.
log "self-triggering next tick after agent completion"
log "tick end (pid=$$ exit=dispatched-${kind})"
release_all  # Must release before exec (exec prevents EXIT trap from running)
exec "$HERE/tick.sh"
