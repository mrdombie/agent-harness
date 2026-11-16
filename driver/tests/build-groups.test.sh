#!/usr/bin/env bash
# build-groups.test.sh — neighbouring plan tasks naming one `group` build in one session:
# the second call resumes the first's. Each task is still its own call, its own answer and
# its own red-then-green proof. A plan with no group is a fresh session a task, as before.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/plan.sh" || exit 1
. "$HERE/../steps/build.sh" || exit 1
fix_brief plan superpowers:writing-plans
fix_brief build superpowers:test-driven-development 'The task: {{PLAN_TASK}} Last try: {{LAST_TRY}}'

# A model that says which session each call ran in. A fresh call opens session s<n> and
# calls the Skill; a resumed one keeps its session and does NOT call it again, as a real
# resumed session does not. $FIX/ctx.<n> is the context call n reports; $FIX/resume-dies
# makes every resume fail the way an unknown session id does: no transcript, exit 1.
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
step=""; prev=""; sid=""
for a in "$@"; do
  case "$prev" in --name) step="$a" ;; --resume) sid="$a" ;; esac
  prev="$a"
done
printf '%s\n' "$step" >> "$CLAUDE_LOG"
perl -e 'eval { local $SIG{ALRM} = sub { die }; alarm 5; print while <STDIN>; alarm 0 }' \
  > "$FIX/claude-stdin-$step.txt" 2>/dev/null || true
