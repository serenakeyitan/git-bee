# git-bee agent conventions

Ported from breeze (`first-tree/src/products/breeze`). All agents MUST follow.

## Label state machine

Four labels, mutually exclusive. Precedence: **done > MERGED/CLOSED > human > wip > absent**.

| Label | Meaning | Applied by |
| --- | --- | --- |
| `breeze:new` | Default. Absence of all `breeze:*` labels is the real "new" signal. | Human-readable only — never auto-applied. |
| `breeze:wip` | An agent is actively working this item. | `claim.sh` on acquire; drafter when opening a PR. |
| `breeze:human` | Needs human judgment. Tick dispatcher skips this. | Any agent via `bee pause`, supervisor `design-conflicting`, merger when stuck. |
| `breeze:done` | Agent has finished. GitHub MERGED/CLOSED also implies done. | Rarely set explicitly — prefer closing the issue/PR. |

### Rules

- **Use the helper.** All transitions go through `set_breeze_state <repo> <num> <state>` in `scripts/labels.sh`, which atomically removes prior `breeze:*` labels. Never call `gh edit --add-label breeze:*` directly.
- **Exactly one.** At any moment a non-closed item has zero or one `breeze:*` label. Two is a bug.
- **Agent claims = `breeze:wip`.** `claim_acquire` in `scripts/claim.sh` already does this for issues; drafter must also set `breeze:wip` on PRs it opens.
- **No other label namespaces.** Do NOT apply `source:*` or `priority:*` labels on issues or PRs. Source is internal (task kind). Priority is a dispatcher concern — if you need it, sort in `tick.sh`, don't label.
- **`breeze:done` is rarely needed.** Closing the issue/PR is enough (GitHub's state derives done). Only set `breeze:done` explicitly when the agent has finished its part but the item stays open for downstream work.

## Comment prefixes

Every PR/issue comment an agent posts must start with `**<role>:**` on its own first line:

- `**drafter:**`, `**reviewer:**`, `**e2e:**`, `**e2e-designer:**`, `**e2e-supervisor:**`, `**planner:**`, `**auditor:**`, `**merger:**`

The canonical E2E trace comment (`**E2E trace (pass|fail)**`) emitted by `scripts/e2e-sandbox.sh finalize` is exempt — it identifies itself.

## Claims

Claim acquisition is label-based today (via `breeze:wip`) with a freshness comment marker. This differs from breeze (filesystem lockfiles) and is acceptable while git-bee is single-machine. See `scripts/claim.sh`.

## When blocked

Any agent that gets stuck must call `bee pause <n> "<reason>"`. That applies `breeze:human`, posts a comment, and releases the claim.
