#!/usr/bin/env bash
# git-bee E2E runner: invokes PR's tests/e2e/verify.sh, captures NDJSON,
# writes crash-safe artifact to ~/.git-bee/evals/<short-sha>-<ts>.json
#
# Usage:
#   scripts/e2e-runner.sh <pr-number>
#
# Behavior:
#   1. Fetches PR metadata to get SHA
#   2. Checks if tests/e2e/verify.sh exists (exit 2 if missing)
#   3. Runs verify.sh, captures transcript and NDJSON output
#   4. Parses {"passed":N,"total":M} verdict from last matching line
#   5. Writes artifact atomically via tmp+rename
#
# Output artifact format:
#   {
#     "pr_number": <number>,
#     "pr_sha": "<full-sha>",
#     "short_sha": "<7-char-sha>",
#     "timestamp": "<ISO8601>",
#     "verify_exit_code": <number>,
#     "passed": <number or null>,
#     "total": <number or null>,
#     "transcript": "<full stdout+stderr>",
#     "ndjson_lines": [<parsed NDJSON objects>]
#   }

set -euo pipefail

# Parse arguments
if [[ $# -ne 1 ]]; then
  echo "usage: $0 <pr-number>" >&2
  exit 2
fi

PR_NUMBER="$1"
UPSTREAM_REPO="serenakeyitan/git-bee"
EVALS_DIR="$HOME/.git-bee/evals"

# Ensure evals directory exists
mkdir -p "$EVALS_DIR"

# Fetch PR metadata
echo "Fetching PR #${PR_NUMBER} metadata..." >&2
PR_SHA=$(gh pr view "$PR_NUMBER" --repo "$UPSTREAM_REPO" --json headRefOid --jq '.headRefOid')
SHORT_SHA="${PR_SHA:0:7}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
UNIX_TS=$(date -u +%s)

# Check if verify.sh exists
VERIFY_SCRIPT="tests/e2e/verify.sh"
if [[ ! -f "$VERIFY_SCRIPT" ]]; then
  echo "Error: $VERIFY_SCRIPT not found (fail-closed)" >&2
  exit 2
fi

# Make verify.sh executable if it isn't already
chmod +x "$VERIFY_SCRIPT"

# Create temp file for output
TEMP_OUTPUT=$(mktemp)
TEMP_ARTIFACT=$(mktemp)

# Trap to clean up temp files on exit/interrupt
cleanup() {
  rm -f "$TEMP_OUTPUT" "$TEMP_ARTIFACT"
}
trap cleanup EXIT INT TERM

# Run verify.sh and capture output
echo "Running $VERIFY_SCRIPT..." >&2
set +e
"$VERIFY_SCRIPT" > "$TEMP_OUTPUT" 2>&1
VERIFY_EXIT_CODE=$?
set -e

# Read the full transcript
TRANSCRIPT=$(cat "$TEMP_OUTPUT")

# Parse NDJSON lines and extract verdict
NDJSON_LINES=()
PASSED=""
TOTAL=""

while IFS= read -r line; do
  # Try to parse as JSON
  if echo "$line" | jq -e . >/dev/null 2>&1; then
    NDJSON_LINES+=("$line")
    # Check if this line contains a verdict
    if echo "$line" | jq -e 'has("passed") and has("total")' >/dev/null 2>&1; then
      PASSED=$(echo "$line" | jq -r '.passed')
      TOTAL=$(echo "$line" | jq -r '.total')
    fi
  fi
done < "$TEMP_OUTPUT"

# Convert NDJSON lines array to JSON array
NDJSON_JSON="[]"
for line in "${NDJSON_LINES[@]}"; do
  NDJSON_JSON=$(echo "$NDJSON_JSON" | jq --argjson obj "$line" '. + [$obj]')
done

# Construct the artifact JSON
cat > "$TEMP_ARTIFACT" <<EOF
{
  "pr_number": ${PR_NUMBER},
  "pr_sha": "${PR_SHA}",
  "short_sha": "${SHORT_SHA}",
  "timestamp": "${TIMESTAMP}",
  "verify_exit_code": ${VERIFY_EXIT_CODE},
  "passed": ${PASSED:-null},
  "total": ${TOTAL:-null},
  "transcript": $(echo "$TRANSCRIPT" | jq -Rs .),
  "ndjson_lines": ${NDJSON_JSON}
}
EOF

# Validate the JSON
if ! jq -e . "$TEMP_ARTIFACT" >/dev/null 2>&1; then
  echo "Error: Failed to create valid JSON artifact" >&2
  exit 1
fi

# Atomically write the artifact (rename is atomic on same filesystem)
FINAL_ARTIFACT="${EVALS_DIR}/${SHORT_SHA}-${UNIX_TS}.json"
mv "$TEMP_ARTIFACT" "$FINAL_ARTIFACT"

# Report results
echo "E2E runner completed:" >&2
echo "  PR: #${PR_NUMBER}" >&2
echo "  SHA: ${SHORT_SHA}" >&2
echo "  Exit code: ${VERIFY_EXIT_CODE}" >&2
if [[ -n "$PASSED" ]] && [[ -n "$TOTAL" ]]; then
  echo "  Verdict: ${PASSED}/${TOTAL} passed" >&2
else
  echo "  Verdict: no verdict found in output" >&2
fi
echo "  Artifact: ${FINAL_ARTIFACT}" >&2

# Exit with verify.sh's exit code
exit $VERIFY_EXIT_CODE