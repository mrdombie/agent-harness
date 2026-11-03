#!/usr/bin/env bash
# review-panel.test.sh — the review is a cheap vote with a bounded agent count. A review
# step's agent count is bounded and configured, never left to a skill's top level: three
# voters by default (review.voters), each one session running `code-review` at high
# (review.effort) with no Agent tool, and a voter that starts a subagent of its own fails
# the step. A finding stays when 2 of the 3 report it; it takes their most common grade, a
# tie going lower; 1 voter counts without a vote. Then, as before: a nit is dropped, a
# pre-existing defect goes to the sweep queue, and no posted finding is raised twice.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
. "$HERE/../steps/review.sh" || exit 1
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/sf"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/pl"
chmod +x "$FIX/sf" "$FIX/pl"
export DRIVER_SCREEN_FINDINGS="$FIX/sf" DRIVER_POLISH_LIST="$FIX/pl" SWEEP_QUEUE="$FIX/sweep.jsonl"
# The shipped defaults: the fixture's one reviewer taken out.
unset DRIVER_REVIEW_VOTERS
jq '.release = {mergeFirst: true, done: false}' "$HARNESS_CFG_PATH" > "$FIX/mf-on.json"
jq '.review.voters = 1' "$FIX/mf-on.json" > "$FIX/one.json"
on()  { HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" "$@"; }
one() { HARNESS_CFG="$FIX/one.json" HARNESS_CFG_PATH="$FIX/one.json" "$@"; }

rp_tree() { # <ticket> — a P1 branch whose change touches a.sh
  git -C "$REPO" worktree add -q "$FIX/rp$1" -b "tkt-$1/work" develop
  printf 'a\n' > "$FIX/rp$1/a.sh"; git -C "$FIX/rp$1" add -A; git -C "$FIX/rp$1" commit -qm "feat: a"
  driver_state_init "$1" --worktree "$FIX/rp$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "status:claimed,P1"
}
rj()  { printf '%s/steps/review.json' "$(driver_state_dir "$1")"; }
ids() { jq -r '[.findings[]?.id] | join(" ")' "$(rj "$1")"; }
fu()  { jq -r .id "$(driver_state_dir "$1")/steps/review.followups.jsonl" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
sweep_ids() { jq -r '.summary' "$SWEEP_QUEUE" 2>/dev/null | tr '\n' '|' | sed 's/|$//'; }
fact() { cat "$(driver_state_dir "$1")/steps/review.facts/$2" 2>/dev/null; }
calls() { grep -cx review "$CLAUDE_LOG"; }
# answer <round> <verdict> <findings json> — one voter's whole answer in the shipped contract.
answer() {
  jq -nc --argjson r "$1" --arg v "$2" --argjson f "$3" \
    '{step: "review", skills: ["code-review"], status: "reviewed", round: $r, verdict: $v,
      panel: {skill: "code-review", effort: "high"}, findings: $f}'
}
# transcript <file> <answer> [extra event…] — what one voter's session leaves, in the shape
# measured 2026-11-02 at high: the Skill call, the one task it forks (opened by that call,
# spawn depth 1), any extra events a case adds, then the answer.
transcript() {
  local f="$1" a="$2"; shift 2
  : > "$f"
  jq -nc '{type:"assistant", message:{content:[{type:"tool_use", id:"toolu_skill", name:"Skill", input:{skill:"code-review", args:"high develop"}}]}}' >> "$f"
  jq -nc '{type:"system", subtype:"task_started", task_id:"a1", tool_use_id:"toolu_skill", description:"/code-review", spawn_depth:1}' >> "$f"
  local e; for e in "$@"; do printf '%s\n' "$e" >> "$f"; done
  jq -nc '{type:"system", subtype:"task_notification", task_id:"a1", tool_use_id:"toolu_skill", status:"completed"}' >> "$f"
  jq -nc --arg r "$a" '{type:"result", subtype:"success", is_error:false, result:$r, structured_output:($r | fromjson)}' >> "$f"
}
# votes <answer 1> <answer 2> <answer 3> — what each of the three voters answers.
# One reviewer (no voter number) reads the shared transcript: it is voter 1's.
votes() {
  rm -f "$FIX"/ai/review.v*.jsonl; local i=0 a
  for a in "$@"; do i=$((i + 1)); transcript "$FIX/ai/review.v$i.jsonl" "$a"; done
  cp "$FIX/ai/review.v1.jsonl" "$FIX/ai/review.jsonl"
}
# same <answer> — every voter answers the same (the shared transcript).
same() { rm -f "$FIX"/ai/review.v*.jsonl; transcript "$FIX/ai/review.jsonl" "$1"; }

F_A1='{"id":"a1","file":"a.sh","line":1,"grade":"major","tag":"important","summary":"the save is dropped on retry","reason":"a person sees saved and loses the draft","fix":"keep it"}'
F_A2='{"id":"x9","file":"./a.sh","line":4,"grade":"major","tag":"important","summary":"On retry the save gets dropped","reason":"the draft is lost","fix":"keep the save"}'
F_B='{"id":"b1","file":"a.sh","line":30,"grade":"major","tag":"important","summary":"the timer may race the retry","reason":"r","fix":"f"}'
F_NIT='{"id":"n1","file":"a.sh","line":9,"grade":"nit","tag":"nit","summary":"the loop could be a for-of","reason":"cleanup","fix":"f"}'
F_PRE='{"id":"p1","file":"lib/old.sh","line":9,"grade":"major","tag":"pre-existing","summary":"the old reader drops a 500 as an empty page","reason":"r","fix":"f"}'
F_MINOR='{"id":"m1","file":"lib/other.sh","line":2,"grade":"minor","tag":"important","summary":"the label is vague","reason":"r","fix":"f"}'
MIXED=("$(answer 1 BLOCKED "[$F_A1,$F_NIT,$F_PRE]")" "$(answer 1 BLOCKED "[$F_A2,$F_NIT,$F_PRE]")" "$(answer 1 BLOCKED "[$F_B]")")

echo "--- the default is 3 voters, each code-review at high with no Agent tool ---"
rp_tree 701
votes "${MIXED[@]}"
: > "$CLAUDE_LOG"
rc=0; out=$(on driver_step_review 701 2>&1) || rc=$?
want "the agreed Major goes back to fix"           "30" "$rc"
want "three voter sessions ran, no more"           "3" "$(calls)"
want "the effort defaults to high"                 "high" "$(fact 701 EFFORT)"
want "the target is the trunk"                     "develop" "$(fact 701 TARGET)"
want "each voter was handed the same diff"         "$(fact 701 DIFF)" "$(cat "$(driver_state_dir 701)/steps/review-v3.facts/DIFF")"
tools=$(awk 'p { if ($0 ~ /^--/) exit; print } $0 == "--tools" { p = 1 }' "$FIX/claude-args-review.txt" | tr '\n' ' ' | sed 's/ $//')
want "a voter's tools carry no Agent and no Task"  "Bash Read Grep Glob Skill" "$tools"
want "the panel names 3 voters, 3 answered"        "3/3 high" "$(jq -r '.panel | "\(.voters)/\(.answered) \(.effort)"' "$(rj 701)")"

echo "--- 2 of 3 keeps; 1 of 3 drops, and the drop is said ---"
want "kept: the finding two voters reported"       "a1" "$(ids 701)"
want "its tally is the vote"                       "2/3" "$(jq -r '.findings[0].votes | "\(.agree)/\(.of)"' "$(rj 701)")"
want_in "the 1-of-3 is said, not dropped silently" "1 finding.s. the voters did not agree on" "$out"
want_in "an agreed nit is dropped and said"        "1 nit" "$out"
want "the agreed pre-existing one is swept"        "the old reader drops a 500 as an empty page" "$(sweep_ids)"
want "it names the ticket that found it"           "701" "$(jq -r .ticket "$SWEEP_QUEUE")"
want "it is not a follow-up ticket"                "" "$(fu 701)"

rp_tree 702
votes "$(answer 1 BLOCKED "[$F_B]")" "$(answer 1 SHIP '[]')" "$(answer 1 SHIP '[]')"
rc=0; on driver_step_review 702 >/dev/null 2>&1 || rc=$?
want "a Major only one voter saw ships"            "0" "$rc"
want "and nothing is kept"                         "" "$(ids 702)"

echo "--- a split grade goes to the lower; a majority grade stands ---"
rp_tree 703
F_A2_MINOR=$(jq -c '.grade = "minor"' <<<"$F_A2")
votes "$(answer 1 BLOCKED "[$F_A1]")" "$(answer 1 BLOCKED "[$F_A2_MINOR]")" "$(answer 1 SHIP '[]')"
on driver_step_review 703 >/dev/null 2>&1
want "major against minor is kept as minor"        "minor" "$(jq -r '.findings[0].grade' "$(rj 703)")"
want "with the wording of the voter that said minor" "x9" "$(ids 703)"
rp_tree 704
votes "$(answer 1 BLOCKED "[$F_A1]")" "$(answer 1 BLOCKED "[$F_A2_MINOR]")" "$(answer 1 BLOCKED "[$F_A2]")"
on driver_step_review 704 >/dev/null 2>&1
want "major, minor, major is kept as major"        "major" "$(jq -r '.findings[0].grade' "$(rj 704)")"
want "3 of 3"                                      "3/3" "$(jq -r '.findings[0].votes | "\(.agree)/\(.of)"' "$(rj 704)")"

echo "--- review.voters 1 is a single reviewer whose findings count without a vote ---"
rp_tree 705
same "$(answer 1 BLOCKED "[$F_B]")"
: > "$CLAUDE_LOG"
rc=0; one driver_step_review 705 >/dev/null 2>&1 || rc=$?
want "its lone Major goes back to fix"             "30" "$rc"
want "one session ran"                             "1" "$(calls)"
want "it is kept, with no tally on it"             "b1 null" "$(jq -r '.findings[0] | "\(.id) \(.votes)"' "$(rj 705)")"

echo "--- the cap: a voter that starts a subagent of its own fails the step, loudly ---"
AGENT='{"type":"assistant","parent_tool_use_id":"toolu_skill","message":{"content":[{"type":"tool_use","id":"toolu_finder","name":"Agent","input":{"description":"Finder 1","prompt":"hunt"}}]}}'
rp_tree 706
votes "${MIXED[@]}"
transcript "$FIX/ai/review.v2.jsonl" "${MIXED[1]}" "$AGENT"
rc=0; out=$(on driver_step_review 706 2>&1) || rc=$?
want "an Agent call inside the skill fails the step" "24" "$rc"
want_in "and says which voter, and why"            "voter 2 started 1 subagent" "$out"
want_in "the park names the cap"                   "past the cap of none" "$(driver_state_get 706 park_note)"
rp_tree 707
votes "${MIXED[@]}"
transcript "$FIX/ai/review.v1.jsonl" "${MIXED[0]}" '{"type":"system","subtype":"task_started","task_id":"b2","tool_use_id":"toolu_other","spawn_depth":2}'
rc=0; on driver_step_review 707 >/dev/null 2>&1 || rc=$?
want "a task no Skill call opened fails it too"    "24" "$rc"
rp_tree 790
votes "${MIXED[@]}"
transcript "$FIX/ai/review.v1.jsonl" "${MIXED[0]}" '{"type":"system","subtype":"task_started","task_id":"bu1","tool_use_id":"toolu_bash","parent_task_id":"a1","owned_by_subagent":true,"task_type":"local_bash","description":"Run loop tests"}'
rc=0; on driver_step_review 790 >/dev/null 2>&1 || rc=$?
want "a command the review runs is not a subagent" "30" "$rc"
rp_tree 708
same "$(answer 1 BLOCKED "[$F_B]")"
transcript "$FIX/ai/review.jsonl" "$(answer 1 BLOCKED "[$F_B]")" "$AGENT"
rc=0; one driver_step_review 708 >/dev/null 2>&1 || rc=$?
want "one reviewer is capped as well"              "24" "$rc"

echo "--- a voter that gives no verdict is left out; the other two still vote ---"
rp_tree 709
votes "${MIXED[0]}" "${MIXED[1]}" "$(answer 1 BLOCKED "[$F_B]")"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"I could not finish"}' > "$FIX/ai/review.v3.jsonl"
rc=0; out=$(on driver_step_review 709 2>&1) || rc=$?
want "the two that answered keep their agreed Major" "30" "$rc"
want "it is the one they agreed on"                "a1" "$(ids 709)"
want_in "the missing voter is said"                "voter 3 gave no verdict" "$out"

