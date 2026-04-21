#!/usr/bin/env bash
# preflight-push.sh — refuse direct pushes to main.
#
# Usage: `source scripts/preflight-push.sh` at the top of any agent script
# that runs `git push`. Overrides `git` to intercept `git push` and reject
# any invocation whose resolved target ref on the remote is `main`.
#
# Rationale: on 2026-04-20 the drafter pushed commit 7d8c387 directly to
# main with `Closes #551` in the body, which auto-closed the PR without
# merging it — bypassing e2e and the merger. See issue #555.

set -u

__preflight_push_guard() {
  # Scan args for `push`. If absent, this isn't a push.
  local saw_push=0 i
  for i in "$@"; do
    if [[ "$i" == "push" ]]; then saw_push=1; break; fi
  done
  if (( ! saw_push )); then return 0; fi

  # Find remote and refspecs. Heuristic: first non-flag after `push` is remote,
  # subsequent non-flags are refspecs. If none, the refspec is the current
  # branch's upstream target.
  local past_push=0 remote="" refspecs=() tok
  for tok in "$@"; do
    if (( ! past_push )); then
      [[ "$tok" == "push" ]] && past_push=1
      continue
    fi
    [[ "$tok" == -* ]] && continue
    if [[ -z "$remote" ]]; then remote="$tok"; else refspecs+=("$tok"); fi
  done

  # Resolve target ref(s).
  local targets=()
  if (( ${#refspecs[@]} == 0 )); then
    # Default push: use current branch.
    local cur
    cur=$(command git symbolic-ref --short -q HEAD 2>/dev/null || echo "")
    [[ -n "$cur" ]] && targets+=("$cur")
  else
    for tok in "${refspecs[@]}"; do
      # refspec form: [+]src:dst  OR  src (dst == src)
      local dst="${tok##*:}"
      # Strip refs/heads/ prefix if present
      dst="${dst#refs/heads/}"
      # Strip leading + (force)
      dst="${dst#+}"
      targets+=("$dst")
    done
  fi

  for tok in "${targets[@]}"; do
    if [[ "$tok" == "main" || "$tok" == "master" ]]; then
      echo "preflight-push: REFUSING direct push to '$tok'." >&2
      echo "  All work lands via PR on a feature branch. See agents/drafter.md." >&2
      echo "  If you need to bypass this, you are almost certainly wrong — escalate with bee pause." >&2
      return 2
    fi
  done
  return 0
}

git() {
  __preflight_push_guard "$@" || return $?
  command git "$@"
}

export -f git __preflight_push_guard 2>/dev/null || true
