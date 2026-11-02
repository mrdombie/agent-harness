#!/usr/bin/env bash
# review-panel.test.sh — the review runs Claude Code's own `code-review`: finders in
# parallel, a verifier vote on each candidate. Only findings a majority agreed on are
# kept; a nit (style, cleanup) is dropped; a pre-existing defect never goes back to the
# builder or onto a ticket, it goes to the sweep queue; and no posted finding is raised
# twice. The grade effects and the round cap stay as they were.
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
jq '.release = {mergeFirst: true, done: false}' "$HARNESS_CFG_PATH" > "$FIX/mf-on.json"
on() { HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" "$@"; }

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
# answer <round> <verdict> <findings json> — a whole answer in the shipped contract.
answer() {
  jq -nc --argjson r "$1" --arg v "$2" --argjson f "$3" \
    '{step: "review", skills: ["code-review"], status: "reviewed", round: $r, verdict: $v,
      panel: {skill: "code-review", effort: "max", hunters: 10, verifiers: ($f | length)}, findings: $f}'
}
# panel_ai <answer> [words json] — the transcript code-review leaves: the Skill call, one
# verifier agent per candidate (its prompt names the candidate, its result opens on the
# verdict, the shapes measured on 2026-11-02), then the answer. The verifier's word for each
# finding is `words[id]` when given, else the finding's own `verified`; "none" starts none.
panel_ai() {
  local a="$1" w="${2:-}" f="$FIX/ai/review.jsonl" i=0 x id word
  [ -n "$w" ] || w='{}'
  : > "$f"
  jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"Skill", input:{skill:"code-review", args:"max develop"}}]}}' >> "$f"
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    i=$((i + 1)); id="toolu_verify_$i"
    word=$(jq -rn --argjson x "$x" --argjson w "$w" '$w[$x.id] // $x.verified // "none"')
    case "$word" in none|unverified) continue ;; esac
    jq -nc --arg id "$id" --argjson x "$x" '{type:"assistant", message:{content:[{type:"tool_use", id:$id, name:"Agent",
        input:{description:"Verify: \($x.summary)", prompt:"You are a verifier in a code review.\n\nCANDIDATE\nfile: \($x.file), line \($x.line)\nsummary: \($x.summary)\nfailure_scenario: f\n"}}]}}' >> "$f"
    # Odd ones come back as the tool result, even ones as the background task's notification.
    if [ $((i % 2)) -eq 1 ]; then
      jq -nc --arg id "$id" --arg w "$(printf '%s' "$word" | tr '[:lower:]' '[:upper:]')" '{type:"user", message:{content:[{type:"tool_result", tool_use_id:$id, content:[{type:"text", text:("{\"verdict\": \"" + $w + "\", \"evidence\": \"ran it\"}")}]}]}}' >> "$f"
    else
      jq -nc --arg id "$id" --arg w "$(printf '%s' "$word" | tr '[:lower:]' '[:upper:]')" '{type:"system", subtype:"task_notification", tool_use_id:$id, status:"completed", summary:($w + "\nran it")}' >> "$f"
    fi
  done < <(printf '%s' "$a" | jq -c '.findings[]?')
  jq -nc --arg r "$a" '{type:"result", subtype:"success", is_error:false, result:$r, structured_output:($r | fromjson)}' >> "$f"
}
F_AGREED='{"id":"f1","file":"a.sh","line":1,"grade":"major","tag":"important","verified":"confirmed","summary":"the save is dropped on retry","reason":"a person sees saved and loses the draft","fix":"keep it"}'
F_PLAUS='{"id":"f2","file":"a.sh","line":2,"grade":"major","tag":"important","verified":"plausible","summary":"the retry may race the timer","reason":"r","fix":"f"}'
F_SWEPT='{"id":"f3","file":"a.sh","line":3,"grade":"major","tag":"important","verified":"unverified","summary":"a gap sweep thought of this","reason":"r","fix":"f"}'
F_NIT='{"id":"f4","file":"a.sh","line":4,"grade":"nit","tag":"nit","verified":"confirmed","summary":"the loop could be a for-of","reason":"cleanup","fix":"f"}'
F_PRE='{"id":"f5","file":"lib/old.sh","line":9,"grade":"major","tag":"pre-existing","verified":"confirmed","summary":"the old reader drops a 500 as an empty page","reason":"r","fix":"f"}'
F_MINOR='{"id":"f6","file":"lib/other.sh","line":2,"grade":"minor","tag":"important","verified":"confirmed","summary":"the label is vague","reason":"r","fix":"f"}'
ALL="[$F_AGREED,$F_PLAUS,$F_SWEPT,$F_NIT,$F_PRE]"