echo "--- no posted finding is raised twice ---"
rp_tree 710
same "$(answer 1 BLOCKED "[$F_A1]")"
on driver_step_review 710 >/dev/null 2>&1
want "the posted ledger holds it"                  "a.sh|the save is dropped on retry" "$(jq -r .key "$(driver_state_dir 710)/steps/review.posted.jsonl")"
printf 'z\n' > "$FIX/rp710/z.sh"; git -C "$FIX/rp710" add -A; git -C "$FIX/rp710" commit -qm "fix: z"; driver_state_bump 710 fix
again='{"id":"g1","file":"./a.sh","line":7,"grade":"major","tag":"important","summary":"The save is dropped on RETRY.","reason":"r","fix":"f"}'
fresh='{"id":"g2","file":"z.sh","line":1,"grade":"major","tag":"important","summary":"the new helper swallows the error","reason":"r","fix":"f"}'
same "$(answer 2 BLOCKED "[$again,$fresh]")"
rc=0; out=$(on driver_step_review 710 2>&1) || rc=$?
want "round 2 still blocks on the fresh one"       "30" "$rc"
want "the repeat is gone"                          "g2" "$(ids 710)"
want_in "and said"                                 "1 finding.s. already raised on this change" "$out"
want_in "round 2 is told what was already raised"  "the save is dropped on retry" "$(fact 710 DIFF)"

