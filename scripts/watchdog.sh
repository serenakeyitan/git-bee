#!/usr/bin/env bash
# git-bee watchdog: deadman switch for tick loop wedges.
#
# Invoked by launchd every 5 minutes (same cadence as tick.sh).
# If the heartbeat file is older than 3 tick intervals (15 minutes),
# logs WEDGED to ~/.git-bee/HEALTH and files an alert issue.
#
# Issue #798 M2/PR 6

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck disable=SC1091
source "$HERE/labels.sh"

REPO="serenakeyitan/git-bee"
LOG_DIR="${HOME}/.git-bee"
HEARTBEAT_FILE="${LOG_DIR}/heartbeat"
HEALTH_FILE="${LOG_DIR}/HEALTH"
WATCHDOG_LOG="${LOG_DIR}/watchdog.log"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$WATCHDOG_LOG" >&2; }

mkdir -p "$LOG_DIR"

log "watchdog start (pid=$$)"

# If heartbeat file doesn't exist, create a warning but don't alert
# (tick may not have run yet after fresh setup)
if [[ ! -f "$HEARTBEAT_FILE" ]]; then
  log "heartbeat file missing — tick may not have run yet"
  log "watchdog end (pid=$$ status=no-heartbeat-file)"
  exit 0
fi

# Read the heartbeat timestamp
heartbeat_line=$(cat "$HEARTBEAT_FILE")
heartbeat_ts=$(echo "$heartbeat_line" | awk '{print $1}')

# Calculate age in seconds
now_epoch=$(date -u +%s)

# Cross-platform date parsing
if date --version >/dev/null 2>&1; then
  # GNU date (Linux)
  heartbeat_epoch=$(date -u -d "$heartbeat_ts" +%s)
else
  # BSD date (macOS)
  heartbeat_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$heartbeat_ts" +%s)
fi

age_seconds=$((now_epoch - heartbeat_epoch))
age_minutes=$((age_seconds / 60))

# Threshold: 3 ticks × 5 minutes = 15 minutes
WEDGE_THRESHOLD_MINUTES=15

log "heartbeat age: ${age_minutes}m (threshold: ${WEDGE_THRESHOLD_MINUTES}m)"

if (( age_minutes >= WEDGE_THRESHOLD_MINUTES )); then
  log "WEDGED: tick loop has not updated heartbeat in ${age_minutes} minutes"

  # Log to HEALTH file
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) WEDGED heartbeat_age=${age_minutes}m" >> "$HEALTH_FILE"

  # File alert issue (idempotent)
  # Use file_or_update_issue if available, otherwise direct create
  alert_title="Watchdog: tick loop wedged (heartbeat stale for ${age_minutes}m)"
  current_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Build alert body without nested command substitution
  read -r -d '' alert_body <<EOF || true
**watchdog:**

The tick loop has not updated its heartbeat file in ${age_minutes} minutes (threshold: ${WEDGE_THRESHOLD_MINUTES}m).

**Heartbeat file:** \`${HEARTBEAT_FILE}\`
**Last heartbeat:** ${heartbeat_ts}
**Current time:** ${current_time}

This indicates the tick loop is either:
1. Wedged (running but stuck in an infinite loop or blocking operation)
2. Crashed (not running at all)
3. Disabled (launchd job unloaded)

**Diagnostics:**

\`\`\`bash
# Check if tick loop is running
ps aux | grep tick.sh

# Check launchd job status
launchctl list | grep git-bee

# Check recent tick log
tail -50 ~/.git-bee/tick.log

# Check for lock file
ls -l /tmp/git-bee-agent.pid
\`\`\`

**Recovery steps:**

1. If tick is stuck: \`killall -9 bash\` or kill the specific PID
2. If launchd job is unloaded: \`launchctl load ~/Library/LaunchAgents/com.gitbee.tick.plist\`
3. If persistent wedge: check for rollback marker at \`~/.git-bee/ROLLBACK\`
4. Check \`~/.git-bee/HEALTH\` for prior wedge events

This issue was auto-filed by the watchdog deadman switch (issue #798 M2/PR 6).
EOF

  # Check if gh and git are available
  if command -v gh >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
    # Try to use file_or_update_issue from tick.sh
    if declare -f file_or_update_issue >/dev/null 2>&1; then
      issue_num=$(file_or_update_issue "$REPO" "$alert_title" "$alert_body" "" "watchdog")
      if [[ -n "$issue_num" ]]; then
        set_breeze_state "$REPO" "$issue_num" human
        log "filed or updated wedge alert issue #$issue_num"
      fi
    else
      # Fallback: direct issue create (may create duplicates, but watchdog runs rarely)
      # Check if an open issue already exists with this title pattern
      existing=$(gh issue list --repo "$REPO" --state open --limit 50 --json number,title --jq '.[] | select(.title | startswith("Watchdog: tick loop wedged")) | .number' | head -1 || echo "")

      if [[ -n "$existing" ]]; then
        log "wedge alert issue #$existing already exists, adding comment"
        gh issue comment "$existing" --repo "$REPO" --body "$alert_body" || true
        set_breeze_state "$REPO" "$existing" human
      else
        url=$(gh issue create --repo "$REPO" --title "$alert_title" --body "$alert_body" 2>&1 | tail -1 || true)
        issue_num=$(echo "$url" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+' || echo "")
        if [[ -n "$issue_num" ]]; then
          set_breeze_state "$REPO" "$issue_num" human
          log "filed wedge alert issue #$issue_num"
        fi
      fi
    fi
  else
    log "gh or git not available, cannot file issue"
  fi

  log "watchdog end (pid=$$ status=wedge-detected)"
  exit 0
else
  log "heartbeat fresh (${age_minutes}m < ${WEDGE_THRESHOLD_MINUTES}m)"
  log "watchdog end (pid=$$ status=ok)"
  exit 0
fi