echo "--- the review runs code-review, at the configured effort, against the trunk ---"
rp_tree 701
panel_ai "$(answer 1 BLOCKED "$ALL")"
rc=0; out=$(on driver_step_review 701 2>&1) || rc=$?
want "the agreed Major goes back to fix"           "30" "$rc"
want "the effort defaults to max"                  "max" "$(fact 701 EFFORT)"
want "the target is the trunk"                     "develop" "$(fact 701 TARGET)"

echo "--- only what a majority of the panel agreed on is kept ---"
want "kept: the agreed one alone"                  "f1" "$(ids 701)"
want_in "the unagreed are said, not dropped silently" "2 finding.s. the panel did not agree on" "$out"
want_in "a nit is dropped and said"                "1 nit" "$out"

echo "--- a pre-existing defect goes to the sweep queue, never to fix or a ticket ---"
want "it is in the sweep queue"                    "the old reader drops a 500 as an empty page" "$(sweep_ids)"
want "it names the ticket that found it"           "701" "$(jq -r .ticket "$SWEEP_QUEUE")"
want "it is not a follow-up ticket"                "" "$(fu 701)"
want_in "and the run says where it went"           "1 pre-existing finding.s. to the nightly sweep" "$out"

echo "--- a review whose only blocking finding is pre-existing ships ---"
rp_tree 702
panel_ai "$(answer 1 SHIP "[$F_PRE]")"
rc=0; on driver_step_review 702 >/dev/null 2>&1 || rc=$?
want "it ships"                                    "0" "$rc"
want "the verdict is SHIP"                         "SHIP" "$(jq -r .verdict "$(rj 702)")"
want "the sweep queue holds it once"               "1" "$(grep -c . "$SWEEP_QUEUE")"

echo "--- no posted finding is raised twice ---"
rp_tree 703
panel_ai "$(answer 1 BLOCKED "[$F_AGREED]")"
on driver_step_review 703 >/dev/null 2>&1
want "the posted ledger holds it"                  "a.sh|the save is dropped on retry" "$(jq -r .key "$(driver_state_dir 703)/steps/review.posted.jsonl")"
printf 'z\n' > "$FIX/rp703/z.sh"; git -C "$FIX/rp703" add -A; git -C "$FIX/rp703" commit -qm "fix: z"; driver_state_bump 703 fix
again='{"id":"g1","file":"./a.sh","line":7,"grade":"major","tag":"important","verified":"confirmed","summary":"The save is dropped on RETRY.","reason":"r","fix":"f"}'
fresh='{"id":"g2","file":"z.sh","line":1,"grade":"major","tag":"important","verified":"confirmed","summary":"the new helper swallows the error","reason":"r","fix":"f"}'
panel_ai "$(answer 2 BLOCKED "[$again,$fresh]")"
rc=0; out=$(on driver_step_review 703 2>&1) || rc=$?
want "round 2 still blocks on the fresh one"       "30" "$rc"
want "the repeat is gone"                          "g2" "$(ids 703)"
want_in "and said"                                 "1 finding.s. already raised on this change" "$out"
want_in "round 2 is told what was already raised"  "the save is dropped on retry" "$(fact 703 DIFF)"

echo "--- a re-raise with no fix round since is the finding still standing, not a repeat ---"
rp_tree 710
panel_ai "$(answer 1 BLOCKED "[$F_AGREED]")"
on driver_step_review 710 >/dev/null 2>&1
panel_ai "$(answer 2 BLOCKED "[$F_AGREED]")"
rc=0; on driver_step_review 710 >/dev/null 2>&1 || rc=$?
want "it still blocks"                             "30" "$rc"
want "and is still on the answer"                  "f1" "$(ids 710)"

echo "--- a class is one finding; a later instance of the same class is not raised again ---"
rp_tree 704
cls='{"id":"c1","file":"a.sh","line":1,"grade":"major","tag":"important","verified":"confirmed","class":"a failed read shown as empty","instances":["a.sh:1","b.sh:4"],"summary":"the queue shows empty on a failed read","reason":"r","fix":"f"}'
panel_ai "$(answer 1 BLOCKED "[$cls]")"
on driver_step_review 704 >/dev/null 2>&1
printf 'z\n' > "$FIX/rp704/z.sh"; git -C "$FIX/rp704" add -A; git -C "$FIX/rp704" commit -qm "fix: z"; driver_state_bump 704 fix
cls2='{"id":"c2","file":"z.sh","line":3,"grade":"major","tag":"important","verified":"confirmed","class":"A failed read shown as empty","summary":"the rail shows empty on a failed read","reason":"r","fix":"f"}'
panel_ai "$(answer 2 BLOCKED "[$cls2]")"
rc=0; on driver_step_review 704 >/dev/null 2>&1 || rc=$?
want "the class already raised does not block again" "0" "$rc"

