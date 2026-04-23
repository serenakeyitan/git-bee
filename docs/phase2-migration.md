# Phase 2 migration: git-bee → first-tree breeze

**Status:** design, not started.
**Prerequisites:** Phase 1a shipped (#796 — label inventory delegated). Phase 1b skipped (unnecessary).
**Scope:** move git-bee's dispatch runtime onto breeze's TypeScript daemon so `scripts/tick.sh`, `scripts/claim.sh`, `scripts/activity.sh`, and `scripts/bee` can be deprecated.

## The structural gap

Breeze thinks in **GitHub notifications**. Every candidate in breeze's dispatcher starts as a notification row in `~/.breeze/inbox.json`: a PR review-request, a mention, an assigned issue. If nothing notifies the user, breeze sees nothing.

Git-bee thinks in **PR states**. `pick_target` in `tick.sh` polls its own repo's issues/PRs directly and routes based on state: approval marker, E2E trace, supervisor verdict, merge-conflict status, etc. Notifications are irrelevant — the loop is self-polling.

These models do not compose. An "approved PR with passing E2E" produces no GitHub notification, so breeze would never dispatch the merger. A "drafter-just-opened PR" produces no notification *to yourself*, so breeze would never route it to reviewer.

**Phase 2 cannot proceed until this gap is resolved.** Three options:

1. **Add a state-driven candidate source to breeze** (preferred). Breeze's `CandidateLoop` already accepts injected sources per `daemon/candidate-loop.ts`. Contribute a `RepoStateCandidateSource` that polls a repo's issues/PRs and emits candidates driven by PR-state transitions, not notification reasons. This is the cleanest fit and benefits other first-tree products.
2. **Keep a thin git-bee shim.** git-bee continues to do state classification in a rewritten `tick.sh` but delegates every individual agent dispatch to `first-tree breeze run` via IPC. Preserves all git-bee logic but loses the benefit of sharing breeze's dispatcher, broker, and activity log.
3. **Accept the downgrade.** Drop state-driven dispatch entirely. Route only on notifications. This means the merger never runs unless someone mentions the bot, E2E is manual, etc. Not viable.

Option 1 is the real Phase 2. Option 2 is the compromise if Option 1 is rejected by breeze maintainers. Option 3 is documentation-only.

## Blocker questions to resolve before coding

File each on first-tree's issue tracker and await answers.

1. **Will breeze accept a `RepoStateCandidateSource` contribution?** Sketch the interface and the subset of git-bee's `pick_target` taxonomy it would need to express.
2. **Does breeze's claim protocol compose with a non-notification source?** `daemon/claim.ts` keys claims by notification ID. We'd need repo+number keying too, or a synthesized ID scheme.
3. **What's the expected cadence of breaking changes in breeze's daemon / runtime API?** git-bee will be tightly coupled. A v0.x.0 bump that changes dispatcher semantics is a git-bee outage.
4. **Does breeze's `gh` broker handle the pre-push guard git-bee enforces?** If not, does it have an extension point for git-bee's `preflight-push.sh` to plug in?
5. **Where does a new label like `breeze:quarantine-hotloop` live?** Extension mechanism in breeze, or does git-bee own it forever as a side-car?

## 15 git-bee-only features to port

Each one is a Phase 2 work item. In rough dependency / risk order.

### Tier A — core runtime (must port before anything else)

1. **State-driven candidate source** — the dispatcher taxonomy in `tick.sh:pick_target`. ~8 branches: approved+e2e-pass → merger; approved no e2e → e2e; conflicting → drafter-for-rebase; E2E trace → supervisor; supervisor verdict → role-specific; unreviewed → reviewer; review-at-head → drafter; issue-with-open-PR → drafter on the PR.
2. **Status-line contract** — agents write `<role>: target=<n> action=<...> next=<role|none>` on stdout. Breeze's runner currently parses agent exit-code only. Needs an extension point.
3. **PID lock + GitHub claim alignment** — git-bee uses `breeze:wip` label + filesystem `/tmp/git-bee-agent.pid`. Breeze uses `~/.breeze/claims/<id>/`. Unify on breeze's scheme; teach agents to read the new path.
4. **Single-account escape hatches** (`<!-- bee:approved-for-e2e -->`, `<!-- bee:changes-requested -->`). These are git-bee's workaround for GitHub blocking self-review. Breeze assumes multi-account. Extend breeze's candidate-classifier to recognize both markers.

### Tier B — safety mechanisms (port before cutover)

5. **3-consecutive-crash rollback** (`ROLLBACK` marker, last-known-good SHA checkpointing). Breeze has no equivalent.
6. **Hot-loop quarantine** (`breeze:quarantine-hotloop`, auto-release on new commits, auto-filed bug issue). Pure git-bee.
7. **Pre-push guard** (`scripts/preflight-push.sh`). Must refuse pushes targeting main/master from agent subprocesses. Needs hook into breeze's `gh` broker or runner env.
8. **Janitor for stale `breeze:*` on merged/closed items** (from #785). Port to breeze's `cleanup` command or as a breeze extension.

### Tier C — routing intelligence (port during cutover)

9. **Supervisor verdict → dispatch routing** (lazy-run → e2e, code-bug → drafter, test-bug → e2e-designer, design-conflicting → human, design-trivial → advance).
10. **PR size-based fast paths** (`tiny-fix` skipping reviewer+e2e). Size heuristic + state-machine short-circuit.
11. **Human-comment revision-request routing** (#784). `bee:changes-requested` comment at/after HEAD → drafter. Special case of the escape hatch port.
12. **Design-doc issue handling** — gate-check, milestone plans, `Fixes` vs `Refs` semantics, umbrella issues, auditor close-on-all-green. Multi-PR coordination logic.

### Tier D — UX (port after cutover works)

13. **`bee` CLI** (`status`, `log`, `pause`, `request-changes`, `config`, statusline integration). Replace with equivalent `first-tree breeze ...` commands; add what breeze lacks (`pause`, `request-changes`).
14. **8 agent prompts** (`agents/*.md`). Each contains hard-won edge-case instructions. Breeze's runner invokes agents differently (different stdin format, different claim lifecycle). Every prompt needs rewriting — or breeze's runner needs a compatibility mode.
15. **All existing git-bee config** (`scripts/bee config`, watchlist, exclusions). Map to breeze's `~/.breeze/config.yaml`.

## Proposed sequencing

**Milestone 1 — blocker resolution (1 week, external dependency).** File the 5 blocker questions as issues on first-tree. Wait for answers. Do not start coding Phase 2 until Milestone 1 is resolved.

**Milestone 2 — Tier A (2 weeks).** Implement `RepoStateCandidateSource` in breeze (if Option 1 accepted). Port status-line parsing, unify claims, port both escape hatches. Ship as a feature-flagged opt-in in git-bee: `GIT_BEE_USE_BREEZE=1` kills tick.sh and switches to `first-tree breeze start --allow-repo serenakeyitan/git-bee`. Run with flag off by default.

**Milestone 3 — Tier B (1 week).** Port the 4 safety mechanisms into breeze (as extensions) or git-bee (as side-cars that watch breeze's state).

**Milestone 4 — Tier C (1 week).** Port routing logic. Run old and new side-by-side for at least 5 days. Compare `activity.ndjson` vs `~/.breeze/activity.log`. Require zero divergence before flipping the default flag.

**Milestone 5 — Tier D + deprecation (1 week).** Port `bee` CLI to breeze extensions or shims. Rewrite 8 agent prompts. Flip `GIT_BEE_USE_BREEZE=1` default. Delete `tick.sh`, `claim.sh`, `activity.sh`, `ensure-labels.sh`, keep `labels.sh` as thin shim or delete.

Total: ~5 weeks of focused work, assuming blocker questions are answered favorably.

## What we ship tonight

- Phase 1a: `scripts/ensure-labels.sh` delegates to `first-tree breeze status-manager ensure-labels`. Shipped in #796.
- Phase 1b: dropped — not worth the complexity.
- Phase 2: **this document.** Blueprint for the future work. No code.

## What we do NOT ship tonight

- Any dispatch migration. The feature-flag harness scoped in the Phase 2 prep discussion is not viable as originally designed: breeze's `run-once` refuses to run when a daemon is already active, and even if routed around, it would only dispatch on notification-driven candidates — losing git-bee's state-driven behavior.
- Any agent prompt rewrites.
- Any deprecation of `tick.sh`.

Attempting Phase 2 without first resolving the 5 blocker questions is premature. The correct next action is to file those questions on first-tree and pick Phase 2 back up when they're answered.

Refs #31.
