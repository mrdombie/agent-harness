#!/usr/bin/env bash
# Plant tests for block-push-no-verify.sh. Exit 1 on any mismatch.
H="$(dirname "$0")/block-push-no-verify.sh"; fail=0
t(){ want=$1; shift; out=$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$H"); r=allow; [ -n "$out" ] && r=deny; mark=OK; [ "$r" = "$want" ] || { mark=MISMATCH; fail=1; }; printf '%-8s want=%-5s got=%-5s %s\n' "$mark" "$want" "$r" "$1"; }
t deny  'git push --no-verify origin x'
t deny  'cd /tmp && git push origin HEAD --no-verify'
t deny  'git -C /tmp/x push --no-verify'
t deny  'git fetch; git push --no-verify'
t allow 'git merge --no-verify --no-edit origin/develop && git push'
t allow 'git commit --no-verify -m x; git push'
t allow 'git push -n origin x'
t allow 'git push origin x'
t allow 'echo "never git push --no-verify" > notes.md'
exit $fail