echo "--- grade effects stand: under merge first a kept Major elsewhere is a follow-up, a Minor too ---"
rp_tree 705
panel_ai "$(answer 1 BLOCKED "[$F_MINOR]")"
rc=0; on driver_step_review 705 >/dev/null 2>&1 || rc=$?
want "a Minor in a file the change did not touch ships" "0" "$rc"
want "and is filed as before"                      "f6" "$(fu 705)"

echo "--- the quorum is a setting: review.quorum 1 keeps a single vote ---"
rp_tree 706
jq '.review.quorum = 1' "$FIX/mf-on.json" > "$FIX/q1.json"
panel_ai "$(answer 1 BLOCKED "[$F_SWEPT]")"
rc=0; HARNESS_CFG="$FIX/q1.json" HARNESS_CFG_PATH="$FIX/q1.json" driver_step_review 706 >/dev/null 2>&1 || rc=$?
want "one agreeing vote of one is kept"            "30" "$rc"
want "it is the finding"                           "f3" "$(ids 706)"
panel_ai "$(answer 1 BLOCKED "[$F_PLAUS]")"
rp_tree 707
rc=0; HARNESS_CFG="$FIX/q1.json" HARNESS_CFG_PATH="$FIX/q1.json" driver_step_review 707 >/dev/null 2>&1 || rc=$?
want "but one of two is still no majority"         "0" "$rc"

echo "--- the tally comes from the verifier's own word, never the model's arithmetic ---"
# Measured 2026-11-02, the shipped brief end to end: the verifiers said CONFIRMED and the
# model wrote 1 of 1 on every finding, which the quorum would have dropped, a crash with it.
rp_tree 709
V_CONF='{"id":"v1","file":"a.sh","line":1,"grade":"critical","tag":"important","verified":"confirmed","votes":{"agree":1,"of":1},"summary":"the loop reads past the end","reason":"every call throws","fix":"use <"}'
V_PLAUS='{"id":"v2","file":"a.sh","line":2,"grade":"major","tag":"important","verified":"plausible","votes":{"agree":2,"of":2},"summary":"a missing qty is NaN","reason":"r","fix":"f"}'
V_NONE='{"id":"v3","file":"a.sh","line":3,"grade":"major","tag":"important","verified":"unverified","summary":"a sweep idea","reason":"r","fix":"f"}'
panel_ai "$(answer 1 BLOCKED "[$V_CONF,$V_PLAUS,$V_NONE]")"
rc=0; on driver_step_review 709 >/dev/null 2>&1 || rc=$?
want "a confirmed finding blocks whatever tally was typed" "30" "$rc"
want "only the confirmed one is kept"                      "v1" "$(ids 709)"
want "its tally is the panel's: finder and verifier"       "2/2" "$(jq -r '.findings[0].votes | "\(.agree)/\(.of)"' "$(rj 709)")"

echo "--- the verifier's word is read off the transcript, never taken from the model ---"
# Measured 2026-11-02, the shipped brief end to end, second run: six verifiers said
# CONFIRMED and the model marked every finding unverified.
rp_tree 711
M_LOST='{"id":"m1","file":"a.sh","line":3,"grade":"critical","tag":"important","verified":"unverified","summary":"the loop bound reads past the end of the list","reason":"every call throws","fix":"use <"}'
M_BOAST='{"id":"m2","file":"a.sh","line":9,"grade":"major","tag":"important","verified":"confirmed","summary":"the cache is never cleared","reason":"r","fix":"f"}'
M_ALONE='{"id":"m3","file":"lib/x.sh","line":4,"grade":"major","tag":"important","verified":"confirmed","summary":"no verifier ever saw this one","reason":"r","fix":"f"}'
panel_ai "$(answer 1 BLOCKED "[$M_LOST,$M_BOAST,$M_ALONE]")" '{"m1":"confirmed","m2":"refuted","m3":"none"}'
rc=0; out=$(on driver_step_review 711 2>&1) || rc=$?
want "the confirmed one the model called unverified blocks" "30" "$rc"
want "it alone is kept"                                     "m1" "$(ids 711)"
want "its word is the verifier's"                           "confirmed" "$(jq -r '.findings[0].verified' "$(rj 711)")"
want_in "the reading is said"                               "1 confirmed, 0 plausible, 1 refuted by their verifiers; 1 no verifier judged" "$out"

