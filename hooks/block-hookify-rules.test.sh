#!/usr/bin/env bash
# Plant tests for block-hookify-rules.sh. Every DENY row must deny, every
# ALLOW row must pass. Exit 1 on any mismatch. Run: bash "$0"
H="$(cd "$(dirname "$0")" && pwd)/block-hookify-rules.sh"
fail=0
# The hook reads the state dir and branch prefix through the resolver; pin both
# so the rows below are built from the same values the hook sees.
export CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
export HARNESS_STATE_DIR="${HARNESS_STATE_DIR:-$HOME/.claude/tickets-fixture}"
BRANCH_PREFIX="${BRANCH_PREFIX:-sh-}"
t(){ want=$1; shift; out=$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$H"); r=allow; [ -n "$out" ] && r=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'); mark=OK; [ "$r" = "$want" ] || { mark=MISMATCH; fail=1; }; printf '%-8s want=%-5s got=%-5s %s\n' "$mark" "$want" "$r" "$1"; }
echo "--- must deny ---"
t deny "rm -rf $HARNESS_STATE_DIR/claims/SH-9822.lock"
t deny "rm -rf $HARNESS_STATE_DIR/claims/9822"
t deny 'git push origin :refs/claims/9822'
t deny 'git commit -am "fix"'
t deny 'cd /tmp/x && git reset --hard origin/develop'
t deny 'git add -A'
t deny 'git add .'
t deny 'npm install lodash'
t deny 'gh pr create --base develop --title "x"'
t deny "git worktree add /tmp/${BRANCH_PREFIX}9999-x -b ${BRANCH_PREFIX}9999/x origin/develop"
echo "--- git commit --no-verify skips the SECRET SCAN, so it is blocked too ---"
# It succeeded 130 times across 40 runs because only the push form was blocked,
# and both hooks said in prose that the commit form "only skips formatting".
# Measured against .husky/pre-commit on 2026-09-27, it skips: gitleaks protect
# --staged, the .deploy-trigger stamp, and commitlint. Formatting is the least
# of it.
t deny 'git commit --no-verify -m "x"'
t deny 'git commit -m "x" --no-verify'
t deny 'git -C /x commit --no-verify -m "x"'
t deny 'git commit -n -m "x"'
t allow 'git commit -m "x"'
# The one caller that needs it says so. /finish commits rendered evidence with
# --no-verify by design; a blanket block would stop the gate that produces it.
t allow 'git commit -m "evidence(#1): shots" --no-verify  # no-verify-ok: evidence commit, no source changes'
t allow 'git commit --no-verify -m "x" # via /finish'
# -n on a PUSH is --dry-run, a different flag, and must not be caught here.
t allow 'git push -n origin develop'

echo "--- git's global options are not a way round the rule ---"
# `git -C <dir>` is the HOUSE STYLE in this estate, and every destructive rule
# required its subcommand to sit immediately after `git `. Measured with fake
# tool input on 2026-09-27: every one of these was ALLOWED by every copy of the
# hook, while the same command without the option was denied.
t deny 'git -C /x reset --hard'
t deny 'git -C /x reset --hard origin/develop'
t deny 'git --git-dir=/x/.git reset --hard'
t deny 'git --work-tree=/x -C /x clean -fd'
t deny 'git -C /x add -A'
t deny 'git -C /x add .'
t deny 'git -C /x commit -am "x"'
t deny 'git -C /x stash pop'
t deny 'git -c user.name=t -C /x reset --hard'
t deny 'git --no-pager -C /x add --all'
# A shell wrapper hides the command from a start-of-line anchor.
t deny 'bash -c "git reset --hard"'
t deny "sh -c 'git add -A'"
# …and the options must not turn a SAFE command into a denied one.
t allow 'git -C /x add apps/web/src/x.tsx'
t allow 'git -C /x commit -m "x"'
t allow 'git --no-pager -C /x log --oneline -5'
t allow 'git -C /x status --porcelain'
t allow 'git -C /x reset apps/web/src/x.tsx'

echo "--- must allow ---"
t allow 'git commit --amend --no-edit'
t allow 'git commit -m "x" -m "y"'
t allow 'git add apps/web/src/x.tsx'
t allow 'npm install --dry-run'
t allow 'cd ~/main-clone && npm install --prefer-offline # in the main clone'
t deny 'npm install lodash # in the worktree'
t allow 'gh pr create --base develop --title "x" # via /finish'
t allow "git worktree add /tmp/${BRANCH_PREFIX}9999-x -b ${BRANCH_PREFIX}9999/x origin/develop # via /claim"
t allow 'cat <<EOF > t.md
Run gh pr create only through /agent-harness:finish; never git add -A
EOF'
t allow 'git worktree add /tmp/flows-abc origin/develop'
echo "--- outside any checkout: no config, no env — the generic shapes still fire ---"
u(){ want=$1; shift; out=$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | (cd /tmp && env -u CLAUDE_PROJECT_DIR -u HARNESS_STATE_DIR -u HARNESS_LEGACY_ENV_PREFIX HOME=/nonexistent bash "$H")); r=allow; [ -n "$out" ] && r=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'); mark=OK; [ "$r" = "$want" ] || { mark=MISMATCH; fail=1; }; printf '%-8s want=%-5s got=%-5s %s\n' "$mark" "$want" "$r" "$1"; }
u deny "git worktree add /tmp/x -b ${BRANCH_PREFIX}9999/x origin/develop"
u deny 'git worktree add /tmp/x -b tkt-12/x origin/trunk'
u deny 'rm -rf /some/state/claims/9822'
u deny 'git add -A'
u allow 'git worktree add /tmp/x -b feature/x origin/develop'
echo "--- legacy env prefix: HARNESS_STATE_DIR unset, the config-declared prefix must still name the claims dir ---"
# The state dir is read through the declared legacy prefix; the claims path here has
# no numeric id, so only a RESOLVED state dir (basename/claims) can deny it.
l(){ want=$1; shift; out=$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | (env -u HARNESS_STATE_DIR HARNESS_LEGACY_ENV_PREFIX=LEGACY LEGACY_STATE_DIR=/x/legacy-state HOME=/nonexistent bash "$H")); r=allow; [ -n "$out" ] && r=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'); mark=OK; [ "$r" = "$want" ] || { mark=MISMATCH; fail=1; }; printf '%-8s want=%-5s got=%-5s %s\n' "$mark" "$want" "$r" "$1"; }
l deny  'rm -rf legacy-state/claims'
l allow 'rm -rf other-state/claims'
exit $fail
