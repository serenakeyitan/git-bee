#!/usr/bin/env bash
# git-bee tick: one pass of the scheduler.
#
# Guards (in order):
#   1. Local PID lock — if an agent is already running on this machine, exit.
#   2. GitHub state — find the oldest open issue/PR without a fresh breeze:wip.
#   3. If nothing is open, the project is finalized. Exit quietly.
#
# Invoked by launchd every 15 minutes.

set -euo pipefail

REPO="serenakeyitan/git-bee"
LOCK="/tmp/git-bee-agent.pid"
CLAIM_TTL_SECONDS=7200  # 2 hours
LOG="${HOME}/.git-bee/tick.log"
mkdir -p "$(dirname "$LOG")"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

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
# List open issues + PRs, filter out those with fresh breeze:wip claim.
# A claim is fresh if a <!-- breeze:claimed-at=<iso> --> comment exists within CLAIM_TTL_SECONDS.

candidates=$(gh issue list --repo "$REPO" --state open --limit 50 --json number,labels,updatedAt \
  --jq '.[] | select(.labels | map(.name) | index("breeze:wip") | not) | .number' 2>/dev/null || echo "")

if [[ -z "$candidates" ]]; then
  # Also check PRs
  candidates=$(gh pr list --repo "$REPO" --state open --limit 50 --json number,labels \
    --jq '.[] | select(.labels | map(.name) | index("breeze:wip") | not) | .number' 2>/dev/null || echo "")
fi

if [[ -z "$candidates" ]]; then
  log "idle: no unclaimed open items — project finalized or nothing to do"
  exit 0
fi

target=$(echo "$candidates" | head -1)
log "dispatch: target=#$target"

# Guard 3: write lock, spawn agent
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# The actual agent spawn is intentionally left as a TODO — wire this to your
# preferred runtime (claude -p, codex exec, or a custom dispatcher) once the
# role prompts in agents/ are finalized.
log "TODO: spawn agent with role=drafter target=#$target (see issue #1)"

# Placeholder: print what we would do
echo "would dispatch drafter on $REPO#$target"
