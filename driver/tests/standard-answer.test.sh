#!/usr/bin/env bash
# standard-answer.test.sh — under release.mergeFirst a question a standing rule answers is
# never put to a person (the owner, 23 Oct). Real park texts from the origin project on
# 22–23 Oct take their answer and do not park: (a) base red → wait (#13044, #12209),
# (b) a follow-up of an open PR → blocked on it (#13997), (c) a Minor or Major → defer
# (#13454, #10637), (d) the critic or evidence → ignore (#12209), (e) signed off → ship
# (#12704). A data-model question and a Critical still park; with mergeFirst off, all park.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
mkdir -p "$FIX/tmp"; export TMPDIR="$FIX/tmp" HARNESS_RELEASE_FETCH_SECS=0
. "$HERE/../ai-step.sh" || exit 1
BT="$HERE/../build-ticket"

CFGF="$HARNESS_CFG_PATH"; cp "$CFGF" "$FIX/cfg.base"
mf_on()  { jq '.release = {mergeFirst: true, done: false}' "$FIX/cfg.base" > "$CFGF"; }
mf_off() { jq '.release = {mergeFirst: false, done: false}' "$FIX/cfg.base" > "$CFGF"; }
sa_off() { jq '.release = {mergeFirst: true, done: false, standardAnswers: false}' "$FIX/cfg.base" > "$CFGF"; }

# The classifier: records each call, answers what the case wrote.
cat > "$BIN/sa-claude" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >> "$FIX/sa-calls"; cat > /dev/null
cat "$FIX/sa-verdict" 2>/dev/null
SH
chmod +x "$BIN/sa-claude"; export DRIVER_SA_CLAUDE="$BIN/sa-claude"
: > "$FIX/sa-calls"; printf 'park\n' > "$FIX/sa-verdict"

# ---- the real texts --------------------------------------------------------
Q13044="Neither binding answer covers this. The 2026-10-20 answer covers load and tests that pass alone, but this test fails alone, with no load, on clean develop at 77e875c057. The 2026-10-21 answer covers only fake-null-source. test:changed stays red until preview-only.sh stops reading the Test card's ./test module as a test import (#13994). Should #13044 wait for #13994 to merge, or should that one-line regex fix land on this branch? Pick one: wait or fix-here."
Q12209A="Develop itself fails narrating-copy and empty-has-error in four files this PR never touches. Fix them on develop first (yes), or let this PR carry the escape comments (no)?"
Q12209B="develop's new NEVER_SETTLES rule (0399d775a6, #13643) rejects the /dev/components shots in the plans that merged PRs #11429 and #13390 committed, so test:changed stays red on pristine develop too. Should I drop those 4 shots from docs/evidence/11429/plan.json and docs/evidence/13390/plan.json on this branch (yes), or does that fix land on develop (no)?"
Q13997="PR #13772 hasn't merged (it's red on typecheck and unit tests), so asksInstead isn't on develop yet. Should this fix go into #13772 itself while it's being healed, or should this ticket wait until #13772 merges and then build on develop? I recommend folding it into #13772. The same applies to the sibling follow-up #13998."
Q13454="the fix round deferred a blocking finding: R5: Minor and not confirmed reachable for LinkedIn (PROCESSING not counted with PUBLISHING in goingOutRefusal). Not a blocker this round.; R6: Minor: the list route's held note isn't passed through heldWaitNote. It's a consistency polish item, not a blocker."
Q10637="The Major polish item polish-13511-TWFqb3Igwr (the Create phone masthead clips its primary verb) is on a screen this branch does not touch: its own diff from the merge-base is 28 Pulse-chart files. A Major cannot be deferred. Do I fix it in this ticket, or does it stay on polish list #13511 for its own ticket?"
Q12209C="the fix round says a red gate is not this change's to repair: critic-library-toast-on-load: Already fixed in this tree, by trunk rather than by a commit of this branch. CI's shot b0c817946f (18:03) came before #13376 (db11c8cba3, 18:32), which took the toast out of usePickerLibrarySearch and now shows 'Couldn’t search your library' with Retry next to the attach control (the critic's second option)."
Q12209D="the fix round deferred a blocking finding: critic-library-toast-on-load: The owner answered decision:12209:driver-park-2 on the ticket: the 'Couldn't search your library' toast comes from the evidence fixture's library search, not from this change. Per that answer it is not fixed in this PR."
Q12704="PR #13216 (Pulse templates card) is signed off but the design critic says SLOP (round 2): the shots miss the chosen-row, long-name and twin-'Classic' states, and it wants a 'Yours' marker. Ship as signed off, or have an agent add those fixtures (and the marker) and re-capture?"
QDATA="The import needs to remember which calendar a row came from, and the data model has no column for it. Add a sourceCalendarId column to Event, or keep it in the row's JSON?"
QCRIT="1 blocking finding(s) from the review to clear: critical apps/api/src/lib/org.ts:40 another workspace's rows are returned to this one. Fix it here, or defer it as a follow-up?"
QCOPY="the fix round deferred a blocking finding: R1-09: Minor. The novelty-collision copy differs from the approved copy. Changing approved user-facing words is the owner's call, not the fix step's, so the current copy stays until the owner confirms."
QODD="The ticket says the button sits on the left; the screen has nowhere on the left. Which side?"
# Two fix runs parked on 2026-10-24 asking whether to go ahead past a red the base has too.
Q14311="gate-changed-3 is red only on tests this branch does not touch: the same 15 fail at merge-base c967f3e548 with the change removed. May this branch go ahead while the develop-red ticket owns them? (yes/no)"
QOWN="gate-changed-3 is red on src/voice.test.ts, which this branch changed; it passes at merge-base c967f3e548. Fix it here, or defer it?"
# Three parts that parked within 3 minutes on 2026-10-24, asking whether to wait for a part not built yet.
Q14276="This part posts the new 'One question' card, but the part that adds that card (part 2, #14273) hasn't been built or claimed yet. Should this part wait until part 2 merges? (yes / no)"
Q14277="Hold this part until parts 2 to 5 (#14273–#14276) merge? Every piece it wires together is missing on develop: the factQuestion/factSaved cards (#14273), the private-life filter (#14274), recordOwnFact (#14275)."
Q13573="This ticket needs the context loader from part 2 of the programme, and none of it has been built. That part (#13572) was closed as split into #14268, #14269, #14270 and #14271, and all four are still open with no pull request. Should this ticket wait for them?"

