#!/usr/bin/env bash
# git-bee tick: one pass of the scheduler.
#
# Guards (in order):
#   1. Local PID lock — if an agent is already running on this machine, exit.
#   2. GitHub state — find the oldest open issue/PR without a fresh breeze:wip.
#   3. If no unclaimed open items exist, project is finalized. Exit quietly.
#
# Invoked by launchd every 15 minutes.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/claim.sh"

REPO="serenakeyitan/git-bee"
LOCK="/tmp/git-bee-agent.pid"
LOG_DIR="${HOME}/.git-bee"
LOG="${LOG_DIR}/tick.log"
TICK_HISTORY="${LOG_DIR}/tick-history.log"
ROLLBACK_MARKER="${LOG_DIR}/ROLLBACK"
mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# EXIT trap for tick history logging
TICK_START_SHA=""
record_tick_exit() {
  local exit_code=$?
  if [[ -n "$TICK_START_SHA" ]]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $exit_code $TICK_START_SHA" >> "$TICK_HISTORY"

    # Log rotation at 1000 lines
    if [[ -f "$TICK_HISTORY" ]] && (( $(wc -l < "$TICK_HISTORY") > 1000 )); then
      tail -n 1000 "$TICK_HISTORY" > "$TICK_HISTORY.tmp"
      mv "$TICK_HISTORY.tmp" "$TICK_HISTORY"
    fi
  fi
}
trap record_tick_exit EXIT

# Capture current SHA at start
TICK_START_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Guard -0: 3-consecutive-crash detector
if [[ -f "$TICK_HISTORY" ]]; then
  # Count non-zero exits in last 3 ticks (Guard 0 exits with 0 by design)
  crashes=$(tail -n 3 "$TICK_HISTORY" 2>/dev/null | awk '$2 != 0' | wc -l | xargs)

  if [[ "$crashes" == "3" ]]; then
    log "ROLLBACK: 3 consecutive crashes detected"

    # Find the most recent known-good SHA (last exit 0)
    last_good=$(awk '$2 == 0 {sha=$3} END {print sha}' "$TICK_HISTORY" 2>/dev/null || echo "")

    if [[ -n "$last_good" && "$last_good" != "unknown" ]]; then
      log "Rolling back to last known-good SHA: $last_good"
      git -C "$REPO_ROOT" checkout "$last_good" 2>&1 | tee -a "$LOG"

      # Write ROLLBACK marker
      cat > "$ROLLBACK_MARKER" <<EOF
