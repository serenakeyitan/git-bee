#!/usr/bin/env bash
# Parse agent status line and output JSON
#
# Usage:
#   parse-status.sh <status-line>
#   parse-status.sh --from-file <output-file> <agent-kind>
#   parse-status.sh --from-log <log-file> <agent-kind>
#
# Output: JSON with fields: outcome, next
#   {"outcome": "approved", "next": "e2e"}
#   {"outcome": "", "next": ""}  (if no status line found)
#
# Status line format:
#   <agent-kind>: [other fields...] action=<value> next=<value>
#   <agent-kind>: [other fields...] result=<value> next=<value>
#   <agent-kind>: [other fields...] verdict=<value> next=<value>

set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage:
  parse-status.sh <status-line>
  parse-status.sh --from-file <output-file> <agent-kind>
  parse-status.sh --from-log <log-file> <agent-kind>

Parses agent status line and outputs JSON: {"outcome": "...", "next": "..."}
EOF
  exit 1
}

parse_status_line() {
  local status_line="$1"
  local outcome="" next=""

  if [[ -n "$status_line" ]]; then
    # Parse outcome field (could be action=, result=, or verdict=)
    outcome=$(echo "$status_line" | grep -oE '(action|result|verdict)=[^ ]+' | cut -d= -f2 | head -1 || echo "")
    # Parse next field
    next=$(echo "$status_line" | grep -oE 'next=[^ ]+' | cut -d= -f2 | head -1 || echo "")
  fi

  # Output JSON
  printf '{"outcome": "%s", "next": "%s"}\n' "$outcome" "$next"
}

case "${1:-}" in
  --from-file)
    [[ $# -eq 3 ]] || usage
    output_file="$2"
    agent_kind="$3"

    if [[ ! -f "$output_file" ]]; then
      # File doesn't exist, output empty result
      printf '{"outcome": "", "next": ""}\n'
      exit 0
    fi

    # Extract last status line matching agent kind
    status_line=$(grep -E "^${agent_kind}:" "$output_file" | tail -1 || echo "")
    parse_status_line "$status_line"
    ;;

  --from-log)
    [[ $# -eq 3 ]] || usage
    log_file="$2"
    agent_kind="$3"

    if [[ ! -f "$log_file" ]]; then
      # File doesn't exist, output empty result
      printf '{"outcome": "", "next": ""}\n'
      exit 0
    fi

    # Extract last status line matching agent kind from timestamped log
    # Log format: "YYYY-MM-DDTHH:MM:SSZ agent-kind: ..."
    status_line=$(tail -100 "$log_file" | grep -E "^[0-9T:Z-]+ ${agent_kind}:" | tail -1 | cut -d' ' -f2- || echo "")
    parse_status_line "$status_line"
    ;;

  --help|-h)
    usage
    ;;

  *)
    # Direct status line parsing (including empty string)
    if [[ $# -ne 1 ]]; then
      usage
    fi
    parse_status_line "$1"
    ;;
esac
