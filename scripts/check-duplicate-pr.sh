#!/bin/bash
# check-duplicate-pr.sh
# Helper to detect duplicate PRs that reference the same root-cause issue
#
# Usage: check-duplicate-pr.sh <repo> <issue-number>
# Returns: JSON with matching PR info if found, empty otherwise
#
# Search strategy:
# 1. Direct search: PRs that mention this issue (#N) in title/body
# 2. Root-cause search: If this issue mentions a root-cause (e.g., "fixes #X"),
#    find other open issues that also mention #X, then find PRs for those issues.
#    This prevents cascades like #785→#787→#791→#793 where each new issue
#    references #785 but drafter didn't realize they're all for the same bug.

set -euo pipefail

REPO="${1:-}"
ISSUE_NUM="${2:-}"

if [[ -z "$REPO" || -z "$ISSUE_NUM" ]]; then
  echo "Usage: $0 <repo> <issue-number>" >&2
  exit 1
fi

# Check for PRs with direct Fixes/Refs links to this issue
direct_prs=$(gh pr list --repo "$REPO" --state open --search "$ISSUE_NUM in:body" --json number,headRefName,title,body 2>/dev/null || echo "[]")

# Check for PRs that mention this issue in title or body (broader search)
# This catches PRs like "Fix divergence from #785" or "Address issue found in #798"
mention_prs=$(gh pr list --repo "$REPO" --state open --search "#$ISSUE_NUM" --json number,headRefName,title,body 2>/dev/null || echo "[]")

# Combine results and deduplicate
combined=$(echo "$direct_prs" | jq -r --argjson mention "$mention_prs" --arg issue_num "$ISSUE_NUM" '
  . + $mention |
  group_by(.number) |
  map(.[0]) |
  map(select(.body // "" | test("#" + $issue_num + "\\b") or (.title // "" | test("#" + $issue_num + "\\b"))))
')

# Root-cause search: extract root-cause issue numbers from this issue's body
# Look for patterns like "divergence on PR #785", "fixes #785", "refs #123", etc.
issue_body=$(gh issue view "$ISSUE_NUM" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null || echo "")
root_causes=$(echo "$issue_body" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | head -5 || echo "")

# For each root-cause, find other open issues that reference it, then find their PRs
root_cause_prs="[]"
for root_cause in $root_causes; do
  [[ "$root_cause" == "$ISSUE_NUM" ]] && continue  # Skip self-reference

  # Find open issues that mention this root-cause
  related_issues=$(gh issue list --repo "$REPO" --state open --search "#$root_cause" --json number --jq '.[].number' 2>/dev/null || echo "")

  for related_issue in $related_issues; do
    [[ "$related_issue" == "$ISSUE_NUM" ]] && continue  # Skip self

    # Find PRs for this related issue
    related_prs=$(gh pr list --repo "$REPO" --state open --search "$related_issue in:body" --json number,headRefName,title,body 2>/dev/null || echo "[]")
    if [[ "$(echo "$related_prs" | jq 'length')" -gt 0 ]]; then
      root_cause_prs=$(echo "$root_cause_prs" | jq -r --argjson new "$related_prs" '. + $new')
    fi
  done
done

# Merge all results: direct mentions + root-cause chain
all_prs=$(echo "$combined" | jq -r --argjson root "$root_cause_prs" '
  . + $root |
  group_by(.number) |
  map(.[0])
')

# Return the first matching PR (if any)
echo "$all_prs" | jq -r 'if length > 0 then .[0] else empty end'