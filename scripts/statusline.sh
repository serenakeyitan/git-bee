#!/usr/bin/env bash
# git-bee + breeze Claude Code statusline
# Line 1: 🐝 git-bee: <role→#N or last-action> · next <N> · issues: #A,#B · PRs: #C,#D
# Line 2: output of /breeze statusline (from breeze repo)

set -uo pipefail

BEE_SCRIPT="$HOME/git-bee/scripts/bee"
TICK_LOG="$HOME/.git-bee/tick.log"
BREEZE_STATUSLINE="$HOME/breeze/bin/breeze-statusline-wrapper"
CACHE_FILE="/tmp/git-bee-statusline-cache"
CACHE_TTL=30
REPO="serenakeyitan/git-bee"

# ── 1. bee line ──────────────────────────────────────────────────────────────
bee_line="🐝 git-bee: offline"
if [[ -x "$BEE_SCRIPT" ]]; then
  # `bee status` exits 1 when breeze:human items exist — capture output
  # regardless of exit code, otherwise the statusline goes silent exactly
  # when there's something interesting to show.
  bee_out=$("$BEE_SCRIPT" status 2>/dev/null || true)
  if [[ -n "$bee_out" ]]; then
    agent_raw=$(printf '%s\n' "$bee_out" | grep -i '^agent:' | head -1 | sed 's/^agent:[[:space:]]*//')
    launchd_raw=$(printf '%s\n' "$bee_out" | grep -i '^launchd:' | head -1)

    # Role → verb mapping. drafter is "coding" on a PR and "planning" on an issue.
    role_to_verb() {
      case "$1" in
        drafter)
          case "$2" in
            \#*) # target is an issue or PR; look at the second arg for disambiguation
              echo "coding" ;;
            *)
              echo "drafting" ;;
          esac
          ;;
        reviewer) echo "reviewing" ;;
        e2e) echo "testing" ;;
        merger) echo "merging" ;;
        *) echo "${1:-?}" ;;
      esac
    }

    if [[ "$agent_raw" == *"running"* ]]; then
      role=$(printf '%s' "$agent_raw" | grep -oE 'role=[a-z0-9-]+' | head -1 | sed 's/role=//')
      target=$(printf '%s' "$agent_raw" | grep -oE 'target=#[0-9]+' | head -1 | sed 's/target=//')
      claimed=$(printf '%s' "$agent_raw" | grep -oE 'claimed [0-9]+:[0-9]+:[0-9]+' | head -1 | sed 's/claimed //')

      # drafter is "coding" when the target is a PR, "planning" when an issue.
      if [[ "$role" == "drafter" && -n "$target" ]]; then
        num=${target#\#}
        if gh pr view "$num" --repo "$REPO" --json number >/dev/null 2>&1; then
          verb="coding"
        else
          verb="planning"
        fi
      else
        verb=$(role_to_verb "$role" "$target")
      fi

      if [[ -n "$claimed" ]]; then
        hh=${claimed%%:*}
        rest=${claimed#*:}
        mm=${rest%%:*}
        if [[ "$hh" != "00" ]]; then
          compact="${hh#0}h${mm#0}m"
        else
          compact="${mm#0}m"
          [[ -z "$compact" || "$compact" == "m" ]] && compact="<1m"
        fi
        state="${verb} ${target:-?} (${compact})"
      else
        state="${verb} ${target:-?}"
      fi
    else
      # Idle: show last agent's activity as verb
      last_done=""
      if [[ -f "$TICK_LOG" ]]; then
        last_dispatch=$(grep -E 'dispatch: kind=' "$TICK_LOG" 2>/dev/null | tail -1)
        if [[ -n "$last_dispatch" ]]; then
          lrole=$(printf '%s' "$last_dispatch" | grep -oE 'kind=[a-z0-9-]+' | head -1 | sed 's/kind=//')
          ltarget=$(printf '%s' "$last_dispatch" | grep -oE 'target=#[0-9]+' | head -1 | sed 's/target=//')
          lverb=$(role_to_verb "$lrole" "$ltarget")
          last_done="idle after ${lverb} ${ltarget}"
        fi
      fi
      [[ -z "$last_done" ]] && last_done="idle"
      state="$last_done"
    fi

    if [[ "$launchd_raw" == *"after agent"* ]]; then
      next_tick="after ${role:-agent}"
    else
      next_tick=$(printf '%s\n' "$launchd_raw" | grep -oE '[0-9]+m([0-9]+s)?|[0-9]+s' | head -1)
      [[ -z "$next_tick" ]] && next_tick="?"
    fi

    # Paused count (breeze:human-labeled items), cached.
    now=$(date +%s)
    use_cache=0
    if [[ -f "$CACHE_FILE" ]]; then
      cached_epoch=$(sed -n '1p' "$CACHE_FILE" 2>/dev/null)
      if [[ -n "$cached_epoch" ]] && (( now - cached_epoch < CACHE_TTL )); then
        paused_count=$(sed -n '2p' "$CACHE_FILE")
        use_cache=1
      fi
    fi
    if (( use_cache == 0 )); then
      paused_issues=$(gh issue list --repo "$REPO" --state open --label "breeze:human" --json number --jq 'length' 2>/dev/null || echo 0)
      paused_prs=$(gh pr list --repo "$REPO" --state open --label "breeze:human" --json number --jq 'length' 2>/dev/null || echo 0)
      paused_count=$(( paused_issues + paused_prs ))
      printf '%s\n%s\n' "$now" "$paused_count" > "$CACHE_FILE"
    fi
    [[ -z "$paused_count" ]] && paused_count=0

    bee_line="🐝 git-bee: ${state} · next ${next_tick}"
    if (( paused_count > 0 )); then
      bee_line="${bee_line} · ⚠ ${paused_count} paused"
    fi
  fi
fi

# ── 2. breeze line ───────────────────────────────────────────────────────────
breeze_line=""
if [[ -x "$BREEZE_STATUSLINE" ]]; then
  # wrapper expects stdin; just pipe empty input
  breeze_line=$(printf '' | "$BREEZE_STATUSLINE" 2>/dev/null | tail -1)
fi
[[ -z "$breeze_line" ]] && breeze_line="/breeze: offline"

printf '%s\n%s\n' "$bee_line" "$breeze_line"
