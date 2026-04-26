#!/usr/bin/env bash
# Test helper: extract functions from tick.sh for E2E tests
# This avoids sourcing tick.sh which has execution code that runs on source

# Set up required global variables
LOG_DIR="${HOME}/.git-bee"
LOG="${LOG_DIR}/tick.log"
mkdir -p "$LOG_DIR"

# Define log function (from tick.sh line 59)
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }

# Source just the functions we need for testing
eval "$(sed -n '/^file_or_update_issue()/,/^}/p' "$REPO_ROOT/scripts/tick.sh")"
eval "$(sed -n '/^check_generic_meta_loop()/,/^}/p' "$REPO_ROOT/scripts/tick.sh")"
