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

  # Track start time for duration measurement
  local start_timestamp
  # macOS doesn't support %N, use python for cross-platform millisecond timestamps
  start_timestamp=$(python3 -c 'import time; print(int(time.time() * 1000))')

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
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "start_timestamp_ms": ${start_timestamp},
  "steps": [],
  "tokens": {"input": 0, "output": 0},
  "cost_usd_cents": 0
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

  # Check if stdout contains JSON assertions in the format {"passed": N, "total": M}
  local assertions='{"passed": 1, "total": 1}'  # default for simple exit code
  if [[ "$exit_code" == "0" ]]; then
    # Try to parse JSON assertions from the last line of stdout
    local last_line
    last_line=$(tail -n1 "$out" 2>/dev/null || echo "")
    if echo "$last_line" | grep -qE '^\s*\{"passed":\s*[0-9]+\s*,\s*"total":\s*[0-9]+\s*\}\s*$'; then
      assertions="$last_line"
      # Validate that passed <= total
      local passed total
      passed=$(echo "$assertions" | sed -nE 's/.*"passed":\s*([0-9]+).*/\1/p')
      total=$(echo "$assertions" | sed -nE 's/.*"total":\s*([0-9]+).*/\1/p')
      if [[ "$passed" != "$total" ]]; then
        exit_code=1  # Override exit code if not all assertions passed
      fi
    fi
  else
    assertions='{"passed": 0, "total": 1}'
  fi

  local step_dir="steps/step-${num}"
  mkdir -p "$step_dir"
  cp "$out" "$step_dir/stdout.txt"
  cp "$err" "$step_dir/stderr.txt"
  echo "$exit_code" > "$step_dir/exit-code"
  echo "$cmd" > "$step_dir/command"
  echo "$desc" > "$step_dir/description"
  echo "$assertions" > "$step_dir/assertions.json"

  # Update .meta.json with step info
  local step_info
  step_info=$(jq -n \
    --arg n "$num" \
    --arg desc "$desc" \
    --argjson exit "$exit_code" \
    --argjson assertions "$assertions" \
    '{
      "n": ($n | tonumber),
      "description": $desc,
      "exit": $exit,
      "skipped": false,
      "assertions": $assertions
    }')

  jq ".steps += [$step_info]" .meta.json > .meta.json.tmp && mv .meta.json.tmp .meta.json

  git add -A
  local msg_body
  msg_body=$(cat <<EOF
step-${num} ${desc}

command:
${cmd}

exit_code: ${exit_code}
assertions: ${assertions}

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

  # Update .meta.json with skipped step info
  local step_info
  step_info=$(jq -n \
    --arg n "$num" \
    --arg desc "$desc" \
    --arg reason "$reason" \
    '{
      "n": ($n | tonumber),
      "description": $desc,
      "exit": 0,
      "skipped": true,
      "skip_reason": $reason,
      "assertions": {"passed": 0, "total": 0}
    }')

  jq ".steps += [$step_info]" .meta.json > .meta.json.tmp && mv .meta.json.tmp .meta.json

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
  local pr_number pr_sha
  pr_number=$(jq -r '.pr_number' .meta.json)
  pr_sha=$(jq -r '.pr_sha' .meta.json)

  # Calculate duration
  local start_timestamp end_timestamp duration_ms
  start_timestamp=$(jq -r '.start_timestamp_ms' .meta.json)
  # macOS doesn't support %N, use python for cross-platform millisecond timestamps
  end_timestamp=$(python3 -c 'import time; print(int(time.time() * 1000))')
  duration_ms=$((end_timestamp - start_timestamp))

  # Get token and cost metrics (from .meta.json if updated by agents)
  local tokens cost_usd_cents
  tokens=$(jq -c '.tokens // {"input": 0, "output": 0}' .meta.json)
  cost_usd_cents=$(jq -r '.cost_usd_cents // 0' .meta.json)

  # Generate RESULT.json
  local steps_array
  steps_array=$(jq -c '.steps' .meta.json)

  cat > RESULT.json <<EOF
{
  "pr": ${pr_number},
  "sha": "${pr_sha:0:7}",
  "status": "${result}",
  "steps": ${steps_array},
  "duration_ms": ${duration_ms},
  "tokens": ${tokens},
  "cost_usd_cents": ${cost_usd_cents}
}
EOF

  local msg="final: ${result}"
  [[ -n "$reason" ]] && msg="${msg} — ${reason}"

  cat > FINAL.md <<EOF
# Result: ${result}

${reason:-No additional notes.}

See the step-NN commits for the full trace.

## Metrics Summary

- Duration: ${duration_ms}ms
- Tokens: $(echo "$tokens" | jq -r '"input: \(.input), output: \(.output)"')
- Estimated cost: \$$(printf "%.2f" $(echo "scale=2; $cost_usd_cents / 100" | bc))

Machine-readable metrics in RESULT.json.
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

cmd_update_metrics() {
  local sandbox_path="$1"
  local input_tokens="${2:-0}"
  local output_tokens="${3:-0}"
  local cost_cents="${4:-0}"

  # Resolve to absolute path
  sandbox_path=$(cd "$sandbox_path" && pwd)
  cd "$sandbox_path"

  # Update metrics in .meta.json
  jq ".tokens.input += $input_tokens | .tokens.output += $output_tokens | .cost_usd_cents += $cost_cents" \
    .meta.json > .meta.json.tmp && mv .meta.json.tmp .meta.json

  echo "updated metrics: +${input_tokens} input, +${output_tokens} output, +${cost_cents}¢"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  create)   cmd_create "$@" ;;
  step)     cmd_step "$@" ;;
  skip)     cmd_skip "$@" ;;
  finalize) cmd_finalize "$@" ;;
  update-metrics) cmd_update_metrics "$@" ;;
  *) cat >&2 <<EOF
usage:
  e2e-sandbox.sh create <pr-number>
  e2e-sandbox.sh step <sandbox-path> "<desc>" "<cmd>"
  e2e-sandbox.sh skip <sandbox-path> "<desc>" "<reason>"
  e2e-sandbox.sh finalize <sandbox-path> <pass|fail> [reason]
  e2e-sandbox.sh update-metrics <sandbox-path> [input-tokens] [output-tokens] [cost-cents]
EOF
  exit 2 ;;
esac
