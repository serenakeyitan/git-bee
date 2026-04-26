# git-bee agent conventions

Ported from breeze (`first-tree/src/products/breeze`). All agents MUST follow.

## Label state machine

Four canonical labels plus one quarantine label. Mutually exclusive among the canonical four. Precedence: **done > MERGED/CLOSED > human > wip > absent**.

| Label | Meaning | Applied by |
| --- | --- | --- |
| `breeze:new` | Visual marker only. Absence of all `breeze:*` labels is the real "new" signal. | Human, optionally. Never auto-applied. |
| `breeze:wip` | An agent is actively working this item. | `claim.sh` on acquire. |
| `breeze:human` | Needs human judgment. Tick dispatcher skips this. | Any agent via `bee pause`; supervisor on `design-conflicting`; merger when stuck. |
| `breeze:done` | Agent has finished. GitHub MERGED/CLOSED also implies done. | Merger on merge/close, janitor on drift cleanup. |
| `breeze:quarantine-hotloop` | A hot-loop was detected on this PR; dispatcher skips. | Tick's hot-loop detector (see `check_hot_loop` in `tick.sh`). |

### Rules

- **Use the helper.** All transitions go through `set_breeze_state <repo> <num> <state>` in `scripts/labels.sh`, which atomically removes prior `breeze:*` labels. Never call `gh edit --add-label breeze:*` directly.
- **Exactly one canonical label.** At any moment a non-closed item has zero or one of {`wip`, `human`, `done`}. `quarantine-hotloop` may coexist with another canonical label.
- **Do NOT label PRs you open.** Drafter leaves opened PRs unlabeled so the dispatcher can route them. `claim_acquire` handles `breeze:wip` on issues only.
- **No other label namespaces.** Do NOT apply `source:*` or `priority:*` labels on issues or PRs. Source is internal (task kind). Priority is a dispatcher concern — if you need it, sort in `tick.sh`, don't label.
- **`breeze:done` on merge/close.** Merger sets it after squash-merge and before closing umbrella issues. The janitor (`janitor_label_cleanup` in `tick.sh`) fixes drift from any agent that forgot.

## Escape hatches (single-account mode)

Because git-bee runs all agents + human as the same GitHub account (#754), GitHub blocks formal self-approval and self-request-changes. Two HTML markers replace those actions:

| Marker | Posted by | Effect |
| --- | --- | --- |
| `<!-- bee:approved-for-e2e -->` | Human, in a PR comment or review at/after HEAD SHA | Dispatcher treats the PR as approved; advances to e2e/merger. |
| `<!-- bee:changes-requested -->` | Human, in a PR comment at/after HEAD SHA | Dispatcher routes the PR to drafter for revision on next tick. |

Use the `bee` CLI:

```bash
bee request-changes <pr> [reason]   # posts the revision marker, removes breeze:human
bee pause <pr> "<reason>"           # applies breeze:human, posts comment, releases claim
```

## Agent roster

| Agent | Job |
| --- | --- |
| `planner` | Reads finalized design-doc issues, creates structured milestone plans that break work into appropriately-sized PRs. |
| `drafter` | Turns design-doc issues into shipped code; pushes fixes addressing review feedback. |
| `reviewer` | Reviews implementation PRs. Three-state verdict invariant: approve / request-changes / escalate. |
| `test-agent` | Runs a PR's `tests/e2e/verify.sh` in a sandbox; writes test cases when missing; posts the canonical `**E2E trace (pass\|fail)**` comment; classifies failures (lazy-run, code-bug, test-bug, design-trivial, design-conflicting). |
| `merger` | Squash-merges approved PRs with passing e2e, transitions to `breeze:done`, closes linked issues (including umbrella issues). |

## Comment prefixes

Every PR/issue comment an agent posts must start with `**<role>:**` on its own first line:

- `**planner:**`, `**drafter:**`, `**reviewer:**`, `**test-agent:**`, `**merger:**`
- Human comments posted through `bee` use `**human:**`.

The canonical e2e trace comment (`**E2E trace (pass|fail)**`) emitted by `scripts/e2e-sandbox.sh finalize` is exempt — it identifies itself.

## Status-line contract

Every agent ends its stdout with one line matching:

```
<role>: target=<n> action=<action> next=<role|none>
```

`tick.sh` parses this to populate `activity.ndjson` and to drive next-role hints. Acceptable field names: `action=`, `result=`, `verdict=`. If none is present, the tick treats it as a null outcome and writes a failure file.

## Claims

Claim acquisition is label-based (via `breeze:wip`) plus a freshness comment marker (`<!-- breeze:claimed-at=<ISO8601> by=<agent-id> -->`). A claim is stale once the labeled-event timestamp is older than `CLAIM_TTL_SECONDS` (default 7200 = 2h). Any agent may take over a stale claim.

See `scripts/claim.sh` for `claim_acquire` / `claim_release` / `claim_check`.

## When blocked

Any agent that gets stuck must call `bee pause <n> "<reason>"`. That applies `breeze:human`, posts a comment, and releases the claim.

## Safety mechanisms

- **PID lock** (`/tmp/git-bee-agent.pid`) prevents concurrent agents on the same machine. Tick exits `lock-held` if set.
- **3-consecutive-crash rollback**: if three ticks in a row exit non-zero, tick.sh rolls back to the last known-good SHA, writes `~/.git-bee/ROLLBACK`, and files an alert issue. The marker gates further ticks until removed.
- **Hot-loop quarantine**: if an agent is dispatched on the same target twice within 5 minutes with `outcome=null`, the PR gets `breeze:quarantine-hotloop` and a bug issue is filed. Quarantine auto-releases when new commits land on the PR.
- **Pre-push guard**: `scripts/preflight-push.sh` hard-refuses pushes whose target ref is `main` or `master`. Source it before any `git push` in agent Bash tool calls.
