#!/usr/bin/env bash
# The 7 hookify rules that BLOCK, re-implemented as a settings.json hook.
#
# WHY: hookify loads rules with a relative glob on .claude/hookify.*.local.md,
# so every rule is inert unless the session started inside a checkout of the repo — no
# warning, no error (measured 2026-08-28: a hand-rolled ticket branch went
# through unblocked from a non-repo directory). A settings.json hook reads the
# command text before bash does and does not care about cwd.
#
# Mirrors: block-claim-tampering, block-commit-through-conflict (the -a/--all
# half; `git commit --no-verify` stays ALLOWED per block-push-no-verify.sh),
# block-destructive-git, block-git-add-all, block-npm-install-in-worktree,
# no-handrolled-pr, no-handrolled-ticket-branch.
#
# Every rule is anchored to command position (start of the text, or after
# ; & |) so a rule name quoted inside a heredoc or a commit message does
# not trip it. Self-test: .claude/hooks/block-hookify-rules.test.sh
# Project facts (state dir, branch prefix) from harness.json, via the resolver.
# Best effort, BEFORE set -e: this hook runs from ~/.claude/settings.json in
# sessions that never enter a checkout, and going inert there is the exact bug
# it was written to fix — so a missing resolver degrades the two rules that
# need a project fact, and the other five keep firing.
# Two facts, one jq read, no resolver: sourcing toolkit-env.sh cost ~370 ms on
# EVERY Bash tool call (review of PR #10362). Outside a checkout there is no
# config, and that is the case this hook exists for — so the rules below carry a
# GENERIC fallback shape (any `<letters>-<digits>/` branch, any `/claims/` path)
# rather than going inert. The env overrides are honoured the same way the
# resolver honours them.
_cfg="${HARNESS_CFG_PATH:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}/.claude/harness.json}"
if [ -f "$_cfg" ]; then
  eval "$(jq -r '"BRANCH_PREFIX=\(.branchPrefix // "" | @sh) CFG_STATE_DIR=\(.stateDir // "" | @sh) CFG_LEGACY_PREFIX=\(.legacyEnvPrefix // "" | @sh)"' "$_cfg" 2>/dev/null)"
fi
# A project may declare legacyEnvPrefix in harness.json (or HARNESS_LEGACY_ENV_PREFIX)
# so an older env prefix its fixtures pin still counts; the kit names none itself.
_lp="${HARNESS_LEGACY_ENV_PREFIX:-${CFG_LEGACY_PREFIX:-}}"; _lv=""
[ -n "$_lp" ] && { _n="${_lp}_STATE_DIR"; _lv="${!_n:-}"; }
STATE_DIR="${HARNESS_STATE_DIR:-${_lv:-${CFG_STATE_DIR:-}}}"
[ -n "$STATE_DIR" ] || STATE_DIR=$(cat "$HOME/.claude/.harness-last-state-dir" 2>/dev/null || true)   # the resolver's last-seen value
STATE_DIR="${STATE_DIR/#\~/$HOME}"
BRANCH_PREFIX="${BRANCH_PREFIX:-}"
set -euo pipefail
payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -z "$cmd" ] && exit 0
has(){ printf '%s' "$cmd" | grep -qE "$1"; }
hasF(){ printf '%s' "$cmd" | grep -qF -- "$1"; }
deny(){ jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
S='[[:space:]]'
START="(^|[;&|]$S*|&&$S*)"

claims_re='/claims/[0-9]+|\.lock'; [ -n "${STATE_DIR:-}" ] && claims_re="$(basename "$STATE_DIR")/claims|/claims/[0-9]+|\.lock"
has "${START}rm$S+(-[a-zA-Z]+$S+)*[^;&|]*($claims_re)" && deny "Hand-releasing a claim. Use claim-lock.sh release <ticket>: it deletes refs/claims/<n> on origin and updates the labels."
has "${START}git$S+[^;&|]*push$S+[^;&|]*(--delete|:)$S*refs/claims" && deny "Deleting refs/claims/<n> by hand. Use claim-lock.sh release <ticket>."
has "${START}git$S+commit[^;&|]*$S(-[a-zA-Z]*a[a-zA-Z]*|--all)($S|$)" && deny "git commit -a / --all stages everything, including conflict markers mid-merge and the node_modules symlink. Stage files by name."
has "${START}git$S+(reset$S+--hard|stash$S+pop|clean$S+-[a-zA-Z]*[fd])" && deny "reset --hard / stash pop / clean -f destroys a peer agent's uncommitted work in a shared worktree. Branch a backup first (git branch backup/<n>) and ask."
has "${START}git$S+add$S+(-A|--all|\.)($S|$)" && deny "git add -A / . stages the node_modules symlink in a worktree. Add files by path."
if has "${START}(sudo$S+)?npm$S+(install|i|ci)($S|$)" && ! hasF "--dry-run" && ! hasF "# in the main clone" && ! hasF "# main-clone install"; then deny "Worktrees share node_modules by symlink; npm install here breaks every other agent mid-build. Use --dry-run, or install at the MAIN CLONE with peers stopped and append '# main-clone install' (the same escape the hookify rule reads)."; fi
if has "${START}gh$S+pr$S+create" && ! hasF "# via /finish"; then deny "Opening a PR is /agent-harness:finish's job (gates, UI-Gate trailer, .deploy-trigger, changelog, claim release). Run /agent-harness:finish. If you ARE /agent-harness:finish, append '# via /finish' to the command."; fi
branch_re='[A-Za-z]{1,12}-[0-9]+/'; [ -n "${BRANCH_PREFIX:-}" ] && branch_re="${BRANCH_PREFIX}[0-9]+/|$branch_re"
if has "${START}git$S+worktree$S+add[^|;&]*-b$S+($branch_re)" && ! hasF "# via /claim"; then deny "Ticket branches are /agent-harness:claim's job (claim ref, spec gate, anti-orphan gates, husky shims). Run /agent-harness:claim <n>. If you ARE /agent-harness:claim, append '# via /claim'."; fi
exit 0
