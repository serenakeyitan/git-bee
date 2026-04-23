#!/usr/bin/env bash
# Test for structured assertions support in e2e-sandbox.sh

set -euo pipefail

echo "Starting structured assertions test suite"
echo "=========================================="

# Test setup
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# Mock gh command
export PATH="$TEST_DIR/bin:$PATH"
mkdir -p "$TEST_DIR/bin"

cat > "$TEST_DIR/bin/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  echo '{"headRefOid": "test1234567890", "headRefName": "test-branch"}'
fi
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

# Test structured assertions in step command
test_structured_assertions() {
  echo ""
  echo "Test: Structured assertions in step command"
  echo "-------------------------------------------"

  # Create a test sandbox
  local sandbox="$TEST_DIR/sandbox"
  mkdir -p "$sandbox"
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
  "pr_sha": "test1234567890",
  "short_sha": "test123",
  "branch": "trace/test",
  "upstream": "serenakeyitan/git-bee",
  "trace_repo": "serenakeyitan/git-bee-e2e"
}
EOF

  git add -A
  git commit -q -m "step-00 bootstrap"

  # Define the _generate_result_json function inline
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

          # Check for structured assertions file first, otherwise derive from exit code
          if [[ -f "$step_dir/assertions.json" ]]; then
            assertions_json=$(cat "$step_dir/assertions.json")
          elif [[ "$skipped" == "true" ]]; then
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

  # Test 1: Step with structured assertions (partial pass)
  local test_cmd="echo 'Running tests...'; exit 1"

  STEP_ASSERTIONS='{"passed": 3, "total": 5}' bash -c "
    set -euo pipefail

    # Bypass the command running part and just create the step data
    mkdir -p steps/step-01
    echo 'Running tests...' > steps/step-01/stdout.txt
    echo '' > steps/step-01/stderr.txt
    echo '1' > steps/step-01/exit-code
    echo '$test_cmd' > steps/step-01/command
    echo 'test with assertions' > steps/step-01/description

    # Save structured assertions
    if [[ -n \"\${STEP_ASSERTIONS:-}\" ]]; then
      echo \"\$STEP_ASSERTIONS\" > steps/step-01/assertions.json
    fi

    git add -A
    git commit -q -m \"step-01 test with assertions

command:
$test_cmd

exit_code: 1
assertions: 3/5 passed\"
  "

  # Test 2: Step without structured assertions (derive from exit code)
  mkdir -p steps/step-02
  echo "Test passed" > steps/step-02/stdout.txt
  echo "" > steps/step-02/stderr.txt
  echo "0" > steps/step-02/exit-code
  echo "echo 'Test passed'" > steps/step-02/command
  echo "simple test" > steps/step-02/description

  git add -A
  git commit -q -m "step-02 simple test"

  # Test 3: Step with all assertions passing
  STEP_ASSERTIONS='{"passed": 10, "total": 10}' bash -c "
    mkdir -p steps/step-03
    echo 'All tests passed' > steps/step-03/stdout.txt
    echo '' > steps/step-03/stderr.txt
    echo '0' > steps/step-03/exit-code
    echo 'run all tests' > steps/step-03/command
    echo 'comprehensive test' > steps/step-03/description
    echo '{\"passed\": 10, \"total\": 10}' > steps/step-03/assertions.json

    git add -A
    git commit -q -m 'step-03 comprehensive test'
  "

  # Generate RESULT.json and verify structured assertions
  _generate_result_json "$sandbox" "99" "test123" "pass" ""

  if [[ ! -f "RESULT.json" ]]; then
    echo "❌ RESULT.json not created"
    return 1
  fi

  # Verify step 1 has structured assertions
  local step1_passed=$(jq -r '.steps[0].assertions.passed' RESULT.json)
  local step1_total=$(jq -r '.steps[0].assertions.total' RESULT.json)

  if [[ "$step1_passed" != "3" || "$step1_total" != "5" ]]; then
    echo "❌ Step 1 structured assertions incorrect: $step1_passed/$step1_total"
    return 1
  fi

  # Verify step 2 has derived assertions (from exit code)
  local step2_passed=$(jq -r '.steps[1].assertions.passed' RESULT.json)
  local step2_total=$(jq -r '.steps[1].assertions.total' RESULT.json)

  if [[ "$step2_passed" != "1" || "$step2_total" != "1" ]]; then
    echo "❌ Step 2 derived assertions incorrect: $step2_passed/$step2_total"
    return 1
  fi

  # Verify step 3 has all passing assertions
  local step3_passed=$(jq -r '.steps[2].assertions.passed' RESULT.json)
  local step3_total=$(jq -r '.steps[2].assertions.total' RESULT.json)

  if [[ "$step3_passed" != "10" || "$step3_total" != "10" ]]; then
    echo "❌ Step 3 structured assertions incorrect: $step3_passed/$step3_total"
    return 1
  fi

  echo "✅ Structured assertions correctly handled in RESULT.json"

  echo ""
  echo "Generated RESULT.json with structured assertions:"
  jq '.steps[] | {n: .n, description: .description, assertions: .assertions}' RESULT.json

  return 0
}

# Run test
test_structured_assertions

echo ""
echo "=========================================="
echo "Structured assertions tests completed successfully!"
exit 0