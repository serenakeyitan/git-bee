#!/usr/bin/env bash
# Test for metrics capture infrastructure in e2e-agent-wrapper.sh

set -euo pipefail

echo "Starting metrics capture test suite"
echo "===================================="

# Test setup
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# Mock claude command
export PATH="$TEST_DIR/bin:$PATH"
mkdir -p "$TEST_DIR/bin"

cat > "$TEST_DIR/bin/claude" << 'EOF'
#!/usr/bin/env bash
# Mock claude that simulates running for a bit
echo "Mock claude running..."
sleep 0.5
echo "Mock claude completed"
exit 0
EOF
chmod +x "$TEST_DIR/bin/claude"

export CLAUDE_BIN="$TEST_DIR/bin/claude"

# Test metrics file generation
test_metrics_generation() {
  echo ""
  echo "Test: Metrics file generation by wrapper"
  echo "-----------------------------------------"

  # Create test prompt file
  local prompt_file="$TEST_DIR/test-prompt.txt"
  cat > "$prompt_file" << 'PROMPT'
Test prompt for e2e agent
PROMPT

  # Run the wrapper
  HOME="$TEST_DIR" bash scripts/e2e-agent-wrapper.sh 123 "$prompt_file" >/dev/null 2>&1

  # Check metrics file was created
  local metrics_dir="$TEST_DIR/.git-bee/e2e-metrics"
  if [[ ! -d "$metrics_dir" ]]; then
    echo "❌ Metrics directory not created"
    return 1
  fi

  local metrics_file=$(ls "$metrics_dir"/pr-123-*.json 2>/dev/null | head -1)
  if [[ -z "$metrics_file" ]]; then
    echo "❌ Metrics file not created"
    return 1
  fi

  # Verify JSON structure
  local pr_num=$(jq -r '.pr' "$metrics_file")
  local status=$(jq -r '.status' "$metrics_file")
  local duration=$(jq -r '.duration_ms' "$metrics_file")

  if [[ "$pr_num" != "123" ]]; then
    echo "❌ PR number incorrect: $pr_num"
    return 1
  fi

  if [[ "$status" != "completed" ]]; then
    echo "❌ Status not completed: $status"
    return 1
  fi

  if [[ "$duration" == "null" ]] || [[ "$duration" -lt 500 ]]; then
    echo "❌ Duration not captured correctly: $duration"
    return 1
  fi

  echo "✅ Metrics file generated with correct structure"
  return 0
}

