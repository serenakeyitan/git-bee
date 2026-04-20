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
(cd "$REPO_ROOT" && git config --local gpg.format ssh && \
  git config --local user.signingkey "$HOME/.ssh/id_ed25519.pub" && \
  git config --local commit.gpgsign true && \
  git config --local tag.gpgsign true)
ok "ssh signing enabled for $(basename "$REPO_ROOT")"

# 2b. Warn if the key isn't registered with GitHub as a signing key
pubkey_oneline=$(awk '{print $1" "$2}' "$HOME/.ssh/id_ed25519.pub")
registered=$(gh api /user/ssh_signing_keys --jq '.[].key' 2>/dev/null | awk '{print $1" "$2}' || echo "")
if echo "$registered" | grep -qF "$pubkey_oneline"; then
  ok "ssh key registered as a GitHub signing key — commits will be Verified"
else
  warn "ssh key NOT registered as a GitHub signing key — commits will show 'Unverified'"
  warn "  register at: https://github.com/settings/ssh/new (select 'Signing Key')"
  warn "  or via API:  gh api /user/ssh_signing_keys -f key=\"\$(cat ~/.ssh/id_ed25519.pub)\" -f title=git-bee"
fi

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

# 4. Configuration setup
step "setting up git-bee configuration"
CONFIG_FILE="$HOME/.git-bee/config.json"
mkdir -p "$(dirname "$CONFIG_FILE")"

if [[ ! -f "$CONFIG_FILE" ]]; then
  # First-time setup: prompt for scope choice
  echo ""
  echo "How should git-bee watch GitHub notifications?"
  echo "  (e) exclusion — watch all repos you have access to except an exclusion list (brave mode)"
  echo "  (c) curated — only watch a specific allowlist of repos (experimental mode)"
  echo ""
  printf "Choose [e/c]: "

  read -r scope_choice
  case "$scope_choice" in
    c|C)
      cat > "$CONFIG_FILE" <<'EOF'
{
  "scope": "curated",
  "exclude_repos": [],
  "include_repos": []
}
EOF
      ok "config: curated mode (edit include_repos with: bee config add include_repos <repo>)"
      ;;
    *)
      cat > "$CONFIG_FILE" <<'EOF'
{
  "scope": "exclusion",
  "exclude_repos": [
    "unispark-inc/paperclip",
    "unispark-inc/paperclip-context-tree"
  ],
  "include_repos": []
}
EOF
      ok "config: exclusion mode with default exclusions"
      ;;
  esac
else
  ok "config exists: $CONFIG_FILE"
fi

# 5. bee CLI on PATH
step "exposing bee CLI on PATH"
BEE_SRC="$REPO_ROOT/scripts/bee"
chmod +x "$BEE_SRC" 2>/dev/null || true
# Pick the first directory of these that exists on PATH. No auto-mkdir.
BEE_LINK_DIR=""
for candidate in "$HOME/.local/bin" "$HOME/bin" "/usr/local/bin" "/opt/homebrew/bin"; do
  if [[ -d "$candidate" ]] && printf '%s' ":$PATH:" | grep -qF ":$candidate:"; then
    BEE_LINK_DIR="$candidate"
    break
  fi
done
if [[ -n "$BEE_LINK_DIR" ]]; then
  BEE_LINK="$BEE_LINK_DIR/bee"
  ln -sf "$BEE_SRC" "$BEE_LINK"
  ok "bee -> $BEE_LINK"
else
  warn "no writable PATH dir found (tried ~/.local/bin, ~/bin, /usr/local/bin, /opt/homebrew/bin)"
  warn "  add one to PATH, then: ln -sf $BEE_SRC <dir>/bee"
fi

# 6. launchd plist
step "installing launchd plist"
PLIST_NAME="com.serenakeyitan.git-bee.plist"
PLIST_SRC="$REPO_ROOT/launchd/$PLIST_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"

if [[ ! -f "$PLIST_SRC" ]]; then
  fail "missing $PLIST_SRC"
fi

# Rewrite the plist to point at the real repo path (not ~/git-bee if user cloned elsewhere)
sed "s|cd ~/git-bee|cd ${REPO_ROOT}|" "$PLIST_SRC" > "$PLIST_DST"

# Unload if loaded, then load
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
ok "launchd plist loaded: $PLIST_DST"

# 7. First tick (optional)
if [[ "${SKIP_FIRST_TICK:-0}" != "1" ]]; then
  step "running first tick (use SKIP_FIRST_TICK=1 to skip)"
  "$REPO_ROOT/scripts/tick.sh" || warn "first tick exited non-zero (check ~/.git-bee/tick.log)"
fi

cat <<EOF

$(printf '\033[1;32m')git-bee installed.$(printf '\033[0m')

Next:
  • Open a design-doc issue:   gh issue create --repo $REPO --template design-doc
  • Check current state:       bee status
  • Watch the tick log:        tail -f ~/.git-bee/tick.log
  • Uninstall:                 launchctl unload $PLIST_DST

The tick fires every 15 minutes. When there are no open unclaimed items,
it exits silently (project is finalized).
EOF
