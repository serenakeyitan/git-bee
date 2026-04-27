#!/usr/bin/env bash
# quarantine-janitor.sh — proactively scan and auto-release stale quarantines
#
# Scans all items with breeze:quarantine-hotloop label and auto-releases
# quarantine when release conditions are met:
# - PRs: new commits after quarantine OR fix PR merged on main
# - Issues: human comment OR milestone PR merged after quarantine
#
# Respects max 3 auto-releases per item cap.
#
# Usage: ./quarantine-janitor.sh [--repo <owner/repo>] [--min-age-hours <N>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-${GIT_BEE_REPO:-serenakeyitan/git-bee}}"
MIN_AGE_HOURS="${2:-2}"  # Default: quarantine must be at least 2h old

LOG_DIR="${GIT_BEE_LOG_DIR:-$HOME/.git-bee}"
LOG="${LOG_DIR}/tick.log"
mkdir -p "$LOG_DIR"

# Source labels.sh for set_breeze_state helper
# shellcheck source=./labels.sh
source "$SCRIPT_DIR/labels.sh"

log() {
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "$ts [janitor] $*" | tee -a "$LOG"
}

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

# Check if quarantine should be auto-released
# Returns 0 if released, 1 if not
try_auto_release() {
  local number="$1"

  # Check release count cap (max 3 auto-releases per item)
  local release_dir="${LOG_DIR}/quarantine-releases"
  mkdir -p "$release_dir"
  local release_file="${release_dir}/issue-${number}"
  local release_count=0
  if [[ -f "$release_file" ]]; then
    release_count=$(cat "$release_file" 2>/dev/null || echo "0")
  fi

  if [[ "$release_count" -ge 3 ]]; then
    log "#$number: release count=$release_count (capped at 3) — applying breeze:human"
    # Apply breeze:human if not already set
    local has_human
    has_human=$(gh issue view "$number" --repo "$REPO" --json labels \
      --jq '.labels | map(.name) | index("breeze:human") // false' 2>/dev/null || echo "false")

    if [[ "$has_human" == "false" ]]; then
      set_breeze_state "$REPO" "$number" human
      gh issue comment "$number" --repo "$REPO" --body "**janitor:**

Quarantine auto-release limit reached (3/3 releases). Applied \`breeze:human\` — this item needs manual investigation and resolution.

The quarantine will NOT auto-release again." 2>&1 | tee -a "$LOG" || true
    fi
    return 1  # Do not release
  fi

  # Get quarantine timestamp
  local quarantine_ts
  quarantine_ts=$(get_quarantine_timestamp "$number")

  if [[ "$quarantine_ts" == "0" ]]; then
    log "#$number: cannot determine quarantine timestamp — skipping"
    return 1
  fi

  # Check if quarantine is old enough
  local now_ts
  now_ts=$(date +%s)
  local age_hours=$(( (now_ts - quarantine_ts) / 3600 ))

  if [[ "$age_hours" -lt "$MIN_AGE_HOURS" ]]; then
    log "#$number: quarantine age ${age_hours}h < ${MIN_AGE_HOURS}h threshold — skipping"
    return 1
  fi

  # Check if this is a PR or issue
  local is_pr=false
  if gh pr view "$number" --repo "$REPO" --json number >/dev/null 2>&1; then
    is_pr=true
  fi

  local should_release=false
  local release_reason=""

  if [[ "$is_pr" == "true" ]]; then
    # PR auto-release: new commits after quarantine OR fix PR merged
    local pr_branch
    pr_branch=$(gh pr view "$number" --repo "$REPO" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")

    if [[ -z "$pr_branch" ]]; then
      log "#$number: cannot get PR branch — skipping"
      return 1
    fi

    # Check 1: New commits after quarantine
    git fetch origin "$pr_branch" --quiet 2>/dev/null || true

    local quarantine_iso
    quarantine_iso=$(date -u -r "$quarantine_ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "@$quarantine_ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || echo "")

    if [[ -n "$quarantine_iso" ]]; then
      local newer_commits
      newer_commits=$(git log "origin/$pr_branch" --since="$quarantine_iso" --format="%H" 2>/dev/null | head -1 || echo "")

      if [[ -n "$newer_commits" ]]; then
        should_release=true
        release_reason="new commits detected on PR #$number since quarantine"
      fi
    fi

    # Check 2: Fix PR merged on main (M2/PR 4 logic)
    if [[ "$should_release" == "false" ]]; then
      # Look for bug issues filed about this PR
      local bug_issues
      bug_issues=$(gh issue list --repo "$REPO" --state all --search "hot-loop stuck on PR #$number in:title" \
        --json number --jq '.[].number' 2>/dev/null || echo "")

      for bug_issue in $bug_issues; do
        [[ -z "$bug_issue" ]] && continue

        # Find merged PRs that fix this bug issue
        local fix_prs
        fix_prs=$(gh pr list --repo "$REPO" --state merged --limit 100 \
          --json number,mergedAt,body 2>/dev/null | \
          jq -r --arg bug "$bug_issue" '.[] |
            select(.body | test("(Fixes|Closes|Resolves) #" + $bug + "\\b")) |
            "\(.number)|\(.mergedAt)"' || echo "")

        while IFS='|' read -r fix_pr fix_merged_at; do
          [[ -z "$fix_pr" ]] && continue
          [[ -z "$fix_merged_at" ]] && continue

          local fix_merged_ts
          fix_merged_ts=$(printf '"%s"' "$fix_merged_at" | jq -r 'sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null || echo "0")

          if [[ "$fix_merged_ts" -gt "$quarantine_ts" ]]; then
            should_release=true
            release_reason="fix PR #$fix_pr for bug issue #$bug_issue merged on main after quarantine"
            break 2
          fi
        done <<< "$fix_prs"
      done
    fi
  else
    # Issue auto-release: human comment OR milestone PR merge after quarantine
    local issue_json
    issue_json=$(gh issue view "$number" --repo "$REPO" --json comments,body 2>/dev/null || echo "{}")

    # Check for human comment after quarantine timestamp
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

      # Extract milestone PRs from body
      local milestone_prs
      milestone_prs=$(echo "$issue_body" | awk '
        /^## Milestone plan/ { in_milestone=1; next }
        /^##[^#]/ && in_milestone { exit }
        in_milestone && /PR #[0-9]+/ {
          while (match($0, /PR #[0-9]+/)) {
            print substr($0, RSTART+4, RLENGTH-4)
            $0 = substr($0, RSTART+RLENGTH)
          }
        }
      ' | sort -u)

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
  fi

  if [[ "$should_release" == "true" ]]; then
    # Increment release count
    release_count=$((release_count + 1))
    echo "$release_count" > "$release_file"

    log "#$number: auto-releasing quarantine ($release_reason, release $release_count/3)"

    # Remove quarantine label
    gh issue edit "$number" --repo "$REPO" --remove-label "breeze:quarantine-hotloop" 2>&1 | tee -a "$LOG" || true

    # Post comment about auto-release
    local release_comment="**janitor:**

Quarantine auto-released: $release_reason.

Auto-release $release_count/3. The \`breeze:quarantine-hotloop\` label has been removed and normal dispatch can resume."

    gh issue comment "$number" --repo "$REPO" --body "$release_comment" 2>&1 | tee -a "$LOG" || true

    return 0
  fi

  return 1
}

# Main: scan all quarantined items
log "scanning for quarantined items (min age: ${MIN_AGE_HOURS}h)"

quarantined_items=$(gh issue list --repo "$REPO" --state open --label "breeze:quarantine-hotloop" \
  --json number --jq '.[].number' 2>/dev/null || echo "")

if [[ -z "$quarantined_items" ]]; then
  log "no quarantined items found"
  exit 0
fi

released_count=0
skipped_count=0
capped_count=0

for item in $quarantined_items; do
  log "checking #$item"

  if try_auto_release "$item"; then
    released_count=$((released_count + 1))
  else
    # Check if it was skipped due to cap
    release_file="${LOG_DIR}/quarantine-releases/issue-${item}"
    if [[ -f "$release_file" ]]; then
      count=$(cat "$release_file" 2>/dev/null || echo "0")
      if [[ "$count" -ge 3 ]]; then
        capped_count=$((capped_count + 1))
      else
        skipped_count=$((skipped_count + 1))
      fi
    else
      skipped_count=$((skipped_count + 1))
    fi
  fi
done

log "scan complete: released=$released_count, skipped=$skipped_count, capped=$capped_count"
