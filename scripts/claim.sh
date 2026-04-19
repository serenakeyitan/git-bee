#!/usr/bin/env bash
# Shared claim protocol for git-bee agents.
#
# Usage:
#   source scripts/claim.sh
#   claim_check <repo> <number>              # prints status: free | fresh-claim | stale-claim
#   claim_acquire <repo> <number> <agent-id> # sets breeze:wip + posts timestamp marker
#   claim_release <repo> <number> <agent-id> # removes breeze:wip
#   claim_is_mine <repo> <number> <agent-id> # 0 if the latest claim on this item is ours
#
# Conventions (see repo README):
#   - breeze:wip on an open item = claimed
#   - absence of breeze:wip = fair game
#   - "fresh" = a <!-- breeze:claimed-at=<ISO8601-UTC> by=<agent-id> --> comment
#     authored within CLAIM_TTL_SECONDS (default 7200 = 2h)
#   - multiple claim markers on the same item: the newest one wins

set -euo pipefail

: "${CLAIM_TTL_SECONDS:=7200}"

_claim_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_claim_ttl_cutoff_iso() {
  # ISO8601 UTC timestamp CLAIM_TTL_SECONDS in the past
  if date -v -${CLAIM_TTL_SECONDS}S +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -v -${CLAIM_TTL_SECONDS}S +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "-${CLAIM_TTL_SECONDS} seconds" +%Y-%m-%dT%H:%M:%SZ
  fi
}

# Find the latest claim marker on an issue/PR. Emits: "<iso-timestamp> <agent-id>"
# or nothing if no marker found.
_claim_latest_marker() {
  local repo="$1" number="$2"
  gh issue view "$number" --repo "$repo" --comments --json comments \
    --jq '.comments[] | .body' 2>/dev/null \
    | grep -oE '<!-- breeze:claimed-at=[^ ]+ by=[^ ]+ -->' \
    | tail -1 \
    | sed -E 's/<!-- breeze:claimed-at=([^ ]+) by=([^ ]+) -->/\1 \2/'
}

claim_check() {
  local repo="$1" number="$2"
  local has_label
  has_label=$(gh issue view "$number" --repo "$repo" --json labels \
    --jq '.labels | map(.name) | index("breeze:wip")' 2>/dev/null || echo "null")
  if [[ "$has_label" == "null" || -z "$has_label" ]]; then
    echo "free"
    return 0
  fi
  local marker
  marker=$(_claim_latest_marker "$repo" "$number")
  if [[ -z "$marker" ]]; then
    # Label set but no marker — treat as stale (agent crashed before marker)
    echo "stale-claim"
    return 0
  fi
  local claimed_at cutoff
  claimed_at=$(echo "$marker" | awk '{print $1}')
  cutoff=$(_claim_ttl_cutoff_iso)
  if [[ "$claimed_at" < "$cutoff" ]]; then
    echo "stale-claim"
  else
    echo "fresh-claim"
  fi
}

claim_acquire() {
  local repo="$1" number="$2" agent="$3"
  local status
  status=$(claim_check "$repo" "$number")
  case "$status" in
    fresh-claim) return 1 ;;
    stale-claim)
      # Forcibly clear and re-claim
      gh issue edit "$number" --repo "$repo" --remove-label "breeze:wip" >/dev/null 2>&1 || true
      ;;
  esac
  gh issue edit "$number" --repo "$repo" --add-label "breeze:wip" >/dev/null
  local marker_body
  marker_body="<!-- breeze:claimed-at=$(_claim_now_iso) by=${agent} -->"
  gh issue comment "$number" --repo "$repo" --body "$marker_body" >/dev/null
  return 0
}

claim_release() {
  local repo="$1" number="$2" agent="$3"
  gh issue edit "$number" --repo "$repo" --remove-label "breeze:wip" >/dev/null 2>&1 || true
  # Do not delete the marker — it's the audit trail. It just becomes stale.
}

claim_is_mine() {
  local repo="$1" number="$2" agent="$3"
  local marker
  marker=$(_claim_latest_marker "$repo" "$number")
  [[ -z "$marker" ]] && return 1
  local marker_agent
  marker_agent=$(echo "$marker" | awk '{print $2}')
  [[ "$marker_agent" == "$agent" ]]
}

# If invoked directly, expose a small CLI for humans/smoke tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    check)   claim_check "$@" ;;
    acquire) claim_acquire "$@" ;;
    release) claim_release "$@" ;;
    mine)    claim_is_mine "$@" && echo "yes" || echo "no" ;;
    *) echo "usage: claim.sh {check|acquire|release|mine} <repo> <number> [agent-id]" >&2; exit 2 ;;
  esac
fi