N=600
cls() { # <text> [pr] — the class a fresh ticket's question gets, or park
  N=$(( $(cat "$FIX/n" 2>/dev/null || echo 600) + 1 )); echo "$N" > "$FIX/n"; driver_state_init "$N" >/dev/null
  [ -z "${2:-}" ] || driver_state_set "$N" pr "$2"
  if driver_standard_answer "$N" fix "$1" >/dev/null 2>&1; then printf '%s %s' "$SA_CLASS" "$SA_ACTION"; else printf park; fi
}

echo "--- on: each real text takes its standard answer ---"
mf_on
want "#13044 wait or fix-here: (a), waits for the base"       "a base-wait"   "$(cls "$Q13044" 77)"
want "#12209 develop itself fails: (a)"                       "a base-wait"   "$(cls "$Q12209A" 77)"
want "#12209 red on pristine develop: (a)"                    "a base-wait"   "$(cls "$Q12209B" 77)"
want "#13997 wait or fold in: (b), waits for its parent"      "b parent-wait" "$(cls "$Q13997")"
N=$(( $(cat "$FIX/n") + 1 )); echo "$N" > "$FIX/n"; driver_state_init "$N" >/dev/null; SA_PARENT=""; driver_standard_answer "$N" plan "$Q13997" >/dev/null 2>&1
want "and the parent is the PR the text names"                "13772"         "$SA_PARENT"
want "#13454 deferred Minors: (c), carry on"                  "c carry"       "$(cls "$Q13454" 77)"
want "#14311 fails at the merge base too: (g), carry on"      "g carry"       "$(cls "$Q14311" 77)"
want "  a branch-only red is no (g)"                          "park"          "$(cls "$QOWN" 77)"
: > "$FIX/sa-calls"   # that text is the classifier's (it answers park here); the rest are mechanical
want "#14276 wait for part 2: (f), waits for the dependency"  "f dependency-wait" "$(cls "$Q14276")"
want "#14277 hold until parts 2 to 5: (f)"                    "f dependency-wait" "$(cls "$Q14277")"
want "#13573 wait for the split parts: (f)"                   "f dependency-wait" "$(cls "$Q13573")"
deps() { N=$(( $(cat "$FIX/n") + 1 )); echo "$N" > "$FIX/n"; driver_state_init "$N" >/dev/null; SA_PARENT=""; driver_standard_answer "${2:-$N}" plan "$1" >/dev/null 2>&1; printf '%s' "$SA_PARENT"; }
want "  #14276 waits for #14273"                              "14273" "$(deps "$Q14276" 14276)"
want "  #14277's range is each ticket in it"                  "14273 14274 14275 14276" "$(deps "$Q14277" 14277)"
want "  #13573 waits for the parts, and the split parent named" "13572 14268 14269 14270 14271" "$(deps "$Q13573" 13573)"
want "a wait that names no ticket parks"                      "park" "$(cls "Should this part wait until part 2 merges? (yes / no)")"
want "#10637 a Major on another screen: (c)"                  "c carry"       "$(cls "$Q10637" 77)"
want "#12209 the critic's toast: (d), ignore"                 "d carry"       "$(cls "$Q12209C" 77)"
want "#12209 the critic deferred again: (d)"                  "d carry"       "$(cls "$Q12209D" 77)"
want "#12704 critic after sign-off: (e), ship"                "e carry"       "$(cls "$Q12704" 77)"
want "a base red with no PR yet carries on, as nothing waits" "a carry"       "$(cls "$Q13044")"
want "no model call for any of them"                          "0"             "$(grep -c . "$FIX/sa-calls")"

