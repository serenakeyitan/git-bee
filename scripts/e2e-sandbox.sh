#!/usr/bin/env bash
# git-bee E2E sandbox: consolidated trace repo.
#
# Every PR's E2E run lives as a branch `trace/<short-sha>` in a single
# canonical repo `serenakeyitan/git-bee-e2e`. On finalize, an immutable
# annotated tag `trace-<short-sha>-<unix-ts>` is pushed and the branch
# is deleted. Tags preserve history; branches are cleaned up after 30d.
#
# Usage:
#   scripts/e2e-sandbox.sh create <pr-number>
#     → ensures canonical repo exists, creates orphan branch
#       trace/<short-sha> with step-00 bootstrap, prints local worktree path
#
#   scripts/e2e-sandbox.sh step <sandbox-path> "<desc>" "<cmd>"
#     → runs <cmd>, commits stdout/stderr/exit-code as step-NN.
#       Fails fast unless STEP_ALLOW_FAIL=1.
#
#   scripts/e2e-sandbox.sh skip <sandbox-path> "<desc>" "<reason>"
#     → commits step-NN as "skipped — reason"
#
#   scripts/e2e-sandbox.sh finalize <sandbox-path> <pass|fail> [reason]
#     → final commit, push branch, create+push tag trace-<sha>-<ts>,
#       delete branch locally and on remote, post PR comment linking the tag.
#
#   scripts/e2e-sandbox.sh cleanup [days]
#     → prunes trace/* branches older than <days> (default 30) from the
#       canonical remote. Tags are never touched.

set -euo pipefail

UPSTREAM_REPO="serenakeyitan/git-bee"
TRACE_REPO="serenakeyitan/git-bee-e2e"
TRACE_REMOTE="https://github.com/${TRACE_REPO}.git"
E2E_ROOT="/tmp/git-bee-e2e"
mkdir -p "$E2E_ROOT"

_ensure_trace_repo() {
  if ! gh repo view "$TRACE_REPO" --json name >/dev/null 2>&1; then
    gh repo create "$TRACE_REPO" --private \
      --description "Consolidated E2E traces for git-bee PRs. One branch+tag per run." \
      --clone=false >/dev/null
    # Seed main so branches have a base to push against.
    local seed="$E2E_ROOT/.seed"
    rm -rf "$seed"
    mkdir -p "$seed"
    (
      cd "$seed"
      git init -q -b main
      cat > README.md <<'EOF'
# git-bee E2E traces

One branch `trace/<short-sha>` per run. On finalize, an annotated tag
`trace-<short-sha>-<unix-ts>` is pushed and the branch is deleted.
Tags preserve history permanently; old branches are pruned after 30d.
EOF
      git add README.md
      git -c commit.gpgsign=false commit -q -m "seed: canonical trace repo"
      git remote add origin "$TRACE_REMOTE"
      git push -q -u origin main
    )
    rm -rf "$seed"
  fi
}