Automatic rollback triggered at $(date -u +%Y-%m-%dT%H:%M:%SZ)
Reason: 3 consecutive non-zero tick exits
Rolled back to: $last_good
Remove this file to resume normal operation.
EOF

      # Create breeze:human issue
      issue_body=$(cat <<EOF
**Automatic rollback triggered**

The git-bee tick loop detected 3 consecutive crashes and rolled back to the last known-good commit.

- **Time**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- **Rolled back to**: $last_good
- **Current SHA before rollback**: $TICK_START_SHA

**Action required**:
1. Investigate the crashes in \`~/.git-bee/tick.log\`
2. Fix the underlying issue
3. Remove \`~/.git-bee/ROLLBACK\` to resume the tick loop

The tick loop is now paused and will not dispatch agents until the ROLLBACK marker is removed.
EOF
)

      gh issue create --repo "$REPO" \
        --title "Automatic rollback: 3 consecutive tick crashes detected" \
        --body "$issue_body" \
        --label "breeze:human,priority:high" 2>&1 | tee -a "$LOG" || true
    else
      log "WARNING: Could not find a known-good SHA in tick history"
    fi
  fi
fi

# Guard -1: ROLLBACK marker — if it exists, exit early without dispatching
if [[ -f "$ROLLBACK_MARKER" ]]; then
  log "ROLLBACK marker exists — ticks paused. Remove $ROLLBACK_MARKER to resume."
  exit 0
fi

# Guard 0: credential healthcheck. A tick that runs with expired gh auth
# produces the same "idle: nothing to do" log line as a finalized project,
# which silently breaks the loop. Fail loudly and exit instead.
if ! gh auth status >/dev/null 2>&1; then
  log "CREDENTIAL EXPIRED — gh auth status failed; skipping tick. Run 'gh auth login'."
  exit 0
fi

# Guard 1: local PID lock
# Runs before the notification scanner so that a running agent blocks scanning
# too — the scanner makes GitHub API calls we don't want piled on an already-
# busy tick, and any issues it creates would sit behind the current agent's
# claim anyway.
if [[ -f "$LOCK" ]]; then
  pid=$(cat "$LOCK" 2>/dev/null || echo "")
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    log "skip: agent already running (pid=$pid)"
    exit 0
  fi
  log "stale lock (pid=$pid), removing"
  rm -f "$LOCK"
fi

# Guard 1b: reset working tree to origin/main.
# ~/git-bee is shared state between the cron and the running agents. Agents
# check out feature branches to do drafter/merger work and sometimes exit
# without restoring main. The next tick would then run whatever scripts are
# on that feature branch — which may be a buggy older version. On 2026-04-20
# this caused notification-scanner to create 127 junk issues (#576–#702).
# The lock guard above proves no agent is running, so it's safe to checkout.
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  current_branch=$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo "DETACHED")
  if [[ "$current_branch" != "main" ]]; then
    log "working tree on '$current_branch', resetting to origin/main"
  fi
  git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true
  git -C "$REPO_ROOT" checkout main --quiet 2>/dev/null || true
  git -C "$REPO_ROOT" reset --hard origin/main --quiet 2>/dev/null || true
fi

# Run notification scanner after the lock guard. No-op by default (empty
# watchlist); only fires for repos the user explicitly added via `bee watch`.
if [[ -x "$HERE/notification-scanner.sh" ]]; then
  log "running notification scanner"
  "$HERE/notification-scanner.sh" 2>&1 | tee -a "$LOG" || log "notification scanner failed (rc=$?)"
fi

# Guard 2: find work
# Priority order (PRs beat issues — if an issue already has a linked PR,
# the PR is the next actionable step):
#   1. approved PRs → e2e agent
#   2. unreviewed open PRs → reviewer agent
#   3. issues with NO linked open PR and no breeze:wip → drafter agent
pick_target() {
  # Emits "<kind> <number>" to stdout, nothing if idle.

  local pr_basics
  pr_basics=$(gh pr list --repo "$REPO" --state open --search "sort:created-asc" --limit 50 \
    --json number,reviewDecision,labels,reviews,comments 2>/dev/null || echo "[]")
  # Priority sort: priority:high first, then original (created-asc) order.
  pr_basics=$(echo "$pr_basics" | jq '[ .[] | . as $p | $p + {_prio: (if ($p.labels | map(.name) | index("priority:high")) then 0 else 1 end)} ] | sort_by(._prio) | map(del(._prio))')

  # 1. Approved PRs that also have a passing E2E trace → merger.
  # "Approved" = reviewDecision == APPROVED OR a review body contains the marker.
  # "E2E pass" = any PR issue-comment contains "**E2E trace (pass)**".
  local mergeable_prs
  mergeable_prs=$(echo "$pr_basics" | jq -r '
    .[]
    | select(.labels | map(.name) | index("breeze:wip") | not)
    | select(.labels | map(.name) | index("breeze:human") | not)
    | select(
        .reviewDecision == "APPROVED"
        or any(.reviews[]?.body // ""; contains("<!-- bee:approved-for-e2e -->"))
      )
    | select(any(.comments[]?.body // ""; contains("**E2E trace (pass)**")))
    | .number
  ' 2>/dev/null || true)
  if [[ -n "$mergeable_prs" ]]; then
    echo "merger $(echo "$mergeable_prs" | head -1)"
    return
  fi

  # 1b. PRs with E2E trace that needs supervisor classification
  local traced_prs
  traced_prs=$(echo "$pr_basics" | jq -r '
    .[]
    | select(.labels | map(.name) | index("breeze:wip") | not)
    | select(.labels | map(.name) | index("breeze:human") | not)
    | select(any(.comments[]?.body // ""; contains("**E2E trace")))
    | select(any(.comments[]?.body // ""; contains("**E2E trace (pass)**")) | not)
    | select(any(.comments[]?.body // ""; contains("**e2e-supervisor:")) | not)
    | .number
  ' 2>/dev/null || true)
  if [[ -n "$traced_prs" ]]; then
    echo "e2e-supervisor $(echo "$traced_prs" | head -1)"
    return
  fi

  # 1b'. PRs with a supervisor verdict — route based on the verdict. The
  # `pass` verdict is covered by the approved+E2E-trace-pass route above,
  # so here we only need to handle the five non-pass outcomes.
  #
  # A verdict is STALE if drafter or e2e has posted a comment after it — that
  # means the bug was already addressed and we need a fresh E2E run to judge
  # the new state, not to re-trigger the same role on every tick (hot-loop).
  local supervised
  supervised=$(echo "$pr_basics" | jq -r '
    .[]
    | . as $pr
    | select($pr.labels | map(.name) | index("breeze:wip") | not)
    | select($pr.labels | map(.name) | index("breeze:human") | not)
    | ([$pr.comments[]? | select(.body // "" | test("\\*\\*e2e-supervisor: (pass|lazy-run|code-bug|test-bug|design-trivial|design-conflicting)\\*\\*"))]
        | sort_by(.createdAt) | last) as $v
    | select($v != null)
    | ([$pr.comments[]? | select(.createdAt > $v.createdAt) | select(.body // "" | test("^\\*\\*(drafter|e2e):"))] | length) as $followups
    | select($followups == 0)
    | ($v.body | capture("\\*\\*e2e-supervisor: (?<verdict>pass|lazy-run|code-bug|test-bug|design-trivial|design-conflicting)\\*\\*").verdict) as $vd
    | "\($pr.number) \($vd)"
  ' 2>/dev/null || true)
  if [[ -n "$supervised" ]]; then
    while IFS= read -r row; do
      [[ -z "$row" ]] && continue
      local pr_n="${row%% *}" vd="${row##* }"
      case "$vd" in
        lazy-run)  echo "e2e $pr_n"; return ;;
        code-bug)  echo "drafter $pr_n"; return ;;
        test-bug)  echo "e2e-designer $pr_n"; return ;;
        design-conflicting)
          # Belt-and-suspenders: supervisor should have applied breeze:human,
          # but ensure it's labeled so this tick never re-dispatches.
          gh issue edit "$pr_n" --repo "$REPO" --add-label "breeze:human" >/dev/null 2>&1 || true
          log "skip: #$pr_n design-conflicting — labeled breeze:human, held for human"
          ;;
        design-trivial|pass) : ;;  # handled elsewhere / nothing to do
      esac
    done <<< "$supervised"
  fi

  # 1c. Approved PRs without an E2E trace yet → E2E.
  local approved_prs
  approved_prs=$(echo "$pr_basics" | jq -r '
    .[]
    | select(.labels | map(.name) | index("breeze:wip") | not)
    | select(.labels | map(.name) | index("breeze:human") | not)
    | select(
        .reviewDecision == "APPROVED"
        or any(.reviews[]?.body // ""; contains("<!-- bee:approved-for-e2e -->"))
      )
    | select(any(.comments[]?.body // ""; contains("**E2E trace")) | not)
    | .number
  ' 2>/dev/null || true)
  if [[ -n "$approved_prs" ]]; then
    echo "e2e $(echo "$approved_prs" | head -1)"
    return
  fi

  # 2. PRs needing a reviewer — no review yet at current HEAD SHA.
  # We inspect reviews, not reviewDecision: "COMMENTED" still leaves
  # reviewDecision empty, but means a review exists.
  local pr_rows
  pr_rows=$(gh pr list --repo "$REPO" --state open --search "sort:created-asc" --limit 50 \
    --json number,reviewDecision,labels,reviews,headRefOid 2>/dev/null || echo "[]")
  pr_rows=$(echo "$pr_rows" | jq '[ .[] | . as $p | $p + {_prio: (if ($p.labels | map(.name) | index("priority:high")) then 0 else 1 end)} ] | sort_by(._prio) | map(del(._prio))')

  local unreviewed_prs
  unreviewed_prs=$(echo "$pr_rows" | jq -r '
    .[]
    | . as $pr
    | select($pr.labels | map(.name) | index("breeze:wip") | not)
    | select($pr.labels | map(.name) | index("breeze:human") | not)
    | select([$pr.reviews[]? | select(.commit.oid == $pr.headRefOid)] | length == 0)
    | $pr.number
  ' 2>/dev/null || true)
  if [[ -n "$unreviewed_prs" ]]; then
    echo "reviewer $(echo "$unreviewed_prs" | head -1)"
    return
  fi

  # 2b. PRs with a review at HEAD but not approved + no e2e marker → drafter.
  # Guard against re-dispatching drafter on a PR it just updated:
  # only match if no approval marker is present AND a review at HEAD exists.
  local feedback_prs
  feedback_prs=$(echo "$pr_rows" | jq -r '
    .[]
    | . as $pr
    | select($pr.labels | map(.name) | index("breeze:wip") | not)
    | select($pr.labels | map(.name) | index("breeze:human") | not)
    | select($pr.reviewDecision != "APPROVED")
    | select(any($pr.reviews[]?.body // ""; contains("<!-- bee:approved-for-e2e -->")) | not)
    | select([$pr.reviews[]? | select(.commit.oid == $pr.headRefOid)] | length > 0)
    | $pr.number
  ' 2>/dev/null || true)
  if [[ -n "$feedback_prs" ]]; then
    echo "drafter $(echo "$feedback_prs" | head -1)"
    return
  fi

  # 3. issues with no linked OPEN PR and no breeze:wip
  # We detect linkage by scanning open PR bodies for "Fixes #N" / "Closes #N".
  local open_pr_bodies
  open_pr_bodies=$(gh pr list --repo "$REPO" --state open --limit 50 \
    --json body --jq '.[].body' 2>/dev/null || true)

  local all_open_issues
  all_open_issues=$(gh issue list --repo "$REPO" --state open --search "sort:created-asc" --limit 50 \
    --json number,labels \
    --jq '[ .[]
            | select(.labels | map(.name) | index("breeze:wip") | not)
            | select(.labels | map(.name) | index("breeze:human") | not)
            | . + {_prio: (if (.labels | map(.name) | index("priority:high")) then 0 else 1 end)} ]
          | sort_by(._prio)
          | .[].number' 2>/dev/null || true)

  for n in $all_open_issues; do
    if echo "$open_pr_bodies" | grep -qiE "(fixes|closes|resolves)[[:space:]]+#${n}\b"; then
      continue
    fi
    # Mechanical finalization-gate check (design-doc issues only).
    # Exit 0 = gate open, 1 = closed, 2 = ticked by non-owner, 3 = not a design doc.
    # We silently skip (1) and (2); (3) means the gate doesn't apply and we dispatch.
    if [[ -x "$HERE/gate-check.sh" ]]; then
      set +e
      "$HERE/gate-check.sh" "$REPO" "$n" >/dev/null 2>&1
      gate_rc=$?
      set -e
      if [[ "$gate_rc" == "1" || "$gate_rc" == "2" ]]; then
        log "skip: #$n gate-check rc=$gate_rc (closed or non-owner tick)"
        continue
      fi
      # If gate is open (rc=0), check for Phase 2 routing
      if [[ "$gate_rc" == "0" ]]; then
        local issue_body
        issue_body=$(gh issue view "$n" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")

        # Check for milestone plan
        if ! echo "$issue_body" | grep -q "^## Milestone plan"; then
          echo "planner $n"
          return
        fi

        # Check for E2E test plan
        if ! echo "$issue_body" | grep -q "^## E2E test plan"; then
          echo "e2e-designer $n"
          return
        fi

        # Check if plan confirmation gate is checked
        if echo "$issue_body" | grep -q "^- \[x\] \*\*plan confirmed"; then
          # If every PR number enumerated in the milestone plan is merged, route
          # to the auditor. Otherwise continue with drafter.
          # grep returns 1 when no match; under `set -euo pipefail` that aborts
          # the whole function silently. Wrap so an empty plan list is a valid
          # "no PRs enumerated" signal, not a fatal error.
          local plan_prs
          plan_prs=$({ echo "$issue_body" | awk '/^## Milestone plan/,/^## /' \
            | grep -oE '^### PR [0-9]+' | grep -oE '[0-9]+' | sort -u; } || true)
          if [[ -n "$plan_prs" ]]; then
            local all_merged=1
            local any_pr=0
            while IFS= read -r pr_ref; do
              [[ -z "$pr_ref" ]] && continue
              any_pr=1
              # Look for a merged PR whose body contains "PR <ref>" heading or
              # whose title starts with "PR <ref>". We approximate by checking
              # that SOME merged PR references this milestone slot via its
              # linked issue body — cheap heuristic: scan closed PRs' titles.
              local slot_hit
              slot_hit=$(gh pr list --repo "$REPO" --state merged --search "PR $pr_ref in:title" --json number --jq 'length' 2>/dev/null || echo 0)
              if [[ "$slot_hit" == "0" ]]; then
                all_merged=0
                break
              fi
            done <<< "$plan_prs"
            if [[ "$any_pr" == "1" && "$all_merged" == "1" ]]; then
              echo "auditor $n"
              return
            fi
          fi
          # Plan is confirmed, proceed to drafter
          echo "drafter $n"
          return
        else
          # Has test plan but needs supervisor review
          echo "e2e-supervisor $n"
          return
        fi
      fi
    fi
    echo "drafter $n"
    return
  done
}

target=$(pick_target)

if [[ -z "$target" ]]; then
  # Pause-don't-stop: distinguish "all open work paused on human" from
  # genuine "nothing to do", so the tick log makes it visible when the
  # loop is blocked on human action rather than finalized.
  paused_count=$(gh issue list --repo "$REPO" --state open --label "breeze:human" --json number --jq 'length' 2>/dev/null || echo 0)
  paused_count=$(( paused_count + $(gh pr list --repo "$REPO" --state open --label "breeze:human" --json number --jq 'length' 2>/dev/null || echo 0) ))
  if (( paused_count > 0 )); then
    log "idle: all open work paused on human (${paused_count} item(s) with breeze:human)"
  else
    log "idle: no unclaimed open items — project finalized or nothing to do"
  fi
  exit 0
fi

kind="${target%% *}"
number="${target##* }"
log "dispatch: kind=$kind target=#$number"
DISPATCH_START_TS=$SECONDS

# Acquire claim BEFORE spawning, so concurrent ticks don't dispatch twice
agent_id="${kind}-$(hostname -s)"
if ! claim_acquire "$REPO" "$number" "$agent_id"; then
  log "lost race to acquire claim on #$number, exiting"
  exit 0
fi

# Write the PID lock BEFORE spawning so an unexpected failure can't orphan
# the GitHub claim without also showing on the local filesystem. The release
# trap takes both down together.
echo $$ > "$LOCK"
release_all() {
  # Keep the label to prevent churn if the item is still open (common case)
  # Only explicit "done" paths should remove the label
  claim_release "$REPO" "$number" "$agent_id" "true" 2>/dev/null || true
  rm -f "$LOCK"
}
# EXIT fires for normal and non-zero exits. Trap SIGINT/TERM/HUP explicitly so
# a Ctrl-C or launchd stop doesn't orphan `breeze:wip` + the PID lock; SIGKILL
# can't be trapped (stale claims then clear on the next tick via
# claim_check's TTL path).
trap release_all EXIT INT TERM HUP

role_prompt_file="$REPO_ROOT/agents/${kind}.md"
if [[ ! -f "$role_prompt_file" ]]; then
  log "ERROR: no role prompt at $role_prompt_file"
  exit 1
fi

# Runtime: claude -p in bypass mode. Set CLAUDE_BIN env to override.
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

prompt=$(cat <<PROMPT_EOF
You are acting in the role defined by @${role_prompt_file}.

Your target is ${REPO}#${number}.
Your agent id for this run is ${agent_id}.

Read the role prompt, read the target issue/PR, and do the work described there.
When you finish (or give up), exit cleanly. The tick wrapper will release the
claim automatically on exit.

CRITICAL — never push to main. All code lands via PRs on feature branches.
If you run any 'git push' in a Bash tool call, source the guard first:
  source ${REPO_ROOT}/scripts/preflight-push.sh && git push ...
The guard hard-refuses pushes whose target ref is 'main' or 'master'.
Using 'Closes #<pr>' in a commit body that lands directly on main will
auto-close the PR without merging it. This happened on PR #551 — see #555.
PROMPT_EOF
)

# macOS notifier — no-op on non-Darwin or if osascript is missing. Never
# fails the tick (|| true at call sites).
notify() {
  command -v osascript >/dev/null 2>&1 || return 0
  local title="$1" body="$2"
  osascript -e "display notification \"${body//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1 || true
}

log "spawning ${CLAUDE_BIN} for role=${kind} target=#${number}"
"$REPO_ROOT/scripts/activity.sh" start "$REPO" "$kind" "$number" "$agent_id" 2>/dev/null || true
"$CLAUDE_BIN" -p "$prompt" --permission-mode bypassPermissions 2>&1 | tee -a "$LOG" || {
  exit_code=$?
  log "agent exited non-zero (${exit_code}) for #${number}"
  "$REPO_ROOT/scripts/activity.sh" end "$REPO" "$kind" "$number" "$agent_id" "$exit_code" "$(( SECONDS - DISPATCH_START_TS ))" 2>/dev/null || true
  notify "🐝 ${kind} failed" "#${number} exited ${exit_code} after $(( (SECONDS - DISPATCH_START_TS) / 60 ))m$(( (SECONDS - DISPATCH_START_TS) % 60 ))s"
  exit "$exit_code"
}

log "agent exited cleanly for #${number}"
"$REPO_ROOT/scripts/activity.sh" end "$REPO" "$kind" "$number" "$agent_id" 0 "$(( SECONDS - DISPATCH_START_TS ))" 2>/dev/null || true
notify "🐝 ${kind} done" "#${number} finished in $(( (SECONDS - DISPATCH_START_TS) / 60 ))m$(( (SECONDS - DISPATCH_START_TS) % 60 ))s"
