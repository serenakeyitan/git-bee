#!/bin/bash
# notification-scanner.sh — turns unresolved GitHub notifications into issues
#
# Part of PR 4 from the phase-gated redesign (issue #7).
#
# Flow:
# 1. Get all unread notifications via `gh api notifications`
# 2. Apply scope filter (exclusion or curated) from config.json
# 3. Classify each notification (needs-fix vs informational)
# 4. Dedup against existing source:notification issues
# 5. Create new issues for needs-fix items not already tracked

set -euo pipefail

REPO="${GITHUB_REPOSITORY:-serenakeyitan/git-bee}"
CONFIG_FILE="$HOME/.git-bee/config.json"

# Load config or use defaults
if [[ -f "$CONFIG_FILE" ]]; then
    SCOPE=$(jq -r '.scope // "exclusion"' "$CONFIG_FILE")
    EXCLUDE_REPOS=$(jq -r '.exclude_repos[]? // empty' "$CONFIG_FILE")
    INCLUDE_REPOS=$(jq -r '.include_repos[]? // empty' "$CONFIG_FILE")
else
    SCOPE="exclusion"
    EXCLUDE_REPOS="unispark-inc/paperclip
unispark-inc/paperclip-context-tree"
    INCLUDE_REPOS=""
fi

# Ensure required labels exist
ensure_labels() {
    local labels=("source:notification" "priority:high")
    for label in "${labels[@]}"; do
        if ! gh label list --repo "$REPO" --limit 100 | grep -q "^$label"; then
            echo "Creating label: $label"
            gh label create "$label" --repo "$REPO" --force 2>/dev/null || true
        fi
    done
}

# Check if a repo is in scope based on config.
# Each entry in include_repos / exclude_repos may be a literal "owner/name"
# or a glob ending in `*` (prefix match). Globs let us auto-cover throwaway
# sandboxes like serenakeyitan/git-bee-e2e-<sha> without hand-editing config.
_match_any() {
    local repo="$1"; shift
    local pattern
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        # shellcheck disable=SC2053 — intentional glob match
        if [[ "$repo" == $pattern ]]; then
            return 0
        fi
    done <<< "$1"
    return 1
}

is_in_scope() {
    local repo="$1"

    if [[ "$SCOPE" == "curated" ]]; then
        if [[ -z "$INCLUDE_REPOS" ]]; then
            return 1
        fi
        _match_any "$repo" "$INCLUDE_REPOS" && return 0
        return 1
    else
        if [[ -z "$EXCLUDE_REPOS" ]]; then
            return 0
        fi
        _match_any "$repo" "$EXCLUDE_REPOS" && return 1
        return 0
    fi
}

# Classify notification type
classify_notification() {
    local reason="$1"
    local subject_type="$2"

    case "$reason" in
        "review_requested")
            echo "needs-fix"
            ;;
        "assign"|"mention"|"team_mention")
            echo "needs-fix"
            ;;
        "author"|"comment"|"manual"|"state_change")
            # These could be needs-fix if on user's own PR/issue
            echo "needs-fix"
            ;;
        *)
            echo "informational"
            ;;
    esac
}

# Check if an issue already exists for this notification
find_existing_issue() {
    local repo="$1"
    local number="$2"

    # Search for open issues with source:notification label that reference this PR/issue
    gh issue list --repo "$REPO" \
        --label "source:notification" \
        --state open \
        --json number,body \
        --jq ".[] | select(.body | contains(\"$repo#$number\")) | .number" | head -1
}

# Create or update issue for notification
create_or_update_issue() {
    local repo="$1"
    local number="$2"
    local type="$3"
    local reason="$4"
    local url="$5"

    local existing=$(find_existing_issue "$repo" "$number")

    if [[ -n "$existing" ]]; then
        # Append comment to existing issue
        echo "Updating existing issue #$existing for $repo#$number"
        gh issue comment "$existing" --repo "$REPO" --body "New notification: $reason on $repo#$number
URL: $url
Reason: $reason
Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    else
        # Create new issue
        echo "Creating new issue for $repo#$number ($reason)"
        local title="address $reason on $repo#$number"
        local body="Automated notification tracking

**Source:** $repo#$number
**Type:** $type
**Reason:** $reason
**URL:** $url
**Created:** $(date -u +%Y-%m-%dT%H:%M:%SZ)

This issue was automatically created by git-bee's notification scanner.
Review and address the notification, then close this issue when done."

        gh issue create --repo "$REPO" \
            --title "$title" \
            --body "$body" \
            --label "source:notification" \
            --label "priority:high"
    fi
}

# Main scanner logic
main() {
    ensure_labels

    # Get all unread notifications
    # Note: We intentionally do NOT mark them as read here
    local notifications=$(gh api notifications --paginate | jq -c '.[]')

    if [[ -z "$notifications" ]]; then
        echo "No unread notifications"
        return 0
    fi

    echo "$notifications" | while IFS= read -r notification; do
        local repo=$(echo "$notification" | jq -r '.repository.full_name')
        local reason=$(echo "$notification" | jq -r '.reason')
        local subject_type=$(echo "$notification" | jq -r '.subject.type')
        local subject_title=$(echo "$notification" | jq -r '.subject.title')
        local subject_url=$(echo "$notification" | jq -r '.subject.url // empty')
        local thread_id=$(echo "$notification" | jq -r '.id')

        # Extract issue/PR number from subject URL if available
        local number=""
        if [[ -n "$subject_url" ]]; then
            number=$(echo "$subject_url" | grep -oE '[0-9]+$' || echo "")
        fi

        # Check if repo is in scope
        if ! is_in_scope "$repo"; then
            echo "Skipping out-of-scope repo: $repo"
            continue
        fi

        # Classify the notification
        local classification=$(classify_notification "$reason" "$subject_type")

        if [[ "$classification" == "needs-fix" ]]; then
            if [[ -n "$number" ]]; then
                # Create or update issue for this notification
                create_or_update_issue "$repo" "$number" "$subject_type" "$reason" "${subject_url:-unknown}"
            else
                echo "Warning: Could not extract issue/PR number for $repo notification"
            fi
        else
            echo "Skipping informational notification: $reason on $repo"
        fi

        # Important: Do NOT mark the notification as read
        # The design spec explicitly says not to call PATCH /notifications/threads/<id>
    done
}

main "$@"