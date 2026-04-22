#!/usr/bin/env bash
# Test for RESULT.json generation in e2e-sandbox.sh

set -euo pipefail

echo "Starting RESULT.json generation test suite"
echo "==========================================="

# Test setup
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# Mock gh and git commands for testing
export PATH="$TEST_DIR/bin:$PATH"
mkdir -p "$TEST_DIR/bin"

# Create mock gh command
cat > "$TEST_DIR/bin/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  echo '{"headRefOid": "abcd1234567890", "headRefName": "test-branch"}'
elif [[ "$1" == "repo" && "$2" == "view" ]]; then
  exit 1  # Simulate repo not existing to trigger creation
elif [[ "$1" == "pr" && "$2" == "comment" ]]; then
  exit 0  # Simulate successful comment
fi
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

# Test RESULT.json generation
test_result_json() {
  echo ""
  echo "Test: RESULT.json generation on finalize"
  echo "----------------------------------------"

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
  cat > .meta.json << 'METAEOF'
{
  "pr_number": 99,
  "pr_sha": "abcd1234567890",
  "short_sha": "abcd123",
  "branch": "trace/test",
  "upstream": "serenakeyitan/git-bee",
  "trace_repo": "serenakeyitan/git-bee-e2e",
  "created_at": "2024-01-01T00:00:00Z"
}
METAEOF

  # Create step directories with test data
  mkdir -p steps/step-01
  echo "init test" > steps/step-01/description
  echo "0" > steps/step-01/exit-code
  echo "init command" > steps/step-01/command

  mkdir -p steps/step-02
  echo "run tests" > steps/step-02/description
  echo "1" > steps/step-02/exit-code
  echo "npm test" > steps/step-02/command

  mkdir -p steps/step-03
  echo "optional check" > steps/step-03/description
  echo "skipped" > steps/step-03/exit-code
  echo "lint check" > steps/step-03/skip-reason

  # Make initial commits for duration calculation
  git add -A
  git commit -q -m "step-00 bootstrap"
  sleep 1  # Ensure some duration
  git commit -q --allow-empty -m "step-01 init"
  git commit -q --allow-empty -m "step-02 tests"
  git commit -q --allow-empty -m "step-03 skipped"

  # Define the function under test inline (copied from e2e-sandbox.sh)
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

    # Generate the full RESULT.json
    jq -n \
      --argjson pr "$pr_number" \
      --arg sha "$short_sha" \
      --arg status "$status" \
      --argjson steps "$steps_json" \
      --argjson duration "$duration_ms" \
      '{
        pr: $pr,
        sha: $sha,
        status: $status,
        steps: $steps,
        duration_ms: $duration,
        tokens: null,
        cost_usd_cents: null
      }' > "$result_json"
  }

  _generate_result_json "$sandbox" "99" "abcd123" "fail" "Tests failed"

  # Verify RESULT.json exists and has correct structure
  if [[ ! -f "RESULT.json" ]]; then
    echo "❌ RESULT.json was not created"
    return 1
  fi

  # Check JSON structure
  local pr_num=$(jq -r '.pr' RESULT.json)
  local sha=$(jq -r '.sha' RESULT.json)
  local status=$(jq -r '.status' RESULT.json)
  local steps_count=$(jq '.steps | length' RESULT.json)

  if [[ "$pr_num" != "99" ]]; then
    echo "❌ PR number incorrect: $pr_num != 99"
    return 1
  fi

  if [[ "$sha" != "abcd123" ]]; then
    echo "❌ SHA incorrect: $sha != abcd123"
    return 1
  fi

  if [[ "$status" != "fail" ]]; then
    echo "❌ Status incorrect: $status != fail"
    return 1
  fi

  if [[ "$steps_count" != "3" ]]; then
    echo "❌ Steps count incorrect: $steps_count != 3"
    return 1
  fi

  # Check step details
  local step1_desc=$(jq -r '.steps[0].description' RESULT.json)
  local step1_exit=$(jq -r '.steps[0].exit' RESULT.json)
  local step1_passed=$(jq -r '.steps[0].assertions.passed' RESULT.json)

  if [[ "$step1_desc" != "init test" ]]; then
    echo "❌ Step 1 description incorrect: $step1_desc"
    return 1
  fi

  if [[ "$step1_exit" != "0" ]]; then
    echo "❌ Step 1 exit code incorrect: $step1_exit"
    return 1
  fi

  if [[ "$step1_passed" != "1" ]]; then
    echo "❌ Step 1 assertions.passed incorrect: $step1_passed"
    return 1
  fi

  # Check step 2 (failed)
  local step2_passed=$(jq -r '.steps[1].assertions.passed' RESULT.json)
  local step2_total=$(jq -r '.steps[1].assertions.total' RESULT.json)

  if [[ "$step2_passed" != "0" || "$step2_total" != "1" ]]; then
    echo "❌ Step 2 assertions incorrect: passed=$step2_passed, total=$step2_total"
    return 1
  fi

  # Check step 3 (skipped)
  local step3_skipped=$(jq -r '.steps[2].skipped' RESULT.json)

  if [[ "$step3_skipped" != "true" ]]; then
    echo "❌ Step 3 skipped flag incorrect: $step3_skipped"
    return 1
  fi

  # Check that tokens and cost are null (to be implemented in PR #2)
  local tokens=$(jq '.tokens' RESULT.json)
  local cost=$(jq '.cost_usd_cents' RESULT.json)

  if [[ "$tokens" != "null" || "$cost" != "null" ]]; then
    echo "❌ Tokens/cost should be null in PR #1: tokens=$tokens, cost=$cost"
    return 1
  fi

  echo "✅ RESULT.json generated with correct structure"
  echo ""
  echo "Generated RESULT.json sample:"
  jq '.' RESULT.json

  return 0
}

# Run the test
test_result_json

echo ""
echo "==========================================="
echo "RESULT.json generation tests completed successfully!"
exit 0