echo "--- a re-raise with no fix round since is the finding still standing, not a repeat ---"
rp_tree 711
same "$(answer 1 BLOCKED "[$F_A1]")"
on driver_step_review 711 >/dev/null 2>&1
same "$(answer 2 BLOCKED "[$F_A1]")"
rc=0; on driver_step_review 711 >/dev/null 2>&1 || rc=$?
want "it still blocks"                             "30" "$rc"
want "and is still on the answer"                  "a1" "$(ids 711)"

echo "--- a class is one finding; voters naming the same class agree on it ---"
rp_tree 712
cls='{"id":"c1","file":"a.sh","line":1,"grade":"major","tag":"important","class":"a failed read shown as empty","instances":["a.sh:1","b.sh:4"],"summary":"the queue shows empty on a failed read","reason":"r","fix":"f"}'
cls_b='{"id":"c7","file":"b.sh","line":40,"grade":"major","tag":"important","class":"A failed read, shown as empty","instances":["b.sh:4","c.sh:2"],"summary":"the rail shows nothing when the fetch fails","reason":"r","fix":"f"}'
votes "$(answer 1 BLOCKED "[$cls]")" "$(answer 1 BLOCKED "[$cls_b]")" "$(answer 1 SHIP '[]')"
on driver_step_review 712 >/dev/null 2>&1
want "two voters naming one class are one finding"  "c1 2/3" "$(jq -r '.findings[0] | "\(.id) \(.votes.agree)/\(.votes.of)"' "$(rj 712)")"
want "its instances are every voter's"              "a.sh:1 b.sh:4 c.sh:2" "$(jq -r '.findings[0].instances | join(" ")' "$(rj 712)")"
printf 'z\n' > "$FIX/rp712/z.sh"; git -C "$FIX/rp712" add -A; git -C "$FIX/rp712" commit -qm "fix: z"; driver_state_bump 712 fix
cls2='{"id":"c2","file":"z.sh","line":3,"grade":"major","tag":"important","class":"A failed read shown as empty","summary":"the rail shows empty on a failed read","reason":"r","fix":"f"}'
same "$(answer 2 BLOCKED "[$cls2]")"
rc=0; on driver_step_review 712 >/dev/null 2>&1 || rc=$?
want "the class already raised does not block again" "0" "$rc"

