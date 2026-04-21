#!/usr/bin/env bash
# Install git hooks for the git-bee repository
# This prevents syntax errors from being pushed to main (issue #557)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="${REPO_ROOT}/.git/hooks"

echo "Installing git hooks..."

# Create the pre-push hook
cat > "${HOOKS_DIR}/pre-push" <<'EOF'
#!/usr/bin/env bash
# Pre-push hook to validate tick.sh syntax before pushing
# Prevents syntax errors from reaching main (issue #557)

set -euo pipefail

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Get the remote and branch being pushed to
remote="$1"
url="$2"

# Check if we're pushing to main/master
while read local_ref local_sha remote_ref remote_sha
do
  # Extract branch name from refs/heads/branch
  remote_branch="${remote_ref#refs/heads/}"

  # Only validate if pushing to main or master
  if [[ "$remote_branch" == "main" || "$remote_branch" == "master" ]]; then
    echo "Pre-push: Validating tick.sh syntax before push to $remote_branch..."

    # Check if tick.sh exists
    if [[ ! -f "scripts/tick.sh" ]]; then
      echo -e "${RED}ERROR: scripts/tick.sh not found${NC}"
      exit 1
    fi

    # Validate tick.sh syntax
    if bash -n scripts/tick.sh 2>/dev/null; then
      echo -e "${GREEN}✓ tick.sh syntax check passed${NC}"
    else
      echo -e "${RED}ERROR: tick.sh has syntax errors:${NC}"
      bash -n scripts/tick.sh 2>&1 | sed 's/^/  /'
      echo ""
      echo -e "${RED}Push aborted. Fix the syntax errors before pushing.${NC}"
      exit 1
    fi

    # Also validate other critical scripts if they exist
    critical_scripts=(
      "scripts/claim.sh"
      "scripts/labels.sh"
      "scripts/gate-check.sh"
      "scripts/notification-scanner.sh"
      "scripts/preflight-push.sh"
      "scripts/activity.sh"
    )

    for script in "${critical_scripts[@]}"; do
      if [[ -f "$script" ]]; then
        if ! bash -n "$script" 2>/dev/null; then
          echo -e "${RED}ERROR: $script has syntax errors:${NC}"
          bash -n "$script" 2>&1 | sed 's/^/  /'
          echo ""
          echo -e "${RED}Push aborted. Fix the syntax errors before pushing.${NC}"
          exit 1
        fi
      fi
    done

    echo -e "${GREEN}✓ All script syntax checks passed${NC}"
  fi
done

exit 0
EOF

chmod +x "${HOOKS_DIR}/pre-push"

echo "✓ Pre-push hook installed successfully"
echo ""
echo "The pre-push hook will validate script syntax before pushing to main/master."
echo "This prevents syntax errors from reaching production (issue #557)."