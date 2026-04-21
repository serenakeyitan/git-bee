#!/usr/bin/env bash
# notification-scanner.sh — turns unresolved GitHub notifications into issues
# on git-bee, but ONLY for repos the user has explicitly opted-in to via
# `bee watch add`.
#
# Redesigned per issue #529. Old shape (`scope: exclusion|curated`) is
# migrated forward automatically. New shape:
#   {
#     "watch": {
#       "enabled": bool,
#       "repos": ["owner/name", ...],
#       "classify_as_needs_fix": ["review_requested", ...],
#       "per_repo_ceiling": 5,
#       "global_ceiling": 20
#     }
#   }
#
# Safety rails:
#   - Empty repos list or enabled=false → no-op (safe default).
#   - Per-repo ceiling: never create more than N issues per repo per tick.
#   - Global ceiling: never create more than M issues total per tick.
#   - On ceiling trip: stop and file ONE breeze:human summary issue, no further
#     creates this tick. The summary asks the human to decide what to do.
#   - Classifier: only actionable reasons (review_requested, assign, mention,
#     team_mention) become issues by default. "author"/"comment" are noise.

set -euo pipefail

REPO="${GITHUB_REPOSITORY:-serenakeyitan/git-bee}"
CONFIG_FILE="$HOME/.git-bee/config.json"

# ---- config migration + load ------------------------------------------------

