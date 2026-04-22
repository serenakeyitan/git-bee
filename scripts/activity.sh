#!/usr/bin/env bash
# activity.sh — structured activity log for git-bee agents.
#
# Writes NDJSON events to ~/.git-bee/activity.ndjson. One line per event.
#
# Usage:
#   scripts/activity.sh start <repo> <kind> <number> <agent_id>
#   scripts/activity.sh end   <repo> <kind> <number> <agent_id> <exit_code> <duration_s>
#
# Event shape:
#   {
#     "ts": "2026-04-21T02:43:01Z",
#     "event": "start" | "end",
#     "agent": "reviewer",
#     "agent_id": "reviewer-myhost",
#     "repo": "serenakeyitan/git-bee",
#     "target": "#561",
#     "target_kind": "pr" | "issue",
#     "title": "feat(...): ...",
#     "umbrella": "#7",            // inferred from Refs/Fixes in PR body; null otherwise
#     "exit_code": 0,              // end events only
#     "duration_s": 108,           // end events only
#     "outcome": "requested-changes", // end events only; parsed from last agent comment
#     "next": "drafter"            // end events only; next-role hint from agent output
#   }
#
# Outcome is extracted from the last comment authored on the target whose body
# starts with `**<agent>:` — e.g. "**reviewer: requested-changes**" yields
# outcome="requested-changes". Best-effort — outcome is null if no such comment.

set -uo pipefail

