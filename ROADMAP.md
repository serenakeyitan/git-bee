# git-bee Roadmap

This roadmap defines the canonical next N work items for autonomous agent execution. Agents pull from this list in order when current work depletes.

## v0.2.0 — Autonomous-safe operation + circuit breakers + minimal breeze alignment

**Theme:** v0.2.0 makes git-bee genuinely autonomous-safe — you can leave it running for 8+ hours without a human in the loop and it will self-recover rather than cascade-fail.

**Status:** IN PROGRESS

### M1 — Circuit breakers on cascading agent behavior ✓

**Problem:** Cascading failures where agents repeatedly file duplicate issues/PRs for the same root cause.

- ✓ PR 1: Dedup supervisor-filed divergence issues (#835)
- ✓ PR 2: Duplicate-PR detection on drafter entry (#804)
- ✓ PR 3: Meta-loop detector (#840)

### M2 — Overnight self-heal ✓

**Problem:** Wedged agents stay quarantined until human intervention, blocking 8h unattended operation.

- ✓ PR 4: Auto-release quarantine when fix PR merges (#868)
- ✓ PR 5: Nightly janitor for stale quarantines (#887)
- ✓ PR 6: Heartbeat + deadman switch (#897)

### M3 — Roadmap-driven work queue

**Problem:** Without explicit roadmap, agents sit idle or invent features.

- ✓ PR 7: Planner reads ROADMAP.md (#917)
- PR 8: ROADMAP.md scaffold (this file)
- PR 9: Dispatcher prefers roadmap-sourced issues

### M4 — Minimal breeze alignment (Phase 1c)

**Problem:** Phase 1a delegated label inventory to breeze. Phase 2 blocked on breeze questions. Ship useful middle-ground work.

- PR 10: `bee` CLI gains `--breeze-compat` flag for cross-product integration
- PR 11: Agent status-line parser extracted to `scripts/parse-status.sh`
- PR 12: File Phase-2 blocker questions on `agent-team-foundation/first-tree`

### M5 — v0.2.0 release

- PR 13: Bump VERSION → 0.2.0, create tag, GitHub release with auto-notes
  - **Merge gate:** All 12 preceding PRs merged AND soaked 48h without rollback AND no `breeze:human` items open

### M6 — Full breeze integration (Phase 2 execution)

**Problem:** git-bee still uses custom tick.sh dispatch. End state: fully runs on breeze daemon.

**Note:** Phase 2 requires answers to 5 blocker questions. If answers don't arrive, vendor breeze modules locally.

- PR 14: File 5 blocker questions on `agent-team-foundation/first-tree`
- PR 15: Implement `RepoStateCandidateSource` in git-bee fork/vendor
- PR 16: Port escape hatches (`bee:approved-for-e2e`, `bee:changes-requested`)
- PR 17: Port 4 safety mechanisms (rollback, quarantine, pre-push guard, janitor)
- PR 18: Port routing intelligence (supervisor verdict routing, tiny-fix fast path, design-doc handling)
- PR 19: Rewrite 8 agent prompts for breeze-runner compatibility
- PR 20: Feature-flagged cutover: `GIT_BEE_USE_BREEZE=1` switches to breeze dispatch
- PR 21: Soak-test run — side-by-side comparison for 48h, zero divergence required
- PR 22: Flip default to breeze dispatch, delete tick.sh
- PR 23: v0.3.0 release (breeze-native milestone)

## v0.3.0 — Full breeze integration

**Theme:** git-bee runs entirely on breeze daemon. `scripts/tick.sh` deleted.

**Status:** NOT STARTED

**Success criteria:**
- `scripts/tick.sh` deleted from main
- git-bee runs on breeze (vendored or upstream) for 72h unattended before release tag
- Zero dispatch divergence between old tick.sh and breeze daemon

**Dependencies:**
- Blocker questions answered by breeze maintainers OR vendored breeze implementation complete

---

## Roadmap maintenance

This file is maintained by:
1. **Planner agent:** Reads this file and files next milestone issue when backlog is thin
2. **Drafter agent:** Updates checkmarks (✓) and PR links as work completes
3. **Human:** Adds new milestones and adjusts priorities

Last updated: 2026-04-28
