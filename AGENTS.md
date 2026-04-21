# Git-bee Agent Conventions

## Label State Machine

Git-bee uses exactly four breeze labels with strict mutual exclusion:
- `breeze:new` — Newly created, not yet claimed
- `breeze:wip` — Actively being worked on by an agent
- `breeze:human` — Blocked on human intervention
- `breeze:done` — Work completed

### State Precedence

When determining the effective state, precedence is:
**done > MERGED/CLOSED > human > wip > absent**

- GitHub's MERGED/CLOSED status implies `breeze:done` even without the label
- Only one `breeze:*` label may be present at any time
- State transitions must be atomic (remove old, add new)

### Prohibited Labels

Agents MUST NOT set these labels on issues or PRs:
- `source:*` — Reserved for human use
- `priority:*` — Reserved for human use

Note: `priority:high` is still read by `tick.sh` for sort ordering (humans can apply it), but no agent sets it.

### State Transition Helper

All agents MUST use the provided helper for state transitions:

```bash
source /path/to/scripts/labels.sh
set_breeze_state "repo-owner/repo-name" <number> <wip|human|done>
```

This helper atomically removes any existing `breeze:*` label before applying the new one, preserving mutual exclusion.

## Agent Rules

1. **Claim before work** — Set `breeze:wip` before starting any task
2. **Release on completion** — Remove `breeze:wip` when done or handing off
3. **Use helper for transitions** — Never manually add/remove breeze labels
4. **Respect human labels** — Skip items with fresh `breeze:human` (< 2 hours old)

## Implementation Reference

- State transitions: `scripts/labels.sh:set_breeze_state()`
- Dispatch logic: `scripts/tick.sh:pick_target()`
- Breeze classifier: `first-tree/src/products/breeze/engine/runtime/classifier.ts`