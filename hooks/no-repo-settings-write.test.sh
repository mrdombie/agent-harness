#!/usr/bin/env bash
# Plant tests for no-repo-settings-write.sh and its classifier. Exit 1 on any mismatch.
H="$(dirname "$0")/no-repo-settings-write.sh"; L="$(dirname "$0")/lib/repo-settings-write.sh"; fail=0
t(){ want=$1; shift; out=$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | CLAIM_RUN_ID=run-1 HARNESS_DRIVER_RUN= bash "$H"); r=allow; [ -n "$out" ] && r=deny; mark=OK; [ "$r" = "$want" ] || { mark=MISMATCH; fail=1; }; printf '%-8s want=%-5s got=%-5s %s\n' "$mark" "$want" "$r" "$1"; }
t deny  'gh api -X PUT repos/o/r/rulesets/1 --input r.json'
t deny  'gh api --method PATCH repos/o/r/rulesets/17138103 -f name=x'
t deny  'gh api -X DELETE /repos/o/r/branches/develop/protection'
t deny  'gh api repos/o/r/branches/main/protection/required_status_checks/contexts -f "contexts[]=Lesson"'
t deny  'gh api -XPUT repos/o/r/collaborators/someone'
t deny  'gh api -X PATCH repos/o/r -f allow_auto_merge=true'
t deny  'gh api -X POST orgs/acme/hooks -f name=web'
t deny  'gh api -X PUT repos/o/r/actions/permissions -F enabled=true'
t deny  'cd /x && GH_TOKEN=1 gh api -X PUT repos/o/r/rulesets/1 --input r.json'
t deny  'gh api graphql -f query="mutation { updateBranchProtectionRule(input:{}) { clientMutationId } }"'
t deny  'gh repo edit --enable-auto-merge'
t deny  'gh secret set FOO --body x'
t allow 'gh api repos/o/r/rulesets'
t allow 'gh api repos/o/r/rulesets/1 --jq .rules'
t allow 'gh api -X GET repos/o/r/branches/main/protection'
t allow 'gh api repos/o/r/issues/5/comments -f body=hi'
t allow 'gh api -X POST repos/o/r/issues/5/labels -f "labels[]=x"'
t allow 'gh api repos/o/r/pulls/7'
t allow 'gh api graphql -f query="{ repository(owner:\"o\",name:\"r\") { id } }"'
t allow 'gh pr create --title x --body y'
t allow 'echo "gh api -X PUT repos/o/r/rulesets/1"'
t allow 'git commit -m "gh api -X PUT repos/o/r/rulesets/1"'
# A person's session (no build run marker) is the PM's and is not refused.
out=$(jq -nc '{tool_name:"Bash",tool_input:{command:"gh api -X PUT repos/o/r/rulesets/1"}}' | env -u CLAIM_RUN_ID -u HARNESS_DRIVER_RUN bash "$H")
[ -z "$out" ] && echo "OK       a person's own session is not refused" || { echo "MISMATCH a person's own session was refused"; fail=1; }
# A driver step is a build run too.
out=$(jq -nc '{tool_name:"Bash",tool_input:{command:"gh api -X PUT repos/o/r/rulesets/1"}}' | env -u CLAIM_RUN_ID HARNESS_DRIVER_RUN=1:build bash "$H")
[ -n "$out" ] && echo "OK       a driver step is refused" || { echo "MISMATCH a driver step was let through"; fail=1; }
# The argv form the driver's gh shim uses.
bash "$L" gh api -X PUT repos/o/r/rulesets/1 && echo "OK       argv form refuses a ruleset write" || { echo "MISMATCH argv form let a ruleset write through"; fail=1; }
bash "$L" gh api repos/o/r/rulesets && { echo "MISMATCH argv form refused a read"; fail=1; } || echo "OK       argv form allows a read"
exit $fail