# Test metrics integration with RESULT.json
test_metrics_integration() {
  echo ""
  echo "Test: Metrics integration with RESULT.json"
  echo "------------------------------------------"

  # Create a test sandbox
  local sandbox="$TEST_DIR/sandbox"
  mkdir -p "$sandbox/steps"
  cd "$sandbox"

  # Initialize git repo
  git init -q -b trace/test
  git config user.email "test@example.com"
  git config user.name "Test User"
  git config commit.gpgsign false

  # Create meta.json
  cat > .meta.json << 'EOF'
{
  "pr_number": 99,
  "pr_sha": "abcd1234567890",
  "short_sha": "abcd123",
  "branch": "trace/test",
  "upstream": "serenakeyitan/git-bee",
  "trace_repo": "serenakeyitan/git-bee-e2e"
}
EOF

  # Create a mock metrics file
  local metrics_file="$TEST_DIR/test-metrics.json"
  cat > "$metrics_file" << 'EOF'
{
  "pr": 99,
  "duration_ms": 5000,
  "tokens": {"input": 1234, "output": 567},
  "cost_usd_cents": 12
}
EOF

  # Set environment variable to point to metrics file
  export E2E_METRICS_FILE="$metrics_file"

  # Create a simple step
  mkdir -p steps/step-01
  echo "test step" > steps/step-01/description
  echo "0" > steps/step-01/exit-code

  git add -A
  git commit -q -m "step-00 bootstrap"
  git commit -q --allow-empty -m "step-01 test"

  # Define the function from e2e-sandbox.sh inline
  _generate_result_json() {
    local sandbox_path="$1" pr_number="$2" short_sha="$3" status="$4" reason="$5"
    local result_json="$sandbox_path/RESULT.json"

    # Calculate duration from first to last commit
    local first_ts last_ts duration_ms
    first_ts=$(git -C "$sandbox_path" log --reverse --format='%ct' | head -1)
    last_ts=$(date +%s)
    duration_ms=$(( (last_ts - first_ts) * 1000 ))

    # Build steps array from the steps directory
    local steps_json="[]"
    if [[ -d "$sandbox_path/steps" ]]; then
      steps_json=$(
        for step_dir in $(ls -d "$sandbox_path/steps"/step-* 2>/dev/null | sort -V); do
          local step_num step_desc exit_code skipped assertions_json
          step_num=$(basename "$step_dir" | sed 's/step-//')
          step_desc=$(cat "$step_dir/description" 2>/dev/null || echo "")
          exit_code=$(cat "$step_dir/exit-code" 2>/dev/null || echo "0")
          skipped=false

          # Check if step was skipped
          if [[ "$exit_code" == "skipped" ]]; then
            skipped=true
            exit_code=0
          fi

          # For now, derive assertions from exit code (will be enhanced in PR #3)
          if [[ "$skipped" == "true" ]]; then
            assertions_json='{"passed": 0, "total": 0}'
          elif [[ "$exit_code" == "0" ]]; then
            assertions_json='{"passed": 1, "total": 1}'
          else
            assertions_json='{"passed": 0, "total": 1}'
          fi

          jq -n \
            --argjson n "$((10#$step_num))" \
            --arg desc "$step_desc" \
            --argjson exit "$exit_code" \
            --argjson skip "$skipped" \
            --argjson asserts "$assertions_json" \
            '{n: $n, description: $desc, exit: $exit, skipped: $skip, assertions: $asserts}'
        done | jq -s '.'
      )
    fi

    # Check for metrics file from e2e-agent-wrapper
    local tokens_json="null" cost_json="null"
    if [[ -n "${E2E_METRICS_FILE:-}" && -f "${E2E_METRICS_FILE}" ]]; then
      tokens_json=$(jq -r '.tokens // null' "$E2E_METRICS_FILE" 2>/dev/null || echo "null")
      cost_json=$(jq -r '.cost_usd_cents // null' "$E2E_METRICS_FILE" 2>/dev/null || echo "null")
    fi

    # Generate the full RESULT.json
    jq -n \
      --argjson pr "$pr_number" \
      --arg sha "$short_sha" \
      --arg status "$status" \
      --argjson steps "$steps_json" \
      --argjson duration "$duration_ms" \
      --argjson tokens "$tokens_json" \
      --argjson cost "$cost_json" \
      '{
        pr: $pr,
        sha: $sha,
        status: $status,
        steps: $steps,
        duration_ms: $duration,
        tokens: $tokens,
        cost_usd_cents: $cost
      }' > "$result_json"
  }

  _generate_result_json "$sandbox" "99" "abcd123" "pass" ""

  # Verify RESULT.json includes metrics
  if [[ ! -f "RESULT.json" ]]; then
    echo "❌ RESULT.json not created"
    return 1
  fi

  local tokens_input=$(jq -r '.tokens.input' RESULT.json)
  local tokens_output=$(jq -r '.tokens.output' RESULT.json)
  local cost=$(jq -r '.cost_usd_cents' RESULT.json)

  if [[ "$tokens_input" != "1234" ]]; then
    echo "❌ Tokens input not captured: $tokens_input"
    return 1
  fi

  if [[ "$tokens_output" != "567" ]]; then
    echo "❌ Tokens output not captured: $tokens_output"
    return 1
  fi

  if [[ "$cost" != "12" ]]; then
    echo "❌ Cost not captured: $cost"
    return 1
  fi

  echo "✅ Metrics correctly integrated into RESULT.json"

  echo ""
  echo "Generated RESULT.json with metrics:"
  jq '.tokens, .cost_usd_cents' RESULT.json

  return 0
}

# Run tests
test_metrics_generation
test_metrics_integration

echo ""
echo "===================================="
echo "Metrics capture tests completed successfully!"
exit 0