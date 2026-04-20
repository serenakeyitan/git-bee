#!/usr/bin/env bash
# git-bee Claude Code statusline
# Outputs one line: 🐝 <agent-state> · <latest-action> · next <N>m · <issues> issue(s), <PRs> PR(s)
# Must complete in < 500ms. GitHub counts cached 30s in /tmp/git-bee-statusline-cache.

set -euo pipefail

BEE_STATUS_CMD="$HOME/git-bee/bee"
TICK_LOG="$HOME/.git-bee/tick.log"
CACHE_FILE="/tmp/git-bee-statusline-cache"
CACHE_TTL=30  # seconds
REPO="serenakeyitan/git-bee"

# ── 1. Run bee status ────────────────────────────────────────────────────────
bee_out=""
if [[ -x "$BEE_STATUS_CMD" ]]; then
  bee_out=$("$BEE_STATUS_CMD" status 2>/dev/null) || bee_out=""
fi

if [[ -z "$bee_out" ]]; then
  printf '🐝 offline\n'
  exit 0
fi

# ── 2. Parse agent state ─────────────────────────────────────────────────────
# "agent:" line: either "idle" or "role → #N"
agent_line=$(printf '%s\n' "$bee_out" | grep -i '^agent:' | head -1)
agent_raw=$(printf '%s\n' "$agent_line" | sed 's/^agent:[[:space:]]*//')

if [[ "$agent_raw" == *"idle"* ]] || [[ -z "$agent_raw" ]]; then
  agent_state="idle"
else
  # Normalise any arrow variants (→, ->, =>) to →
  agent_state=$(printf '%s' "$agent_raw" | sed 's/->/ → /g; s/=>/ → /g')
fi

# ── 3. Parse next launchd tick countdown ────────────────────────────────────
# "launchd:" line expected to contain something like "next tick in 2m" or "2m30s"
launchd_line=$(printf '%s\n' "$bee_out" | grep -i '^launchd:' | head -1)
next_tick=""
if [[ -n "$launchd_line" ]]; then
  # Extract first occurrence of a duration like "2m", "30s", "1m30s"
  next_tick=$(printf '%s\n' "$launchd_line" | grep -oE '[0-9]+m([0-9]+s)?|[0-9]+s' | head -1)
fi
if [[ -n "$next_tick" ]]; then
  next_part="next $next_tick"
else
  next_part=""
fi

# ── 4. Latest action verb from tick.log ─────────────────────────────────────
latest_action=""
if [[ -f "$TICK_LOG" ]]; then
  # Look at last ~40 lines for structured log entries (timestamp + verb keyword)
  tail_lines=$(tail -40 "$TICK_LOG" 2>/dev/null)

  # Priority: last timestamped line that contains a known verb
  # Timestamped lines look like: 2026-04-19T07:20:18Z <verb> ...
  last_ts_line=$(printf '%s\n' "$tail_lines" \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ' \
    | tail -1)

  if [[ -n "$last_ts_line" ]]; then
    # Strip timestamp prefix, grab first word as the verb
    verb=$(printf '%s\n' "$last_ts_line" | sed 's/^[^ ]* //' | awk '{print $1}')
    case "$verb" in
      spawning|dispatch|idle|exited)
        latest_action="$verb"
        ;;
      *)
        # Try to find a meaningful keyword further in the line
        if printf '%s\n' "$last_ts_line" | grep -qi 'Created PR\|opened PR'; then
          latest_action="Created PR"
        elif printf '%s\n' "$last_ts_line" | grep -qi 'exited'; then
          latest_action="exited"
        else
          latest_action="$verb"
        fi
        ;;
    esac
  fi
fi

# ── 5. GitHub open issue + PR counts (cached 30s) ───────────────────────────
issues=0
prs=0

now=$(date +%s)
cache_valid=false
if [[ -f "$CACHE_FILE" ]]; then
  cache_ts=$(head -1 "$CACHE_FILE" 2>/dev/null || echo 0)
  if (( now - cache_ts < CACHE_TTL )); then
    cache_valid=true
    issues=$(sed -n '2p' "$CACHE_FILE" 2>/dev/null || echo 0)
    prs=$(sed -n '3p'    "$CACHE_FILE" 2>/dev/null || echo 0)
  fi
fi

if ! $cache_valid; then
  if command -v gh &>/dev/null; then
    issues=$(gh issue list --repo "$REPO" --state open --json number --jq length 2>/dev/null || echo 0)
    prs=$(gh pr list    --repo "$REPO" --state open --json number --jq length 2>/dev/null || echo 0)
    printf '%s\n%s\n%s\n' "$now" "$issues" "$prs" >"$CACHE_FILE" 2>/dev/null || true
  fi
fi

# ── 6. Assemble output line ──────────────────────────────────────────────────
parts=("🐝" "$agent_state")

[[ -n "$latest_action" ]] && parts+=("·" "$latest_action")
[[ -n "$next_part"     ]] && parts+=("·" "$next_part")

issue_word="issue"; [[ "$issues" != "1" ]] && issue_word="issues"
pr_word="PR";       [[ "$prs"    != "1" ]] && pr_word="PRs"
parts+=("·" "${issues} ${issue_word}, ${prs} ${pr_word}")

printf '%s\n' "${parts[*]}"
