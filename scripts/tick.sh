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

# file_or_update_issue: idempotent issue filer. If an open issue with the exact
# <title> already exists, append a comment instead of creating a duplicate.
# Emits the resolved issue number on stdout (empty if both create and lookup failed).
#
# Prevents cascade patterns like #786 -> #788 -> #792 where the same divergence
# bug got filed once per attempt at fixing it. Originally added in #799, lost
# in a subsequent merge/rebase, caused tonight's exit-127 rollback cascade.
file_or_update_issue() {
  local repo="$1" title="$2" body="$3" extra_args="${4:-}" agent_role="${5:-tick}"
  local existing
  existing=$(gh issue list --repo "$repo" --state open --search "in:title \"$title\"" --json number,title --jq ".[] | select(.title == \"$title\") | .number" 2>/dev/null | head -1 || echo "")
  if [[ -n "$existing" ]]; then
    log "file_or_update_issue: #$existing already open with title '''$title''' — appending comment"
    gh issue comment "$existing" --repo "$repo" --body "$body" >/dev/null 2>&1 || true
    # Check for generic meta-loop on update
    check_generic_meta_loop "$repo" "$agent_role" "$title" "$existing" || true
    echo "$existing"
    return 0
  fi
  local url num
  # shellcheck disable=SC2086
  url=$(gh issue create --repo "$repo" --title "$title" --body "$body" $extra_args 2>&1 | tee -a "$LOG" | tail -1 || true)
  num=$(echo "$url" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+' || echo "")
  # Check for generic meta-loop on creation
  if [[ -n "$num" ]]; then
    check_generic_meta_loop "$repo" "$agent_role" "$title" "$num" || true
  fi
  echo "$num"
}


REPO="serenakeyitan/git-bee"
LOCK="/tmp/git-bee-agent.pid"
LOG_DIR="${HOME}/.git-bee"
LOG="${LOG_DIR}/tick.log"
TICK_HISTORY="${LOG_DIR}/tick-history.log"
ROLLBACK_MARKER="${LOG_DIR}/ROLLBACK"
mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }

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

# Guard -1 (moved up): ROLLBACK marker — if it exists, exit early without dispatching
# This must run BEFORE the crash detector to prevent rollback loops
if [[ -f "$ROLLBACK_MARKER" ]]; then
  log "ROLLBACK marker exists — ticks paused. Remove $ROLLBACK_MARKER to resume."
  log "tick end (pid=$$ exit=rollback-marker)"
  exit 0
fi

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

      # Use file_or_update_issue to prevent duplicates.
      # We don't set priority:high — per AGENTS.md no auto-priority labels.
      new_issue_n=""
      new_issue_n=$(file_or_update_issue "$REPO" "Automatic rollback: 3 consecutive tick crashes detected" "$issue_body" "" "tick")
      if [[ -n "$new_issue_n" ]]; then
        set_breeze_state "$REPO" "$new_issue_n" human
        log "filed or updated rollback issue #$new_issue_n"
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

      # Use file_or_update_issue to prevent duplicates.
      new_issue_n=""
      new_issue_n=$(file_or_update_issue "$REPO" "Tick crashing with no rollback target available" "$issue_body" "" "tick")
      if [[ -n "$new_issue_n" ]]; then
        set_breeze_state "$REPO" "$new_issue_n" human
        log "filed or updated no-rollback-target issue #$new_issue_n"
      fi
    fi
  fi
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

# Janitor: Clean up stale breeze labels on closed/merged items
# This fixes the issue where merged PRs retain pre-merge breeze:* labels
janitor_label_cleanup() {
  # Only run if enabled
  if [[ "${GIT_BEE_JANITOR:-1}" != "1" ]]; then
    return
  fi

  log "running janitor label cleanup"

  # Source labels.sh for set_breeze_state function
  # shellcheck disable=SC1091
  source "$HERE/labels.sh"

  # Clean up closed issues with stale breeze labels
  local stale_issues
  stale_issues=$(gh issue list --repo "$REPO" --state closed --json number,labels \
    --jq '[.[] | select(.labels | map(.name) | any(test("breeze:(human|wip|new)")))] | .[].number' 2>/dev/null || echo "")

  if [[ -n "$stale_issues" ]]; then
    for n in $stale_issues; do
      log "janitor: transitioning closed issue #$n to breeze:done"
      set_breeze_state "$REPO" "$n" done
    done
  fi

  # Clean up merged/closed PRs with stale breeze labels
  local stale_prs
  stale_prs=$(gh pr list --repo "$REPO" --state merged --json number,labels \
    --jq '[.[] | select(.labels | map(.name) | any(test("breeze:(human|wip|new)")))] | .[].number' 2>/dev/null || echo "")

  # Also check closed (not just merged) PRs
  local closed_prs
  closed_prs=$(gh pr list --repo "$REPO" --state closed --json number,labels,merged \
    --jq '[.[] | select((.merged == false) and (.labels | map(.name) | any(test("breeze:(human|wip|new)"))))] | .[].number' 2>/dev/null || echo "")

  stale_prs="${stale_prs}${stale_prs:+ }${closed_prs}"

  if [[ -n "$stale_prs" ]]; then
    for n in $stale_prs; do
      log "janitor: transitioning closed/merged PR #$n to breeze:done"
      set_breeze_state "$REPO" "$n" done
    done
  fi
}

# Run janitor cleanup before finding work
janitor_label_cleanup

