#!/usr/bin/env bash
# gate-check: verify a design-doc issue's finalization gate.
#
# Usage: gate-check.sh <owner/repo> <issue-number>
#
# Exit codes:
#   0  gate open — EITHER (a) no `## Finalization gate` section (most issues), OR
#      (b) has the section AND last body edit is by the repo owner AND the first
#      checkbox under `## Finalization gate` is `[x]`. Dispatch ok.
#   1  gate closed — checkbox unchecked, or body unreadable. Fail closed.
#   2  gate ticked by non-owner — checkbox is `[x]` but the latest body author
#      is not the repo owner. Bot-authored ticks don't count.
#   3  (deprecated — now returns 0) previously indicated no gate section.
#
# Why GraphQL: GitHub's REST timeline API does not emit events for issue body
# edits. `userContentEdits` on the issue node does — newest first.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: gate-check.sh <owner/repo> <issue-number>" >&2
  exit 1
fi

REPO="$1"
NUM="$2"
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

body=$(gh issue view "$NUM" --repo "$REPO" --json body --jq '.body' 2>/dev/null || true)
if [[ -z "$body" ]]; then
  echo "gate-check: could not read body of $REPO#$NUM" >&2
  exit 1
fi

# Extract the first checkbox line after `## Finalization gate`. We stop at the
# next `##` heading so we don't accidentally read a checkbox from a later
# section (the plan-confirmation gate has its own check).
gate_line=$(awk '
  /^## Finalization gate[[:space:]]*$/ { in_section = 1; next }
  in_section && /^## / { exit }
  in_section && /^[[:space:]]*-[[:space:]]*\[[ xX]\]/ { print; exit }
' <<<"$body")

if ! grep -qE '^## Finalization gate[[:space:]]*$' <<<"$body"; then
  # No Finalization gate section: treat as gate open by default (rc=0)
  # This allows Phase 2 routing to apply to issues without the formal header
  exit 0
fi

if [[ -z "$gate_line" ]]; then
  echo "gate-check: '## Finalization gate' section has no checkbox in $REPO#$NUM" >&2
  exit 1
fi

if ! [[ "$gate_line" =~ \[[xX]\] ]]; then
  echo "gate-check: finalization checkbox not ticked in $REPO#$NUM" >&2
  exit 1
fi

# Figure out who is responsible for the current body. If the body has been
# edited, the latest editor owns it; otherwise the original author does.
edit_info=$(gh api graphql \
  -f query='query($o:String!,$n:String!,$i:Int!){repository(owner:$o,name:$n){issue(number:$i){author{login} userContentEdits(last:1){nodes{editor{login}}}}}}' \
  -f o="$OWNER" -f n="$NAME" -F i="$NUM" 2>/dev/null || true)

if [[ -z "$edit_info" ]]; then
  echo "gate-check: GraphQL query failed for $REPO#$NUM" >&2
  exit 1
fi

latest_editor=$(echo "$edit_info" | jq -r '.data.repository.issue.userContentEdits.nodes[0].editor.login // ""')
original_author=$(echo "$edit_info" | jq -r '.data.repository.issue.author.login // ""')

responsible="${latest_editor:-$original_author}"

if [[ -z "$responsible" ]]; then
  echo "gate-check: could not determine body author for $REPO#$NUM" >&2
  exit 1
fi

if [[ "$responsible" != "$OWNER" ]]; then
  echo "gate-check: finalization tick in $REPO#$NUM is by '$responsible', not repo owner '$OWNER'" >&2
  exit 2
fi

exit 0
