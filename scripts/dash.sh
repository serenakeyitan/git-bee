#!/usr/bin/env bash
# dash.sh — terminal dashboard for git-bee. Refreshes every 5s.
#
# Usage: scripts/dash.sh [interval_seconds]   (default 5)
#        scripts/dash.sh --once                 # single render, no loop, no clear
# Exit: Ctrl-C.
#
# Renders:
#   - Top strip: launchd state, next tick, current agent (role → #N, age)
#   - Middle: recent dispatches from tick.log (last 8)
#   - Bottom: open PRs with breeze state + open issues with breeze:human flagged
#
# Reads only local state (`bee status --json` + `~/.git-bee/tick.log`) plus
# one `gh pr/issue list` call per refresh, so it's cheap.

set -uo pipefail

# Dependency checks
if ! command -v jq &>/dev/null; then
  echo "Error: jq is not installed. Please install jq to use the dashboard." >&2
  echo "  macOS: brew install jq" >&2
  echo "  Linux: apt-get install jq or yum install jq" >&2
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "Error: GitHub CLI (gh) is not installed. Please install gh to use the dashboard." >&2
  echo "  macOS: brew install gh" >&2
  echo "  Linux: https://github.com/cli/cli/blob/trunk/docs/install_linux.md" >&2
  exit 1
fi

# Check gh authentication
if ! gh auth status &>/dev/null; then
  echo "Error: GitHub CLI is not authenticated. Please run 'gh auth login' first." >&2
  exit 1
fi

ONCE=0
case "${1:-}" in
  --once) ONCE=1; INTERVAL=0 ;;
  "")     INTERVAL=5 ;;
  *)      INTERVAL="$1" ;;
esac
REPO="serenakeyitan/git-bee"
BEE="$(cd "$(dirname "$0")" && pwd)/bee"
TICK_LOG="$HOME/.git-bee/tick.log"
ROLLBACK_MARKER="$HOME/.git-bee/ROLLBACK"

# ANSI
BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'
if (( ONCE )); then CLEAR=""; else CLEAR=$'\033[2J\033[H'; fi

hline() { printf '%s\n' "────────────────────────────────────────────────────────────────"; }

