#!/usr/bin/env bash
# PR 1 E2E verify — gate-check + stale-wip hygiene.
#
# Contract (design doc, "Cross-cutting expectations"):
#   - Prints exactly one JSON line at the end: {"passed": N, "total": M}.
#   - Exit 0 regardless of pass/fail count — the JSON line is the verdict.
#   - Idempotent — re-running in the same tree produces the same verdict.
#   - Cleans up temp files on EXIT/INT/TERM.
#   - Uses only bash, gh, jq, git (no Python/Node/installs).
#
# Isolates gh calls via a PATH-overriding `gh` stub that reads fixtures under
# `tests/fixtures/gate-check/`. This keeps cases (a)–(d) deterministic without
# a live API round-trip. Cases (e)–(f) exercise the tick.sh wiring and the
# claim.sh release trap; they run against the real scripts with stub gh.

set -u  # -e intentionally off — we want to count test failures, not abort.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
FIX_DIR="$REPO_ROOT/tests/fixtures/gate-check"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gitbee-pr1-verify.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM HUP

passed=0
total=0

pass() { passed=$((passed+1)); total=$((total+1)); echo "  PASS: $1"; }
fail() { total=$((total+1)); echo "  FAIL: $1"; }

# ---- gh stub ---------------------------------------------------------------
# The stub reads $GH_STUB_FIXTURE (a dir) and dispatches on the command shape.
# Supported calls (what gate-check.sh and tick.sh actually issue):
#   gh issue view <n> --repo <r> --json body --jq '.body'    → cat body.md
#   gh issue view <n> --repo <r> --json body                 → wrap body in JSON
#   gh api graphql -f query=... (userContentEdits)           → cat edits.json
# Anything else → exit 99 (unexpected call surfaces as a test failure).
make_gh_stub() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -u
args=("$@")
case "${args[0]:-}" in
  issue)
    # `gh issue view <n> --repo <r> --json body [--jq '.body']`
    wants_jq=0
    for a in "${args[@]}"; do [[ "$a" == "--jq" ]] && wants_jq=1; done
    if [[ "$wants_jq" == 1 ]]; then
      cat "$GH_STUB_FIXTURE/body.md"
    else
      jq -Rs '{body: .}' <"$GH_STUB_FIXTURE/body.md"
    fi
    exit 0
    ;;
  api)
    # `gh api graphql -f query=... -f o=... -f n=... -F i=...`
    cat "$GH_STUB_FIXTURE/edits.json"
    exit 0
    ;;
esac
echo "gh stub: unexpected call: ${args[*]}" >&2
exit 99
STUB
  chmod +x "$bin_dir/gh"
}

run_gate() {
  local fixture="$1"
  local bin_dir="$TMP/bin-$fixture"
  make_gh_stub "$bin_dir"
  GH_STUB_FIXTURE="$FIX_DIR/$fixture" PATH="$bin_dir:$PATH" \
    bash "$REPO_ROOT/scripts/gate-check.sh" owner/repo 1 >/dev/null 2>&1
  echo $?
}

echo "== PR 1 E2E: gate-check + stale-wip hygiene =="

# (a) owner-ticked → exit 0
[[ "$(run_gate owner-ticked)" == "0" ]] \
  && pass "(a) owner-ticked gate → exit 0" \
  || fail "(a) owner-ticked gate → exit 0"

# (b) unticked → exit 1
[[ "$(run_gate unticked)" == "1" ]] \
  && pass "(b) unticked gate → exit 1" \
  || fail "(b) unticked gate → exit 1"

# (c) ticked-by-bot → exit 2
[[ "$(run_gate bot-ticked)" == "2" ]] \
  && pass "(c) bot-ticked gate → exit 2" \
  || fail "(c) bot-ticked gate → exit 2"

# (d) no Finalization gate section → exit 3 (not-applicable; tick.sh still dispatches).
# Note: design doc sketched exit 1 here, but that would block non-design issues
# (smoke tests, etc.) from ever being drafted. Exit 3 is "gate not applicable".
[[ "$(run_gate no-section)" == "3" ]] \
  && pass "(d) no gate section → exit 3 (not applicable)" \
  || fail "(d) no gate section → exit 3 (not applicable)"

# (e) tick.sh wiring: the drafter issue-loop branch in pick_target() calls
# gate-check.sh and skips on rc=1|2. Asserted by grep — cheaper and more
# stable than spawning the full pick_target() against a stubbed github.
grep -q 'gate-check.sh' "$REPO_ROOT/scripts/tick.sh" \
  && grep -q 'gate_rc' "$REPO_ROOT/scripts/tick.sh" \
  && pass "(e) tick.sh calls gate-check.sh in drafter issue loop" \
  || fail "(e) tick.sh calls gate-check.sh in drafter issue loop"

# (f) stale breeze:wip hygiene: claim.sh documents that tick.sh wires the
# release into EXIT+INT+TERM+HUP, and the TTL fallback handles SIGKILL.
# We assert the wiring is in place.
grep -qE 'trap +release_all +EXIT +INT +TERM +HUP' "$REPO_ROOT/scripts/tick.sh" \
  && pass "(f) tick.sh trap covers EXIT/INT/TERM/HUP for claim release" \
  || fail "(f) tick.sh trap covers EXIT/INT/TERM/HUP for claim release"

# (g) Cold-start / onboarding coverage: a fresh clone can run verify.sh
# end-to-end with only bash + gh + jq + git. Implemented by re-running this
# script against a shallow clone of HEAD in a temp dir. Inner runs set
# COLD_RUN=1 and skip (g) to avoid infinite recursion.
if [[ "${COLD_RUN:-0}" == "1" ]]; then
  pass "(g) cold-start — skipped in inner recursion"
elif git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  cold="$TMP/cold"
  # shallow local clone of the current working tree — does not hit the network
  if git clone --quiet --depth 1 "$REPO_ROOT" "$cold" 2>/dev/null; then
    # Some of this PR's files are only in the working tree until commit; copy
    # them over so the cold clone can run verify.sh against them. Post-commit
    # the `git clone` alone suffices (this is a no-op if the files are already
    # in the clone's HEAD).
    cp -R "$REPO_ROOT/tests" "$cold/" 2>/dev/null || true
    cp "$REPO_ROOT/scripts/gate-check.sh" "$cold/scripts/" 2>/dev/null || true
    cp "$REPO_ROOT/scripts/tick.sh" "$cold/scripts/" 2>/dev/null || true
    cp "$REPO_ROOT/scripts/claim.sh" "$cold/scripts/" 2>/dev/null || true
    if [[ -x "$cold/tests/e2e/verify.sh" ]] \
       && verdict=$(COLD_RUN=1 bash "$cold/tests/e2e/verify.sh" 2>/dev/null | tail -1) \
       && [[ -n "$verdict" ]] \
       && echo "$verdict" | jq -e 'type == "object" and (.total | type == "number") and .total >= 6' >/dev/null 2>&1; then
      pass "(g) cold-start clone runs verify.sh and emits JSON verdict"
    else
      fail "(g) cold-start clone runs verify.sh and emits JSON verdict"
    fi
  else
    fail "(g) cold-start clone could not be created"
  fi
else
  fail "(g) cold-start clone — not inside a git work tree"
fi

# Final verdict — exactly one JSON line, per the contract.
printf '{"passed": %d, "total": %d}\n' "$passed" "$total"
exit 0
