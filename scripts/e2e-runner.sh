#!/usr/bin/env bash
# e2e-runner.sh — invokes a PR's tests/e2e/verify.sh, captures NDJSON transcript, writes eval artifact
#
# Usage:
#   scripts/e2e-runner.sh <pr-number>
#
# - Fails closed (exit 2) if PR lacks tests/e2e/verify.sh
# - Captures stdout as NDJSON line-by-line
# - Writes crash-safe artifact to ~/.git-bee/evals/<pr-sha>-<ts>.json
#
# Exit codes:
#   0 — verify.sh passed
#   1 — verify.sh failed
#   2 — verify.sh missing (fail-closed)
#   3 — artifact write error

set -euo pipefail

UPSTREAM_REPO="serenakeyitan/git-bee"

if [[ $# -ne 1 ]]; then
  echo "usage: e2e-runner.sh <pr-number>" >&2
  exit 2
fi

pr_number="$1"

# Get PR SHA
pr_sha=$(gh pr view "$pr_number" --repo "$UPSTREAM_REPO" --json headRefOid --jq '.headRefOid')
short_sha="${pr_sha:0:7}"

# Check if verify.sh exists at the PR SHA
if ! gh api "repos/$UPSTREAM_REPO/contents/tests/e2e/verify.sh?ref=$pr_sha" --jq '.content' >/dev/null 2>&1; then
  echo "ERROR: PR #${pr_number} lacks tests/e2e/verify.sh — fail-closed" >&2
  exit 2
fi

# Prepare artifact directory
eval_dir="$HOME/.git-bee/evals"
mkdir -p "$eval_dir"

ts=$(date -u +%s)
artifact_path="${eval_dir}/${short_sha}-${ts}.json"
tmp_artifact="${artifact_path}.tmp"

# Clone the PR branch to a temporary location
tmp_clone=$(mktemp -d)
trap "rm -rf '$tmp_clone'" EXIT

echo "Cloning PR #${pr_number} @ ${short_sha} to temporary location..." >&2
git clone --quiet --depth=1 --branch "$(gh pr view "$pr_number" --repo "$UPSTREAM_REPO" --json headRefName --jq '.headRefName')" \
  "https://github.com/$UPSTREAM_REPO.git" "$tmp_clone" >&2

# Start NDJSON transcript
{
  echo '{"type": "metadata", "pr_number": '"$pr_number"', "pr_sha": "'"$pr_sha"'", "short_sha": "'"$short_sha"'", "started_at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
} > "$tmp_artifact"

# Run verify.sh and capture output line-by-line as NDJSON
cd "$tmp_clone"
echo "Running tests/e2e/verify.sh..." >&2

exit_code=0
line_num=0
while IFS= read -r line; do
  line_num=$((line_num + 1))
  # Escape the line for JSON
  escaped_line=$(echo -n "$line" | jq -Rs .)
  echo '{"type": "stdout", "line": '"$line_num"', "content": '"$escaped_line"', "timestamp": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' >> "$tmp_artifact"
  echo "$line"  # Pass through to stdout
done < <(bash tests/e2e/verify.sh 2>&1 && echo "VERIFY_EXIT_CODE:0" || echo "VERIFY_EXIT_CODE:$?")

# Extract exit code from the last line
last_line=$(tail -1 "$tmp_artifact" | jq -r '.content' 2>/dev/null || echo "")
if [[ "$last_line" =~ ^VERIFY_EXIT_CODE:([0-9]+)$ ]]; then
  verify_exit="${BASH_REMATCH[1]}"
  # Remove the exit code marker line from transcript
  head -n -1 "$tmp_artifact" > "${tmp_artifact}.clean" && mv "${tmp_artifact}.clean" "$tmp_artifact"
else
  # Fallback if we couldn't capture exit code properly
  verify_exit=1
fi

# Add final entry with result
{
  echo '{"type": "result", "exit_code": '"$verify_exit"', "completed_at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
} >> "$tmp_artifact"

# Atomic rename (crash-safe)
if mv "$tmp_artifact" "$artifact_path"; then
  echo "Artifact written: $artifact_path" >&2
else
  echo "ERROR: Failed to write artifact to $artifact_path" >&2
  rm -f "$tmp_artifact"
  exit 3
fi

# Exit with verify.sh's exit code
exit "$verify_exit"