render() {
  local now status_json
  now=$(date '+%Y-%m-%d %H:%M:%S')
  # `bee status --json` exits non-zero when there are breeze:human items;
  # that's a healthy signal, not a JSON failure. Swallow the exit code but
  # keep the stdout. Fallback to {} only if the command produces nothing.
  status_json=$("$BEE" status --json 2>/dev/null; true)
  [[ -z "$status_json" ]] && status_json='{}'

  # Extract fields
  local agent_state role target claimed_ago launchd_state next_tick
  local issues_open prs_open human_items abandoned stale last_line
  agent_state=$(jq -r '.agent.state // "?"' <<<"$status_json")
  role=$(jq -r '.agent.role // ""' <<<"$status_json")
  target=$(jq -r '.agent.target // ""' <<<"$status_json")
  claimed_ago=$(jq -r '.agent.claimed_ago_secs // 0' <<<"$status_json")
  launchd_state=$(jq -r '.launchd.state // "?"' <<<"$status_json")
  next_tick=$(jq -r '.launchd.next_tick_secs // "?"' <<<"$status_json")
  issues_open=$(jq -r '.github.issues_open // 0' <<<"$status_json")
  prs_open=$(jq -r '.github.prs_open // 0' <<<"$status_json")
  human_items=$(jq -r '.github.human_items // 0' <<<"$status_json")
  abandoned=$(jq -r '.github.abandoned_items // 0' <<<"$status_json")
  stale=$(jq -r '.github.stale_claims // 0' <<<"$status_json")
  last_line=$(jq -r '.tick_log.last_line // ""' <<<"$status_json")

  # Compose agent cell
  local agent_cell
  if [[ "$agent_state" == "running" ]]; then
    local mm=$(( claimed_ago / 60 )) ss=$(( claimed_ago % 60 ))
    agent_cell="${GREEN}● running${RESET} ${BOLD}${role}${RESET} → ${BOLD}${target}${RESET} (${mm}m${ss}s)"
  else
    agent_cell="${DIM}○ idle${RESET}"
  fi

  # Launchd cell — paused if ROLLBACK marker exists
  local launchd_cell
  if [[ -f "$ROLLBACK_MARKER" ]]; then
    launchd_cell="${RED}⏸ PAUSED (ROLLBACK marker)${RESET}"
  elif [[ "$launchd_state" == "loaded" ]]; then
    launchd_cell="${GREEN}loaded${RESET} · next tick ${next_tick}s"
  else
    launchd_cell="${RED}${launchd_state}${RESET}"
  fi

  printf '%s' "$CLEAR"
  printf '%s🐝 git-bee dashboard%s   %s%s%s   refresh=%ss (Ctrl-C to exit)\n' \
    "$BOLD" "$RESET" "$DIM" "$now" "$RESET" "$INTERVAL"
  hline

  printf '%s launchd:%s  %s\n' "$CYAN" "$RESET" "$launchd_cell"
  printf '%s agent:%s    %s\n' "$CYAN" "$RESET" "$agent_cell"

  # Health badges
  local badges=""
  (( human_items > 0 ))     && badges+=" ${RED}${human_items} breeze:human${RESET}"
  (( abandoned > 0 ))       && badges+=" ${YELLOW}${abandoned} abandoned${RESET}"
  (( stale > 0 ))           && badges+=" ${YELLOW}${stale} stale-claim${RESET}"
  [[ -z "$badges" ]]        && badges=" ${GREEN}healthy${RESET}"
  printf '%s health:%s   %b\n' "$CYAN" "$RESET" "$badges"
  printf '%s tick.log:%s %s%s%s\n' "$CYAN" "$RESET" "$DIM" "$last_line" "$RESET"

  hline
  printf '%s Recent dispatches (last 8)%s\n' "$BOLD" "$RESET"
  if [[ -f "$TICK_LOG" ]]; then
    # Use a temporary variable to capture the read, avoiding partial line issues
    local dispatches
    if dispatches=$(grep -E 'dispatch: kind=|agent exited' "$TICK_LOG" 2>/dev/null | tail -8); then
      echo "$dispatches" | \
        sed -E "s/^([0-9T:Z-]+)/${DIM}\1${RESET}/" | \
        sed -E "s/(dispatch: kind=[a-z0-9-]+)/${GREEN}\1${RESET}/" | \
        sed -E "s/(agent exited non-zero \([0-9]+\))/${RED}\1${RESET}/" | \
        sed -E "s/(agent exited cleanly)/${GREEN}\1${RESET}/" | \
        sed 's/^/  /'
    else
      printf '  %s(could not read tick.log)%s\n' "$DIM" "$RESET"
    fi
  else
    printf '  %s(no tick.log yet)%s\n' "$DIM" "$RESET"
  fi

  hline
  printf '%s Open PRs (%d)%s\n' "$BOLD" "$prs_open" "$RESET"
  local pr_data
  if pr_data=$(gh pr list --repo "$REPO" --state open --limit 20 \
    --json number,title,labels,isDraft 2>/dev/null); then
    echo "$pr_data" | \
      jq -r '.[] | "\(.number)\t\([.labels[].name] | map(select(startswith("breeze:"))) | join(",") // "")\t\(if .isDraft then "DRAFT " else "" end)\(.title)"' | \
      while IFS=$'\t' read -r num lbls rest; do
        local lbl_colored=""
        case "$lbls" in
          *breeze:wip*)   lbl_colored="${YELLOW}wip${RESET}" ;;
          *breeze:human*) lbl_colored="${RED}human${RESET}" ;;
          *breeze:done*)  lbl_colored="${GREEN}done${RESET}" ;;
          *)              lbl_colored="${DIM}new${RESET}" ;;
        esac
        printf '  %s#%s%s  %-6b  %s\n' "$BLUE" "$num" "$RESET" "$lbl_colored" "$rest"
      done
  else
    printf '  %s(GitHub API error - could not fetch PRs)%s\n' "$RED" "$RESET"
  fi

  hline
  printf '%s Open issues (%d) — breeze:human flagged%s\n' "$BOLD" "$issues_open" "$RESET"
  local issue_data
  if issue_data=$(gh issue list --repo "$REPO" --state open --limit 20 \
    --json number,title,labels 2>/dev/null); then
    echo "$issue_data" | \
      jq -r '.[] | "\(.number)\t\(([.labels[].name] | map(select(startswith("breeze:"))) | join(",")) // "-")\t\(.title)"' | \
      awk -F'\t' '{ if ($2 == "") $2 = "-"; OFS="\t"; print }' | \
      while IFS=$'\t' read -r num lbls rest; do
        local lbl_colored=""
        case "$lbls" in
          *breeze:human*) lbl_colored="${RED}human${RESET}" ;;
          *breeze:wip*)   lbl_colored="${YELLOW}wip${RESET}" ;;
          *breeze:done*)  lbl_colored="${GREEN}done${RESET}" ;;
          *)              lbl_colored="${DIM}new${RESET}" ;;
        esac
        printf '  %s#%s%s  %-6b  %s\n' "$BLUE" "$num" "$RESET" "$lbl_colored" "$rest"
      done
  else
    printf '  %s(GitHub API error - could not fetch issues)%s\n' "$RED" "$RESET"
  fi
}

trap 'printf "\n%sdashboard stopped.%s\n" "$DIM" "$RESET"; exit 0' INT TERM

if (( ONCE )); then
  render
  exit 0
fi

while true; do
  render
  sleep "$INTERVAL"
done