echo "--- grade effects stand: under merge first a kept Minor elsewhere goes to the sweep, never a ticket ---"
rp_tree 713
same "$(answer 1 BLOCKED "[$F_MINOR]")"
rc=0; on driver_step_review 713 >/dev/null 2>&1 || rc=$?
want "a Minor in a file the change did not touch ships" "0" "$rc"
want "and is filed nowhere"                        "" "$(fu 713)"
want "it is sent to the sweep"                     "m1=sweep" "$(jq -r '"\(.id)=\(.list)"' "$(driver_state_dir 713)/steps/review.deferred.jsonl")"

echo "--- an answer with no panel (an older reviewer) is graded exactly as before ---"
rp_tree 714
fix_ai review '{"step":"review","skills":["code-review"],"status":"reviewed","round":1,"verdict":"BLOCKED","findings":[{"id":"o1","file":"a.sh","line":1,"grade":"major","summary":"s","reason":"r","fix":"f"}]}' code-review
rm -f "$FIX"/ai/review.v*.jsonl
rc=0; one driver_step_review 714 >/dev/null 2>&1 || rc=$?
want "its Major goes to fix"                       "30" "$rc"

echo "--- plants: each guard out of a copy of the kit, its case fails ---"
KIT="$FIX/kit"; N=750
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$KIT/"; }
in_kit() { # <ticket> — the review step run from the copy of the kit, at the shipped defaults
  local rc=0
  HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" DRIVER_BRIEFS="$KIT/briefs" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/review.sh" && driver_step_review "$2"' _ "$KIT" "$1" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
case_mixed() { # the three mixed voters: the exit, what was kept, what the sweep got, the calls
  N=$((N + 1)); rp_tree "$N"; : > "$SWEEP_QUEUE"; : > "$CLAUDE_LOG"; votes "${MIXED[@]}"
  local rc; rc=$(in_kit "$N")
  R="rc=$rc kept=$(ids "$N") swept=$(grep -c . "$SWEEP_QUEUE") calls=$(calls) effort=$(fact "$N" EFFORT)"
}
case_capped() { # voter 2 starts a finder agent inside the skill
  N=$((N + 1)); rp_tree "$N"; votes "${MIXED[@]}"; transcript "$FIX/ai/review.v2.jsonl" "${MIXED[1]}" "$AGENT"
  R="rc=$(in_kit "$N")"
}
case_bash() { # voter 1's review runs a test command, a local_bash task inside its fork
  N=$((N + 1)); rp_tree "$N"; votes "${MIXED[@]}"
  transcript "$FIX/ai/review.v1.jsonl" "${MIXED[0]}" '{"type":"system","subtype":"task_started","task_id":"bu1","tool_use_id":"toolu_bash","parent_task_id":"a1","owned_by_subagent":true,"task_type":"local_bash"}'
  R="rc=$(in_kit "$N")"
}
case_tools() { # the tools a voter session was started with
  N=$((N + 1)); rp_tree "$N"; votes "${MIXED[@]}"; in_kit "$N" >/dev/null
  R="tools=$(awk 'p { if ($0 ~ /^--/) exit; print } $0 == "--tools" { p = 1 }' "$FIX/claude-args-review.txt" | tr '\n' ' ' | sed 's/ $//')"
}
case_tie() { # major against minor
  N=$((N + 1)); rp_tree "$N"; votes "$(answer 1 BLOCKED "[$F_A1]")" "$(answer 1 BLOCKED "[$F_A2_MINOR]")" "$(answer 1 SHIP '[]')"
  in_kit "$N" >/dev/null; R="grade=$(jq -r '.findings[0].grade' "$(rj "$N")")"
}
kit_copy
case_mixed;  want "the unplanted kit: the vote"          "rc=30 kept=a1 swept=1 calls=3 effort=high" "$R"
case_capped; want "the unplanted kit: the cap"           "rc=24" "$R"
case_tools;  want "the unplanted kit: no Agent tool"     "tools=Bash Read Grep Glob Skill" "$R"
case_bash;   want "the unplanted kit: a command is no agent" "rc=30" "$R"
case_tie;    want "the unplanted kit: a tie goes lower"  "grade=minor" "$R"
# plant <label> <file under the kit> <exact text> <replacement> <case> <the result the line prevents>
plant() {
  kit_copy
  python3 -I -c 'import sys; p, l, r = sys.argv[1], sys.argv[2], sys.argv[3]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, r, 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" "$4" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  "$5"; want "planted ($1): the case now fails" "$6" "$R"
}
# 0.7.334's behaviour, one piece at a time: the panel at max, no cap, every tool.
plant "the cap is deleted" driver/steps/review.sh \
  '  for i in $(seq 1 "$n"); do _driver_review_capped "$t" "review-v$i" "voter $i" || return "$DRIVER_E_REFUSED"; done' '' case_capped "rc=30"
plant "commands count as subagents again" driver/steps/review.sh \
  '          | select((.task_type // "local_agent") | test("agent"))' '' case_bash "rc=24"
plant "the effort defaults to max again" driver/steps/review.sh \
  'effort=$(driver_opt review.effort high)' 'effort=$(driver_opt review.effort max)' case_mixed "rc=30 kept=a1 swept=1 calls=3 effort=max"
plant "the voters are deleted (one reviewer)" driver/steps/review.sh \
  'n=${DRIVER_REVIEW_VOTERS:-$(driver_opt review.voters 3)}' 'n=${DRIVER_REVIEW_VOTERS:-$(driver_opt review.voters 1)}' case_mixed "rc=30 kept=a1 swept=1 calls=1 effort=high"
plant "the review step's tool list is deleted" briefs/facts.json \
  '      "tools": ["Bash", "Read", "Grep", "Glob", "Skill"],' '' case_tools "tools=Bash Read Edit Write Grep Glob Skill Agent"
plant "the quorum is deleted" driver/steps/review.sh \
  ' | select(.votes == null or (.votes.agree >= $q and .votes.agree * 2 > .votes.of))' '' case_mixed "rc=30 kept=a1 b1 swept=1 calls=3 effort=high"
plant "a tie no longer goes lower" driver/steps/review.sh \
  'sort_by([-.c, (.v | r)])' 'sort_by([-.c])' case_tie "grade=major"
plant "the review runs the panel filter" driver/steps/review.sh \
  '  _driver_review_panel "$t" "$ans_file" "$round" || return "$DRIVER_E_REFUSED"' '' case_mixed "rc=30 kept=a1 n1 b1 swept=1 calls=3 effort=high"
plant "a pre-existing finding is swept" driver/steps/review.sh \
  '    _driver_review_to_sweep "$t" "$pre" "$round"' '' case_mixed "rc=30 kept=a1 swept=0 calls=3 effort=high"
case_pre_ship() { # a SHIP whose only blocking-grade finding is pre-existing
  N=$((N + 1)); rp_tree "$N"; : > "$SWEEP_QUEUE"; same "$(answer 1 SHIP "[$F_PRE]")"
  R="rc=$(in_kit "$N")"
}
kit_copy; case_pre_ship; want "the unplanted kit: a SHIP beside a pre-existing Major ships" "rc=0" "$R"
plant "the answer reader exempts pre-existing" driver/ai-step.sh \
  ' | select((.tag // "") != "pre-existing")' '' case_pre_ship "rc=22"

suite_end "$FAILED"
