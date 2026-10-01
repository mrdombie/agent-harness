#!/usr/bin/env bash
# The 7 hookify rules that BLOCK, re-implemented as a settings.json hook.
#
# WHY: hookify loads rules with a relative glob on .claude/hookify.*.local.md,
# so every rule is inert unless the session started inside a checkout of the repo — no
# warning, no error (measured 2026-08-28: a hand-rolled ticket branch went
# through unblocked from a non-repo directory). A settings.json hook reads the
# command text before bash does and does not care about cwd.
#
# Mirrors: block-claim-tampering, block-commit-through-conflict (both halves —
# `git commit --no-verify` is blocked as of 2026-09-27, because it skips the
# secret scan and not just formatting), block-destructive-git,
# block-git-add-all, block-npm-install-in-worktree, no-handrolled-pr,
# no-handrolled-ticket-branch.
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
  eval "$(jq -r '"BRANCH_PREFIX=\(.branchPrefix // "" | @sh) CFG_STATE_DIR=\(.stateDir // "" | @sh) CFG_LEGACY_PREFIX=\(.legacyEnvPrefix // "" | @sh) CFG_REPO=\(.repo // "" | @sh)"' "$_cfg" 2>/dev/null)"
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
# Match against the command, with any heredoc BODY removed. A heredoc body is
# DATA the command reads on stdin, not shell the command runs — and the rule text
# in this repo's own docs, PR bodies and skill files is full of the shapes these
# rules deny. There was already an allow-row for `cat <<EOF … never git add -A
# EOF`; it passed only because the body's lines happened not to start a command
# position. A markdown table row does: `| git -C /x reset --hard | allow |` opens
# with a literal pipe, which the separator class reads as one, so writing this
# very PR body was denied (2026-09-27).
#
# Known limit, deliberately left: `bash <<EOF` really does run its body, so a
# destructive command hidden there is not caught. The wrapper forms that are
# caught are the ones agents actually use (`bash -c "…"`).
strip_heredocs() {
  awk '
    # Closing the current body?
    inbody { if ($0 == term) { inbody = 0 }; next }
    {
      line = $0
      # <<WORD, <<-WORD, <<"WORD", <<'"'"'WORD'"'"' — take the last one on the line.
      if (match(line, /<<-?[ \t]*("[^"]+"|'"'"'[^'"'"']+'"'"'|[A-Za-z_][A-Za-z0-9_]*)/)) {
        t = substr(line, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", t)
        gsub(/["'"'"']/, "", t)
        term = t; inbody = 1
      }
      print line
    }
  '
}
cmd_code=$(printf '%s\n' "$cmd" | strip_heredocs)
has(){ printf '%s' "$cmd_code" | grep -qE "$1"; }
hasF(){ printf '%s' "$cmd" | grep -qF -- "$1"; }
deny(){ jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
S='[[:space:]]'
# End of a command word: whitespace, end of text, or the quote that CLOSES a
# shell wrapper — `sh -c 'git add -A'` ends in a quote, not a space, so a bare
# ($S|$) read it as an unfinished flag and allowed it.
EOW="($S|\$|['\"])"
# A command starts at the text's start, after a separator — OR inside a shell
# wrapper. `bash -c "git reset --hard"` put the command where a start-of-line
# anchor could not see it, and it was allowed by every copy of this hook.
START="(^|[;&|]$S*|&&$S*|(ba|z|da)?sh$S+-c$S*['\"]?)"
# `git` plus its GLOBAL OPTIONS, so a rule can anchor on the SUBCOMMAND. Every
# destructive rule below required the subcommand to sit immediately after `git `,
# and `git -C <dir>` is the house style in this estate — so, measured with fake
# tool input on 2026-09-27, `git -C /x reset --hard`, `git -C /x add -A` and
# `git --git-dir=… reset --hard` were ALL allowed while the bare forms were
# denied. Borrowed from block-push-no-verify.sh, which has handled -C all along.
#
# The options are enumerated rather than globbed: a loose `-\S+` would swallow the
# subcommand and turn safe commands into denials. -C/-c take a separate value;
# the long forms take an attached one.
GITOPT="(-[Cc]$S+[^;&|[:space:]]+|--[a-z-]+(=[^;&|[:space:]]+)?|-[a-zA-Z]+)"
GIT="git($S+$GITOPT)*$S+"

claims_re='/claims/[0-9]+|\.lock'; [ -n "${STATE_DIR:-}" ] && claims_re="$(basename "$STATE_DIR")/claims|/claims/[0-9]+|\.lock"
has "${START}rm$S+(-[a-zA-Z]+$S+)*[^;&|]*($claims_re)" && deny "Hand-releasing a claim. Use claim-lock.sh release <ticket>: it deletes refs/claims/<n> on origin and updates the labels."
has "${START}${GIT}[^;&|]*push$S+[^;&|]*(--delete|:)$S*refs/claims" && deny "Deleting refs/claims/<n> by hand. Use claim-lock.sh release <ticket>."
has "${START}${GIT}commit[^;&|]*$S(-[a-zA-Z]*a[a-zA-Z]*|--all)$EOW" && deny "git commit -a / --all stages everything, including conflict markers mid-merge and the node_modules symlink. Stage files by name."
# `git commit --no-verify` was allowed on the stated grounds that it "only skips
# formatting". That was measured on 2026-09-27 and is false: against
# .husky/pre-commit it skips the SECRET SCAN (gitleaks protect --staged), the
# .deploy-trigger stamp, and commitlint. It succeeded 130 times across 40 runs
# because only the push form was ever blocked. `-n` is the short form on a
# commit; on a push it means --dry-run, which is why this rule names `commit`.
if has "${START}${GIT}commit[^;&|]*$S(--no-verify|-[a-zA-Z]*n[a-zA-Z]*)$EOW" \
   && ! hasF "no-verify-ok:" && ! hasF "# via /finish"; then
  deny "git commit --no-verify skips the SECRET SCAN (gitleaks protect --staged), the .deploy-trigger stamp and commitlint — not just formatting. Commit without it. If a commit genuinely must bypass them (a rendered-evidence commit that touches no source), append '# no-verify-ok: <reason>'."
fi
has "${START}${GIT}(reset$S+--hard|stash$S+pop|clean$S+-[a-zA-Z]*[fd])" && deny "reset --hard / stash pop / clean -f destroys a peer agent's uncommitted work in a shared worktree. Branch a backup first (git branch backup/<n>) and ask."
has "${START}${GIT}add$S+(-A|--all|\.)$EOW" && deny "git add -A / . stages the node_modules symlink in a worktree. Add files by path."
# --package-lock-only rewrites package-lock.json and never reads or writes
# node_modules, so it cannot break a peer's linked install. It is the one way to
# repair a dependency bot's PR whose lockfile it failed to refresh (2026-10-01:
# two security updates sat red behind this rule with no other way through).
if has "${START}(sudo$S+)?npm$S+(install|i|ci)($S|$)" && ! hasF "--dry-run" && ! hasF "--package-lock-only" && ! hasF "# in the main clone" && ! hasF "# main-clone install"; then deny "Worktrees share node_modules by symlink; npm install here breaks every other agent mid-build. Use --dry-run, or install at the MAIN CLONE with peers stopped and append '# main-clone install' (the same escape the hookify rule reads)."; fi
# The finish flow owns PRs against THE CONFIGURED PROJECT, because that is where
# its gates, trailer, changelog and claim release apply. A PR against a DIFFERENT
# repo — this kit itself, a sister repo — has none of those, and blocking it
# leaves an agent with pushed work and only two ways out: claim to be the finish
# flow, or abandon the work. Both are worse than the rule.
#
# A PreToolUse hook runs in the harness's environment, not inside the command it
# judges, so an env override in that command never reaches here. And a session
# working in another repo's clone — exactly when this exemption is wanted — has
# no config to read. So the slug is cached: written whenever a configured session
# sees it, read only when nothing else supplies it, and absent both it denies.
REPO_SLUG="${HARNESS_REPO_SLUG:-${CFG_REPO:-}}"
_slug_cache="$HOME/.claude/.harness-last-repo-slug"
if [ -n "$REPO_SLUG" ]; then
  [ "$(cat "$_slug_cache" 2>/dev/null)" = "$REPO_SLUG" ] || printf '%s' "$REPO_SLUG" > "$_slug_cache" 2>/dev/null || true
else
  REPO_SLUG=$(cat "$_slug_cache" 2>/dev/null || true)
fi
pr_targets_elsewhere() {
  local target
  target=$(printf '%s' "$cmd" | grep -oE -- '--repo[= ]+[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' | head -1 | sed -E 's/--repo[= ]+//')
  [ -n "$target" ] && [ -n "$REPO_SLUG" ] && [ "$target" != "$REPO_SLUG" ]
}
if has "${START}gh$S+pr$S+create" && ! hasF "# via /finish" && ! pr_targets_elsewhere; then deny "Opening a PR against ${REPO_SLUG:-the configured project} is /agent-harness:finish's job (gates, UI-Gate trailer, .deploy-trigger, changelog, claim release). Run /agent-harness:finish. If you ARE /agent-harness:finish, append '# via /finish' to the command. A PR against another repo needs an explicit --repo <owner>/<name>."; fi
branch_re='[A-Za-z]{1,12}-[0-9]+/'; [ -n "${BRANCH_PREFIX:-}" ] && branch_re="${BRANCH_PREFIX}[0-9]+/|$branch_re"
if has "${START}git$S+worktree$S+add[^|;&]*-b$S+($branch_re)" && ! hasF "# via /claim"; then deny "Ticket branches are /agent-harness:claim's job (claim ref, spec gate, anti-orphan gates, husky shims). Run /agent-harness:claim <n>. If you ARE /agent-harness:claim, append '# via /claim'."; fi
exit 0
