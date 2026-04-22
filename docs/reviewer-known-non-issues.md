# Reviewer Known Non-Issues

This document maintains a curated list of patterns that the reviewer agent has previously flagged as issues but were determined by humans to be false positives. The reviewer must consult this document before posting any review to avoid repeating known false positives.

## tick.sh reviewer-dispatch at lines ~344-348
Not dead code. These are the live echo/return that dispatches reviewer role.
Last flagged as false-positive on 2026-04-21 (PRs #731, #738).

## Self-authored PRs can be approved via <!-- bee:approved-for-e2e --> marker
See #746. Not a blocker — marker is the canonical approval path.
Self-authored PRs cannot receive GitHub's `--approve` review state due to GitHub API limitations, but the bee:approved-for-e2e HTML comment marker serves as the canonical approval mechanism for the e2e agent.

## How to maintain this document

When a reviewer posts a finding that a human later rejects (comment "not actually an issue" + close without change), a follow-up drafter tick should add the pattern to this document.

Each entry should include:
- A clear heading describing the pattern
- Explanation of why it's not actually an issue
- Reference to when/where it was last incorrectly flagged
- Any relevant context or background