echo "--- a verifier is matched on file and wording, not on the line alone ---"
rp_tree 712
T1='{"id":"t1","file":"./a.sh","line":3,"grade":"critical","tag":"important","verified":"plausible","summary":"the loop bound reads past the end","reason":"r","fix":"f"}'
T2='{"id":"t2","file":"a.sh","line":3,"grade":"major","tag":"important","verified":"plausible","summary":"a missing qty turns the sum into NaN","reason":"r","fix":"f"}'
panel_ai "$(answer 1 BLOCKED "[$T1,$T2]")" '{"t1":"confirmed","t2":"plausible"}'
on driver_step_review 712 >/dev/null 2>&1
want "two findings on one line each get their own verifier" "t1" "$(ids 712)"

echo "--- the finding names its verifier, and that agent's verdict is the one read ---"
# Measured 2026-11-02: two verifiers on one line, summaries the model reworded; wording
# alone scored them 11 and 10 shared words, so the join is the verifier the finding names.
rp_tree 713
N1='{"id":"n1","file":"calc.js","line":12,"grade":"critical","tag":"important","verified":"plausible","verifier":"Verify: avg empty list NaN","summary":"avg divides by the length with no guard, so an empty list gives NaN","reason":"r","fix":"f"}'
N2='{"id":"n2","file":"calc.js","line":12,"grade":"major","tag":"important","verified":"confirmed","verifier":"Verify: avg denominator mismatch","summary":"avg divides by the number of lines, not the units","reason":"r","fix":"f"}'
N3='{"id":"n3","file":"calc.js","line":3,"grade":"critical","tag":"important","verified":"unverified","summary":"the loop bound reads one past the end of the list and throws","reason":"r","fix":"f"}'
f="$FIX/ai/review.jsonl"; : > "$f"
jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"Skill", input:{skill:"code-review", args:"max develop"}}]}}' >> "$f"
ag() { jq -nc --arg id "$1" --arg d "$2" --arg p "$3" '{type:"assistant", message:{content:[{type:"tool_use", id:$id, name:"Agent", input:{description:$d, prompt:$p}}]}}' >> "$f"; }
ag v1 "Verify: avg empty list NaN" $'Judge ONE candidate. Return {"verdict":"CONFIRMED|PLAUSIBLE|REFUTED"}.\nCANDIDATE\nfile: calc.js, line 12\nsummary: avg has no guard for an empty list'
ag v2 "Verify: avg denominator mismatch" $'CANDIDATE\nfile: calc.js, line 12\nsummary: avg divides by lines, not units, with no guard on what it averages'
# The other shape a verifier prompt took (run 1): the place inside the CANDIDATE line.
ag v3 "Verify C1 loop bound crash" $'CANDIDATE (calc.js line 3, claimed new in this diff):\nSummary: the loop bound reads one past the end of the list and throws on every call'
jq -nc '{type:"system", subtype:"task_notification", tool_use_id:"v1", status:"completed", summary:"CONFIRMED\nran avg([])"}' >> "$f"
jq -nc '{type:"user", message:{content:[{type:"tool_result", tool_use_id:"v2", content:[{type:"text", text:"{\"verdict\": \"PLAUSIBLE\", \"quote\": \"CONFIRMED|PLAUSIBLE|REFUTED is the scale\"}"}]}]}}' >> "$f"
jq -nc '{type:"user", message:{content:[{type:"tool_result", tool_use_id:"v3", content:[{type:"text", text:"{\"verdict\":\"CONFIRMED\",\"evidence\":\"threw\"}"}]}]}}' >> "$f"
a=$(answer 1 BLOCKED "[$N1,$N2,$N3]")
jq -nc --arg r "$a" '{type:"result", subtype:"success", is_error:false, result:$r, structured_output:($r | fromjson)}' >> "$f"
rc=0; out=$(on driver_step_review 713 2>&1) || rc=$?
want_in "each finding takes its named verifier's verdict" "2 confirmed, 1 plausible, 0 refuted by their verifiers; 0 no verifier judged" "$out"
want "the confirmed two are kept"                      "n1 n3" "$(ids 713)"

