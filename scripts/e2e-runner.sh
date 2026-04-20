#!/usr/bin/env bash
# git-bee E2E runner: canonical harness for invoking a PR's
# tests/e2e/verify.sh. Captures stdout as an NDJSON transcript and writes
# a crash-safe JSON artifact to ~/.git-bee/evals/<sha>-<ts>.json via
# tmp+rename, so a SIGTERM mid-run can never leave a half-written file.
#
# Usage:
#   e2e-runner.sh <pr-checkout-path> <pr-sha>
#     → runs <pr-checkout-path>/tests/e2e/verify.sh
#     → writes ~/.git-bee/evals/<short-sha>-<ts>.json
#     → prints the artifact path on stdout
#     → exit 0 if verify.sh ran to completion (even if cases failed)
#     → exit 2 if verify.sh is missing
#     → exit 1 on any other error
#
# The verify.sh contract (from the design doc):
#   - Prints one JSON line at the end: {"passed": N, "total": M}
#   - Exit 0 whether or not cases passed — the JSON line is the verdict
#   - May print additional NDJSON lines before the verdict for per-case detail

set -uo pipefail

EVALS_DIR="${HOME}/.git-bee/evals"
mkdir -p "$EVALS_DIR"

usage() {
  cat >&2 <<EOF
usage: e2e-runner.sh <pr-checkout-path> <pr-sha>
EOF
  exit 64
}

[[ $# -eq 2 ]] || usage
PR_PATH="$1"
PR_SHA="$2"

VERIFY="$PR_PATH/tests/e2e/verify.sh"
if [[ ! -x "$VERIFY" ]]; then
  if [[ -f "$VERIFY" ]]; then
    chmod +x "$VERIFY"
  else
    echo "e2e-runner: missing $VERIFY" >&2
    exit 2
  fi
fi

SHORT_SHA="${PR_SHA:0:7}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
ARTIFACT="$EVALS_DIR/${SHORT_SHA}-${TS}.json"
TMP="${ARTIFACT}.tmp.$$"
TRANSCRIPT=$(mktemp)

# Clean up temp file on any exit path so SIGTERM/SIGINT can't leave debris.
cleanup() {
  rm -f "$TRANSCRIPT" "$TMP"
}
trap cleanup EXIT INT TERM HUP

START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
set +e
( cd "$PR_PATH" && bash "$VERIFY" ) > "$TRANSCRIPT" 2>&1
VERIFY_EXIT=$?
set -e
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Parse the verdict — the LAST valid JSON line that contains "passed" and "total".
VERDICT_LINE=$(awk '
  /^\{.*"passed".*"total".*\}$/ { last=$0 }
  END { if (last) print last }
' "$TRANSCRIPT")

PASSED="null"
TOTAL="null"
if [[ -n "$VERDICT_LINE" ]]; then
  PASSED=$(echo "$VERDICT_LINE" | jq -r '.passed // "null"' 2>/dev/null || echo "null")
  TOTAL=$(echo "$VERDICT_LINE" | jq -r '.total // "null"' 2>/dev/null || echo "null")
fi

# Build the crash-safe artifact. Write to TMP first, then atomic rename.
jq -n \
  --arg sha "$PR_SHA" \
  --arg short_sha "$SHORT_SHA" \
  --arg started "$START" \
  --arg ended "$END" \
  --argjson exit_code "$VERIFY_EXIT" \
  --arg verdict "$VERDICT_LINE" \
  --argjson passed "$PASSED" \
  --argjson total "$TOTAL" \
  --rawfile transcript "$TRANSCRIPT" \
  '{
    sha: $sha,
    short_sha: $short_sha,
    started_at: $started,
    ended_at: $ended,
    verify_exit_code: $exit_code,
    verdict_line: $verdict,
    passed: $passed,
    total: $total,
    transcript: $transcript
  }' > "$TMP"

mv "$TMP" "$ARTIFACT"

echo "$ARTIFACT"

# Propagate nothing beyond "ran to completion" — the verdict is in the artifact,
# not in the exit code. Callers inspect the JSON.
exit 0
