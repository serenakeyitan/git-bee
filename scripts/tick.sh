#!/usr/bin/env bash
# git-bee tick: one pass of the scheduler.
#
# Guards (in order):
#   1. Local PID lock — if an agent is already running on this machine, exit.
#   2. GitHub state — find the oldest open issue/PR without a fresh breeze:wip.
#   3. If no unclaimed open items exist, project is finalized. Exit quietly.
#
# Invoked by launchd every 15 minutes.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/claim.sh"

REPO="serenakeyitan/git-bee"
LOCK="/tmp/git-bee-agent.pid"
LOG_DIR="${HOME}/.git-bee"
LOG="${LOG_DIR}/tick.log"
mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# Guard 1: local PID lock
if [[ -f "$LOCK" ]]; then
  pid=$(cat "$LOCK" 2>/dev/null || echo "")
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    log "skip: agent already running (pid=$pid)"
    exit 0
  fi
  log "stale lock (pid=$pid), removing"
  rm -f "$LOCK"
fi

# Guard 2: find work
# Priority order (PRs beat issues — if an issue already has a linked PR,
# the PR is the next actionable step):
#   1. approved PRs → e2e agent
#   2. unreviewed open PRs → reviewer agent
#   3. issues with NO linked open PR and no breeze:wip → drafter agent
pick_target() {
  # Emits "<kind> <number>" to stdout, nothing if idle.

  local pr_basics
  pr_basics=$(gh pr list --repo "$REPO" --state open --search "sort:created-asc" --limit 50 \
    --json number,reviewDecision,labels,reviews,comments 2>/dev/null || echo "[]")

  # 1. Approved PRs that also have a passing E2E trace → merger.
  # "Approved" = reviewDecision == APPROVED OR a review body contains the marker.
  # "E2E pass" = any PR issue-comment contains "**E2E trace (pass)**".
  local mergeable_prs
  mergeable_prs=$(echo "$pr_basics" | jq -r '
    .[]
    | select(.labels | map(.name) | index("breeze:wip") | not)
    | select(.labels | map(.name) | index("breeze:human") | not)
    | select(
        .reviewDecision == "APPROVED"
        or any(.reviews[]?.body // ""; contains("<!-- bee:approved-for-e2e -->"))
      )
    | select(any(.comments[]?.body // ""; contains("**E2E trace (pass)**")))
    | .number
  ' 2>/dev/null || true)
  if [[ -n "$mergeable_prs" ]]; then
    echo "merger $(echo "$mergeable_prs" | head -1)"
    return
  fi

  # 1b. Approved PRs without an E2E trace yet → E2E.
  local approved_prs
  approved_prs=$(echo "$pr_basics" | jq -r '
    .[]
    | select(.labels | map(.name) | index("breeze:wip") | not)
    | select(.labels | map(.name) | index("breeze:human") | not)
    | select(
        .reviewDecision == "APPROVED"
        or any(.reviews[]?.body // ""; contains("<!-- bee:approved-for-e2e -->"))
      )
    | select(any(.comments[]?.body // ""; contains("**E2E trace")) | not)
    | .number
  ' 2>/dev/null || true)
  if [[ -n "$approved_prs" ]]; then
    echo "e2e $(echo "$approved_prs" | head -1)"
    return
  fi

  # 2. PRs needing a reviewer — no review yet at current HEAD SHA.
  # We inspect reviews, not reviewDecision: "COMMENTED" still leaves
  # reviewDecision empty, but means a review exists.
  local pr_rows
  pr_rows=$(gh pr list --repo "$REPO" --state open --search "sort:created-asc" --limit 50 \
    --json number,reviewDecision,labels,reviews,headRefOid 2>/dev/null || echo "[]")

  local unreviewed_prs
  unreviewed_prs=$(echo "$pr_rows" | jq -r '
    .[]
    | . as $pr
    | select($pr.labels | map(.name) | index("breeze:wip") | not)
    | select($pr.labels | map(.name) | index("breeze:human") | not)
    | select([$pr.reviews[]? | select(.commit.oid == $pr.headRefOid)] | length == 0)
    | $pr.number
  ' 2>/dev/null || true)
  if [[ -n "$unreviewed_prs" ]]; then
    echo "reviewer $(echo "$unreviewed_prs" | head -1)"
    return
  fi

  # 2b. PRs with a review at HEAD but not approved + no e2e marker → drafter.
  # Guard against re-dispatching drafter on a PR it just updated:
  # only match if no approval marker is present AND a review at HEAD exists.
  local feedback_prs
  feedback_prs=$(echo "$pr_rows" | jq -r '
    .[]
    | . as $pr
    | select($pr.labels | map(.name) | index("breeze:wip") | not)
    | select($pr.labels | map(.name) | index("breeze:human") | not)
    | select($pr.reviewDecision != "APPROVED")
    | select(any($pr.reviews[]?.body // ""; contains("<!-- bee:approved-for-e2e -->")) | not)
    | select([$pr.reviews[]? | select(.commit.oid == $pr.headRefOid)] | length > 0)
    | $pr.number
  ' 2>/dev/null || true)
  if [[ -n "$feedback_prs" ]]; then
    echo "drafter $(echo "$feedback_prs" | head -1)"
    return
  fi

  # 3. issues with no linked OPEN PR and no breeze:wip
  # We detect linkage by scanning open PR bodies for "Fixes #N" / "Closes #N".
  local open_pr_bodies
  open_pr_bodies=$(gh pr list --repo "$REPO" --state open --limit 50 \
    --json body --jq '.[].body' 2>/dev/null || true)

  local all_open_issues
  all_open_issues=$(gh issue list --repo "$REPO" --state open --search "sort:created-asc" --limit 50 \
    --json number,labels \
    --jq '.[] | select(.labels | map(.name) | index("breeze:wip") | not) | select(.labels | map(.name) | index("breeze:human") | not) | .number' 2>/dev/null || true)

  for n in $all_open_issues; do
    if echo "$open_pr_bodies" | grep -qiE "(fixes|closes|resolves)[[:space:]]+#${n}\b"; then
      continue
    fi
    echo "drafter $n"
    return
  done
}

target=$(pick_target)

if [[ -z "$target" ]]; then
  log "idle: no unclaimed open items — project finalized or nothing to do"
  exit 0
fi

kind="${target%% *}"
number="${target##* }"
log "dispatch: kind=$kind target=#$number"

# Acquire claim BEFORE spawning, so concurrent ticks don't dispatch twice
agent_id="${kind}-$(hostname -s)"
if ! claim_acquire "$REPO" "$number" "$agent_id"; then
  log "lost race to acquire claim on #$number, exiting"
  exit 0
fi

# Write the PID lock BEFORE spawning so an unexpected failure can't orphan
# the GitHub claim without also showing on the local filesystem. The release
# trap takes both down together.
echo $$ > "$LOCK"
release_all() {
  claim_release "$REPO" "$number" "$agent_id" 2>/dev/null || true
  rm -f "$LOCK"
}
trap release_all EXIT

role_prompt_file="$REPO_ROOT/agents/${kind}.md"
if [[ ! -f "$role_prompt_file" ]]; then
  log "ERROR: no role prompt at $role_prompt_file"
  exit 1
fi

# Runtime: claude -p in bypass mode. Set CLAUDE_BIN env to override.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

prompt=$(cat <<EOF
You are acting in the role defined by @${role_prompt_file}.

Your target is ${REPO}#${number}.
Your agent id for this run is ${agent_id}.

Read the role prompt, read the target issue/PR, and do the work described there.
When you finish (or give up), exit cleanly. The tick wrapper will release the
claim automatically on exit.
EOF
)

log "spawning ${CLAUDE_BIN} for role=${kind} target=#${number}"
"$CLAUDE_BIN" -p "$prompt" --permission-mode bypassPermissions 2>&1 | tee -a "$LOG" || {
  exit_code=$?
  log "agent exited non-zero (${exit_code}) for #${number}"
  exit "$exit_code"
}

log "agent exited cleanly for #${number}"
