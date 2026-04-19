# Runbook

How the loop actually runs. Read this if you're operating the bee.

## Install

```bash
./scripts/install.sh
```

Does: checks prereqs (gh, git, jq, claude), configures SSH signing on the repo, creates the three `breeze:*` labels if missing, writes the launchd plist into `~/Library/LaunchAgents/`, loads it. Idempotent.

## One tick

```bash
./scripts/tick.sh
```

1. If `/tmp/git-bee-agent.pid` exists and the PID is alive → exit (agent already running).
2. Pick a target with this priority (oldest-first within each bucket):
   1. **Approved PR with passing E2E** → merger agent (merges, closes linked issues with `breeze:done`)
   2. **Approved PR without E2E yet** → E2E agent (`APPROVED` or `<!-- bee:approved-for-e2e -->` marker in a review counts as approved)
   3. **Unreviewed PR** (no review at current HEAD) → reviewer agent
   4. **PR with non-approving review** → drafter agent (addresses feedback)
   5. **Open issue with no linked open PR and no `breeze:wip`** → drafter agent
3. If no target → exit quietly (project finalized).
4. Acquire `breeze:wip` + post timestamped claim comment.
5. Write PID lock, spawn `claude -p` with the matching role prompt.
6. On exit, release the claim and remove the lock.

## Claim protocol

Every agent uses `scripts/claim.sh`:

- `claim.sh check <repo> <n>` → `free | fresh-claim | stale-claim`
- `claim.sh acquire <repo> <n> <agent-id>` → sets label + posts `<!-- breeze:claimed-at=<iso> by=<agent-id> -->`
- `claim.sh release <repo> <n> <agent-id>` → removes label, leaves marker as audit trail
- `claim.sh mine <repo> <n> <agent-id>` → `yes | no` — am I the latest claimer?

A claim is **fresh** if the newest claim marker is within `CLAIM_TTL_SECONDS` (default 2h).
A claim is **stale** if older — any agent may forcibly re-claim.

## E2E sandbox

Every implementation PR gets its own E2E run:

```bash
path=$(./scripts/e2e-sandbox.sh create 123)
./scripts/e2e-sandbox.sh step "$path" "install from fresh clone" "./scripts/install.sh"
./scripts/e2e-sandbox.sh step "$path" "tick exits idle when no work" "./scripts/tick.sh"
./scripts/e2e-sandbox.sh skip "$path" "ssh signing" "CI does not have user key"
./scripts/e2e-sandbox.sh finalize "$path" pass
```

Each step is an SSH-signed commit in a private throwaway repo `serenakeyitan/git-bee-e2e-<sha>`. The commit message contains stdout, stderr, exit code, and the command that ran. The Git log is the test trace — replay with `git log` or visit the repo on GitHub.

On finalize, the sandbox is archived and a comment is posted on the implementation PR with a link.

## Labels

| Label | When | Who |
|---|---|---|
| `breeze:wip` | An agent has claimed this item | Any agent (via `claim.sh acquire`) |
| `breeze:done` | Work is complete | Drafter, on close |
| `breeze:human` | Agent gave up after N attempts (default 5) | Responder/drafter, before stopping |

Absence of any label on an open item = fair game.

## Termination

The loop halts when `scripts/tick.sh` finds zero unclaimed open items. For your project to be finalized:

- All design-doc issues closed with `breeze:done`
- All linked PRs merged
- All E2E sandboxes commented with `final: pass`
- Nothing open, nothing unclaimed

Cron will keep firing every 15 min. It exits silently when there's no work. That's the termination state.
