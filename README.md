# git-bee

*(call it **bee**)*

An autonomous agent that buzzes through GitHub issues on a schedule, picks up unfinished work, and ships it while you're not watching.

## Flow

```text
  👤 human opens design-doc issue
          │
          ▼
  ┌───────────────────────┐
  │ design finalized? ────┼─── no ──► human edits issue ──┐
  └───────┬───────────────┘                               │
          │ yes                                           │
          ▼                                               │
  🐝 drafter appends milestone plan to issue ◄────────────┘
          │                                      ▲
          ▼                                      │
  ┌───────────────────────┐                      │
  │ plan finalized?   ────┼── no ──► human edits ┤
  │                       │          (drafter    │
  │                       │           re-plans)  │
  └───────┬───────────────┘                      │
          │ yes                                  │
          ▼                                      │
  🐝 drafter opens implementation PR ◄───────────┘
          │                          ▲
          ▼                          │
  🐝 reviewer reviews PR             │
          │                          │
          ▼                          │
  ┌───────────────────────┐          │
  │ approved?         ────┼── no ────┘ (drafter addresses feedback)
  └───────┬───────────────┘
          │ yes
          ▼
  🐝 e2e runs in sandbox repo
          │
          ▼
  ┌───────────────────────┐
  │ E2E passes?       ────┼── no ──► drafter fixes, re-enters loop
  └───────┬───────────────┘
          │ yes
          ▼
  🐝 merger squash-merges PR
          │
          ▼
  ┌───────────────────────┐
  │ more milestone steps? ┼── yes ──► back to drafter (next PR)
  └───────┬───────────────┘
          │ no
          ▼
      ✅ project shipped


  Pause paths (any agent can exit the loop by elevating to human):

  🐝 <agent> stuck (5 failed tries, ambiguous design, external blocker)
          │
          ▼
  runs `bee pause <n> "<reason>"` which atomically:
    1. adds `breeze:human` label to the issue/PR
    2. posts a **<role>: paused** comment with the reason
    3. removes the agent's `breeze:wip` claim
    4. exits cleanly
          │
          ▼
  👤 human reads comment, unblocks by one of:
    • edits the issue/PR to resolve the ambiguity
    • removes `breeze:human` to hand back to agents
    • comments with guidance and removes the label
          │
          ▼
  next tick re-dispatches an agent on the same item
```

## How it works

1. You open a **design-doc issue** describing what you want built; tick the "design finalized" checkbox when ready.
2. A cron (launchd) fires `scripts/tick.sh` every 5 minutes (default).
3. The tick checks: is an agent already running locally? If yes, exit.
4. Otherwise it scans the repo for open issues/PRs without a fresh `breeze:wip` claim and picks the oldest one.
5. It claims the item (adds `breeze:wip` label), spawns an agent, and exits.
6. The agent works the item to completion, then removes its claim.
7. When nothing is left open, the tick exits quietly. The project is finalized.

## Single-account mode

git-bee is a **one-account** system — all agents run as your GitHub account. This eliminates onboarding friction (no second GitHub account required) but means GitHub's self-review restrictions apply: you can't formally approve or request-changes on your own PR. Two HTML markers replace those actions.

### Approving a PR

Post a comment on the PR containing `<!-- bee:approved-for-e2e -->`. The marker must be at or after the current HEAD commit timestamp. The dispatcher advances the PR through E2E testing and merging without further pauses (unless new commits are pushed).

### Requesting changes on a PR

Use `bee request-changes <pr> [reason]` (or post a comment with `<!-- bee:changes-requested -->` manually). The dispatcher routes the PR to drafter for revision on the next tick.

## Labels

Four canonical labels plus one quarantine label. See `AGENTS.md` for the full state machine.

| Label | Meaning | Who sets |
|---|---|---|
| `breeze:wip` | An agent has claimed this item | `claim_acquire` |
| `breeze:human` | Agent needs human judgment | Any agent via `bee pause` |
| `breeze:done` | All work complete | Merger, auditor, janitor |
| `breeze:quarantine-hotloop` | Hot-loop detected; dispatcher skips | Tick's hot-loop detector |

Stale `breeze:wip` = labeled-event timestamp older than 2 hours. Any agent may take over a stale claim. The `breeze:done` transition happens automatically on merge/close via merger and a periodic janitor sweep.

## Agent roles

- [`agents/drafter.md`](agents/drafter.md) — Reads a design-doc issue, drafts the design in comments, opens implementation PRs linked with `Fixes #<issue>`. Also addresses reviewer feedback.
- [`agents/planner.md`](agents/planner.md) — Breaks thin design-doc issues into a milestone plan before drafter implements.
- [`agents/reviewer.md`](agents/reviewer.md) — Reviews implementation PRs with a three-state verdict: approve / request-changes / escalate.
- [`agents/e2e.md`](agents/e2e.md) — Runs E2E for a PR in a sandbox repo. Commits each step as its own commit; the Git log is the test trace.
- [`agents/e2e-designer.md`](agents/e2e-designer.md) — Writes e2e test cases for PRs that lack one.
- [`agents/e2e-supervisor.md`](agents/e2e-supervisor.md) — Classifies e2e failures (lazy-run, code-bug, test-bug, design-trivial, design-conflicting).
- [`agents/merger.md`](agents/merger.md) — Squash-merges approved PRs with passing E2E; transitions to `breeze:done`, closes linked issues.
- [`agents/auditor.md`](agents/auditor.md) — Fresh-context audit of multi-PR design-doc coverage. Closes the umbrella only if all coverage checks pass, else labels `breeze:human`.

## Safety mechanisms

- **PID lock** (`/tmp/git-bee-agent.pid`) prevents concurrent agents on the same machine.
- **3-crash rollback**: three consecutive non-zero ticks roll back to the last known-good SHA and pause the loop via `~/.git-bee/ROLLBACK`.
- **Hot-loop quarantine**: dispatching the same agent on the same target twice within 5 minutes with `outcome=null` quarantines the PR and files a bug.
- **Pre-push guard**: `scripts/preflight-push.sh` refuses pushes targeting `main` or `master`.

## Setup

### Git hooks

To prevent syntax errors from being pushed to main (issue #557), install the pre-push hook:

```bash
./scripts/install-hooks.sh
```

This validates `tick.sh` and other critical scripts before allowing pushes to main.

### Cron

`launchd/com.serenakeyitan.git-bee.plist` — installs `scripts/tick.sh` as a 5-minute launch agent (default). Install with:

```bash
cp launchd/com.serenakeyitan.git-bee.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.serenakeyitan.git-bee.plist
```

Uninstall with `launchctl unload ...`.

## Status

Early. See [issue #1](https://github.com/serenakeyitan/git-bee/issues/1) — the bootstrap design doc.
