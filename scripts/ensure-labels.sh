#!/usr/bin/env bash
# Ensure all breeze labels exist with canonical colors/descriptions.
# Idempotent — safe to run multiple times.
#
# Phase 1a of migration to first-tree breeze (#31): delegate the
# breeze:* label inventory to `first-tree breeze status-manager
# ensure-labels` so the colors, descriptions, and list are sourced
# from breeze's `BREEZE_LABEL_META` (single source of truth). Fall
# back to the inline list if first-tree is not on PATH so the tick
# loop keeps working on machines that haven't installed first-tree.
#
# The git-bee-only `breeze:quarantine-hotloop` label (from #779) is
# still created by this script — breeze does not know about it.

set -euo pipefail

REPO="${1:-serenakeyitan/git-bee}"

# Delegate breeze canonical labels (breeze:new|wip|human|done) to first-tree
# if available. Errors are swallowed and we continue to the fallback so a
# missing or misbehaving first-tree never blocks the tick loop.
if command -v first-tree >/dev/null 2>&1; then
  if first-tree breeze status-manager ensure-labels "$REPO" >/dev/null 2>&1; then
    DELEGATED=1
  fi
fi

# Fallback list — used when first-tree is not on PATH OR when the delegation
# call above failed. Also always applied for git-bee-only labels (quarantine).
declare -a LABELS=()
if [[ "${DELEGATED:-0}" != "1" ]]; then
  LABELS+=(
    "breeze:new|0075ca|Breeze: new notification"
    "breeze:wip|e4e669|Breeze: work in progress"
    "breeze:human|d93f0b|Breeze: needs human attention"
    "breeze:done|0e8a16|Breeze: handled"
  )
fi

# git-bee extension — not part of breeze canonical spec. Always created here.
LABELS+=(
  "breeze:quarantine-hotloop|fbca04|Bee: hot-loop detected; dispatcher skipping"
)

for label_spec in "${LABELS[@]}"; do
  IFS='|' read -r name color desc <<< "$label_spec"
  if gh label list --repo "$REPO" --limit 200 | grep -q "^${name}\b"; then
    gh label edit "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null 2>&1 || true
  else
    gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null 2>&1 || true
  fi
done
