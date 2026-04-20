#!/usr/bin/env bash
# git-bee E2E sandbox: creates a throwaway repo, commits each step as its
# own SSH-signed commit, and the Git log IS the test trace.
#
# Usage:
#   scripts/e2e-sandbox.sh create <pr-number>
#     → creates serenakeyitan/git-bee-e2e-<pr-sha> as a private repo,
#       clones locally under /tmp, prints the path + URL
#
#   scripts/e2e-sandbox.sh step <sandbox-path> "<step description>" "<cmd>"
#     → runs <cmd>, commits stdout/stderr/exit-code as step-NN,
#       fails fast if the command fails unless STEP_ALLOW_FAIL=1
#
#   scripts/e2e-sandbox.sh skip <sandbox-path> "<step description>" "<reason>"
#     → commits step-NN as "skipped — reason"
#
#   scripts/e2e-sandbox.sh finalize <sandbox-path> <pass|fail> [reason]
#     → final commit, pushes, archives the repo, posts comment on the PR
#
# Every commit is SSH-signed. The commit message contains the full stdout,
# stderr, and exit code, making the log independently auditable.

set -euo pipefail

UPSTREAM_REPO="serenakeyitan/git-bee"
E2E_ROOT="/tmp/git-bee-e2e"
mkdir -p "$E2E_ROOT"

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
  local sandbox_name="git-bee-e2e-${short_sha}"
  local sandbox_path="$E2E_ROOT/$sandbox_name"

  if [[ -d "$sandbox_path" ]]; then
    echo "sandbox already exists at $sandbox_path" >&2
    echo "$sandbox_path"
    return 0
  fi

  gh repo create "serenakeyitan/$sandbox_name" --private \
    --description "E2E trace for git-bee PR #${pr_number} @ ${short_sha}" \
    --clone=false >/dev/null

  mkdir -p "$sandbox_path"
  cd "$sandbox_path"
  git init -q -b main
  git remote add origin "https://github.com/serenakeyitan/$sandbox_name.git"
  git config --local gpg.format ssh
  git config --local user.signingkey "$HOME/.ssh/id_ed25519.pub"
  git config --local commit.gpgsign true

  cat > README.md <<EOF
# E2E trace — git-bee #${pr_number} @ ${short_sha}

Each commit is one E2E step. The Git log is the test trace.

- Upstream PR: https://github.com/${UPSTREAM_REPO}/pull/${pr_number}
- SHA under test: ${pr_sha}
EOF
  cat > .meta.json <<EOF
{
  "pr_number": ${pr_number},
  "pr_sha": "${pr_sha}",
  "upstream": "${UPSTREAM_REPO}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  git add -A
  git commit -q -S -m "step-00 bootstrap sandbox for PR #${pr_number} @ ${short_sha}"
  git push -q -u origin main

  echo "$sandbox_path"
}

cmd_step() {
  local sandbox_path="$1" desc="$2" cmd="$3"
  # Resolve to absolute path to avoid issues with relative paths like "."
  sandbox_path=$(cd "$sandbox_path" && pwd)
  cd "$sandbox_path"
  local num
  num=$(_next_step_num "$sandbox_path")
  local out err exit_code
  out=$(mktemp) err=$(mktemp)
  set +e
  bash -c "$cmd" >"$out" 2>"$err"
  exit_code=$?
  set -e

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
  git push -q origin main

  rm -f "$out" "$err"

  if [[ "$exit_code" != "0" && "${STEP_ALLOW_FAIL:-0}" != "1" ]]; then
    echo "step-${num} FAILED (exit ${exit_code})" >&2
    return "$exit_code"
  fi
  echo "step-${num} ok"
}

cmd_skip() {
  local sandbox_path="$1" desc="$2" reason="$3"
  # Resolve to absolute path to avoid issues with relative paths like "."
  sandbox_path=$(cd "$sandbox_path" && pwd)
  cd "$sandbox_path"
  local num
  num=$(_next_step_num "$sandbox_path")
  local step_dir="steps/step-${num}"
  mkdir -p "$step_dir"
  echo "skipped" > "$step_dir/exit-code"
  echo "$desc" > "$step_dir/description"
  echo "$reason" > "$step_dir/skip-reason"
  git add -A
  git commit -q -S -m "step-${num} skipped — ${desc} — ${reason}"
  git push -q origin main
  echo "step-${num} skipped"
}

cmd_finalize() {
  local sandbox_path="$1" result="$2" reason="${3:-}"
  # Resolve to absolute path to avoid issues with relative paths like "."
  sandbox_path=$(cd "$sandbox_path" && pwd)
  cd "$sandbox_path"
  local pr_number
  pr_number=$(jq -r '.pr_number' .meta.json)

  local msg="final: ${result}"
  [[ -n "$reason" ]] && msg="${msg} — ${reason}"

  cat > FINAL.md <<EOF
# Result: ${result}

${reason:-No additional notes.}

See the step-NN commits for the full trace.
EOF
  git add -A
  git commit -q -S --allow-empty -m "$msg"
  git push -q origin main

  # Archive to prevent future drift
  local sandbox_name
  sandbox_name=$(basename "$sandbox_path")
  gh repo archive "serenakeyitan/$sandbox_name" --yes >/dev/null 2>&1 || true

  # Post back to the implementation PR
  local sandbox_url="https://github.com/serenakeyitan/$sandbox_name"
  gh pr comment "$pr_number" --repo "$UPSTREAM_REPO" --body "$(cat <<EOF
**E2E trace (${result})**

Sandbox: ${sandbox_url}

Each commit in that repo is one verifiable step; the Git log is the full trace. The final commit records the outcome.

$([ "$result" = "fail" ] && echo "Failing reason: ${reason}")

---
_Posted by git-bee E2E agent._
EOF
)" >/dev/null

  echo "finalized ${result}: ${sandbox_url}"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  create)   cmd_create "$@" ;;
  step)     cmd_step "$@" ;;
  skip)     cmd_skip "$@" ;;
  finalize) cmd_finalize "$@" ;;
  *) cat >&2 <<EOF
usage:
  e2e-sandbox.sh create <pr-number>
  e2e-sandbox.sh step <sandbox-path> "<desc>" "<cmd>"
  e2e-sandbox.sh skip <sandbox-path> "<desc>" "<reason>"
  e2e-sandbox.sh finalize <sandbox-path> <pass|fail> [reason]
EOF
  exit 2 ;;
esac
