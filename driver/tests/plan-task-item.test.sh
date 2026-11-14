#!/usr/bin/env bash
# plan-task-item.test.sh - a task item off the contract (usually "fix") on a plan with no
# feature list names nothing, so the driver drops it and the plan goes on with one call.
# With a feature list the same item is still sent back once, by its path.
# The briefs, the contract and the validator are the ones that ship; only the model is stubbed.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
. "$HERE/../state.sh" || exit 1
KIT="$FIX/kit"

ITEMS='## The change
1. the list is renamed

## Acceptance criteria
- [ ] the new name shows on the page'

ticket() { # <n> <body>
  fix_issue "$1" OPEN "status:claimed"
  jq --arg b "$2" '.body = $b' "$FIX/gh/issue-$1.json" > "$FIX/i.json" && mv "$FIX/i.json" "$FIX/gh/issue-$1.json"
  driver_state_init "$1" --worktree "$REPO"
}
plan() { # <task item> [features JSON] - one task; no feature list when the second is absent
  jq -nc --arg i "$1" --argjson f "${2:-null}" '{step:"plan",skills:["superpowers:writing-plans"],status:"planned",designSource:"ticket-body",
    premise:{verdict:"still-true",evidence:"a.sh:1"},
    tasks:[{item:$i,title:"rename it",files:[{path:"f1.sh",action:"modify"}],tests:[{file:"f1.test.sh",behaviour:"b",redWhen:"r"}]}]}
    + (if $f == null then {} else {features:$f} end)'
}
FEATURES='[{"id":"F1","behaviour":"a person sees the new name","steps":["open the page"],"test":"f1.test.sh","passes":false,"covers":["C1","A1"]}]'
step() { # <ticket> <answer> - the plan step from ${SUT_KIT:-the kit}
  local kit="${SUT_KIT:-$ROOT}"
  fix_ai plan "$2" superpowers:writing-plans
  : > "$CLAUDE_LOG"; : > "$GH_LOG"; R_RC=0
  R_OUT=$(DRIVER_BRIEFS="$kit/briefs" DRIVER_SCHEMAS="$kit/briefs/schemas" DRIVER_VALIDATE="$kit/briefs/validate.sh" \
    bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT
      . "$1/driver/driver-env.sh" && . "$1/driver/steps/plan.sh" && driver_step_plan "$2"' _ "$kit" "$1" 2>&1) || R_RC=$?
  R_CALLS=$(grep -c '^plan$' "$CLAUDE_LOG")
  R="rc=$R_RC calls=$R_CALLS"
}
task0() { jq -r '.tasks[0] | [.title, (.item // "none")] | join("|")' "$STATE/driver/$1/steps/plan.json"; }
N=700
next() { N=$((N + 1)); ticket "$N" "${1:-$ITEMS}"; }
case_bare() { next "No list here, only a paragraph."; step "$N" "$(plan fix)"; }

echo "--- no feature list: an item off the contract is dropped, one call ---"
case_bare
want "the plan is accepted on the first answer"      "rc=0 calls=1" "$R"
want_in "  the run says so, in one line"             'plan: 1 task item matched no feature list item and the plan has none - dropped, not asked again' "$(printf '%s' "$R_OUT" | sed 's/—/-/g')"
want "  the task is kept, without the item"          "rename it|none" "$(task0 "$N")"
next "No list here, only a paragraph."; step "$N" "$(plan cleanup)"
want "an item on the contract is kept as it is"      "rc=0 calls=1 rename it|cleanup" "$R $(task0 "$N")"

echo "--- a feature list: an unknown item is sent back once, by its path ---"
next; step "$N" "$(plan fix "$FEATURES")"
want "one re-ask, then the shape park"               "rc=$DRIVER_E_SCHEMA calls=2" "$R"
want_in "  the re-ask names the task"                '/tasks/0/item' "$(cat "$FIX/claude-stdin-plan.txt")"
want_not_in "  and nothing was dropped"              'dropped, not asked again' "$R_OUT"

echo "--- planted: the repair is what holds it ---"
rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$KIT/"
python3 - "$KIT/driver/ai-step.sh" <<'PY' || bad "plant did not land"
import sys
p = sys.argv[1]
s = open(p).read()
old = '        mv "$ans.items" "$ans"\n'
if s.count(old) != 1: sys.exit(1)
open(p, "w").write(s.replace(old, ""))
PY
SUT_KIT="$KIT" case_bare
want "planted (item kept): refused, asked again, parked" "rc=$DRIVER_E_SCHEMA calls=2" "$R"

suite_end "$FAILED"
