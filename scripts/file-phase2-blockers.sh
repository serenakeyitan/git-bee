#!/usr/bin/env bash
set -euo pipefail

# File the 5 Phase-2 blocker questions on agent-team-foundation/first-tree
# as specified in docs/phase2-migration.md

FIRST_TREE_REPO="agent-team-foundation/first-tree"
GIT_BEE_REPO="serenakeyitan/git-bee"

echo "Filing Phase-2 blocker questions on ${FIRST_TREE_REPO}..."

# Helper to check if issue already exists
issue_exists() {
  local title="$1"
  gh issue list --repo "$FIRST_TREE_REPO" --search "in:title \"$title\"" --state open --json number --jq '.[0].number // empty'
}

# Blocker 1: RepoStateCandidateSource contribution
TITLE_1="[git-bee Phase 2] Will breeze accept a RepoStateCandidateSource contribution?"
existing=$(issue_exists "$TITLE_1")
if [[ -n "$existing" ]]; then
  echo "✓ Blocker 1 already filed: issue #${existing}"
  ISSUE_1="$existing"
else
  BODY_1=$(cat <<'EOF'
**Context:** git-bee (https://github.com/serenakeyitan/git-bee) is migrating its dispatch runtime onto breeze TypeScript daemon (Phase 2 migration, tracked in serenakeyitan/git-bee#798).

**Problem:** Breeze dispatcher is notification-driven (polls ~/.breeze/inbox.json). Git-bee dispatcher is state-driven (polls repo issues/PRs directly and routes based on PR state: approval markers, E2E traces, merge conflicts, etc.). These models do not compose.

**Proposed solution:** Contribute a RepoStateCandidateSource to breeze CandidateLoop (per daemon/candidate-loop.ts) that polls a repo issues/PRs and emits candidates driven by PR-state transitions, not notification reasons.

**Question:** Will breeze accept this contribution? If yes, what interface constraints exist?

**Example taxonomy this would need to express:**
- Approved PR + E2E pass → dispatch to merger
- Approved PR, no E2E → dispatch to e2e
- Conflicting PR → dispatch to drafter for rebase
- E2E trace present → dispatch to supervisor
- Supervisor verdict → role-specific routing
- Unreviewed PR → dispatch to reviewer
- Review-requested at HEAD → dispatch to drafter

**Benefits for other first-tree products:** Any product needing state-driven dispatch (not just git-bee) could reuse this source.

**Alternatives if rejected:**
1. Keep a thin git-bee shim that does state classification and delegates individual agent runs to first-tree breeze run
2. Accept the downgrade: drop state-driven dispatch, route only on notifications (not viable for git-bee autonomous operation)

Refs serenakeyitan/git-bee#798 (Phase 2 migration), serenakeyitan/git-bee#31 (breeze integration epic).
EOF
)
  ISSUE_URL=$(gh issue create --repo "$FIRST_TREE_REPO" --title "$TITLE_1" --body "$BODY_1")
  ISSUE_1=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
  echo "✓ Filed blocker 1: issue #${ISSUE_1}"
fi

# Blocker 2: Claim protocol composition
TITLE_2="[git-bee Phase 2] Does breeze claim protocol compose with non-notification sources?"
existing=$(issue_exists "$TITLE_2")
if [[ -n "$existing" ]]; then
  echo "✓ Blocker 2 already filed: issue #${existing}"
  ISSUE_2="$existing"
else
  BODY_2=$(cat <<'EOF'
**Context:** git-bee Phase 2 migration requires integrating state-driven dispatch into breeze (see related blocker question on RepoStateCandidateSource).

**Problem:** Breeze daemon/claim.ts keys claims by notification ID. A state-driven candidate source (polling repo issues/PRs) produces candidates without notification IDs.

**Question:** Does breeze claim protocol support non-notification sources? If not, what extension is needed?

**Possible approaches:**
1. Synthesize IDs for state-driven candidates (e.g., repo:owner/name#123)
2. Extend claim keying to support both notification IDs and {repo, number} tuples
3. Other approach recommended by breeze maintainers

**Impact:** Without this, git-bee cannot track which agent is working on which PR/issue when using breeze dispatcher.

Refs serenakeyitan/git-bee#798 (Phase 2 migration).
EOF
)
  ISSUE_URL=$(gh issue create --repo "$FIRST_TREE_REPO" --title "$TITLE_2" --body "$BODY_2")
  ISSUE_2=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
  echo "✓ Filed blocker 2: issue #${ISSUE_2}"
fi

# Blocker 3: Breaking change cadence
TITLE_3="[git-bee Phase 2] What is the expected cadence of breaking changes in breeze daemon/runtime API?"
existing=$(issue_exists "$TITLE_3")
if [[ -n "$existing" ]]; then
  echo "✓ Blocker 3 already filed: issue #${existing}"
  ISSUE_3="$existing"
else
  BODY_3=$(cat <<'EOF'
**Context:** git-bee will be tightly coupled to breeze dispatcher, runner, and activity log once Phase 2 completes.

**Question:** What is the expected cadence of breaking changes in breeze daemon/runtime API?

**Why this matters:**
- A v0.x.0 bump that changes dispatcher semantics is a git-bee outage
- git-bee needs to plan for maintenance burden: tracking upstream changes, porting breaking changes, testing compatibility
- If breaking changes are frequent (e.g., weekly), a thin shim layer may be safer than deep integration

**Ideal answer:** Versioning policy, expected stability window, advance notice period for breaking changes, recommended integration pattern for products building on breeze.

Refs serenakeyitan/git-bee#798 (Phase 2 migration).
EOF
)
  ISSUE_URL=$(gh issue create --repo "$FIRST_TREE_REPO" --title "$TITLE_3" --body "$BODY_3")
  ISSUE_3=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
  echo "✓ Filed blocker 3: issue #${ISSUE_3}"
fi

# Blocker 4: Pre-push guard
TITLE_4="[git-bee Phase 2] Does breeze gh broker support pre-push guards?"
existing=$(issue_exists "$TITLE_4")
if [[ -n "$existing" ]]; then
  echo "✓ Blocker 4 already filed: issue #${existing}"
  ISSUE_4="$existing"
else
  BODY_4=$(cat <<'EOF'
**Context:** git-bee enforces a pre-push guard (scripts/preflight-push.sh) that hard-refuses pushes targeting main or master from agent subprocesses. This prevents agents from bypassing PR review.

**Problem:** When breeze runs git-bee agents, the guard must remain enforceable.

**Question:** Does breeze gh broker have an extension point for pre-push guards? Or does breeze enforce this at a different layer?

**Current git-bee mechanism:**
- All agent prompts require sourcing preflight-push.sh before any git push
- The guard exits 1 if target ref is main or master
- Prevents bypass scenarios like "drafter pushes directly to main instead of opening PR"

**Required for safety:** Without this, agents could accidentally (or via prompt injection) push directly to protected branches, bypassing review + E2E.

**Alternatives:**
1. Breeze provides a pre-push hook mechanism
2. git-bee injects the guard via core.hooksPath in agent subprocess env
3. Breeze runner enforces read-only main branches at a higher level

Refs serenakeyitan/git-bee#798 (Phase 2 migration), serenakeyitan/git-bee#555 (prior direct-to-main incident).
EOF
)
  ISSUE_URL=$(gh issue create --repo "$FIRST_TREE_REPO" --title "$TITLE_4" --body "$BODY_4")
  ISSUE_4=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
  echo "✓ Filed blocker 4: issue #${ISSUE_4}"
fi

# Blocker 5: Custom labels
TITLE_5="[git-bee Phase 2] Where do git-bee-specific labels like breeze:quarantine-hotloop live?"
existing=$(issue_exists "$TITLE_5")
if [[ -n "$existing" ]]; then
  echo "✓ Blocker 5 already filed: issue #${existing}"
  ISSUE_5="$existing"
else
  BODY_5=$(cat <<'EOF'
**Context:** git-bee uses several custom labels that are part of its safety mechanisms:
- breeze:quarantine-hotloop (applied when agent wedges 2+ times on same item)
- breeze:wip (claim marker)
- breeze:human (escalation marker)
- Others in the breeze:* namespace

**Question:** Where should these labels live after Phase 2?

**Options:**
1. Breeze accepts them into its label taxonomy (all first-tree products share them)
2. Git-bee owns them as side-car extensions (breeze ignores them, git-bee-specific logic reads them)
3. Git-bee uses a different namespace (e.g., git-bee:*) to avoid polluting breeze taxonomy
4. Breeze provides an extension mechanism for custom labels

**Impact:** Label inventory was already delegated to breeze in Phase 1a (serenakeyitan/git-bee#796). But quarantine, wip, and human labels have semantic meaning for dispatch routing. Need clarity on ownership + extension points.

Refs serenakeyitan/git-bee#798 (Phase 2 migration), serenakeyitan/git-bee#796 (Phase 1a label delegation).
EOF
)
  ISSUE_URL=$(gh issue create --repo "$FIRST_TREE_REPO" --title "$TITLE_5" --body "$BODY_5")
  ISSUE_5=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
  echo "✓ Filed blocker 5: issue #${ISSUE_5}"
fi

echo ""
echo "Summary: Filed 5 Phase-2 blocker questions on ${FIRST_TREE_REPO}"
echo "  1. RepoStateCandidateSource: #${ISSUE_1}"
echo "  2. Claim protocol composition: #${ISSUE_2}"
echo "  3. Breaking change cadence: #${ISSUE_3}"
echo "  4. Pre-push guard: #${ISSUE_4}"
echo "  5. Custom labels: #${ISSUE_5}"
echo ""
echo "These issues are now awaiting answers from breeze maintainers."
echo "Phase 2 coding should not start until all 5 are resolved."
