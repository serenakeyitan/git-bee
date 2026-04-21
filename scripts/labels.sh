#!/usr/bin/env bash
# git-bee label state-machine helper. Ports breeze's 4-state model.
#
# The four mutually-exclusive states:
#   breeze:new     — absence of all breeze:* labels (human-readable only)
#   breeze:wip     — agent is actively working
#   breeze:human   — needs human input
#   breeze:done    — agent finished (or GitHub MERGED/CLOSED implies this)
#
# Precedence: done > MERGED/CLOSED > human > wip > absent.
#
# Usage:
#   source scripts/labels.sh
#   set_breeze_state <repo> <number> <wip|human|done>
#
# Atomically removes any prior breeze:* label and applies exactly one.
# Agents MUST use this for state transitions — do not call `gh edit
# --add-label breeze:*` directly.

# shellcheck disable=SC2155

set_breeze_state() {
  local repo="$1" number="$2" new_state="$3"
  case "$new_state" in
    wip|human|done) : ;;
    *)
      echo "set_breeze_state: invalid state '$new_state' (expected wip|human|done)" >&2
      return 1
      ;;
  esac

  # Discover current labels (works for both issues and PRs; gh routes by number).
  local labels
  labels=$(gh issue view "$number" --repo "$repo" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")

  local to_remove=""
  for state in new wip human done; do
    local lbl="breeze:${state}"
    if [[ ",$labels," == *",${lbl},"* && "$state" != "$new_state" ]]; then
      to_remove="${to_remove}${lbl},"
    fi
  done

  # Atomic transition: remove old and add new in a single gh command.
  # This ensures we never have two breeze:* labels at once.
  local target="breeze:${new_state}"
  if [[ -n "$to_remove" ]]; then
    # Has old labels to remove — combine remove and add operations
    if [[ ",$labels," != *",${target},"* ]]; then
      # Need to both remove old and add new
      gh issue edit "$number" --repo "$repo" --remove-label "${to_remove%,}" --add-label "$target" >/dev/null 2>&1 || true
    else
      # Target already present, just remove old ones
      gh issue edit "$number" --repo "$repo" --remove-label "${to_remove%,}" >/dev/null 2>&1 || true
    fi
  elif [[ ",$labels," != *",${target},"* ]]; then
    # No old labels to remove, just add new
    gh issue edit "$number" --repo "$repo" --add-label "$target" >/dev/null 2>&1 || true
  fi
}

# Remove ALL breeze:* labels. Used after terminal actions where the agent
# wants the item to fall back to "new" (rare — mostly here for test cleanup).
clear_breeze_state() {
  local repo="$1" number="$2"
  gh issue edit "$number" --repo "$repo" \
    --remove-label "breeze:new" \
    --remove-label "breeze:wip" \
    --remove-label "breeze:human" \
    --remove-label "breeze:done" >/dev/null 2>&1 || true
}