echo "--- on: product, data-model, secrets and Critical questions still park ---"
want "a data-model question parks"                            "park" "$(cls "$QDATA" 77)"
want "a Critical parks"                                       "park" "$(cls "$QCRIT" 77)"
want "approved copy is the owner's call: parks"               "park" "$(cls "$QCOPY" 77)"
want "and none of those asked the model"                      "0"    "$(grep -c . "$FIX/sa-calls")"

echo "--- the step's record decides what the text cannot: c from the deferred grades, a from the base-red cache ---"
N=$(( $(cat "$FIX/n") + 1 )); echo "$N" > "$FIX/n"; driver_state_init "$N" >/dev/null; driver_state_set "$N" pr 77
mkdir -p "$(driver_state_dir "$N")/steps"
printf '{"findings":[{"id":"R7","grade":"minor"},{"id":"R8","grade":"major"}]}' > "$(driver_state_dir "$N")/steps/review.json"
printf '{"deferred":[{"blockerId":"R7","reason":"not this round"},{"blockerId":"R8","reason":"out of scope"}]}' > "$(driver_state_dir "$N")/steps/fix.json"
driver_standard_answer "$N" fix "the fix round left R7 and R8 as they are" >/dev/null 2>&1
want "deferred findings graded Minor and Major are (c)" "c" "$SA_CLASS"
printf '{"findings":[{"id":"R7","grade":"critical"},{"id":"R8","grade":"major"}]}' > "$(driver_state_dir "$N")/steps/review.json"
SA_CLASS=""; driver_state_set "$N" pr 77
driver_standard_answer "$N" fix "the fix round left R7 and R8 as they are" >/dev/null 2>&1
want "one of them a Critical: not (c)" "" "$SA_CLASS"
N=$(( $(cat "$FIX/n") + 1 )); echo "$N" > "$FIX/n"; driver_state_init "$N" >/dev/null; driver_state_set "$N" pr 77; driver_state_set "$N" base_red "unit tests"
driver_standard_answer "$N" fix "unit tests are red in files this PR never touches. Wait, or fix them here?" >/dev/null 2>&1
want "a base-red cache on the record makes a wait-or-fix (a)" "a" "$SA_CLASS"

echo "--- only an undecided text goes to the model, once, and an unknown verdict parks ---"
: > "$FIX/sa-calls"; printf 'd\n' > "$FIX/sa-verdict"
want "the model's class is taken"         "d carry" "$(cls "$QODD" 77)"
want "in one call"                        "1"       "$(grep -c . "$FIX/sa-calls")"
driver_standard_answer "$N" fix "$QODD" >/dev/null 2>&1; driver_standard_answer "$N" fix "$QODD" >/dev/null 2>&1
want "the same question asked again reads the first verdict" "2" "$(grep -c . "$FIX/sa-calls")"
printf 'well, probably d\n' > "$FIX/sa-verdict"
want "an answer that is not one token parks" "park" "$(cls "$QODD" 77)"
printf 'b\n' > "$FIX/sa-verdict"
want "a (b) with no parent PR in the text parks" "park" "$(cls "$QODD" 77)"

echo "--- off: every one parks as before ---"
mf_off; : > "$FIX/sa-calls"
for q in "$Q13044" "$Q13997" "$Q13454" "$Q12209C" "$Q12704"; do
  want "mergeFirst off: $(printf '%s' "$q" | cut -c1-40)… parks" "park" "$(cls "$q" 77)"
done
sa_off
want "release.standardAnswers false: parks" "park" "$(cls "$Q12704" 77)"
want "and nothing asked the model"          "0"    "$(grep -c . "$FIX/sa-calls")"

