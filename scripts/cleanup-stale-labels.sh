#!/usr/bin/env bash
# One-time cleanup script for stale breeze:* labels on closed/merged items
# Run this once to clean up existing label drift before the janitor takes over

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/labels.sh"

REPO="${1:-serenakeyitan/git-bee}"

echo "Cleaning up stale breeze labels on repo: $REPO"

# Clean up closed issues
echo "Checking closed issues..."
stale_issues=$(gh issue list --repo "$REPO" --state closed --limit 100 --json number,labels \
  --jq '[.[] | select(.labels | map(.name) | any(test("breeze:(human|wip|new)")))] | .[].number' 2>/dev/null || echo "")

if [[ -n "$stale_issues" ]]; then
  echo "Found stale labels on closed issues: $stale_issues"
  for n in $stale_issues; do
    echo "  Transitioning issue #$n to breeze:done"
    set_breeze_state "$REPO" "$n" done
  done
else
  echo "No stale labels found on closed issues"
fi

# Clean up merged PRs
echo "Checking merged PRs..."
stale_prs=$(gh pr list --repo "$REPO" --state merged --limit 100 --json number,labels \
  --jq '[.[] | select(.labels | map(.name) | any(test("breeze:(human|wip|new)")))] | .[].number' 2>/dev/null || echo "")

if [[ -n "$stale_prs" ]]; then
  echo "Found stale labels on merged PRs: $stale_prs"
  for n in $stale_prs; do
    echo "  Transitioning PR #$n to breeze:done"
    set_breeze_state "$REPO" "$n" done
  done
else
  echo "No stale labels found on merged PRs"
fi

# Clean up closed (not merged) PRs
echo "Checking closed PRs..."
closed_prs=$(gh pr list --repo "$REPO" --state closed --limit 100 --json number,labels,merged \
  --jq '[.[] | select((.merged == false) and (.labels | map(.name) | any(test("breeze:(human|wip|new)"))))] | .[].number' 2>/dev/null || echo "")

if [[ -n "$closed_prs" ]]; then
  echo "Found stale labels on closed PRs: $closed_prs"
  for n in $closed_prs; do
    echo "  Transitioning PR #$n to breeze:done"
    set_breeze_state "$REPO" "$n" done
  done
else
  echo "No stale labels found on closed PRs"
fi

echo "Cleanup complete!"