echo "--- an answer with no panel (an older reviewer) is graded exactly as before ---"
rp_tree 708
fix_ai review '{"step":"review","skills":["code-review"],"status":"reviewed","round":1,"verdict":"BLOCKED","findings":[{"id":"o1","file":"a.sh","line":1,"grade":"major","summary":"s","reason":"r","fix":"f"}]}' code-review
rc=0; on driver_step_review 708 >/dev/null 2>&1 || rc=$?
want "its Major goes to fix"                       "30" "$rc"

echo "--- plants: each line out of a copy of the kit, its case fails ---"
KIT="$FIX/kit"; N=750
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$KIT/"; }
case_all() { # the mixed answer: the step's exit, what it kept, and what the sweep got
  N=$((N + 1)); rp_tree "$N"; : > "$SWEEP_QUEUE"; panel_ai "$(answer 1 BLOCKED "$ALL")"
  local rc=0; HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/review.sh" && driver_step_review "$2"' _ "$KIT" "$N" >/dev/null 2>&1 || rc=$?
  R="rc=$rc kept=$(ids "$N") swept=$(grep -c . "$SWEEP_QUEUE") filed=$(fu "$N")"
}
kit_copy
case_all; want "the unplanted kit" "rc=30 kept=f1 swept=1 filed=" "$R"
plant() { # <label> <file under the kit> <exact text to delete> <the result the line prevents>
  kit_copy
  python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  case_all; want "planted ($1): the case now fails" "$4" "$R"
}
plant "the review runs the panel filter" driver/steps/review.sh \
  '  _driver_review_panel "$t" "$ans_file" "$round" || return "$DRIVER_E_REFUSED"' "rc=30 kept=f1 f2 f3 f4 swept=0 filed=f5"
plant "the quorum drops the unagreed" driver/steps/review.sh \
  ' | select(.votes == null or (.votes.agree >= $q and .votes.agree * 2 > .votes.of))' "rc=30 kept=f1 f2 f3 swept=1 filed="
plant "the tally is derived from the verifier's word" driver/steps/review.sh \
  "  jq '.findings = [(.findings // [])[] | if .verified then .votes = ({confirmed: {agree: 2, of: 2}, plausible: {agree: 1, of: 2}, unverified: {agree: 1, of: 1}, refuted: {agree: 0, of: 2}}[.verified]) else . end]' \"\$f\" > \"\$f.t\" && mv \"\$f.t\" \"\$f\" || return 1" \
  "rc=30 kept=f1 f2 f3 swept=1 filed="
plant "a pre-existing finding is swept" driver/steps/review.sh \
  '    printf '"'"'%s'"'"' "$pre" | bash "$sq" add "$t" "$round" >/dev/null 2>&1 || driver_say "⚠ review: the sweep queue could not take $npre pre-existing finding(s) — they are dropped from this change all the same"' "rc=30 kept=f1 swept=0 filed="
case_lost() { # the model wrote unverified over a CONFIRMED verdict
  N=$((N + 1)); rp_tree "$N"; panel_ai "$(answer 1 BLOCKED "[$M_LOST]")" '{"m1":"confirmed"}'
  local rc=0; HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/review.sh" && driver_step_review "$2"' _ "$KIT" "$N" >/dev/null 2>&1 || rc=$?
  R="rc=$rc kept=$(ids "$N")"
}
kit_copy; case_lost; want "the unplanted kit: the verifier's CONFIRMED stands" "rc=30 kept=m1" "$R"
kit_copy
python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' \
  "$KIT/driver/steps/review.sh" '  _driver_review_verifier_words "$t" "$f" || return 1' && {
  case_lost; want "planted (the verdicts are read off the transcript): the case now fails" "rc=0 kept=" "$R"
} || want "plant landed: the verdicts are read off the transcript" "landed" "missed"
case_pre_ship() { # a SHIP whose only blocking-grade finding is pre-existing
  N=$((N + 1)); rp_tree "$N"; : > "$SWEEP_QUEUE"; panel_ai "$(answer 1 SHIP "[$F_PRE]")"
  local rc=0; HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/review.sh" && driver_step_review "$2"' _ "$KIT" "$N" >/dev/null 2>&1 || rc=$?
  R="rc=$rc"
}
kit_copy; case_pre_ship; want "the unplanted kit: a SHIP beside a pre-existing Major ships" "rc=0" "$R"
kit_copy
python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' \
  "$KIT/driver/ai-step.sh" ' | select((.tag // "") != "pre-existing")' && {
  case_pre_ship; want "planted (the answer reader exempts pre-existing): the case now fails" "rc=22" "$R"
} || want "plant landed: the answer reader exempts pre-existing" "landed" "missed"

suite_end "$FAILED"
