#!/usr/bin/env bash
# tmux-janitor.sh — clean up old tmux windows from finished agents
#
# Kills tmux windows in the git-bee session that are older than a configurable
# TTL (default 30 minutes). Respects remain-on-exit windows that have finished.
#
# Called from tick.sh after each dispatch in tmux UI mode.

set -euo pipefail

# Configuration
SESSION_NAME="git-bee"
TTL_MINUTES="${GIT_BEE_TMUX_TTL:-30}"  # Default 30 minutes

# Check if tmux is available and session exists
if ! command -v tmux >/dev/null 2>&1 || ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  exit 0
fi

# Get current timestamp
NOW=$(date +%s)
CUTOFF=$((NOW - TTL_MINUTES * 60))

# List all windows in the session with their info
# Format: window_index:window_name:pane_pid:pane_dead
tmux list-windows -t "$SESSION_NAME" -F '#{window_index}:#{window_name}:#{pane_pid}:#{pane_dead}' 2>/dev/null | while IFS=':' read -r idx name pid dead; do
  # Skip the "waiting" window (always keep at least one window)
  [[ "$name" == "waiting" ]] && continue

  # Only process dead panes (remain-on-exit windows where process has finished)
  [[ "$dead" != "1" ]] && continue

  # Try to determine when the window was created/finished
  # Use the process start time as a proxy (this is best-effort)
  if [[ -n "$pid" ]] && [[ "$pid" != "0" ]]; then
    # On macOS, use ps with specific format
    # On Linux, would use stat /proc/$pid or ps with different options
    if [[ "$(uname)" == "Darwin" ]]; then
      # Get process start time in seconds since epoch (macOS ps doesn't have lstart in epoch)
      # Fall back to checking if process still exists
      if ! kill -0 "$pid" 2>/dev/null; then
        # Process is dead, but we can't easily get its end time
        # Use window activity time if available
        activity=$(tmux display-message -t "$SESSION_NAME:$idx" -p '#{window_activity}' 2>/dev/null || echo "0")

        if [[ "$activity" != "0" ]] && [[ "$activity" -lt "$CUTOFF" ]]; then
          echo "Killing old window: $name (index=$idx, inactive since $(date -r "$activity" '+%Y-%m-%d %H:%M:%S'))"
          tmux kill-window -t "$SESSION_NAME:$idx" 2>/dev/null || true
        fi
      fi
    else
      # Linux: could check /proc/$pid/stat if it exists
      # For now, just check window activity like macOS
      activity=$(tmux display-message -t "$SESSION_NAME:$idx" -p '#{window_activity}' 2>/dev/null || echo "0")

      if [[ "$activity" != "0" ]] && [[ "$activity" -lt "$CUTOFF" ]]; then
        echo "Killing old window: $name (index=$idx, inactive since $(date -d "@$activity" '+%Y-%m-%d %H:%M:%S'))"
        tmux kill-window -t "$SESSION_NAME:$idx" 2>/dev/null || true
      fi
    fi
  fi
done

# If all windows were killed except "waiting", ensure at least one window remains
WINDOW_COUNT=$(tmux list-windows -t "$SESSION_NAME" 2>/dev/null | wc -l | xargs)
if [[ "$WINDOW_COUNT" == "0" ]]; then
  # Session needs at least one window
  tmux new-window -t "$SESSION_NAME" -n "waiting" "echo 'Waiting for agents...'; cat" 2>/dev/null || true
fi