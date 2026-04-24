#!/usr/bin/env bash
# Wrapper for test agent that captures metrics when available
#
# Usage:
#   test-agent-wrapper.sh <pr-number> <prompt-file>
#
# Sets E2E_METRICS_FILE environment variable pointing to a JSON file with:
# - tokens (input/output) when available
# - cost_usd_cents when available
# - duration_ms
#
# This wrapper is used by tick.sh when dispatching the test-agent to enable
# metrics capture for RESULT.json generation.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: test-agent-wrapper.sh <pr-number> <prompt-file>" >&2
  exit 2
fi

pr_number="$1"
prompt_file="$2"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

# Create metrics directory
METRICS_DIR="${HOME}/.git-bee/e2e-metrics"
mkdir -p "$METRICS_DIR"

# Unique metrics file for this run
ts=$(date +%s)
metrics_file="${METRICS_DIR}/pr-${pr_number}-${ts}.json"

# Export for e2e-sandbox.sh to read
export E2E_METRICS_FILE="$metrics_file"

# Record start time
start_ms=$(( $(date +%s%N) / 1000000 ))

# Initialize metrics file
cat > "$metrics_file" <<EOF
{
  "pr": $pr_number,
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "running",
  "tokens": null,
  "cost_usd_cents": null
}
EOF

# Run the claude command with the prompt
# In the future, when claude supports metrics output, we can capture it here
"$CLAUDE_BIN" -p "$(cat "$prompt_file")" --permission-mode bypassPermissions 2>&1 | tee -a "${HOME}/.git-bee/tick.log"
exit_code="${PIPESTATUS[0]}"

# Record end time and calculate duration
end_ms=$(( $(date +%s%N) / 1000000 ))
duration_ms=$(( end_ms - start_ms ))

# Future enhancement: Parse claude output for token/cost information
# For now, these remain null but the infrastructure is in place
tokens_json="null"
cost_json="null"

# Check if claude wrote any metrics to a known location (future enhancement)
# This is where we would read claude's metrics output when available
CLAUDE_METRICS_FILE="${HOME}/.claude/last-run-metrics.json"
if [[ -f "$CLAUDE_METRICS_FILE" ]]; then
  # Parse tokens and cost from claude metrics (when available)
  tokens_input=$(jq -r '.tokens.input // null' "$CLAUDE_METRICS_FILE" 2>/dev/null || echo "null")
  tokens_output=$(jq -r '.tokens.output // null' "$CLAUDE_METRICS_FILE" 2>/dev/null || echo "null")
  cost_usd=$(jq -r '.cost_usd // null' "$CLAUDE_METRICS_FILE" 2>/dev/null || echo "null")

  if [[ "$tokens_input" != "null" && "$tokens_output" != "null" ]]; then
    tokens_json="{\"input\": $tokens_input, \"output\": $tokens_output}"
  fi

  if [[ "$cost_usd" != "null" ]]; then
    # Convert dollars to cents
    cost_json=$(echo "$cost_usd * 100" | bc 2>/dev/null || echo "null")
  fi
fi

# Update metrics file with final values
jq -n \
  --argjson pr "$pr_number" \
  --argjson duration "$duration_ms" \
  --argjson tokens "$tokens_json" \
  --argjson cost "$cost_json" \
  --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg status "completed" \
  '{
    pr: $pr,
    started_at: $completed,
    completed_at: $completed,
    status: $status,
    duration_ms: $duration,
    tokens: $tokens,
    cost_usd_cents: $cost
  }' > "$metrics_file"

# Clean up old metrics files (older than 7 days)
find "$METRICS_DIR" -name "pr-*.json" -mtime +7 -delete 2>/dev/null || true

exit "$exit_code"