_next_step_num() {
  local path="$1"
  local last
  last=$(git -C "$path" log --format='%s' 2>/dev/null | grep -oE '^step-[0-9]+' | head -1 | sed 's/step-//' || echo "00")
  printf "%02d" $((10#${last:-00} + 1))
}

cmd_create() {
  local pr_number="$1"
  local pr_sha
  pr_sha=$(gh pr view "$pr_number" --repo "$UPSTREAM_REPO" --json headRefOid --jq '.headRefOid')
  local short_sha="${pr_sha:0:7}"
  local branch="trace/${short_sha}"
  local sandbox_path="$E2E_ROOT/${short_sha}"

  if [[ -d "$sandbox_path/.git" ]]; then
    echo "sandbox already exists at $sandbox_path" >&2
    echo "$sandbox_path"
    return 0
  fi

  _ensure_trace_repo

  rm -rf "$sandbox_path"
  mkdir -p "$sandbox_path"
  cd "$sandbox_path"
  git init -q -b "$branch"
  git remote add origin "$TRACE_REMOTE"
  git config --local gpg.format ssh
  git config --local user.signingkey "$HOME/.ssh/id_ed25519.pub"
  git config --local commit.gpgsign true

  cat > README.md <<EOF
# E2E trace — git-bee #${pr_number} @ ${short_sha}

Each commit is one E2E step. The Git log is the test trace.

- Upstream PR: https://github.com/${UPSTREAM_REPO}/pull/${pr_number}
- SHA under test: ${pr_sha}
- Branch: ${branch}
EOF
  cat > .meta.json <<EOF
{
  "pr_number": ${pr_number},
  "pr_sha": "${pr_sha}",
  "short_sha": "${short_sha}",
  "branch": "${branch}",
  "upstream": "${UPSTREAM_REPO}",
  "trace_repo": "${TRACE_REPO}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  git add -A
  git commit -q -S -m "step-00 bootstrap trace for PR #${pr_number} @ ${short_sha}"
  git push -q -u origin "$branch"

  echo "$sandbox_path"
}

cmd_step() {
  local sandbox_path="$1" desc="$2" cmd="$3"
  sandbox_path=$(cd "$sandbox_path" && pwd)
  cd "$sandbox_path"
  local branch
  branch=$(jq -r '.branch' .meta.json)
  local pr_number
  pr_number=$(jq -r '.pr_number' .meta.json)
  local num
  num=$(_next_step_num "$sandbox_path")
  local out err exit_code
  out=$(mktemp) err=$(mktemp)

  # Check if this is a verify.sh invocation
  if [[ "$cmd" =~ tests/e2e/verify\.sh ]]; then
    # Use e2e-runner.sh instead of direct execution
    local runner_cmd="scripts/e2e-runner.sh $pr_number"
    set +e
    # Run from the git-bee root, not the sandbox
    (cd "$(dirname "$0")/.." && bash -c "$runner_cmd") >"$out" 2>"$err"
    exit_code=$?
    set -e
  else
    # Regular command execution
    set +e
    bash -c "$cmd" >"$out" 2>"$err"
    exit_code=$?
    set -e
  fi

  local step_dir="steps/step-${num}"
  mkdir -p "$step_dir"
  cp "$out" "$step_dir/stdout.txt"
  cp "$err" "$step_dir/stderr.txt"
  echo "$exit_code" > "$step_dir/exit-code"
  echo "$cmd" > "$step_dir/command"
  echo "$desc" > "$step_dir/description"

  git add -A
  local msg_body
  msg_body=$(cat <<EOF
step-${num} ${desc}

command:
${cmd}

exit_code: ${exit_code}

stdout (first 4KB):
$(head -c 4096 "$out")

stderr (first 4KB):
$(head -c 4096 "$err")
EOF
)
  git commit -q -S -m "$msg_body"
  git push -q origin "$branch"

  rm -f "$out" "$err"

  if [[ "$exit_code" != "0" && "${STEP_ALLOW_FAIL:-0}" != "1" ]]; then
    echo "step-${num} FAILED (exit ${exit_code})" >&2
    return "$exit_code"
  fi
  echo "step-${num} ok"
}

cmd_skip() {
  local sandbox_path="$1" desc="$2" reason="$3"
  sandbox_path=$(cd "$sandbox_path" && pwd)
  cd "$sandbox_path"
  local branch
  branch=$(jq -r '.branch' .meta.json)
  local num
  num=$(_next_step_num "$sandbox_path")
  local step_dir="steps/step-${num}"
  mkdir -p "$step_dir"
  echo "skipped" > "$step_dir/exit-code"
  echo "$desc" > "$step_dir/description"
  echo "$reason" > "$step_dir/skip-reason"
  git add -A
  git commit -q -S -m "step-${num} skipped — ${desc} — ${reason}"
  git push -q origin "$branch"
  echo "step-${num} skipped"
}

cmd_finalize() {
  local sandbox_path="$1" result="$2" reason="${3:-}"
  sandbox_path=$(cd "$sandbox_path" && pwd)
  cd "$sandbox_path"
  local pr_number short_sha branch
  pr_number=$(jq -r '.pr_number' .meta.json)
  short_sha=$(jq -r '.short_sha' .meta.json)
  branch=$(jq -r '.branch' .meta.json)

  local msg="final: ${result}"
  [[ -n "$reason" ]] && msg="${msg} — ${reason}"

  cat > FINAL.md <<EOF
# Result: ${result}

${reason:-No additional notes.}

See the step-NN commits for the full trace.
EOF
  git add -A
  git commit -q -S --allow-empty -m "$msg"
  git push -q origin "$branch"

  local ts tag
  ts=$(date -u +%s)
  tag="trace-${short_sha}-${ts}"
  git tag -s -a "$tag" -m "E2E trace for PR #${pr_number} @ ${short_sha} — ${result}${reason:+ — $reason}"
  git push -q origin "$tag"

  # Delete branch locally and on remote; tag preserves the history.
  git push -q origin --delete "$branch" || true

  local tag_url="https://github.com/${TRACE_REPO}/tree/${tag}"
  gh pr comment "$pr_number" --repo "$UPSTREAM_REPO" --body "$(cat <<EOF
**E2E trace (${result})**

Trace: ${tag_url}

Each commit at that tag is one verifiable step; the Git log is the full trace. The final commit records the outcome.

$([ "$result" = "fail" ] && echo "Failing reason: ${reason}")

---
_Posted by git-bee E2E agent._
EOF
)" >/dev/null

  echo "finalized ${result}: ${tag_url}"
}

cmd_cleanup() {
  local days="${1:-30}"
  local cutoff
  cutoff=$(( $(date -u +%s) - days * 86400 ))
  # List remote trace/* branches with their tip commit dates.
  local tmpdir
  tmpdir=$(mktemp -d)
  (
    cd "$tmpdir"
    git init -q
    git remote add origin "$TRACE_REMOTE"
    git fetch -q origin "+refs/heads/trace/*:refs/remotes/origin/trace/*"
    local b ts
    for ref in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin/trace/); do
      b="${ref#origin/}"
      ts=$(git log -1 --format='%ct' "$ref")
      if (( ts < cutoff )); then
        echo "pruning $b (age $(( ($(date -u +%s) - ts) / 86400 ))d)"
        git push -q origin --delete "$b" || true
      fi
    done
  )
  rm -rf "$tmpdir"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  create)   cmd_create "$@" ;;
  step)     cmd_step "$@" ;;
  skip)     cmd_skip "$@" ;;
  finalize) cmd_finalize "$@" ;;
  cleanup)  cmd_cleanup "$@" ;;
  *) cat >&2 <<EOF
usage:
  e2e-sandbox.sh create <pr-number>
  e2e-sandbox.sh step <sandbox-path> "<desc>" "<cmd>"
  e2e-sandbox.sh skip <sandbox-path> "<desc>" "<reason>"
  e2e-sandbox.sh finalize <sandbox-path> <pass|fail> [reason]
  e2e-sandbox.sh cleanup [days=30]
EOF
  exit 2 ;;
esac
