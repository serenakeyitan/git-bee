#!/bin/bash
# check-duplicate-pr.sh
# Helper to detect duplicate PRs that reference the same root-cause issue
#
# Usage: check-duplicate-pr.sh <repo> <issue-number>
# Returns: JSON with matching PR info if found, empty otherwise

set -euo pipefail

REPO="${1:-}"
ISSUE_NUM="${2:-}"

if [[ -z "$REPO" || -z "$ISSUE_NUM" ]]; then
  echo "Usage: $0 <repo> <issue-number>" >&2
  exit 1
fi

# Check for PRs with direct Fixes/Refs links to this issue
direct_prs=$(gh pr list --repo "$REPO" --state open --search "$ISSUE_NUM in:body" --json number,headRefName,title 2>/dev/null || echo "[]")

# Check for PRs that mention this issue in title or body (broader search)
# This catches PRs like "Fix divergence from #785" or "Address issue found in #798"
mention_prs=$(gh pr list --repo "$REPO" --state open --search "#$ISSUE_NUM" --json number,headRefName,title,body 2>/dev/null || echo "[]")

# Combine results and deduplicate
combined=$(echo "$direct_prs" | jq -r --argjson mention "$mention_prs" '
  . + $mention |
  group_by(.number) |
  map(.[0]) |
  map(select(.body // "" | test("#'"$ISSUE_NUM"'\\b") or (.title // "" | test("#'"$ISSUE_NUM"'\\b"))))
')

# Return the first matching PR (if any)
echo "$combined" | jq -r 'if length > 0 then .[0] else empty end'