# Guard 2: find work
# Priority order (PRs beat issues — if an issue already has a linked PR,
# the PR is the next actionable step):
#   1. approved PRs → test-agent
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

  # Check for reviewer verdict in review bodies at/after HEAD timestamp.
  # In single-account mode the reviewer agent cannot formally --approve its own
  # PR; it posts a COMMENTED review whose body starts with
  # **reviewer verdict: approved** (per agents/reviewer.md). Treat that body
  # marker as authoritative approval — same way we treat the human's HTML
  # marker. See #798 / role simplification and #827 for context.
  local has_reviewer_verdict_approved
  has_reviewer_verdict_approved=$(echo "$pr_json" | jq --arg head_ts "$head_timestamp" '
    any(.reviews[]?;
      (.body // "" | test("\\*\\*reviewer verdict: approved\\*\\*")) and
      ((.submittedAt // "" | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= ($head_ts | tonumber))
    )
  ' 2>/dev/null || echo "false")
  if [[ "$has_reviewer_verdict_approved" == "true" ]]; then
    return 0
  fi

  return 1
}

# Returns 0 if PR has a human revision-request marker in a comment at/after
# HEAD SHA timestamp. This is the revision-direction counterpart to the
# bee:approved-for-e2e escape hatch: in single-account mode (#754) humans
# cannot post formal `--request-changes` reviews on their own PRs, so the
# dispatcher needs a way to recognize "please fix this" intent in comments.
# See #780.
has_human_revision_request() {
  local pr_json="$1"
  local pr_head_sha="$2"

  local head_timestamp
  head_timestamp=$(git -C "$REPO_ROOT" show -s --format=%ct "$pr_head_sha" 2>/dev/null || echo "0")

  local has_marker_in_comments
  has_marker_in_comments=$(echo "$pr_json" | jq --arg head_ts "$head_timestamp" '
    any(.comments[]?;
      (.body // "" | contains("<!-- bee:changes-requested -->")) and
      ((.createdAt // "" | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= ($head_ts | tonumber))
    )
  ' 2>/dev/null || echo "false")

  if [[ "$has_marker_in_comments" == "true" ]]; then
    return 0
  fi

  return 1
}

# pr_pipeline_position: pure classifier for PR routing.
#
# Given a PR's JSON blob (as emitted by gh pr list --json) plus the pre-resolved
# has_human_approval/has_human_revision_request results, returns exactly ONE
# pipeline-position string on stdout:
#
#   quarantined            — breeze:quarantine-hotloop label set, skip
#   wip                    — breeze:wip label set, another agent owns it
#   human                  — breeze:human label set, awaiting human
#   conflicted             — mergeable == CONFLICTING (drafter rebases)
#   ready-to-merge         — approved + E2E pass at HEAD (merger)
#   approved-e2e-stale     — approved + no E2E pass at HEAD (test-agent)
#   approved-e2e-failed    — approved + E2E trace at HEAD with no pass (test-agent)
#   needs-drafter-feedback — human posted bee:changes-requested marker at/after HEAD (drafter)
#   needs-drafter-review   — reviewer requested changes at HEAD (drafter)
#   needs-review           — unreviewed at HEAD AND no approval marker (reviewer)
#   skip                   — nothing actionable (fall through to issues)
#
# Replaces the old 8-branch pick_target which had overlapping conditions and
# routing blind spots (see #809). The rule here is: compute position from
# pure state, then route via a single table — no branch ordering can be
# wrong because there's only one position per PR.
pr_pipeline_position() {
  local pr_json="$1"

  local pr_sha has_wip has_human has_quarantine mergeable_state
  pr_sha=$(echo "$pr_json" | jq -r '.headRefOid')
  has_wip=$(echo "$pr_json" | jq -r '.labels | map(.name) | index("breeze:wip") // false' 2>/dev/null || echo "false")
  has_human=$(echo "$pr_json" | jq -r '.labels | map(.name) | index("breeze:human") // false' 2>/dev/null || echo "false")
  has_quarantine=$(echo "$pr_json" | jq -r '.labels | map(.name) | index("breeze:quarantine-hotloop") // false' 2>/dev/null || echo "false")
  mergeable_state=$(echo "$pr_json" | jq -r '.mergeable // "UNKNOWN"')

  # Label-based early exits, in precedence order.
  if [[ "$has_quarantine" != "false" ]]; then echo "quarantined"; return; fi
  if [[ "$has_wip" != "false" ]]; then echo "wip"; return; fi
  if [[ "$has_human" != "false" ]]; then echo "human"; return; fi

  # Merge conflict → drafter for rebase, regardless of approval/e2e state (#763).
  if [[ "$mergeable_state" == "CONFLICTING" ]]; then echo "conflicted"; return; fi

  # Signals we need to compute:
  local sha7 e2e_pass_at_head e2e_any_at_head e2e_fail_at_head
  sha7="${pr_sha:0:7}"
  e2e_pass_at_head=$(echo "$pr_json" | jq -r --arg sha "$sha7"     'any(.comments[]?.body // ""; (contains("**E2E trace (pass)**") and contains($sha)))' 2>/dev/null || echo "false")
  e2e_any_at_head=$(echo "$pr_json" | jq -r --arg sha "$sha7"     'any(.comments[]?.body // ""; (contains("**E2E trace") and contains($sha)))' 2>/dev/null || echo "false")
  e2e_fail_at_head="false"
  if [[ "$e2e_any_at_head" == "true" && "$e2e_pass_at_head" != "true" ]]; then
    e2e_fail_at_head="true"
  fi

  # Revision request marker from human — takes priority over all other signals
  # below (human explicitly asked for changes, regardless of prior approval).
  if has_human_revision_request "$pr_json" "$pr_sha"; then
    echo "needs-drafter-feedback"
    return
  fi

  # Approval in any form: formal APPROVED review OR bee:approved-for-e2e marker.
  # has_human_approval handles both, including single-account COMMENTED reviews
  # with the marker (#754).
  local approved="false"
  if [[ "$(echo "$pr_json" | jq -r '.reviewDecision // ""')" == "APPROVED" ]]; then
    approved="true"
  elif has_human_approval "$pr_json" "$pr_sha"; then
    approved="true"
  fi

  if [[ "$approved" == "true" ]]; then
    if [[ "$e2e_pass_at_head" == "true" ]]; then
      echo "ready-to-merge"
    elif [[ "$e2e_fail_at_head" == "true" ]]; then
      echo "approved-e2e-failed"
    else
      # Approved but no E2E at HEAD (either none at all, or only at older SHA).
      # This is the #809 bug: old code routed here to reviewer because it
      # counted formal reviews only. Correct action: refresh E2E at HEAD.
      echo "approved-e2e-stale"
    fi
    return
  fi

  # Not approved. Figure out whether reviewer has already looked at HEAD.
  # In single-account mode, reviewer can't use --request-changes formally,
  # so it posts the verdict in a COMMENTED review body. Recognize both.
  # Mirror of the approval-body recognition added in #828.
  local changes_requested_at_head reviews_at_head changes_requested_in_body
  changes_requested_at_head=$(echo "$pr_json" | jq -r --arg sha "$pr_sha"     '[.reviews[]? | select(.commit.oid == $sha and .state == "CHANGES_REQUESTED")] | length > 0' 2>/dev/null || echo "false")
  reviews_at_head=$(echo "$pr_json" | jq -r --arg sha "$pr_sha"     '[.reviews[]? | select(.commit.oid == $sha)] | length' 2>/dev/null || echo "0")
  changes_requested_in_body=$(echo "$pr_json" | jq -r --arg sha "$pr_sha"     '[.reviews[]? | select(.commit.oid == $sha) | select(.body | test("\\*\\*reviewer verdict: changes-requested\\*\\*"))] | length > 0' 2>/dev/null || echo "false")

  if [[ "$changes_requested_at_head" == "true" || "$changes_requested_in_body" == "true" ]]; then
    echo "needs-drafter-review"
    return
  fi

  # Reviewed-but-not-approved-not-changes-requested at HEAD. In single-account
  # mode this is the common case: all reviews are COMMENTED (can't self-approve).
  # If reviewer has already looked at HEAD, do NOT re-dispatch reviewer — the
  # ball is in the human's court to post an approval marker or changes-requested
  # marker. Skip.
  if (( reviews_at_head > 0 )); then
    echo "skip"
    return
  fi

  # No review at HEAD at all → reviewer.
  echo "needs-review"
}

pick_target() {
  # Emits "<kind> <number>" to stdout, nothing if idle.
  # Note: --state open excludes MERGED/CLOSED PRs per first-tree classifier precedence.

  local pr_basics
  pr_basics=$(gh pr list --repo "$REPO" --state open --search "sort:created-asc" --limit 50     --json number,reviewDecision,labels,reviews,comments,headRefOid,mergeable,mergeStateStatus 2>/dev/null || echo "[]")
  # Priority sort: priority:high first, then original (created-asc) order.
  pr_basics=$(echo "$pr_basics" | jq '[ .[] | . as $p | $p + {_prio: (if ($p.labels | map(.name) | index("priority:high")) then 0 else 1 end)} ] | sort_by(._prio) | map(del(._prio))')

  # Iterate through PRs in priority order, compute each one's pipeline position,
  # dispatch the first actionable match. Route table:
  #
  #   ready-to-merge         → merger
  #   approved-e2e-stale     → test-agent
  #   approved-e2e-failed    → test-agent
  #   conflicted             → drafter
  #   needs-drafter-feedback → drafter
  #   needs-drafter-review   → drafter
  #   needs-review           → needs review from human (single-account) — skip
  #                            unless there is already a reviewer verdict at HEAD
  #   (all other positions)  → skip
  #
  # Exactly one position per PR; no blind spots because the case default is
  # "skip" (which falls through to issues and eventually to the debt watchdog).
  local pr
  while IFS= read -r pr; do
    [[ -z "$pr" ]] && continue
    local pr_num position
    pr_num=$(echo "$pr" | jq -r '.number')
    position=$(pr_pipeline_position "$pr")
    case "$position" in
      ready-to-merge)
        echo "merger $pr_num"
        return
        ;;
      approved-e2e-stale)
        echo "test-agent $pr_num"
        return
        ;;
      approved-e2e-failed)
        echo "test-agent $pr_num"
        return
        ;;
      conflicted|needs-drafter-feedback|needs-drafter-review)
        echo "drafter $pr_num"
        return
        ;;
      needs-review)
        # Dispatch reviewer. In single-account mode the reviewer posts a
        # comment-style verdict (per #815 updated agents/reviewer.md);
        # the dispatcher recognizes action=approved as authoritative and
        # routes to e2e on the next tick. Reviewer does NOT pause on
        # self-authored — that was the root cause of the overnight
        # "everything ends up breeze:human" failure mode.
        echo "reviewer $pr_num"
        return
        ;;
      quarantined|wip|human|skip)
        continue
        ;;
      *)
        log "pick_target: unknown pipeline position '$position' for PR #$pr_num — skipping"
        continue
        ;;
    esac
  done < <(echo "$pr_basics" | jq -c '.[]' 2>/dev/null)

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
        local issue_body issue_title
        issue_body=$(gh issue view "$n" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")
        issue_title=$(gh issue view "$n" --repo "$REPO" --json title --jq '.title' 2>/dev/null || echo "")

        # Skip Phase 2 routing for bug-report-shaped issues. Planner/test-agent
        # don't have useful work on these — they're not design docs needing
        # plans. Without this skip, dispatcher dispatches planner repeatedly
        # on issues like 'hot-loop: ...' or 'Watchdog: ...' which the planner
        # agent recognizes and self-exits, but wastes a tick + API call each
        # time. Pattern observed today after #864 cleanup: closed bug issues
        # kept getting re-dispatched until I noticed.
        if echo "$issue_title" | grep -qiE "^(hot-loop:|watchdog:|bug:|regression:|fix:|error:)"; then
          continue
        fi

        # Check for milestone plan
        if ! echo "$issue_body" | grep -q "^## Milestone plan"; then
          echo "planner $n"
          return
        fi

        # Check for E2E test plan in body OR in a test-agent comment.
        # test-agent posts its plan as a **test-agent:** prefixed comment by
        # default (it doesn't edit the issue body). Treat both as "plan exists."
        # Old code only checked the body, so test-agent was dispatched on every
        # tick forever even after writing the plan — quarantined #798/#820/#832
        # three nights running.
        local has_test_plan=false
        if echo "$issue_body" | grep -q "^## E2E test plan"; then
          has_test_plan=true
        elif gh issue view "$n" --repo "$REPO" --json comments \
              --jq '[.comments[] | select(.body | startswith("**test-agent:**"))] | length > 0' \
              2>/dev/null | grep -q true; then
          has_test_plan=true
        fi
        if [[ "$has_test_plan" != "true" ]]; then
          echo "test-agent $n"
          return
        fi

        # Plan exists. Drafter takes it from here. Plan-confirmation
        # checkbox is human-only; do NOT re-dispatch test-agent to "review"
        # the plan — that was the second half of the loop bug from #832.
        echo "drafter $n"
        return
      fi
    fi
    # Guard: check if this issue already has an open PR linked to it.
    # If yes, SKIP this issue — the PR block above already dispatched on
    # the PR via pr_pipeline_position if it was actionable. Don't force
    # drafter on the linked PR regardless of its state (that's what
    # caused #812 to route to drafter instead of reviewer).
    local linked_pr_json linked_pr=""
    linked_pr_json=$("$HERE/check-duplicate-pr.sh" "$REPO" "$n" 2>/dev/null || echo "")
    if [[ -n "$linked_pr_json" ]]; then
      linked_pr=$(echo "$linked_pr_json" | jq -r '.number // empty')
    fi
    if [[ -z "$linked_pr" ]]; then
      linked_pr=$(gh pr list --repo "$REPO" --state open --search "$n in:body" --json number --jq '.[0].number' 2>/dev/null || echo "")
    fi
    if [[ -n "$linked_pr" ]]; then
      log "issue #$n has open PR #$linked_pr — skipping (PR block handles its own state)"
      continue
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

# Generic meta-loop detector (M1/PR3, refs #798).
# Detects when the SAME issue title is created/updated 2+ times within 1 hour by
# the SAME agent role, indicating a cascading failure that won't self-heal.
# Args: $1=repo, $2=agent_role, $3=issue_title, $4=new_issue_number (if just created)
#       $5=cutoff_iso (optional, for testing; if provided, overrides window calculation)
# When detected:
# - Applies breeze:human to the issue
# - If issue title mentions "PR #N", applies breeze:quarantine-hotloop to that PR
# - Posts explanatory comment on the issue
# Returns 0 if meta-loop detected, 1 otherwise.
check_generic_meta_loop() {
  local repo="$1" agent_role="$2" issue_title="$3" issue_number="$4"
  local cutoff_override="${5:-}"
  local threshold=2 window_minutes=60

  # Fetch ALL open issues with this exact title
  local existing_issues
  existing_issues=$(gh issue list --repo "$repo" --state open \
    --search "in:title \"$issue_title\"" --json number,title \
    | jq -r ".[] | select(.title == \"$issue_title\") | .number" 2>/dev/null || echo "")

  [[ -z "$existing_issues" ]] && return 1

  # For each issue, count non-human comments within the window
  local cutoff_iso
  if [[ -n "$cutoff_override" ]]; then
    cutoff_iso="$cutoff_override"
  else
    cutoff_iso=$(date -u -v-${window_minutes}M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "${window_minutes} minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || echo "")
  fi
  [[ -z "$cutoff_iso" ]] && return 1

  local total_count=0
  for iss in $existing_issues; do
    local count
    count=$(gh issue view "$iss" --repo "$repo" --json comments,body,createdAt 2>/dev/null \
      | jq --arg cutoff "$cutoff_iso" --arg role "$agent_role" \
          '(if (.createdAt > $cutoff and (.body | startswith("**\($role):**"))) then 1 else 0 end) +
           ([.comments[] | select(.createdAt > $cutoff and (.body | startswith("**\($role):**")))] | length)' \
      2>/dev/null || echo "0")
    total_count=$((total_count + count))
  done

  if [[ "$total_count" -ge "$threshold" ]]; then
    log "check_generic_meta_loop: detected meta-loop for role=$agent_role title='$issue_title' (count=$total_count in ${window_minutes}min)"

    # Apply breeze:human to the issue
    set_breeze_state "$repo" "$issue_number" human

    # Extract PR number from title if present (e.g., "hot-loop: agent stuck on PR #123")
    local pr_number
    pr_number=$(echo "$issue_title" | grep -oE 'PR #[0-9]+' | grep -oE '[0-9]+' || echo "")

    if [[ -n "$pr_number" ]]; then
      # Apply breeze:quarantine-hotloop to the PR
      gh pr edit "$pr_number" --repo "$repo" --add-label "breeze:quarantine-hotloop" 2>&1 | tee -a "$LOG" || true
      log "check_generic_meta_loop: applied breeze:quarantine-hotloop to PR #$pr_number"
    fi

    # Post explanatory comment
    local quarantine_msg="**tick:**

Meta-loop detected: this issue title has been created/updated $total_count times within the last $window_minutes minutes by \`$agent_role\`. Automatic retry is not resolving the underlying cause.

Applied \`breeze:human\` to this issue"

    if [[ -n "$pr_number" ]]; then
      quarantine_msg="$quarantine_msg and \`breeze:quarantine-hotloop\` to PR #$pr_number"
    fi

    quarantine_msg="$quarantine_msg. Both are paused pending human investigation — the loop will stop cascading."

    gh issue comment "$issue_number" --repo "$repo" --body "$quarantine_msg" 2>&1 | tee -a "$LOG" || true

    return 0
  fi

  return 1
}

# Meta-loop detector (M1/PR3, refs #798).
# Counts "Hot-loop detected again" update comments posted on an existing
# hot-loop issue within the last hour. When ≥2 re-fires happen in that window,
# both the agent and the underlying PR are stuck in a cascade: the dedup path
# alone isn't enough (it prevents duplicate issues, but the same bug pattern
# keeps firing). Escalates by labeling the re-fired issue breeze:human so a
# human looks at it instead of the loop continuing to comment on it.
# Returns 0 if meta-loop detected, 1 otherwise.
check_meta_loop() {
  local issue_number="$1"
  local threshold=2 window_minutes=60

  # Fetch comments with timestamps; filter to our "again" updates within window.
  local cutoff_iso
  cutoff_iso=$(date -u -v-${window_minutes}M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "${window_minutes} minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo "")
  [[ -z "$cutoff_iso" ]] && return 1

  local count
  count=$(gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null \
    | jq --arg cutoff "$cutoff_iso" \
        '[.comments[] | select(.body | startswith("**Hot-loop detected again**")) | select(.createdAt > $cutoff)] | length' \
    2>/dev/null || echo "0")

  [[ "$count" -ge "$threshold" ]]
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

    # Meta-loop escalation: if the same (agent, PR) hot-loop has re-fired 2+
    # times within the last hour, the underlying issue isn't self-healing —
    # escalate to human. The PR already carries breeze:quarantine-hotloop from
    # the caller, so we only need to flag the re-fired issue here.
    if check_meta_loop "$existing_issue"; then
      log "meta-loop: agent=$agent pr=#$number issue=#$existing_issue re-fired 2+ times in 60min → breeze:human"
      set_breeze_state "$REPO" "$existing_issue" human
      gh issue comment "$existing_issue" --repo "$REPO" --body "**tick:**

Meta-loop detected: this hot-loop issue has been re-filed 2+ times within the last hour for the same (agent=\`$agent\`, target=PR #$number) pair. Automatic quarantine + dedup is not resolving the underlying cause.

Applied \`breeze:human\` to this issue and \`breeze:quarantine-hotloop\` remains on PR #$number. Both are paused pending human investigation — the loop will stop cascading." 2>&1 | tee -a "$LOG" || true
    fi
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

    # Use file_or_update_issue to prevent duplicates.
    # Apply priority:high + breeze:human to the issue.
    local new_issue_n
    new_issue_n=$(file_or_update_issue "$REPO" "hot-loop: $agent stuck on PR #$number" "$issue_body" "--label priority:high" "tick")
    if [[ -n "$new_issue_n" ]]; then
      set_breeze_state "$REPO" "$new_issue_n" human
      log "filed or updated hot-loop bug issue #$new_issue_n"
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
    if check_hint_loop "$hint" "$t"; then
      continue
    fi
    # Validate hint against current pipeline position for PRs (#855).
    # Stale hints from before the PR's state advanced cause re-quarantine loops.
    is_pr=$(gh pr view "$t" --repo "$REPO" --json number --jq '.number' 2>/dev/null || echo "")
    if [[ -n "$is_pr" ]]; then
      pr_json=$(gh pr view "$t" --repo "$REPO" --json number,reviewDecision,labels,reviews,comments,headRefOid,mergeable,mergeStateStatus 2>/dev/null || echo "{}")
      position=$(pr_pipeline_position "$pr_json")
      expected_role=""
      case "$position" in
        ready-to-merge)        expected_role="merger" ;;
        approved-e2e-stale)    expected_role="test-agent" ;;
        approved-e2e-failed)   expected_role="test-agent" ;;
        conflicted|needs-drafter-feedback|needs-drafter-review) expected_role="drafter" ;;
        needs-review)          expected_role="reviewer" ;;
      esac
      if [[ -n "$expected_role" && "$hint" != "$expected_role" ]]; then
        log "dispatch: hint stale ($hint vs expected $expected_role for position $position on #$t) — discarding"
        continue
      fi
    fi
    hint_target="$hint $t"
    log "dispatch: using hint from activity log - $hint on #$t"
    break
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
  # Total open items across all labels (for debt detection)
  open_issues=$(gh issue list --repo "$REPO" --state open --json number --jq 'length' 2>/dev/null || echo 0)
  open_prs=$(gh pr list --repo "$REPO" --state open --json number --jq 'length' 2>/dev/null || echo 0)
  total_open=$(( open_issues + open_prs ))

  if (( paused_count > 0 )); then
    log "idle: all open work paused on human (${paused_count} item(s) with breeze:human)"
  elif (( total_open > 0 )); then
    # DEBT state: idle with open items that aren't paused on human. The
    # dispatcher couldn't route them for some reason. Track consecutive
    # ticks in this state and alert after 3.
    DEBT_STREAK_FILE="${LOG_DIR}/debt-streak"
    streak=$(cat "$DEBT_STREAK_FILE" 2>/dev/null || echo 0)
    streak=$(( streak + 1 ))
    echo "$streak" > "$DEBT_STREAK_FILE"
    log "idle-with-debt: ${total_open} open item(s), dispatcher returned nothing (streak=${streak})"
    if (( streak >= 3 )); then
      # Gather context for the alert issue
      debt_body=$(printf '%s\n' \
        "**Watchdog: idle-with-debt detected**" \
        "" \
        "Tick loop returned \`pick_target\` empty for ${streak} consecutive ticks, but ${total_open} open item(s) exist (${open_issues} issue(s) + ${open_prs} PR(s)) and none are labeled \`breeze:human\`." \
        "" \
        "This means the dispatcher's taxonomy has a blind spot: there is open work that does not match any routing branch. Common causes:" \
        "" \
        "- Open PR with no review and no formal-review state (reviewer branch doesn't match)" \
        "- Open issue linked to an open PR but dispatcher lost the link" \
        "- All items are quarantined (\`breeze:quarantine-hotloop\`) with no auto-release signal" \
        "- Escape-hatch marker present but at a timestamp before HEAD" \
        "" \
        "**Investigation:**" \
        "" \
        "\`\`\`" \
        "$(gh issue list --repo "$REPO" --state open --json number,title,labels --jq '.[] | "  #\(.number) [\(.labels | map(.name) | join(","))] \(.title)"' 2>/dev/null | head -10)" \
        "$(gh pr list --repo "$REPO" --state open --json number,title,labels --jq '.[] | "  #\(.number) [\(.labels | map(.name) | join(","))] \(.title)"' 2>/dev/null | head -10)" \
        "\`\`\`" \
        "" \
        "Auto-filed by \`scripts/tick.sh\` debt watchdog. Once a fix lands, the streak file resets on the next successful dispatch.")
      file_or_update_issue "$REPO" "Watchdog: idle-with-debt (dispatcher blind spot)" "$debt_body" "--label priority:high" "tick" >/dev/null
      # Reset streak after filing so we don't spam the issue every tick
      echo "0" > "$DEBT_STREAK_FILE"
    fi
  else
    # Truly finalized: zero open items anywhere.
    # One-time "project finalized" comment on the newest roadmap umbrella.
    FINALIZED_MARKER="${LOG_DIR}/FINALIZED"
    if [[ ! -f "$FINALIZED_MARKER" ]]; then
      # Try to find the most recent roadmap umbrella (title starts with "v" or contains "roadmap")
      umbrella=$(gh issue list --repo "$REPO" --state closed --limit 20 --search "roadmap in:title" --json number,title --jq '.[0].number' 2>/dev/null || echo "")
      if [[ -n "$umbrella" ]]; then
        gh issue comment "$umbrella" --repo "$REPO" --body "**bot: project finalized**

All open issues and PRs on the repo are closed. Tick loop will remain idle until new work is filed. Auto-filed by \`scripts/tick.sh\` on $(date -u +%Y-%m-%dT%H:%M:%SZ)." >/dev/null 2>&1 || true
        log "project-finalized: posted completion note on umbrella #$umbrella"
      else
        log "project-finalized: no roadmap umbrella found to annotate"
      fi
      touch "$FINALIZED_MARKER"
    fi
    log "idle: no unclaimed open items — project finalized or nothing to do"
  fi
  log "tick end (pid=$$ exit=idle)"
  exit 0
fi

# Reaching here means dispatch happened — reset debt streak (if any)
rm -f "${LOG_DIR}/debt-streak" 2>/dev/null || true
# And clear the FINALIZED marker since we are no longer finalized
rm -f "${LOG_DIR}/FINALIZED" 2>/dev/null || true

kind="${target%% *}"
number="${target##* }"

# E2E skip logic for script/docs-only PRs (issue #749)
if [[ "$kind" == "test-agent" ]]; then
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
      log "test-agent: pr=$number result=skipped-scripts-only (only touches *.sh/*.md/agents/docs/tests)"

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
      log "switching dispatch: test-agent→merger for scripts-only PR #$number"
    fi
  fi
fi

# Get quarantine timestamp from GitHub timeline or fallback to tick.log
get_quarantine_timestamp() {
  local number="$1"

  # Try to get from GitHub timeline events (most accurate)
  local timeline_ts
  timeline_ts=$(gh api "repos/$REPO/issues/$number/timeline" --jq '
    [.[] | select(.event == "labeled" and .label.name == "breeze:quarantine-hotloop")]
    | sort_by(.created_at)
    | last
    | .created_at // ""
  ' 2>/dev/null || echo "")

  if [[ -n "$timeline_ts" ]]; then
    # Convert ISO to unix timestamp
    printf '"%s"' "$timeline_ts" | jq -r 'sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null || echo "0"
    return
  fi

  # Fallback: grep tick.log for hot-loop detection
  local quarantine_time
  quarantine_time=$(grep "hot.*loop.*#$number" "$LOG" 2>/dev/null | tail -1 | awk '{print $1}' || echo "")

  if [[ -n "$quarantine_time" ]]; then
    printf '"%s"' "$quarantine_time" | jq -r 'sub("Z$"; "+00:00") | fromdateiso8601' 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# Check if quarantine should be auto-released (new commits pushed for PRs, human comment or milestone PR for issues)
check_quarantine_release() {
  local number="$1"

  # Check if target has quarantine label
  local has_quarantine
  has_quarantine=$(gh issue view "$number" --repo "$REPO" --json labels \
    --jq '.labels | map(.name) | index("breeze:quarantine-hotloop") // false' 2>/dev/null || echo "false")

  if [[ "$has_quarantine" == "false" ]]; then
    return  # No quarantine to release
  fi

  # Check release count cap (max 3 auto-releases per issue)
  local release_dir="${LOG_DIR}/quarantine-releases"
  mkdir -p "$release_dir"
  local release_file="${release_dir}/issue-${number}"
  local release_count=0
  if [[ -f "$release_file" ]]; then
    release_count=$(cat "$release_file" 2>/dev/null || echo "0")
  fi

  if [[ "$release_count" -ge 3 ]]; then
    log "quarantine on #$number: release count=$release_count (capped at 3) — quarantine sticks"
    return  # Max releases reached, quarantine sticks
  fi

  # Get quarantine timestamp
  local quarantine_ts
  quarantine_ts=$(get_quarantine_timestamp "$number")

  if [[ "$quarantine_ts" == "0" ]]; then
    log "quarantine on #$number: cannot determine quarantine timestamp — skipping auto-release"
    return
  fi

  # Check if this is a PR or issue
  local is_pr=false
  if gh pr view "$number" --repo "$REPO" --json number >/dev/null 2>&1; then
    is_pr=true
  fi

  if [[ "$is_pr" == "true" ]]; then
    # PR auto-release: new commits after quarantine OR fix PR merged
    local current_sha pr_branch
    current_sha=$(gh pr view "$number" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")

    if [[ -z "$current_sha" ]]; then
      return  # Can't get current SHA
    fi

    local should_release=false
    local release_reason=""

    pr_branch=$(gh pr view "$number" --repo "$REPO" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")

    # Check 1: New commits after quarantine
    if [[ -n "$pr_branch" ]]; then
      # Fetch the branch to ensure we have latest commits
      git fetch origin "$pr_branch" --quiet 2>/dev/null || true

      # Check if there are commits after quarantine time
      local quarantine_iso
      quarantine_iso=$(date -u -r "$quarantine_ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "@$quarantine_ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || echo "")
      local newer_commits=""
      if [[ -n "$quarantine_iso" ]]; then
        newer_commits=$(git log "origin/$pr_branch" --since="$quarantine_iso" --format="%H" 2>/dev/null | head -1 || echo "")
      fi

      if [[ -n "$newer_commits" ]]; then
        should_release=true
        release_reason="new commits detected on PR #$number since quarantine"
      fi
    fi

    # Check 2: Fix PR merged on main (M2/PR 4 logic)
    if [[ "$should_release" == "false" ]]; then
      # Find any hot-loop bug issues filed about this PR
      # Title pattern: "hot-loop: {agent} stuck on PR #N"
      local bug_issues
      bug_issues=$(gh issue list --repo "$REPO" --state all \
        --search "hot-loop stuck on PR #$number in:title" \
        --json number --jq '.[].number' 2>/dev/null || echo "")

      # Check if any merged PRs fix those bug issues
      for bug_issue in $bug_issues; do
        [[ -z "$bug_issue" ]] && continue

        # Find PRs that fix this bug issue (via "Fixes #bug-issue")
        local fix_prs
        fix_prs=$(gh pr list --repo "$REPO" --state merged \
          --search "$bug_issue in:body" \
          --json number,mergedAt,body 2>/dev/null | \
          jq -r --arg bug "$bug_issue" '.[] |
            select(.body | test("(Fixes|Closes|Resolves) #" + $bug + "\\b")) |
            "\(.number)|\(.mergedAt)"' || echo "")

        # Check if any fix PR merged after quarantine time
        while IFS='|' read -r fix_pr fix_merged_at; do
          [[ -z "$fix_pr" ]] && continue
          [[ -z "$fix_merged_at" ]] && continue

          local fix_merged_ts
          fix_merged_ts=$(printf '"%s"' "$fix_merged_at" | jq -r 'sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null || echo "0")

          if [[ "$fix_merged_ts" -gt "$quarantine_ts" ]]; then
            should_release=true
            release_reason="fix PR #$fix_pr for bug issue #$bug_issue merged on main after quarantine"
            break 2  # Break out of both loops
          fi
        done <<< "$fix_prs"
      done
    fi

    if [[ "$should_release" == "true" ]]; then
      # Increment release count
      release_count=$((release_count + 1))
      echo "$release_count" > "$release_file"

      log "auto-releasing quarantine on PR #$number ($release_reason, release $release_count/3)"

      # Remove quarantine label
      gh issue edit "$number" --repo "$REPO" --remove-label "breeze:quarantine-hotloop" 2>&1 | tee -a "$LOG" || true

      # Post comment about auto-release
      local release_comment="**tick:**

Quarantine auto-released: $release_reason.

Auto-release $release_count/3. The \`breeze:quarantine-hotloop\` label has been removed and normal dispatch can resume."

      gh issue comment "$number" --repo "$REPO" --body "$release_comment" 2>&1 | tee -a "$LOG" || true
    fi
  else
    # Issue auto-release: human comment OR milestone PR merge after quarantine
    local should_release=false
    local release_reason=""

    # Check for human comment after quarantine timestamp
    local issue_json
    issue_json=$(gh issue view "$number" --repo "$REPO" --json comments,body 2>/dev/null || echo "{}")

    local human_comment_after_quarantine
    human_comment_after_quarantine=$(echo "$issue_json" | jq --arg ts "$quarantine_ts" '
      [.comments[]? |
       select(.body | startswith("**human:**")) |
       select((.createdAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) > ($ts | tonumber))]
      | length > 0
    ' 2>/dev/null || echo "false")

    if [[ "$human_comment_after_quarantine" == "true" ]]; then
      should_release=true
      release_reason="human comment posted after quarantine"
    fi

    # Check for milestone PR merge after quarantine timestamp
    if [[ "$should_release" == "false" ]]; then
      local issue_body
      issue_body=$(echo "$issue_json" | jq -r '.body // ""')

      # Extract milestone PRs from body using awk to find ## Milestone plan section
      local milestone_prs
      milestone_prs=$(echo "$issue_body" | awk '
        /^## Milestone plan/ { in_milestone=1; next }
        /^## / && in_milestone { exit }
        in_milestone && /PR #[0-9]+/ {
          while (match($0, /PR #[0-9]+/)) {
            print substr($0, RSTART+4, RLENGTH-4)
            $0 = substr($0, RSTART+RLENGTH)
          }
        }
      ' | sort -u)

      # Check if any milestone PR merged after quarantine
      for pr_num in $milestone_prs; do
        [[ -z "$pr_num" ]] && continue

        local pr_merged_at pr_merged_ts
        pr_merged_at=$(gh pr view "$pr_num" --repo "$REPO" --json mergedAt --jq '.mergedAt // ""' 2>/dev/null || echo "")

        if [[ -n "$pr_merged_at" ]]; then
          pr_merged_ts=$(printf '"%s"' "$pr_merged_at" | jq -r 'sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null || echo "0")

          if [[ "$pr_merged_ts" -gt "$quarantine_ts" ]]; then
            should_release=true
            release_reason="milestone PR #$pr_num merged after quarantine"
            break
          fi
        fi
      done
    fi

    if [[ "$should_release" == "true" ]]; then
      # Increment release count
      release_count=$((release_count + 1))
      echo "$release_count" > "$release_file"

      log "auto-releasing quarantine on issue #$number ($release_reason, release $release_count/3)"

      # Remove quarantine label
      gh issue edit "$number" --repo "$REPO" --remove-label "breeze:quarantine-hotloop" 2>&1 | tee -a "$LOG" || true

      # Post comment about auto-release
      local release_comment="**tick:**

Quarantine auto-released: $release_reason.

Auto-release $release_count/3. The \`breeze:quarantine-hotloop\` label has been removed and normal dispatch can resume."

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
  prompt_file="/tmp/git-bee-prompt-${kind}-${number}.txt"
  echo "$prompt" > "$prompt_file"

  # Create new window and run claude with the prompt file
  # Note: self-triggering happens at the end of the tmux command via tick.sh call
  if [[ "$kind" == "test-agent" ]]; then
    # Use wrapper for test-agent to capture metrics
    tmux new-window -t git-bee: -n "${kind}-#${number}" \
      "cd '$REPO_ROOT' && output_file=\"/tmp/git-bee-agent-output-\$\$\"; '$HERE/test-agent-wrapper.sh' '$number' '$prompt_file' 2>&1 | tee \"\$output_file\" | tee -a '$LOG'; exit_code=\$?; status_line=\$(grep -E \"^${kind}:\" \"\$output_file\" 2>/dev/null | tail -1 || echo \"\"); agent_outcome=\$(echo \"\$status_line\" | grep -oE '(action|result|verdict)=[^ ]+' | cut -d= -f2 | head -1 || echo \"\"); agent_next=\$(echo \"\$status_line\" | grep -oE 'next=[^ ]+' | cut -d= -f2 | head -1 || echo \"\"); rm -f \"\$output_file\" '$prompt_file'; echo ''; echo \"Agent exited with code \$exit_code\"; '$REPO_ROOT/scripts/activity.sh' end '$REPO' '$kind' '$number' '$agent_id' \$exit_code \$(( SECONDS - $DISPATCH_START_TS )) \"\$agent_outcome\" \"\$agent_next\" 2>/dev/null || true; sleep 2; echo 'Self-triggering next tick (issue #724)'; '$HERE/tick.sh' 2>&1 | tail -5; sleep 3; exit \$exit_code"
  else
    tmux new-window -t git-bee: -n "${kind}-#${number}" \
      "cd '$REPO_ROOT' && output_file=\"/tmp/git-bee-agent-output-\$\$\"; '$CLAUDE_BIN' -p \"\$(cat '$prompt_file')\" --permission-mode bypassPermissions 2>&1 | tee \"\$output_file\" | tee -a '$LOG'; exit_code=\$?; status_line=\$(grep -E \"^${kind}:\" \"\$output_file\" 2>/dev/null | tail -1 || echo \"\"); agent_outcome=\$(echo \"\$status_line\" | grep -oE '(action|result|verdict)=[^ ]+' | cut -d= -f2 | head -1 || echo \"\"); agent_next=\$(echo \"\$status_line\" | grep -oE 'next=[^ ]+' | cut -d= -f2 | head -1 || echo \"\"); rm -f \"\$output_file\" '$prompt_file'; echo ''; echo \"Agent exited with code \$exit_code\"; '$REPO_ROOT/scripts/activity.sh' end '$REPO' '$kind' '$number' '$agent_id' \$exit_code \$(( SECONDS - $DISPATCH_START_TS )) \"\$agent_outcome\" \"\$agent_next\" 2>/dev/null || true; sleep 2; echo 'Self-triggering next tick (issue #724)'; '$HERE/tick.sh' 2>&1 | tail -5; sleep 3; exit \$exit_code"
  fi

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
  if [[ "$kind" == "test-agent" ]]; then
    # Write prompt to temp file for wrapper
    prompt_file="/tmp/git-bee-prompt-${kind}-${number}.txt"
    echo "$prompt" > "$prompt_file"

    # Use wrapper for test-agent to capture metrics
    output_file="/tmp/git-bee-agent-output-$$"
    "$HERE/test-agent-wrapper.sh" "$number" "$prompt_file" 2>&1 | tee "$output_file" | tee -a "$LOG" || {
      exit_code=$?

      # Parse agent's stdout for outcome and next hint
      agent_outcome="" agent_next=""
      if [[ -f "$output_file" ]]; then
        status_line=$(grep -E "^${kind}:" "$output_file" | tail -1 || echo "")
        if [[ -n "$status_line" ]]; then
          # Parse outcome field (could be action=, result=, or verdict=)
          agent_outcome=$(echo "$status_line" | grep -oE '(action|result|verdict)=[^ ]+' | cut -d= -f2 | head -1 || echo "")
          # Parse next field
          agent_next=$(echo "$status_line" | grep -oE 'next=[^ ]+' | cut -d= -f2 | head -1 || echo "")
        fi
        rm -f "$output_file"
      fi

      rm -f "$prompt_file"
      log "agent exited non-zero (${exit_code}) for #${number}"

      # Capture failure information (issue #751)
      capture_failure_info "$kind" "$number" "$exit_code" "${agent_outcome:-failed-nonzero}"

      "$REPO_ROOT/scripts/activity.sh" end "$REPO" "$kind" "$number" "$agent_id" "$exit_code" "$(( SECONDS - DISPATCH_START_TS ))" "${agent_outcome:-}" "${agent_next:-}" 2>/dev/null || true
      notify "🐝 ${kind} failed" "#${number} exited ${exit_code} after $(( (SECONDS - DISPATCH_START_TS) / 60 ))m$(( (SECONDS - DISPATCH_START_TS) % 60 ))s"

      # Self-trigger the next tick even on failure (issue #724)
      log "self-triggering next tick after agent failure"
      "$HERE/tick.sh" 2>&1 | tail -5 &

      rm -f "$LOCK"
      exit "$exit_code"
    }
    # Parse agent's stdout for successful test run
    agent_outcome="" agent_next=""
    if [[ -f "$output_file" ]]; then
      status_line=$(grep -E "^${kind}:" "$output_file" | tail -1 || echo "")
      if [[ -n "$status_line" ]]; then
        # Parse outcome field (could be action=, result=, or verdict=)
        agent_outcome=$(echo "$status_line" | grep -oE '(action|result|verdict)=[^ ]+' | cut -d= -f2 | head -1 || echo "")
        # Parse next field
        agent_next=$(echo "$status_line" | grep -oE 'next=[^ ]+' | cut -d= -f2 | head -1 || echo "")
      fi
    fi
    rm -f "$prompt_file" "$output_file"
  else
    # Capture agent output to parse the status line
    output_file="/tmp/git-bee-agent-output-$$"
    "$CLAUDE_BIN" -p "$prompt" --permission-mode bypassPermissions 2>&1 | tee "$output_file" | tee -a "$LOG" || {
      exit_code=$?
      log "agent exited non-zero (${exit_code}) for #${number}"

      # Parse agent's stdout for outcome and next hint
      agent_outcome="" agent_next=""
      if [[ -f "$output_file" ]]; then
        status_line=$(grep -E "^${kind}:" "$output_file" | tail -1 || echo "")
        if [[ -n "$status_line" ]]; then
          # Parse outcome field (could be action=, result=, or verdict=)
          agent_outcome=$(echo "$status_line" | grep -oE '(action|result|verdict)=[^ ]+' | cut -d= -f2 | head -1 || echo "")
          # Parse next field
          agent_next=$(echo "$status_line" | grep -oE 'next=[^ ]+' | cut -d= -f2 | head -1 || echo "")
        fi
        rm -f "$output_file"
      fi

      # Capture failure information (issue #751)
      capture_failure_info "$kind" "$number" "$exit_code" "${agent_outcome:-failed-nonzero}"

      "$REPO_ROOT/scripts/activity.sh" end "$REPO" "$kind" "$number" "$agent_id" "$exit_code" "$(( SECONDS - DISPATCH_START_TS ))" "${agent_outcome:-}" "${agent_next:-}" 2>/dev/null || true
      notify "🐝 ${kind} failed" "#${number} exited ${exit_code} after $(( (SECONDS - DISPATCH_START_TS) / 60 ))m$(( (SECONDS - DISPATCH_START_TS) % 60 ))s"

      # Self-trigger the next tick even on failure (issue #724)
      log "self-triggering next tick after agent failure"
      log "tick end (pid=$$ exit=dispatched-${kind})"
      release_all  # Must release before exec (exec prevents EXIT trap from running)
      exec "$HERE/tick.sh"
    }
    rm -f "$output_file"
  fi
fi

# Parse agent's stdout for outcome and next hint
agent_outcome="" agent_next=""
if [[ "${GIT_BEE_UI:-}" != "tmux" ]] || ! command -v tmux >/dev/null 2>&1 || ! tmux has-session -t git-bee 2>/dev/null; then
  # For non-tmux mode, parse from the log file
  status_line=$(tail -100 "$LOG" | grep -E "^[0-9T:Z-]+ ${kind}:" | tail -1 | cut -d' ' -f2- || echo "")
  if [[ -n "$status_line" ]]; then
    # Parse outcome field (could be action=, result=, or verdict=)
    agent_outcome=$(echo "$status_line" | grep -oE '(action|result|verdict)=[^ ]+' | cut -d= -f2 | head -1 || echo "")
    # Parse next field
    agent_next=$(echo "$status_line" | grep -oE 'next=[^ ]+' | cut -d= -f2 | head -1 || echo "")
  fi
fi

log "agent exited cleanly for #${number}"
"$REPO_ROOT/scripts/activity.sh" end "$REPO" "$kind" "$number" "$agent_id" 0 "$(( SECONDS - DISPATCH_START_TS ))" "${agent_outcome:-}" "${agent_next:-}" 2>/dev/null || true

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