_migrate_if_legacy() {
    # If config has the old scope-based shape and no `watch` key, map forward:
    #   scope=curated + include_repos  → watch.repos, watch.enabled=true
    #   scope=exclusion                 → watch.repos=[], watch.enabled=false
    # Print a one-time notice to stderr so the user sees what happened.
    [[ ! -f "$CONFIG_FILE" ]] && return 0
    local has_legacy has_watch
    has_legacy=$(jq 'has("scope") or has("include_repos") or has("exclude_repos")' "$CONFIG_FILE" 2>/dev/null || echo "false")
    has_watch=$(jq 'has("watch")' "$CONFIG_FILE" 2>/dev/null || echo "false")
    if [[ "$has_legacy" != "true" || "$has_watch" == "true" ]]; then
        return 0
    fi
    echo "notification-scanner: migrating legacy config (scope/{include,exclude}_repos → watch)" >&2
    jq '
      . as $in
      | {
          watch: {
            enabled: (($in.scope // "exclusion") == "curated" and (($in.include_repos // []) | length) > 0),
            repos: ($in.include_repos // []),
            exclude_repos: ($in.exclude_repos // []),
            classify_as_needs_fix: ["review_requested", "assign", "mention", "team_mention"],
            per_repo_ceiling: 5,
            global_ceiling: 20
          }
        }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

_migrate_if_legacy

if [[ -f "$CONFIG_FILE" ]]; then
    WATCH_ENABLED=$(jq -r '.watch.enabled // false' "$CONFIG_FILE")
    WATCH_REPOS=$(jq -r '(.watch.repos // [])[]' "$CONFIG_FILE" 2>/dev/null || true)
    EXCLUDE_REPOS=$(jq -r '(.watch.exclude_repos // [])[]' "$CONFIG_FILE" 2>/dev/null || true)
    NEEDS_FIX_REASONS=$(jq -r '(.watch.classify_as_needs_fix // ["review_requested","assign","mention","team_mention"])[]' "$CONFIG_FILE" 2>/dev/null)
    PER_REPO_CEILING=$(jq -r '.watch.per_repo_ceiling // 5' "$CONFIG_FILE")
    GLOBAL_CEILING=$(jq -r '.watch.global_ceiling // 20' "$CONFIG_FILE")
else
    WATCH_ENABLED="false"
    WATCH_REPOS=""
    EXCLUDE_REPOS=""
    NEEDS_FIX_REASONS="review_requested
assign
mention
team_mention"
    PER_REPO_CEILING=5
    GLOBAL_CEILING=20
fi

if [[ "$WATCH_ENABLED" != "true" ]] || [[ -z "$WATCH_REPOS" ]]; then
    echo "notification-scanner: disabled or empty watchlist, no-op"
    exit 0
fi

# ---- helpers ---------------------------------------------------------------

ensure_labels() {
    local labels=("source:notification" "priority:high" "breeze:human")
    for label in "${labels[@]}"; do
        if ! gh label list --repo "$REPO" --limit 100 2>/dev/null | grep -q "^$label"; then
            gh label create "$label" --repo "$REPO" --force 2>/dev/null || true
        fi
    done
}

is_watched() {
    local repo="$1"
    while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        [[ "$repo" == "$w" ]] && return 0
    done <<< "$WATCH_REPOS"
    return 1
}

is_excluded() {
    local repo="$1"
    while IFS= read -r e; do
        [[ -z "$e" ]] && continue
        [[ "$repo" == "$e" ]] && return 0
    done <<< "$EXCLUDE_REPOS"
    return 1
}

is_needs_fix() {
    local reason="$1"
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        [[ "$reason" == "$r" ]] && return 0
    done <<< "$NEEDS_FIX_REASONS"
    return 1
}

find_existing_issue() {
    local repo="$1" number="$2"
    gh issue list --repo "$REPO" \
        --label "source:notification" --state open \
        --json number,body \
        --jq ".[] | select(.body | contains(\"$repo#$number\")) | .number" | head -1
}

create_issue() {
    local repo="$1" number="$2" type="$3" reason="$4" url="$5"
    local title="address $reason on $repo#$number"
    local body
    body=$(cat <<EOF
Automated notification tracking

**Source:** $repo#$number
**Type:** $type
**Reason:** $reason
**URL:** $url
**Created:** $(date -u +%Y-%m-%dT%H:%M:%SZ)

This issue was automatically created by the git-bee notification scanner.
Review and address the notification, then close this issue when done.
EOF
)
    gh issue create --repo "$REPO" \
        --title "$title" --body "$body" \
        --label "source:notification" --label "priority:high" >/dev/null
}

file_ceiling_breach() {
    local scope="$1" limit="$2" repo="$3"
    local title="scanner: ${scope} ceiling hit (${limit}) — watchlist may be too broad"
    local body
    body=$(cat <<EOF
Scanner stopped mid-scan because the ${scope} ceiling of ${limit} was reached${repo:+ on \`$repo\`}.

This usually means one of the watched repos is too noisy for agents to keep up.
Pick one:
- \`bee watch remove <owner/repo>\` to drop it
- raise \`watch.${scope}_ceiling\` in \`~/.git-bee/config.json\`
- \`bee watch pause\` to stop scanning entirely while you decide

Remove \`breeze:human\` once resolved; next tick will resume scanning.
EOF
)
    gh issue create --repo "$REPO" \
        --title "$title" --body "$body" \
        --label "breeze:human" --label "source:notification" >/dev/null 2>&1 || true
}

# ---- main -----------------------------------------------------------------

main() {
    ensure_labels

    local notifications
    notifications=$(gh api notifications --paginate 2>/dev/null | jq -c '.[]' || true)
    if [[ -z "$notifications" ]]; then
        echo "notification-scanner: no unread notifications"
        return 0
    fi

    local global_created=0
    # bash 3.2-compatible per-repo counter: newline-delimited "repo<TAB>count" lines.
    local per_repo_counts=""

    _get_repo_count() {
        local r="$1"
        printf '%s\n' "$per_repo_counts" | awk -v r="$r" -F '\t' '$1==r {print $2; exit}'
    }
    _set_repo_count() {
        local r="$1" c="$2"
        per_repo_counts=$(printf '%s\n' "$per_repo_counts" | awk -v r="$r" -F '\t' '$1!=r')
        per_repo_counts="${per_repo_counts}
${r}	${c}"
    }

    while IFS= read -r notification; do
        [[ -z "$notification" ]] && continue

        local repo reason subject_type subject_url number
        repo=$(echo "$notification" | jq -r '.repository.full_name')
        reason=$(echo "$notification" | jq -r '.reason')
        subject_type=$(echo "$notification" | jq -r '.subject.type')
        subject_url=$(echo "$notification" | jq -r '.subject.url // empty')
        number=""
        [[ -n "$subject_url" ]] && number=$(echo "$subject_url" | grep -oE '[0-9]+$' || echo "")

        is_watched "$repo" || continue
        is_excluded "$repo" && continue
        is_needs_fix "$reason" || continue
        [[ -z "$number" ]] && continue

        # Dedup: already tracked → skip silently.
        local existing
        existing=$(find_existing_issue "$repo" "$number")
        [[ -n "$existing" ]] && continue

        # Global ceiling
        if (( global_created >= GLOBAL_CEILING )); then
            echo "notification-scanner: hit global ceiling ($GLOBAL_CEILING), filing summary and stopping"
            file_ceiling_breach "global" "$GLOBAL_CEILING" ""
            break
        fi

        # Per-repo ceiling
        local repo_count
        repo_count=$(_get_repo_count "$repo")
        [[ -z "$repo_count" ]] && repo_count=0
        if (( repo_count >= PER_REPO_CEILING )); then
            if (( repo_count == PER_REPO_CEILING )); then
                echo "notification-scanner: hit per-repo ceiling ($PER_REPO_CEILING) on $repo, filing summary"
                file_ceiling_breach "per_repo" "$PER_REPO_CEILING" "$repo"
                _set_repo_count "$repo" "$((repo_count + 1))"
            fi
            continue
        fi

        create_issue "$repo" "$number" "$subject_type" "$reason" "${subject_url:-unknown}"
        global_created=$((global_created + 1))
        _set_repo_count "$repo" "$((repo_count + 1))"
        echo "notification-scanner: created issue for $repo#$number ($reason)"
    done <<< "$notifications"

    echo "notification-scanner: done ($global_created created this tick)"
}

main "$@"