if [ "$step" != build ]; then cat "$FIX/ai/$step.jsonl"; exit 0; fi
n=$(( $(cat "$FIX/nth.build" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FIX/nth.build"
if [ -n "$sid" ] && [ -f "$FIX/resume-dies" ]; then
  printf 'resume %s died\n' "$sid" >> "$FIX/calls.log"; echo "No conversation found with session ID: $sid" >&2; exit 1
fi
if [ -n "$sid" ]; then printf 'resume %s\n' "$sid" >> "$FIX/calls.log"; else sid="s$n"; printf 'fresh %s\n' "$sid" >> "$FIX/calls.log"
  jq -nc --arg s "$sid" '{type:"assistant", session_id:$s, message:{content:[{type:"tool_use", name:"Skill", input:{skill:"superpowers:test-driven-development"}}]}}'
fi
jq -nc --arg s "$sid" --argjson c "$(cat "$FIX/ctx.$n" 2>/dev/null || echo 1000)" \
  '{type:"assistant", session_id:$s, message:{content:[], usage:{input_tokens:$c}}}'
a=$(head -1 "$FIX/answers" 2>/dev/null); sed -i.bak 1d "$FIX/answers" 2>/dev/null
jq -nc --arg s "$sid" --arg r "$a" '{type:"result", subtype:"success", is_error:false, session_id:$s, result:$r, structured_output:($r | try fromjson catch null)}'
SH
chmod +x "$BIN/claude"

plan_of() { # <group of task 1> <2> <3> <4> — four behaviours, one task each; "-" is no group
  jq -nc --args '{step:"plan",skills:["superpowers:writing-plans"],status:"planned",designSource:"ticket-body",
    premise:{verdict:"still-true",evidence:"a.sh:1"},
    features:[range(4) | {id:"F\(. + 1)",behaviour:"behaviour \(. + 1)",steps:["step \(. + 1)"],test:"f\(. + 1).test.sh",passes:false}],
    tasks:[range(4) | . as $i | {item:"F\($i + 1)",title:"task F\($i + 1)",files:[{path:"f\($i + 1).txt",action:"modify"}],tests:[{file:"f\($i + 1).test.sh",behaviour:"b",redWhen:"r"}]}
           + (if $ARGS.positional[$i] == "-" then {} else {group: $ARGS.positional[$i]} end)]}' "$@"
}
COMMITS=0
commits() { # <test file> [green-before] — a test commit then its change; queues the answer for <title>
  COMMITS=$((COMMITS+1))
  if [ -n "${2:-}" ]; then printf '#!/usr/bin/env bash\ntrue\n' > "$REPO/$1"; else printf '#!/usr/bin/env bash\ngrep -q yes c%s.txt\n' "$COMMITS" > "$REPO/$1"; fi
  git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: $1"; TS=$(git -C "$REPO" rev-parse HEAD)
  printf 'yes\n' > "$REPO/c$COMMITS.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: $1"; IS=$(git -C "$REPO" rev-parse HEAD)
}
answer() { # <title> <test-file> — the next build call's answer, from TS and IS
  jq -nc --arg f "$2" --arg t "$TS" --arg i "$IS" --arg k "$1" '{step:"build",skills:["superpowers:test-driven-development"],status:"built",task:$k,
      testFirst:{test:{file:$f,behaviour:"b",redWhen:"r"},command:("bash " + $f),testCommit:$t,implCommit:$i,failedBefore:true,redOutput:"FAIL",passedAfter:true,greenOutput:"PASS"},
      changed:[{path:"a.txt",action:"modify"}],changelog:{skipped:"a test change"}}' >> "$FIX/answers"
}
start() { # <ticket> <plan json> — a fresh ticket planned, four tasks committed and their answers queued
  fix_issue "$1" OPEN "status:claimed"; driver_state_init "$1" --worktree "$REPO" --repo "$REPO"
  fix_ai plan "$2" superpowers:writing-plans
  rm -f "$FIX"/nth.* "$FIX"/ctx.* "$FIX/resume-dies" "$FIX/calls.log" "$FIX/answers"
  RC=0; OUT=$(driver_step_plan "$1" 2>&1) || RC=$?
  local n; for n in 1 2 3 4; do commits "f$n.test.sh" "${GREEN_BEFORE:+$([ "$GREEN_BEFORE" = "$n" ] && echo y)}"; answer "task F$n" "f$n.test.sh"; done
}
build() { export DRIVER_TICKET="$1"; RC=0; : > "$CLAUDE_LOG"; OUT=$(driver_step_build "$1" 2>&1) || RC=$?; }
calls() { tr '\n' ',' < "$FIX/calls.log" | sed 's/,$//'; }
proofs() { printf '%s\n' "$OUT" | grep -c 'red (exit [0-9]*) at .*, then green at'; }
passes() { jq -r '[.items[].passes | tostring] | join(" ")' "$(driver_state_dir "$1")/features.json"; }

echo "--- three tasks of one group, then one of none: one session for the three ---"
start 301 "$(plan_of tab-a tab-a tab-a -)"
want "the plan keeps each task's group"          "tab-a tab-a tab-a -" "$(jq -r '[.tasks[] | .group // "-"] | join(" ")' "$(driver_state_dir 301)/steps/plan.json")"
build 301
want "the build finishes"                        "0" "$RC"
want "four calls, one a task"                    "4" "$(grep -c . "$CLAUDE_LOG")"
want "the group's second and third resume its first" "fresh s1,resume s1,resume s1,fresh s4" "$(calls)"
want "every task is proved on its own two commits" "4" "$(proofs)"
want "  each by its own test file"               "f1.test.sh f2.test.sh f3.test.sh f4.test.sh" "$(printf '%s\n' "$OUT" | grep -o 'f[0-9].test.sh: red' | cut -d: -f1 | tr '\n' ' ' | sed 's/ $//')"
want "  and every item passes"                   "true true true true" "$(passes 301)"
want_in "it says which session a task went on in" "task 2 goes on in the session of its group 'tab-a' .2 of at most 6" "$OUT"
want_in "a resumed call is given its own task"   'task F3' "$(cat "$FIX/claude-stdin-build.txt" 2>/dev/null; cat "$(driver_state_dir 301)/steps/build-task-3.prompt.cont")"
want_in "  and told the session goes on"         'goes on to the next task of the same plan' "$(cat "$(driver_state_dir 301)/steps/build-task-3.prompt.cont")"
want "a resumed call's own usage is recorded"    "1" "$(jq -r '.usage["build-task-2"] | length' "$(driver_state_dir 301)/state.json")"

echo "--- no group on any task: a fresh session a task, as before ---"
start 302 "$(plan_of - - - -)"
build 302
want "four fresh sessions"                       "0 fresh s1,fresh s2,fresh s3,fresh s4" "$RC $(calls)"
want_not_in "  and nothing says a session went on" 'goes on in the session' "$OUT"
want "  all four proved"                         "4" "$(proofs)"

echo "--- a group is a run of neighbours: the same name later is another session ---"
start 303 "$(plan_of tab-a tab-b tab-a tab-a)"
build 303
want "only the neighbours share one"             "0 fresh s1,fresh s2,fresh s3,resume s3" "$RC $(calls)"

echo "--- a group over the cap is split: a fresh session after that many tasks ---"
start 304 "$(plan_of tab-a tab-a tab-a tab-a)"
DRIVER_BUILD_GROUP_MAX=2 build 304
want "two tasks a session"                       "0 fresh s1,resume s1,fresh s3,resume s3" "$RC $(calls)"
want "  all four proved"                         "4" "$(proofs)"
start 305 "$(plan_of tab-a tab-a tab-a tab-a)"
DRIVER_BUILD_GROUP_MAX=1 build 305
want "a cap of 1 is a fresh session a task"      "0 fresh s1,fresh s2,fresh s3,fresh s4" "$RC $(calls)"

echo "--- a session whose context passed the ceiling is not resumed ---"
start 306 "$(plan_of tab-a tab-a tab-a -)"
echo 200000 > "$FIX/ctx.2"
build 306
want "the task after the big one starts fresh"   "0 fresh s1,resume s1,fresh s3,fresh s4" "$RC $(calls)"

echo "--- a session that cannot be resumed is a fresh call, never a lost task ---"
start 307 "$(plan_of tab-a tab-a - -)"
: > "$FIX/resume-dies"
build 307
want "the task is built in a session of its own" "0 fresh s1,resume s1 died,fresh s3,fresh s4,fresh s5" "$RC $(calls)"
want_in "  and it says so"                       'could not be resumed' "$OUT"
want "  all four proved"                         "4 true true true true" "$(proofs) $(passes 307)"

echo "--- a grouped task whose test was green before its change is refused, alone ---"
GREEN_BEFORE=2 start 308 "$(plan_of tab-a tab-a tab-a -)"
build 308
want "the build is sent back"                    "$DRIVER_E_REWORK" "$RC"
want "  the other three are proved"              "3" "$(proofs)"
want "  and only that item fails"                "true false true true" "$(passes 308)"
want "  its task carries the reason"             "1" "$(ls "$(driver_state_dir 308)"/steps/build-task-*.refused 2>/dev/null | grep -c 'build-task-2.refused')"

suite_end "$FAILED"
