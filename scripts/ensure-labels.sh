#!/usr/bin/env bash
# Ensure all four breeze labels exist with canonical colors/descriptions.
# Idempotent — safe to run multiple times.
#
# Per first-tree's src/products/breeze/engine/runtime/types.ts:
#   breeze:new    — 0075ca — "Breeze: new notification"
#   breeze:wip    — e4e669 — "Breeze: work in progress"
#   breeze:human  — d93f0b — "Breeze: needs human attention"
#   breeze:done   — 0e8a16 — "Breeze: handled"

set -euo pipefail

REPO="${1:-serenakeyitan/git-bee}"

# Define labels: name|color|description
declare -a LABELS=(
  "breeze:new|0075ca|Breeze: new notification"
  "breeze:wip|e4e669|Breeze: work in progress"
  "breeze:human|d93f0b|Breeze: needs human attention"
  "breeze:done|0e8a16|Breeze: handled"
)

for label_spec in "${LABELS[@]}"; do
  IFS='|' read -r name color desc <<< "$label_spec"

  # Check if label exists
  if gh label list --repo "$REPO" --limit 200 | grep -q "^${name}\b"; then
    # Update existing label (color and description may have changed)
    gh label edit "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null 2>&1 || true
  else
    # Create new label
    gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null 2>&1 || true
  fi
done