LOG_DIR="${HOME}/.git-bee"
ACTIVITY_LOG="${LOG_DIR}/activity.ndjson"
mkdir -p "$LOG_DIR"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Resolve target metadata: is_pr (bool), title, umbrella (#N or null).
# One gh call — we fetch both PR and issue shape to handle either.
resolve_target() {
  local repo="$1" number="$2"
  # Try PR first (cheaper — PRs are a subset of issues on GH)
  local pr_json
  pr_json=$(gh pr view "$number" --repo "$repo" --json title,body 2>/dev/null || echo "")
  if [[ -n "$pr_json" ]]; then
    local title umbrella
    title=$(jq -r '.title // ""' <<<"$pr_json")
    # Umbrella: first "Refs #N" or "Fixes #N" in body, N != this PR
    umbrella=$(jq -r '.body // ""' <<<"$pr_json" | \
      grep -oE '(Refs|Fixes|Closes) #[0-9]+' | \
      head -1 | grep -oE '#[0-9]+' || true)
    printf 'pr\t%s\t%s\n' "$title" "${umbrella:-}"
    return
  fi
  # Fall back to issue
  local issue_json
  issue_json=$(gh issue view "$number" --repo "$repo" --json title 2>/dev/null || echo "")
  if [[ -n "$issue_json" ]]; then
    local title
    title=$(jq -r '.title // ""' <<<"$issue_json")
    printf 'issue\t%s\t\n' "$title"
    return
  fi
  printf 'unknown\t\t\n'
}

# Scrape the last agent output line for the next-role hint.
# Format: "<agent>: <target>=<n> action=<outcome> next=<role|none>"
# Returns the next role (e.g. "reviewer", "e2e", "none") or empty string if not found.
scrape_next_hint() {
  local repo="$1" number="$2" agent="$3"

  # Look for the agent's output in the last comment/review that starts with **<agent>:
  local bodies=""
  local reviews_json
  reviews_json=$(gh pr view "$number" --repo "$repo" --json reviews 2>/dev/null || echo "")
  if [[ -n "$reviews_json" ]]; then
    local review_bodies
    review_bodies=$(jq -r '[.reviews[]? | {ts: .submittedAt, body: (.body // "")}]' <<<"$reviews_json" 2>/dev/null || echo "[]")
    bodies="$review_bodies"
  fi
  local comments_json
  comments_json=$(gh issue view "$number" --repo "$repo" --json comments 2>/dev/null || echo "")
  if [[ -n "$comments_json" ]]; then
    local comment_bodies
    comment_bodies=$(jq -r '[.comments[]? | {ts: .createdAt, body: (.body // "")}]' <<<"$comments_json" 2>/dev/null || echo "[]")
    bodies=$(jq -s '.[0] + .[1]' <(echo "${bodies:-[]}") <(echo "$comment_bodies") 2>/dev/null || echo "[]")
  fi
  [[ -z "$bodies" || "$bodies" == "[]" ]] && { echo ""; return; }

  # Look for the pattern: <agent>: ...<target>=<n> ... next=<role|none>
  # in the agent's last comment
  local next_hint=""
  next_hint=$(jq -r --arg agent "$agent" --arg number "$number" '
    sort_by(.ts) | reverse
    | map(select(.body | test("^\\*\\*" + $agent + ":")))
    | .[0].body // ""
    | split("\n")
    | map(select(test($agent + ":.*\\b(pr|issue)=" + $number + "\\b.*\\bnext=")))
    | .[0] // ""
    | capture("\\bnext=(?<hint>[a-z-]+|none)") // {hint: ""}
    | .hint
  ' <<<"$bodies" 2>/dev/null || echo "")

  echo "$next_hint"
}

# Scrape the last agent-prefixed body for an outcome token.
#
# Two sources, newest wins:
#  1. Reviews on PRs (posted via `gh pr review`) — format
#     "**reviewer verdict: <outcome>**" or "**<agent>: <outcome>**"
#  2. Issue/PR comments — format "**<agent>: <outcome>**"
#
# Examples:
#   "**reviewer verdict: changes-requested**" -> "changes-requested"
#   "**e2e-supervisor: pass**"                -> "pass"
#   "**merger: merged**"                      -> "merged"
#   "**drafter: done**"                       -> "done"
scrape_outcome() {
  local repo="$1" number="$2" agent="$3"
  local bodies=""
  local reviews_json
  reviews_json=$(gh pr view "$number" --repo "$repo" --json reviews 2>/dev/null || echo "")
  if [[ -n "$reviews_json" ]]; then
    local review_bodies
    review_bodies=$(jq -r '[.reviews[]? | {ts: .submittedAt, body: (.body // "")}]' <<<"$reviews_json" 2>/dev/null || echo "[]")
    bodies="$review_bodies"
  fi
  local comments_json
  comments_json=$(gh issue view "$number" --repo "$repo" --json comments 2>/dev/null || echo "")
  if [[ -n "$comments_json" ]]; then
    local comment_bodies
    comment_bodies=$(jq -r '[.comments[]? | {ts: .createdAt, body: (.body // "")}]' <<<"$comments_json" 2>/dev/null || echo "[]")
    bodies=$(jq -s '.[0] + .[1]' <(echo "${bodies:-[]}") <(echo "$comment_bodies") 2>/dev/null || echo "[]")
  fi
  [[ -z "$bodies" || "$bodies" == "[]" ]] && { echo ""; return; }
  # Sort by ts desc, pick first matching line.
  # Matches: "**<agent>: foo**" or "**<agent> verdict: foo**"
  # Agent-specific parsers fall through to the generic "**<agent>: <outcome>**"
  # pattern. e2e is special: the outcome is posted as "**E2E trace (<outcome>)**"
  # in a summary comment, not as the e2e agent's own message.
  local outcome=""
  if [[ "$agent" == "e2e" ]]; then
    outcome=$(jq -r '
      sort_by(.ts) | reverse
      | map(.body)
      | map(select(. | test("^\\*\\*E2E trace \\(")))
      | .[0] // ""
      | capture("^\\*\\*E2E trace \\((?<out>[^)]+)\\)") // {out: ""}
      | .out
    ' <<<"$bodies" 2>/dev/null || echo "")
  fi
  if [[ -z "$outcome" ]]; then
    # Require at least one non-* non-whitespace char after the colon —
    # otherwise it's a generic "**drafter:**" header with no outcome token.
    outcome=$(jq -r --arg agent "$agent" '
      sort_by(.ts) | reverse
      | map(.body)
      | map(select(. | test("^\\*\\*" + $agent + "( verdict)?:\\s*[^*\\s]")))
      | .[0] // ""
      | capture("^\\*\\*" + $agent + "( verdict)?:\\s*(?<out>[^*\\n]+)") // {out: ""}
      | .out
      | gsub("\\s+\\*\\*.*$"; "")
      | gsub("^\\s+|\\s+$"; "")
    ' <<<"$bodies" 2>/dev/null || echo "")
  fi
  echo "$outcome"
}

write_event() {
  local json="$1"
  printf '%s\n' "$json" >> "$ACTIVITY_LOG"
}

cmd_start() {
  local repo="$1" kind="$2" number="$3" agent_id="$4"
  local meta target_kind title umbrella
  meta=$(resolve_target "$repo" "$number")
  target_kind=$(cut -f1 <<<"$meta")
  title=$(cut -f2 <<<"$meta")
  umbrella=$(cut -f3 <<<"$meta")

  local json
  json=$(jq -cn \
    --arg ts "$(now_iso)" \
    --arg agent "$kind" \
    --arg agent_id "$agent_id" \
    --arg repo "$repo" \
    --arg target "#${number}" \
    --arg target_kind "$target_kind" \
    --arg title "$title" \
    --arg umbrella "$umbrella" \
    '{
      ts: $ts,
      event: "start",
      agent: $agent,
      agent_id: $agent_id,
      repo: $repo,
      target: $target,
      target_kind: $target_kind,
      title: $title,
      umbrella: (if $umbrella == "" then null else $umbrella end)
    }')
  write_event "$json"
}

cmd_end() {
  local repo="$1" kind="$2" number="$3" agent_id="$4" exit_code="$5" duration_s="$6"
  local meta target_kind title umbrella outcome next_hint
  meta=$(resolve_target "$repo" "$number")
  target_kind=$(cut -f1 <<<"$meta")
  title=$(cut -f2 <<<"$meta")
  umbrella=$(cut -f3 <<<"$meta")
  outcome=$(scrape_outcome "$repo" "$number" "$kind")
  next_hint=$(scrape_next_hint "$repo" "$number" "$kind")

  local json
  json=$(jq -cn \
    --arg ts "$(now_iso)" \
    --arg agent "$kind" \
    --arg agent_id "$agent_id" \
    --arg repo "$repo" \
    --arg target "#${number}" \
    --arg target_kind "$target_kind" \
    --arg title "$title" \
    --arg umbrella "$umbrella" \
    --arg outcome "$outcome" \
    --arg next_hint "$next_hint" \
    --argjson exit_code "$exit_code" \
    --argjson duration_s "$duration_s" \
    '{
      ts: $ts,
      event: "end",
      agent: $agent,
      agent_id: $agent_id,
      repo: $repo,
      target: $target,
      target_kind: $target_kind,
      title: $title,
      umbrella: (if $umbrella == "" then null else $umbrella end),
      exit_code: $exit_code,
      duration_s: $duration_s,
      outcome: (if $outcome == "" then null else $outcome end),
      next: (if $next_hint == "" then null elif $next_hint == "none" then null else $next_hint end)
    }')
  write_event "$json"
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  end)   shift; cmd_end "$@" ;;
  *)
    echo "usage: activity.sh start <repo> <kind> <number> <agent_id>" >&2
    echo "       activity.sh end   <repo> <kind> <number> <agent_id> <exit_code> <duration_s>" >&2
    exit 2
    ;;
esac
