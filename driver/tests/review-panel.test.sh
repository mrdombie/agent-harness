#!/usr/bin/env bash
# review-panel.test.sh — the review is one hunter, then a check on each finding (the owner,
# 2026-11-03; Anthropic's own shape). The hunter is one session running `code-review` at high
# (review.effort) with no Agent tool, and a hunter that starts a subagent of its own fails the
# step. Only when it raised a finding that is not a nit, ONE check session (Read, Grep and Glob
# only, at review.checkEffort, default medium) judges each finding real or not real, and a
# finding judged not real is dropped. A check that answers nothing usable keeps every finding;
# review.check false runs no check. Then, as before: a nit is dropped, a pre-existing defect
# goes to the sweep queue, and no posted finding is raised twice.
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
# The shipped defaults: the fixture's switch-off of the check taken out.
unset DRIVER_REVIEW_CHECK
jq '.release = {mergeFirst: true, done: false}' "$HARNESS_CFG_PATH" > "$FIX/mf-on.json"
jq '.review.check = false' "$FIX/mf-on.json" > "$FIX/nocheck.json"
jq '.review.checkEffort = "low"' "$FIX/mf-on.json" > "$FIX/low.json"
jq '.review.checkEffort = "fast"' "$FIX/mf-on.json" > "$FIX/badeffort.json"
on()  { HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" "$@"; }
off() { HARNESS_CFG="$FIX/nocheck.json" HARNESS_CFG_PATH="$FIX/nocheck.json" "$@"; }
cfg() { local c="$1"; shift; HARNESS_CFG="$c" HARNESS_CFG_PATH="$c" "$@"; }

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
fact() { cat "$(driver_state_dir "$1")/steps/$3.facts/$2" 2>/dev/null; }
# calls — every model call this case made, in order: "review" is the hunter, "review-check" the check.
calls() { tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//'; }
toolsof() { awk 'p { if ($0 ~ /^--/) exit; print } $0 == "--tools" { p = 1 }' "$FIX/claude-args-$1.txt" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
effortof() { awk 'p { print; exit } $0 == "--effort" { p = 1 }' "$FIX/claude-args-$1.txt" 2>/dev/null; }
# answer <round> <verdict> <findings json> — the hunter's whole answer in the shipped contract.
answer() {
  jq -nc --argjson r "$1" --arg v "$2" --argjson f "$3" \
    '{step: "review", skills: ["code-review"], status: "reviewed", round: $r, verdict: $v,
      panel: {skill: "code-review", effort: "high"}, findings: $f}'
}
# transcript <file> <answer> [extra event…] — what the hunter's session leaves, in the shape
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
hunt() { transcript "$FIX/ai/review.jsonl" "$1"; }
# check_says <judgements json> — what the check's session answers: no skill, one result.
check_says() {
  local a; a=$(jq -nc --argjson j "$1" '{step: "review-check", skills: [], judgements: $j}')
  jq -nc --arg r "$a" '{type:"result", subtype:"success", is_error:false, result:$r, structured_output:($r | fromjson)}' > "$FIX/ai/review-check.jsonl"
}
check_silent() { printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"I could not finish"}' > "$FIX/ai/review-check.jsonl"; }
fresh() { : > "$CLAUDE_LOG"; : > "$SWEEP_QUEUE"; rm -f "$FIX"/claude-args-*.txt "$FIX/ai/review-check.jsonl"; }

F_A1='{"id":"a1","file":"a.sh","line":1,"grade":"major","tag":"important","summary":"the save is dropped on retry","reason":"a person sees saved and loses the draft","fix":"keep it"}'
F_B='{"id":"b1","file":"a.sh","line":30,"grade":"major","tag":"important","summary":"the timer may race the retry","reason":"r","fix":"f"}'
F_NIT='{"id":"n1","file":"a.sh","line":9,"grade":"nit","tag":"nit","summary":"the loop could be a for-of","reason":"cleanup","fix":"f"}'
F_PRE='{"id":"p1","file":"lib/old.sh","line":9,"grade":"major","tag":"pre-existing","summary":"the old reader drops a 500 as an empty page","reason":"r","fix":"f"}'
F_MINOR='{"id":"m1","file":"lib/other.sh","line":2,"grade":"minor","tag":"important","summary":"the label is vague","reason":"r","fix":"f"}'
MIXED="$(answer 1 BLOCKED "[$F_A1,$F_NIT,$F_PRE,$F_B]")"
# The check: a1 and p1 are real, b1 is not.
J_MIXED='[{"id":"a1","real":true,"reason":"line 1 drops it"},{"id":"p1","real":true,"reason":"the reader returns []"},{"id":"b1","real":false,"reason":"the timer is cancelled before retry starts"}]'

echo "--- findings: one hunter, then one check that judges each finding ---"
rp_tree 701; fresh
hunt "$MIXED"; check_says "$J_MIXED"
rc=0; out=$(on driver_step_review 701 2>&1) || rc=$?
want "the real Major goes back to fix"                 "30" "$rc"
want "exactly two calls: the hunter, then the check"   "review review-check" "$(calls)"
want "the hunter's effort defaults to high"            "high" "$(fact 701 EFFORT review)"
want "the target is the trunk"                         "develop" "$(fact 701 TARGET review)"
want "the hunter's tools carry no Agent and no Task"   "Bash Read Grep Glob Skill" "$(toolsof review)"
want "the check's tools are Read, Grep and Glob only"  "Read Grep Glob" "$(toolsof review-check)"
want "the check runs at medium by default"             "medium" "$(effortof review-check)"
want "the hunter runs at no session effort of its own" "" "$(effortof review)"
want "the check is handed the hunter's diff"           "$(fact 701 DIFF review)" "$(fact 701 DIFF review-check)"
want_in "it is handed the code around each line"       "     1  a" "$(fact 701 FINDINGS review-check)"
want_in "with the finding's claim"                     "claim: the save is dropped on retry" "$(fact 701 FINDINGS review-check)"
want_not_in "never the hunter's reasoning"             "a person sees saved and loses the draft" "$(fact 701 FINDINGS review-check)"
want_not_in "nor its grade"                            "major" "$(fact 701 FINDINGS review-check)"
want_not_in "a nit is never sent to the check"         "### n1" "$(fact 701 FINDINGS review-check)"
want "kept: only what the check judged real"           "a1" "$(ids 701)"
want_in "one line says what the check did"             "review: hunter found 3, check kept 2 \\(dropped 1\\)" "$out"
want_in "and names what it dropped, and why"           "check dropped b1 a.sh:30 — the timer is cancelled before retry starts" "$out"
want_in "each session's cost is its own line (hunter)" "review-hunter: [$][0-9]" "$out"
want_in "each session's cost is its own line (check)"  "review-check: [$][0-9]" "$out"
want "the panel keeps skill and effort, adds counts"   "code-review high 3/2" "$(jq -r '.panel | "\(.skill) \(.effort) \(.checked)/\(.kept)"' "$(rj 701)")"
want_in "a nit is still dropped and said"              "1 nit" "$out"
want "a real pre-existing one is still swept"          "the old reader drops a 500 as an empty page" "$(sweep_ids)"
want "it names the ticket that found it"               "701" "$(jq -r .ticket "$SWEEP_QUEUE")"
want "it is not a follow-up ticket"                    "" "$(fu 701)"

echo "--- no finding, or nits alone: the check never runs ---"
rp_tree 702; fresh
hunt "$(answer 1 SHIP '[]')"; check_says "$J_MIXED"
rc=0; out=$(on driver_step_review 702 2>&1) || rc=$?
want "a clean review ships"                            "0" "$rc"
want "exactly one call: the hunter"                    "review" "$(calls)"
want_in "and the line says no check ran"               "review: hunter found 0, check kept 0 \\(dropped 0\\) — nothing to check" "$out"
want "the panel says nothing was checked"              "0/0" "$(jq -r '.panel | "\(.checked)/\(.kept)"' "$(rj 702)")"
rp_tree 703; fresh
hunt "$(answer 1 SHIP "[$F_NIT]")"; check_says "$J_MIXED"
rc=0; out=$(on driver_step_review 703 2>&1) || rc=$?
want "a nit alone ships"                               "0" "$rc"
want "and costs no check"                              "review" "$(calls)"

echo "--- a check that answers nothing usable keeps the hunter's findings (fail safe) ---"
rp_tree 704; fresh
hunt "$(answer 1 BLOCKED "[$F_A1,$F_B]")"; check_silent
rc=0; out=$(on driver_step_review 704 2>&1) || rc=$?
want "both Majors still go back to fix"                "30" "$rc"
want "both are kept"                                   "a1 b1" "$(ids 704)"
want_in "and the line says so"                         "check kept 2 \\(dropped 0\\) — the check answered nothing usable" "$out"
want "the silent check leaves no park note behind"     "" "$(driver_state_get 704 park_note)"
rp_tree 705; fresh
hunt "$(answer 1 BLOCKED "[$F_A1,$F_B]")"; check_says '[{"id":"a1","real":"no","reason":"r"},{"id":"b1","real":"no","reason":"r"}]'
rc=0; out=$(on driver_step_review 705 2>&1) || rc=$?
want "an answer outside the contract keeps them too"   "30 a1 b1" "$rc $(ids 705)"
rp_tree 706; fresh
hunt "$(answer 1 BLOCKED "[$F_A1,$F_B]")"
rc=0; out=$(on driver_step_review 706 2>&1) || rc=$?
want "a check that never ran at all keeps them too"    "30 a1 b1" "$rc $(ids 706)"
rp_tree 707; fresh
hunt "$(answer 1 BLOCKED "[$F_A1,$F_B]")"; check_says '[{"id":"zz","real":false,"reason":"not on the list"}]'
rc=0; out=$(on driver_step_review 707 2>&1) || rc=$?
want "a judgement on no listed finding is no answer"   "30 a1 b1" "$rc $(ids 707)"
rp_tree 708; fresh
hunt "$(answer 1 BLOCKED "[$F_A1,$F_B]")"; check_says '[{"id":"b1","real":false,"reason":"cancelled first"}]'
rc=0; out=$(on driver_step_review 708 2>&1) || rc=$?
want "a finding the check did not judge is kept"       "30 a1" "$rc $(ids 708)"
want_in "and that is said"                             "1 the check did not judge are kept" "$out"

echo "--- review.check false: the hunter's findings count as they are ---"
rp_tree 709; fresh
hunt "$(answer 1 BLOCKED "[$F_A1,$F_B]")"; check_says "$J_MIXED"
rc=0; out=$(off driver_step_review 709 2>&1) || rc=$?
want "no check call"                                   "review" "$(calls)"
want "both findings count"                             "30 a1 b1" "$rc $(ids 709)"
want_in "and the line says the check is off"           "review.check is off" "$out"

echo "--- review.checkEffort sets the check's effort, and a word that is not one is said ---"
rp_tree 715; fresh
hunt "$(answer 1 BLOCKED "[$F_A1,$F_B]")"; check_says "$J_MIXED"
cfg "$FIX/low.json" driver_step_review 715 >/dev/null 2>&1
want "review.checkEffort low runs the check at low"    "low" "$(effortof review-check)"
rp_tree 716; fresh
hunt "$(answer 1 BLOCKED "[$F_A1,$F_B]")"; check_says "$J_MIXED"
out=$(cfg "$FIX/badeffort.json" driver_step_review 716 2>&1)
want "a word that is not an effort runs at medium"     "medium" "$(effortof review-check)"
want_in "and is said"                                  "review.checkEffort is 'fast'" "$out"

echo "--- the cap: a hunter that starts a subagent of its own fails the step, loudly ---"
AGENT='{"type":"assistant","parent_tool_use_id":"toolu_skill","message":{"content":[{"type":"tool_use","id":"toolu_finder","name":"Agent","input":{"description":"Finder 1","prompt":"hunt"}}]}}'
rp_tree 720; fresh
transcript "$FIX/ai/review.jsonl" "$MIXED" "$AGENT"; check_says "$J_MIXED"
rc=0; out=$(on driver_step_review 720 2>&1) || rc=$?
want "an Agent call inside the skill fails the step"   "24" "$rc"
want_in "and says who, and why"                        "the hunter started 1 subagent" "$out"
want_in "the park names the cap"                       "past the cap of none" "$(driver_state_get 720 park_note)"
want "and no check is paid for"                        "review" "$(calls)"
rp_tree 721; fresh
transcript "$FIX/ai/review.jsonl" "$MIXED" '{"type":"system","subtype":"task_started","task_id":"b2","tool_use_id":"toolu_other","spawn_depth":2}'; check_says "$J_MIXED"
rc=0; on driver_step_review 721 >/dev/null 2>&1 || rc=$?
want "a task no Skill call opened fails it too"        "24" "$rc"
rp_tree 722; fresh
transcript "$FIX/ai/review.jsonl" "$MIXED" '{"type":"system","subtype":"task_started","task_id":"bu1","tool_use_id":"toolu_bash","parent_task_id":"a1","owned_by_subagent":true,"task_type":"local_bash","description":"Run loop tests"}'; check_says "$J_MIXED"
rc=0; on driver_step_review 722 >/dev/null 2>&1 || rc=$?
want "a command the review runs is not a subagent"     "30" "$rc"

echo "--- no posted finding is raised twice ---"
rp_tree 710; fresh
hunt "$(answer 1 BLOCKED "[$F_A1]")"
off driver_step_review 710 >/dev/null 2>&1
want "the posted ledger holds it"                      "a.sh|the save is dropped on retry" "$(jq -r .key "$(driver_state_dir 710)/steps/review.posted.jsonl")"
printf 'z\n' > "$FIX/rp710/z.sh"; git -C "$FIX/rp710" add -A; git -C "$FIX/rp710" commit -qm "fix: z"; driver_state_bump 710 fix
again='{"id":"g1","file":"./a.sh","line":7,"grade":"major","tag":"important","summary":"The save is dropped on RETRY.","reason":"r","fix":"f"}'
fresh_one='{"id":"g2","file":"z.sh","line":1,"grade":"major","tag":"important","summary":"the new helper swallows the error","reason":"r","fix":"f"}'
hunt "$(answer 2 BLOCKED "[$again,$fresh_one]")"
rc=0; out=$(off driver_step_review 710 2>&1) || rc=$?
want "round 2 still blocks on the fresh one"           "30" "$rc"
want "the repeat is gone"                              "g2" "$(ids 710)"
want_in "and said"                                     "1 finding.s. already raised on this change" "$out"
want_in "round 2 is told what was already raised"      "the save is dropped on retry" "$(fact 710 DIFF review)"

echo "--- a re-raise with no fix round since is the finding still standing, not a repeat ---"
rp_tree 711; fresh
hunt "$(answer 1 BLOCKED "[$F_A1]")"
off driver_step_review 711 >/dev/null 2>&1
hunt "$(answer 2 BLOCKED "[$F_A1]")"
rc=0; off driver_step_review 711 >/dev/null 2>&1 || rc=$?
want "it still blocks"                                 "30" "$rc"
want "and is still on the answer"                      "a1" "$(ids 711)"

echo "--- a class already raised does not block again ---"
rp_tree 712; fresh
cls='{"id":"c1","file":"a.sh","line":1,"grade":"major","tag":"important","class":"a failed read shown as empty","instances":["a.sh:1","b.sh:4"],"summary":"the queue shows empty on a failed read","reason":"r","fix":"f"}'
hunt "$(answer 1 BLOCKED "[$cls]")"
off driver_step_review 712 >/dev/null 2>&1
printf 'z\n' > "$FIX/rp712/z.sh"; git -C "$FIX/rp712" add -A; git -C "$FIX/rp712" commit -qm "fix: z"; driver_state_bump 712 fix
cls2='{"id":"c2","file":"z.sh","line":3,"grade":"major","tag":"important","class":"A failed read shown as empty","summary":"the rail shows empty on a failed read","reason":"r","fix":"f"}'
hunt "$(answer 2 BLOCKED "[$cls2]")"
rc=0; off driver_step_review 712 >/dev/null 2>&1 || rc=$?
want "the class already raised does not block again"   "0" "$rc"

echo "--- grade effects stand: under merge first a kept Minor elsewhere goes to the sweep, never a ticket ---"
rp_tree 713; fresh
hunt "$(answer 1 BLOCKED "[$F_MINOR]")"; check_says '[{"id":"m1","real":true,"reason":"the label says Go"}]'
rc=0; out=$(on driver_step_review 713 2>&1) || rc=$?
want "a Minor in a file the change did not touch ships" "0" "$rc"
want "it was checked"                                  "review review-check" "$(calls)"
want "and is filed nowhere"                            "" "$(fu 713)"
want "it is sent to the sweep"                         "m1=sweep" "$(jq -r '"\(.id)=\(.list)"' "$(driver_state_dir 713)/steps/review.deferred.jsonl")"

echo "--- an answer with no panel (an older reviewer) is graded exactly as before ---"
rp_tree 714; fresh
fix_ai review '{"step":"review","skills":["code-review"],"status":"reviewed","round":1,"verdict":"BLOCKED","findings":[{"id":"o1","file":"a.sh","line":1,"grade":"major","summary":"s","reason":"r","fix":"f"}]}' code-review
rc=0; off driver_step_review 714 >/dev/null 2>&1 || rc=$?
want "its Major goes to fix"                           "30" "$rc"

echo "--- plants: each guard out of a copy of the kit, its case fails ---"
KIT="$FIX/kit"; N=750
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$KIT/"; }
in_kit() { # <ticket> — the review step run from the copy of the kit, at the shipped defaults
  local rc=0
  HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" DRIVER_BRIEFS="$KIT/briefs" DRIVER_SCHEMAS="$KIT/briefs/schemas" DRIVER_VALIDATE="$KIT/briefs/validate.sh" \
    bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/review.sh" && driver_step_review "$2"' _ "$KIT" "$1" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
case_check() { # the hunter's mixed findings, the check drops b1: exit, kept, swept, calls, tools, effort
  N=$((N + 1)); rp_tree "$N"; fresh; hunt "$MIXED"; check_says "$J_MIXED"
  local rc; rc=$(in_kit "$N")
  R="rc=$rc kept=$(ids "$N") swept=$(grep -c . "$SWEEP_QUEUE") calls=$(calls | tr ' ' ,) check-tools=$(toolsof review-check | tr ' ' ,) effort=$(fact "$N" EFFORT review)"
}
case_blind() { # what the check is handed: the claim, never the hunter's reasoning
  N=$((N + 1)); rp_tree "$N"; fresh; hunt "$MIXED"; check_says "$J_MIXED"; in_kit "$N" >/dev/null
  R="reasoning=$(fact "$N" FINDINGS review-check | grep -c 'a person sees saved and loses the draft')"
}
case_none() { # the hunter finds nothing: whether the check step was so much as started
  N=$((N + 1)); rp_tree "$N"; fresh; hunt "$(answer 1 SHIP '[]')"; check_says "$J_MIXED"
  local rc; rc=$(in_kit "$N")
  R="rc=$rc check-started=$([ -d "$(driver_state_dir "$N")/steps/review-check.facts" ] && echo yes || echo no)"
}
case_silent() { # the check answers nothing usable
  N=$((N + 1)); rp_tree "$N"; fresh; hunt "$(answer 1 BLOCKED "[$F_A1,$F_B]")"; check_silent
  local rc; rc=$(in_kit "$N")
  R="rc=$rc kept=$(ids "$N")"
}
case_capped() { # the hunter starts a finder agent inside the skill
  N=$((N + 1)); rp_tree "$N"; fresh; transcript "$FIX/ai/review.jsonl" "$MIXED" "$AGENT"; check_says "$J_MIXED"
  R="rc=$(in_kit "$N")"
}
case_bash() { # the hunter's review runs a test command, a local_bash task inside its fork
  N=$((N + 1)); rp_tree "$N"; fresh; check_says "$J_MIXED"
  transcript "$FIX/ai/review.jsonl" "$MIXED" '{"type":"system","subtype":"task_started","task_id":"bu1","tool_use_id":"toolu_bash","parent_task_id":"a1","owned_by_subagent":true,"task_type":"local_bash"}'
  R="rc=$(in_kit "$N")"
}
case_tools() { # the tools the hunter session was started with
  N=$((N + 1)); rp_tree "$N"; fresh; hunt "$MIXED"; check_says "$J_MIXED"; in_kit "$N" >/dev/null
  R="tools=$(toolsof review)"
}
case_pre_ship() { # a SHIP whose only blocking-grade finding is pre-existing
  N=$((N + 1)); rp_tree "$N"; fresh; hunt "$(answer 1 SHIP "[$F_PRE]")"; check_says '[{"id":"p1","real":true,"reason":"r"}]'
  R="rc=$(in_kit "$N")"
}
kit_copy
GOOD="rc=30 kept=a1 swept=1 calls=review,review-check check-tools=Read,Grep,Glob effort=high"
case_check;    want "the unplanted kit: hunter then check"      "$GOOD" "$R"
case_none;     want "the unplanted kit: no findings, no check"  "rc=0 check-started=no" "$R"
case_blind;    want "the unplanted kit: the check is blind to the reasoning" "reasoning=0" "$R"
case_silent;   want "the unplanted kit: a silent check keeps"   "rc=30 kept=a1 b1" "$R"
case_capped;   want "the unplanted kit: the cap"                "rc=24" "$R"
case_tools;    want "the unplanted kit: no Agent tool"          "tools=Bash Read Grep Glob Skill" "$R"
case_bash;     want "the unplanted kit: a command is no agent"  "rc=30" "$R"
case_pre_ship; want "the unplanted kit: a SHIP beside a pre-existing Major ships" "rc=0" "$R"
# plant <label> <file under the kit> <exact text> <replacement> <case> <the result the line prevents>
plant() {
  kit_copy
  python3 -I -c 'import sys; p, l, r = sys.argv[1], sys.argv[2], sys.argv[3]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, r, 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" "$4" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  "$5"; want "planted ($1): the case now fails" "$6" "$R"
}
# The check, one piece at a time.
plant "the check call is deleted" driver/steps/review.sh \
  'rc=0; DRIVER_STEP_EFFORT="$ceffort" driver_ai_step "$t" review-check || rc=$?' 'rc=1' \
  case_check "rc=30 kept=a1 b1 swept=1 calls=review check-tools= effort=high"
plant "the checker is given Bash" briefs/facts.json \
  '"tools": ["Read", "Grep", "Glob"],' '"tools": ["Bash", "Read", "Grep", "Glob"],' \
  case_check "rc=30 kept=a1 swept=1 calls=review,review-check check-tools=Bash,Read,Grep,Glob effort=high"
plant "a finding judged not real is kept" driver/steps/review.sh \
  'select(type == "object" and .real == false)' 'select(type == "object" and .real == null)' \
  case_check "rc=30 kept=a1 b1 swept=1 calls=review,review-check check-tools=Read,Grep,Glob effort=high"
plant "the check runs with zero findings" driver/steps/review.sh \
  '  if [ "$n" -eq 0 ]; then' '  if false; then' case_none "rc=0 check-started=yes"
plant "the hunter's reasoning is handed to the check" driver/steps/review.sh \
  '\n- claim: \(.summary // "")"' '\n- claim: \(.summary // "")\n- reason: \(.reason // "")"' case_blind "reasoning=1"
plant "a silent check is read as an answer" driver/steps/review.sh \
  'if [ "${usable:-0}" -gt 0 ] 2>/dev/null; then' 'if true; then' case_silent "rc=24 kept=a1 b1"
# The hunter's bounds, carried over from the vote it replaced.
plant "the cap is deleted" driver/steps/review.sh \
  '  _driver_review_capped "$t" review-hunter "the hunter" || return "$DRIVER_E_REFUSED"' '' case_capped "rc=30"
plant "commands count as subagents again" driver/ai-step.sh \
  '          | select((.task_type // "local_agent") | test("agent"))' '' case_bash "rc=24"
plant "the effort defaults to max again" driver/steps/review.sh \
  'effort=$(driver_opt review.effort high)' 'effort=$(driver_opt review.effort max)' \
  case_check "rc=30 kept=a1 swept=1 calls=review,review-check check-tools=Read,Grep,Glob effort=max"
plant "the review step's tool list is deleted" briefs/facts.json \
  '      "tools": ["Bash", "Read", "Grep", "Glob", "Skill"],' '' case_tools "tools=Bash Read Edit Write Grep Glob Skill Agent"
# What the step does after the check stands as it was.
plant "the review runs the panel filter" driver/steps/review.sh \
  '  _driver_review_panel "$t" "$ans_file" "$round" || return "$DRIVER_E_REFUSED"' '' \
  case_check "rc=30 kept=a1 n1 b1 swept=1 calls=review check-tools= effort=high"
plant "a pre-existing finding is swept" driver/steps/review.sh \
  '    _driver_review_to_sweep "$t" "$pre" "$round"' '' \
  case_check "rc=30 kept=a1 swept=0 calls=review,review-check check-tools=Read,Grep,Glob effort=high"
plant "the answer reader exempts pre-existing" driver/ai-step.sh \
  ' | select((.tag // "") != "pre-existing")' '' case_pre_ship "rc=22"

suite_end "$FAILED"