# ---- the walk ----------------------------------------------------------------
FAKE="$FIX/fakesteps"; RAN="$FIX/ran.log"; export RAN
walk() { # <ticket> <step> <rc> <how: note|question> <text> [pr]
  rm -rf "$FAKE"; mkdir -p "$FAKE"; : > "$RAN"; : > "$FIX/park.log"; : > "$GH_LOG"
  printf '#!/usr/bin/env bash\ndriver_park() { printf "PARK %%s | %%s | cause=%%s\\n" "$2" "${3:-}" "${4:-}" >> "$FIX/park.log"; return 20; }\n' > "$FAKE/park.sh"
  local s
  for s in start size plan build fix compare self-check review record ship reenter repair quick; do
    printf '#!/usr/bin/env bash\ndriver_step_%s() { printf "%%s\\n" %s >> "$RAN"; return 0; }\n' "${s//-/_}" "$s" > "$FAKE/$s.sh"
  done
  jq -n --arg q "$5" '$q' > "$FIX/walk-q.json"
  if [ "$4" = note ]; then
    printf '#!/usr/bin/env bash\ndriver_step_%s() { printf "%%s\\n" %s >> "$RAN"; [ -f "$FIX/asked.%s" ] && return 0; : > "$FIX/asked.%s"; driver_state_set "$1" park_note "$(jq -r . "$FIX/walk-q.json")"; driver_state_set "$1" park_cause person; return %s; }\n' \
      "${2//-/_}" "$2" "$1" "$1" "$3" > "$FAKE/$2.sh"
  else
    printf '#!/usr/bin/env bash\ndriver_step_%s() { printf "%%s\\n" %s >> "$RAN"; mkdir -p "$(driver_state_dir "$1")/steps"; jq -n --slurpfile q "$FIX/walk-q.json" '"'"'{step:"x", status:"park", question:$q[0], questionFor:"pm"}'"'"' > "$(driver_state_dir "$1")/steps/%s.json"; return %s; }\n' \
      "${2//-/_}" "$2" "$2" "$3" > "$FAKE/$2.sh"
  fi
  rm -f "$FIX/asked.$1"
  rm -rf "$STATE/driver/$1"; driver_state_init "$1" >/dev/null
  [ -z "${6:-}" ] || driver_state_set "$1" pr "$6"
  fix_issue "$1" OPEN "status:claimed"
  DRIVER_STEPS_DIR="$FAKE" bash "$BT" "$1" > "$FIX/walk.out" 2>&1
}
walk_rc() { walk "$@"; echo $?; }

echo "--- on: a step's own refusal the critic answers carries on to the ship ---"
mf_on
want "#12209's critic refusal at fix: the run finishes" "0" "$(walk_rc 701 fix 24 note "$Q12209C" 88)"
want "nothing parked"                                  "" "$(cat "$FIX/park.log")"
want "and every step after fix ran"                    "start size plan build fix compare self-check review record ship" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_in "the run log says which standard answer"      'standard answer: \(d\)' "$(cat "$FIX/walk.out")"
want_in "and it is written on the PR"                  'pr comment 88 .*standard answer: \(d\)' "$(tr '\n' ' ' < "$GH_LOG")"
want_not_in "no owner label"                           'needs:owner-decision' "$(cat "$GH_LOG")"

echo "--- on: a fix step's red that fails at the merge base too carries on, never parks ---"
want "#14311's base-red at fix: the run finishes" "0" "$(walk_rc 708 fix 24 note "$Q14311" 88)"
want "  nothing parked"                       "" "$(cat "$FIX/park.log")"
want_in "  the run says base-red, the checks and the base" 'base-red: gate-changed-3 at c967f3e548' "$(cat "$FIX/walk.out")"
want "a branch-only red still stops the run"  "20" "$(walk_rc 709 fix 24 note "$QOWN" 88)"
want_in "  as a park"                         'PARK' "$(cat "$FIX/park.log")"

echo "--- on: a Minor deferral (c) carries on too ---"
want "#13454's deferred Minors: finishes"  "0" "$(walk_rc 702 fix 24 note "$Q13454" 88)"
want "nothing parked"                      "" "$(cat "$FIX/park.log")"

