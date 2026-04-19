#!/usr/bin/env bash
# git-bee onboarding: verify prerequisites, create labels, install launchd plist.
#
# Idempotent. Safe to re-run.

set -euo pipefail

REPO="serenakeyitan/git-bee"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

step()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m !!\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m xx\033[0m %s\n' "$*"; exit 1; }

# 1. Prereqs
step "checking prerequisites"
command -v gh   >/dev/null || fail "gh CLI not installed — https://cli.github.com"
command -v git  >/dev/null || fail "git not installed"
command -v jq   >/dev/null || fail "jq not installed — brew install jq"
command -v claude >/dev/null || warn "claude CLI not on PATH; tick will fail until CLAUDE_BIN is set"
gh auth status >/dev/null 2>&1 || fail "gh not authenticated — run: gh auth login"
ok "prereqs"

# 2. SSH signing
step "verifying SSH signing key"
if [[ ! -f "$HOME/.ssh/id_ed25519.pub" ]]; then
  fail "no SSH key at ~/.ssh/id_ed25519.pub — generate one: ssh-keygen -t ed25519"
fi
# Make sure the repo itself has signing enabled
(cd "$REPO_ROOT" && git config --local gpg.format ssh && \
  git config --local user.signingkey "$HOME/.ssh/id_ed25519.pub" && \
  git config --local commit.gpgsign true && \
  git config --local tag.gpgsign true)
ok "ssh signing enabled for $(basename "$REPO_ROOT")"

# 3. Labels
step "ensuring breeze:* labels on $REPO"
ensure_label() {
  local name="$1" color="$2" desc="$3"
  if gh label list --repo "$REPO" --json name --jq '.[].name' | grep -qx "$name"; then
    ok "label exists: $name"
  else
    gh label create "$name" --color "$color" --description "$desc" --repo "$REPO" >/dev/null
    ok "label created: $name"
  fi
}
ensure_label "breeze:wip"   "e4e669" "Agent has claimed this item"
ensure_label "breeze:done"  "0e8a16" "All work for this item is complete"
ensure_label "breeze:human" "d93f0b" "Agent gave up; needs human"

# 4. launchd plist
step "installing launchd plist"
PLIST_NAME="com.serenakeyitan.git-bee.plist"
PLIST_SRC="$REPO_ROOT/launchd/$PLIST_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"

if [[ ! -f "$PLIST_SRC" ]]; then
  fail "missing $PLIST_SRC"
fi

# Rewrite the plist to point at the real repo path (not ~/git-bee if user cloned elsewhere)
python3 - "$PLIST_SRC" "$REPO_ROOT" > "$PLIST_DST" <<'PY'
import sys, pathlib
src, repo_root = sys.argv[1], sys.argv[2]
content = pathlib.Path(src).read_text()
content = content.replace("cd ~/git-bee", f"cd {repo_root}")
sys.stdout.write(content)
PY

# Unload if loaded, then load
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
ok "launchd plist loaded: $PLIST_DST"

# 5. First tick (optional)
if [[ "${SKIP_FIRST_TICK:-0}" != "1" ]]; then
  step "running first tick (use SKIP_FIRST_TICK=1 to skip)"
  "$REPO_ROOT/scripts/tick.sh" || warn "first tick exited non-zero (check ~/.git-bee/tick.log)"
fi

cat <<EOF

$(printf '\033[1;32m')git-bee installed.$(printf '\033[0m')

Next:
  • Open a design-doc issue:   gh issue create --repo $REPO --template design-doc
  • Watch the tick log:        tail -f ~/.git-bee/tick.log
  • Uninstall:                 launchctl unload $PLIST_DST

The tick fires every 15 minutes. When there are no open unclaimed items,
it exits silently (project is finalized).
EOF
