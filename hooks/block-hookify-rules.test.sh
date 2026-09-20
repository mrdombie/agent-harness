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
u(){ want=$1; shift; out=$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | (cd /private/tmp && env -u CLAUDE_PROJECT_DIR -u HARNESS_STATE_DIR -u HARNESS_LEGACY_ENV_PREFIX HOME=/nonexistent bash "$H")); r=allow; [ -n "$out" ] && r=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'); mark=OK; [ "$r" = "$want" ] || { mark=MISMATCH; fail=1; }; printf '%-8s want=%-5s got=%-5s %s\n' "$mark" "$want" "$r" "$1"; }
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
