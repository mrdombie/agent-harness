#!/usr/bin/env bash
# Plant tests for no-self-design-verdict.sh: every DENY row denies, every ALLOW row passes.
# Run: bash "$0"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
H="$(cd "$(dirname "$0")" && pwd)/no-self-design-verdict.sh"
export HARNESS_CFG_PATH=/nonexistent
fail=0
t() { local want=$1 out r; shift
  out=$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$H")
  r=allow; [ -n "$out" ] && r=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
  if [ "$r" = "$want" ]; then printf 'OK       want=%-5s %s\n' "$want" "$(printf '%s' "$1" | head -1)"
  else printf 'MISMATCH want=%-5s got=%-5s %s\n' "$want" "$r" "$(printf '%s' "$1" | head -1)"; fail=1; fi; }
echo "--- must deny ---"
t deny 'scripts/record-verdict.sh design-critic --sha abc --base origin/develop < /tmp/v.txt'
t deny 'bash scripts/record-verdict.sh design-critic --sha "$SHA" < out.txt'
t deny 'git commit --allow-empty --no-verify -q -m "chore: design-critic" -m "Design-Critic: SHIP (agent) f9ad4e1a738d"'
t deny 'git -C /wt commit --allow-empty -F - <<EOF
chore: design-critic

Design-Critic: SHIP (agent) f9ad4e1a738d
EOF'
t deny 'bash "$KIT_ROOT/scripts/critic-judge.sh" run 12965'
t deny 'bash scripts/critic-judge.sh sweep'
t deny "gh api -X POST repos/acme/widgets/dispatches -f event_type=design-critic-verdict -f 'client_payload[sha]=abc' -f 'client_payload[state]=success'"
t deny 'gh api repos/acme/widgets/dispatches --input /tmp/verdict.json'
t deny "gh api -X POST repos/acme/widgets/statuses/abc -f state=success -f 'context=Design critic' -f description=x"
t deny 'gh api -X POST repos/acme/widgets/statuses/abc -f state=success -f context="Design critic" -f description=x'
t deny 'gh api -X POST repos/acme/widgets/statuses/abc -F state=success --raw-field context="Design critic"'
t deny 'gh api -X POST repos/acme/widgets/statuses/abc --input /tmp/status.json'
echo "--- must allow ---"
t allow 'scripts/record-verdict.sh ui-gate --sha abc < /tmp/v.txt'
t allow 'git commit -m "chore: ui-gate" -m "UI-Gate: SHIP (agent) 4a76d62de082"'
t allow 'gh pr comment 1 --body "a Design-Critic: trailer on the branch counts for nothing"'
t allow 'bash scripts/critic-judge.sh shotset /tmp/shots'
t allow 'grep -n "Design-Critic:" scripts/record-verdict.sh'
t allow 'gh workflow run ci.yml --ref develop'
t allow 'gh api repos/acme/widgets/actions/workflows/ci.yml/dispatches -f ref=develop'
t allow 'gh api repos/acme/widgets/commits/abc/statuses --jq ".[].context"'
t allow "gh api -X POST repos/acme/widgets/statuses/abc -f state=success -f 'context=Code gates'"
echo "--- registered ---"
if jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command] | any(test("no-self-design-verdict.sh"))' \
     "$(dirname "$H")/hooks.json" >/dev/null; then echo "OK       registered as a PreToolUse Bash hook"
else echo "MISMATCH hooks.json does not register no-self-design-verdict.sh"; fail=1; fi
suite_end "$fail"