echo "--- on: #13044's wait or fix-here waits for the base, no park ---"
want "the run ends as a base wait"         "$DRIVER_E_BASE_WAIT" "$(walk_rc 703 fix 20 question "$Q13044" 88)"
want "nothing parked"                      "" "$(cat "$FIX/park.log")"
want_in "it is on the base-wait ledger"    '^703	88	' "$(cat "$STATE/swarm/base-waits.tsv" 2>/dev/null)"
want_in "the PR says why"                  'pr comment 88 .*standard answer: \(a\)' "$(tr '\n' ' ' < "$GH_LOG")"

echo "--- on: #13997's wait or fold in is blocked on its parent, no park ---"
want "the run ends clean"                  "0" "$(walk_rc 704 plan 20 question "$Q13997")"
want "nothing parked"                      "" "$(cat "$FIX/park.log")"
want "nothing after plan ran"              "start size plan" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_in "the ticket is blocked"            'issue edit 704 .*--add-label status:blocked' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "on its parent, in words the unblocker reads" 'issue comment 704 .*Blocked until #13772 merges' "$(tr '\n' ' ' < "$GH_LOG")"

echo "--- on: a plan that finds a dependency not built yet gates on it, never parks ---"
want "the run ends clean"                  "0" "$(walk_rc 707 plan 20 question "$Q14276")"
want "nothing parked"                      "" "$(cat "$FIX/park.log")"
want "nothing after plan ran"              "start size plan" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_in "the ticket is gated"              'issue edit 707 .*--add-label status:gated' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "on what it needs, in words the unblocker reads" 'issue comment 707 .*Blocked until #14273 merge' "$(tr '\n' ' ' < "$GH_LOG")"

echo "--- on: a data-model question and a Critical still park ---"
want "the data-model question parks"       "20" "$(walk_rc 705 plan 20 question "$QDATA")"
want_in "with its question"                'sourceCalendarId' "$(cat "$FIX/park.log")"
want "the Critical parks"                  "20" "$(walk_rc 706 fix 24 note "$QCRIT" 88)"
want_in "with its finding"                 'another workspace' "$(cat "$FIX/park.log")"

echo "--- off: the same walks park as before ---"
mf_off
want "critic refusal parks"                "20" "$(walk_rc 711 fix 24 note "$Q12209C" 88)"
want_in "for a person"                     'cause=person' "$(cat "$FIX/park.log")"
want "wait or fix-here parks"              "20" "$(walk_rc 712 fix 20 question "$Q13044" 88)"
want "wait or fold in parks"               "20" "$(walk_rc 713 plan 20 question "$Q13997")"
want_not_in "and nothing is blocked"       'status:blocked' "$(cat "$GH_LOG")"

# ---- a model's question is asked once more, with the answer ------------------
echo "--- on: #12704's question gets the standard answer in a second ask, and the step answers ---"
fix_brief probe "" "Probe the screens."
ask() { # <ticket> — probe asks #12704's question, then answers once told
  rm -f "$FIX/ai/probe.then.jsonl"
  fix_ai probe "$(jq -nc --arg q "$Q12704" '{step:"probe", status:"park", question:$q}')"
  printf '%s\n' "$(jq -nc '{type:"result", subtype:"success", is_error:false, result:"{\"step\":\"probe\",\"status\":\"ok\"}", structured_output:{step:"probe",status:"ok"}}')" > "$FIX/ai/probe.then.jsonl"
  driver_state_init "$1" >/dev/null; driver_state_set "$1" pr 88; : > "$GH_LOG"
  rc=0; driver_ai_step "$1" probe > "$FIX/ask.out" 2>&1 || rc=$?
  [ -z "${SA_DEBUG:-}" ] || cat "$FIX/ask.out" >&2
  echo "$rc"
}
# The critic left on (duringRelease), so the critic-off re-ask is not what answers it.
jq '.release = {mergeFirst: true, done: false} | .review.judge.duringRelease = true' "$FIX/cfg.base" > "$CFGF"
want "the step finishes"                   "0" "$(ask 721)"
want_in "the second ask carries the answer" 'standard answer \(e\).*Ship as signed off' "$(tr '\n' ' ' < "$(driver_state_dir 721)/steps/probe.standard.prompt")"
want_in "and the PR is told"               'pr comment 88 .*standard answer: \(e\)' "$(tr '\n' ' ' < "$GH_LOG")"
jq '.release = {mergeFirst: false, done: false} | .review.judge.duringRelease = true' "$FIX/cfg.base" > "$CFGF"
want "off: the question stands"            "$DRIVER_E_QUESTION" "$(ask 722)"
want "and no second ask was made"          "absent" "$([ -f "$(driver_state_dir 722)/steps/probe.standard.prompt" ] && echo present || echo absent)"

suite_end "$FAILED"
