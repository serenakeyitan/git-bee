#!/usr/bin/env bash
# Label helpers for git-bee agents
#
# Provides atomic breeze state transitions with mutual exclusion.

set -euo pipefail

# set_breeze_state <repo> <number> <state>
#
# Atomically sets the breeze state on an issue/PR to exactly one of:
#   wip, human, done
#
# This removes any existing breeze:* labels before applying the new one,
# ensuring mutual exclusion per the Breeze convention.
#
# Examples:
#   set_breeze_state "serenakeyitan/git-bee" 123 wip
#   set_breeze_state "serenakeyitan/git-bee" 456 human
#   set_breeze_state "serenakeyitan/git-bee" 789 done
set_breeze_state() {
  local repo="$1"
  local number="$2"
  local state="$3"

  # Validate state argument
  case "$state" in
    wip|human|done) ;;
    *)
      echo "ERROR: set_breeze_state: invalid state '$state' (must be: wip, human, or done)" >&2
      return 1
      ;;
  esac

  # Get current labels
  local current_labels
  current_labels=$(gh issue view "$number" --repo "$repo" --json labels --jq '.labels[].name' 2>/dev/null || echo "")

  # Remove all existing breeze:* labels
  local breeze_labels
  breeze_labels=$(echo "$current_labels" | grep "^breeze:" || true)

  if [[ -n "$breeze_labels" ]]; then
    while IFS= read -r label; do
      [[ -z "$label" ]] && continue
      gh issue edit "$number" --repo "$repo" --remove-label "$label" >/dev/null 2>&1 || true
    done <<< "$breeze_labels"
  fi

  # Apply the new state label
  gh issue edit "$number" --repo "$repo" --add-label "breeze:$state" >/dev/null 2>&1

  echo "set_breeze_state: #$number → breeze:$state"
}