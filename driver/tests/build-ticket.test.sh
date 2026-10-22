#!/usr/bin/env bash
# build-ticket.test.sh — the orchestrator, which is the one thing in this design
# that had to move from the agent's judgement into code. Three guarantees, and
# they are the three the epic measured a failure of:
#
#   THE STEPS RUN IN ORDER, every one of them. 158 of 161 runs skipped a step
#   that every instruction called mandatory, because the decision about what came
#   next belonged to the model. Here it belongs to a list.
#   NOTHING IS LOST ON A STOP. A killed run resumes at the step after the last
#   one that finished, and does not re-run what is already done.
#   ANY REFUSAL PARKS. A step that refuses does not fall through to the next one
#   and does not leave the claim held — it parks, with the reason, and stops.
#
# It is tested twice over: against RECORDED steps, which is how a control-flow
# question gets a clean answer, and then against the REAL seven for one whole
# pass, because a suite full of replicas proves the kit and never the product.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
# The gate cap at 1, so a second red here is past it.
export DRIVER_MAX_GATE_FIXES=1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
BT="$HERE/../build-ticket"

# ---- recorded steps ----------------------------------------------------------
# One file per step, each appending its name to a log and returning whatever the
# test asked it to. The step files are found through DRIVER_STEPS_DIR, the same
# seam the real ones are found through — so this exercises the orchestrator's own
# loader rather than a second copy of it.
FAKE="$FIX/fakesteps"; mkdir -p "$FAKE"
RAN="$FIX/ran.log"; : > "$RAN"; export RAN
fake_step() { # <step> [exit-code-sequence…]
  local s="$1"; shift
  local fn="driver_step_${s//-/_}"
  { echo '#!/usr/bin/env bash'
    printf '%s() {\n' "$fn"
    printf '  printf "%%s\\\\n" %s >> "$RAN"\n' "$s"
    printf '  local nf="$FIX/n.%s"; local n=$(( $(cat "$nf" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$nf"\n' "$s"
    printf '  local codes="%s"\n' "${*:-0}"
    printf '  local c; c=$(printf "%%s\\\\n" $codes | sed -n "${n}p")\n'
    printf '  [ -n "$c" ] || c=$(printf "%%s\\\\n" $codes | tail -1)\n'
    printf '  return "$c"\n'
    echo '}'
  } > "$FAKE/$s.sh"
}
fake_park() {
  { echo '#!/usr/bin/env bash'
    echo 'driver_park() { printf "PARK %s | %s | cause=%s\n" "$2" "${3:-}" "${4:-}" >> "$FIX/park.log"; return 20; }'
  } > "$FAKE/park.sh"
}
reset_fakes() { # <exit-code-plan…>  — plan is "step:codes" pairs
  rm -rf "$FAKE" "$STATE/driver"; mkdir -p "$FAKE" "$STATE/driver"
  : > "$RAN"; : > "$FIX/park.log"; rm -f "$FIX"/n.*
  fake_park
  local s
  for s in start size plan build fix compare self-check review record ship reenter repair quick; do fake_step "$s" 0; done
  local pair
  for pair in "$@"; do fake_step "${pair%%:*}" "${pair#*:}"; done
}
bt() { DRIVER_STEPS_DIR="$FAKE" bash "$BT" "$@" 2>&1; }

echo "--- every step runs, in the declared order ---"
reset_fakes
out=$(bt 101); rc=$?
want "it finishes"        "0" "$rc"
want "all ten ran once" "start size plan build fix compare self-check review record ship" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_in "and it says so"  'shipped|finished|done' "$out"

echo "--- and each one is recorded as finished ---"
export HARNESS_STATE_DIR="$STATE"
. "$HERE/../state.sh" || exit 1
want "the record lists them in order" "start,size,plan,build,fix,compare,self-check,review,record,ship" \
  "$(driver_state_get 101 'done|join(",")')"

echo "--- nothing is lost on a stop: a resumed run picks up where it stopped ---"
# `plan` refuses the first time, so the run parks after `start`. The second run must
# not re-do the WORK that is finished.
#
# start is the exception, and it is not an oversight. It is the re-entry check: the
# hold label, the ticket's state and the claim are all read there, and a park adds
# that label and RELEASES the claim. Skipped on a resume, the ticket a person has
# taken ownership of is built anyway, and the run pushes, marks the pull request
# ready and arms auto-merge while holding no claim at all — so a peer can cut a
# second worktree on the same branch mid-push. So start runs every time, and what
# makes that safe is that it is idempotent: it keeps the worktree and the branch it
# already has.
reset_fakes "plan:24 0"
bt 102 >/dev/null; rc=$?
want "the first run refuses"      "20" "$rc"
want "it got as far as plan"      "start size plan" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "start and size are recorded finished" "start,size" "$(driver_state_get 102 'done|join(",")')"
: > "$RAN"
out=$(bt 102); rc=$?
want "the second run finishes"    "0" "$rc"
want_in "start ran again — it is the re-entry check" '^start$' "$(cat "$RAN")"
want "and nothing else was repeated" "start plan build fix compare self-check review record ship" \
  "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "and plan ran in the resumed run" "1" "$(grep -c '^plan$' "$RAN")"
# Only size was skipped in that run, and the line counts it alone: start re-ran as the
# re-entry check and is never counted, and plan onwards had never finished.
want_in "it counts the one real skip, not start" 'resumed: 1 step\(s\)' "$out"

echo "--- a run that really does skip says how many, not counting the re-entry check ---"
reset_fakes "build:24 0"
bt 119 >/dev/null
want "start, size and plan finished" "start,size,plan" "$(driver_state_get 119 'done|join(",")')"
: > "$RAN"
out=$(bt 119); rc=$?
want "it finishes"                     "0" "$rc"
want_in "and counts the two real skips" 'resumed: 2 step\(s\)' "$out"
want_in "start ran again all the same" '^start$' "$(cat "$RAN")"

echo "--- --restart runs the lot again ---"
: > "$RAN"
out=$(bt 102 --restart); rc=$?
want "it finishes"            "0" "$rc"
want "every step ran again"   "start size plan build fix compare self-check review record ship" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"

echo "--- a refusal parks, with the reason, and does not fall through ---"
reset_fakes "self-check:24"
out=$(bt 103); rc=$?
want "the run stops"                 "20" "$rc"
want "it stopped AT the refusal"     "start size plan build fix compare self-check" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_not_in "review never ran"       'review' "$(cat "$RAN")"
want_in "it parked"                  'PARK' "$(cat "$FIX/park.log")"
want_in "naming the step"            'self-check' "$(cat "$FIX/park.log")"

echo "--- a note a step left behind becomes the question the park asks ---"
# A refusal's exit code says which check said no; it cannot say WHAT. A step that knows
# — what a review graded critical, major or minor — leaves the text
# on the record, and the park brief asks about that rather than about the code.
# The note is written by the step that refuses, which is the only way a real one
# arrives: a note sitting on the record BEFORE the run belongs to a previous one and
# is cleared, which the next case is about.
reset_fakes
cat > "$FAKE/self-check.sh" <<'SH'
#!/usr/bin/env bash
driver_step_self_check() {
  printf 'self-check\n' >> "$RAN"
  driver_state_set "$1" park_note "the save button on a.ts:9 calls nothing"
  return 24
}
SH
out=$(bt 116); rc=$?
want "the run stops" "20" "$rc"
want_in "and the park asks about the finding" 'the save button on a.ts:9 calls nothing' "$(cat "$FIX/park.log")"
want_not_in "not about the exit code" 'which check said no' "$(cat "$FIX/park.log")"

echo "--- and a note from an earlier step never leaks into a later park ---"
# The leak that matters is a note a step left while SUCCEEDING: nothing consumes it, so
# without the clearing it sits on the record and becomes the question a later, unrelated
# park asks. The first version of this case set the note before the run and called
# `reset_fakes` between the two — which does `rm -rf "$STATE/driver"`, destroying the
# record the note lives on, so "previous run" could never appear whatever the code did.
: > "$FIX/park.log"
reset_fakes
cat > "$FAKE/plan.sh" <<'SH'
#!/usr/bin/env bash
driver_step_plan() {
  printf 'plan\n' >> "$RAN"
  driver_state_set "$1" park_note "a note from the plan step, which then succeeded"
  return 0
}
SH
bt 118 >/dev/null; rc=$?
want "the run finishes"                   "0" "$rc"
want "and the note was cleared, unused"   "" "$(driver_state_get 118 park_note)"
# Now a later step refuses, with no note of its own.
: > "$FIX/park.log"; rm -f "$FIX"/n.*
fake_step plan 0
fake_step review 24
out=$(bt 118 --restart); rc=$?
want "the second run stops"               "20" "$rc"
want_not_in "the plan's old note is gone" 'from the plan step' "$(cat "$FIX/park.log")"
want_in "and the park says what really stopped it" 'review' "$(cat "$FIX/park.log")"

echo "--- a refusal parks, with the reason, and does not fall through ---"
reset_fakes "self-check:24"
out=$(bt 103); rc=$?
want "the run stops"                 "20" "$rc"
want "it stopped AT the refusal"     "start size plan build fix compare self-check" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_not_in "review never ran"       'review' "$(cat "$RAN")"
want_in "it parked"                  'PARK' "$(cat "$FIX/park.log")"
want_in "naming the step"            'self-check' "$(cat "$FIX/park.log")"

echo "--- a note a step left behind becomes the question the park asks ---"
# A refusal's exit code says which check said no; it cannot say WHAT. A step that knows
# — what a review graded critical, major or minor — leaves the text
# on the record, and the park brief asks about that rather than about the code.
# The note is written by the step that refuses, which is the only way a real one
# arrives: a note sitting on the record BEFORE the run belongs to a previous one and
# is cleared, which the next case is about.
reset_fakes
cat > "$FAKE/self-check.sh" <<'SH'
#!/usr/bin/env bash
driver_step_self_check() {
  printf 'self-check\n' >> "$RAN"
  driver_state_set "$1" park_note "the save button on a.ts:9 calls nothing"
  return 24
}
SH
out=$(bt 116); rc=$?
want "the run stops" "20" "$rc"
want_in "and the park asks about the finding" 'the save button on a.ts:9 calls nothing' "$(cat "$FIX/park.log")"
want_not_in "not about the exit code" 'which check said no' "$(cat "$FIX/park.log")"

echo "--- a question parks with the question, not with a gate's wording ---"
reset_fakes "plan:20"
out=$(bt 104); rc=$?
want "the run stops"        "20" "$rc"
want_in "parked as a question" 'asked|question' "$(cat "$FIX/park.log")"

echo "--- a skipped Skill parks and says so: that is Superpowers not having run ---"
reset_fakes "build:21"
out=$(bt 105); rc=$?
want "the run stops"    "20" "$rc"
want_in "the park names the skill problem" 'Skill' "$(cat "$FIX/park.log")"

echo "--- a review that grades something critical, major or minor sends the work back to FIX ---"
# BLOCKED on round 1, clean on round 2. It goes back to `fix` — the only step that
# reads review.json — not to `build`, which would re-run the original plan task
# blind to what the reviewer just found. That was T2-3: the two-round ceiling
# bounded a loop that could not act on anything.
reset_fakes "review:30 0"
out=$(bt 106); rc=$?
want "it finishes"  "0" "$rc"
want "the rework repeats fix, compare, the gates and review" \
  "start size plan build fix compare self-check review fix compare self-check review record ship" \
  "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "and plan was not repeated"  "1" "$(grep -c '^plan$' "$RAN")"
want "nor was build — the plan task is already built" "1" "$(grep -c '^build$' "$RAN")"
want "the fix step ran on both passes"  "2" "$(grep -c '^fix$' "$RAN")"
want_in "it says which step it went back to" 'back to fix' "$out"
want_in "it says it is a rework round" 'rework|again|round' "$out"

echo "--- the BUILD step sending itself back goes back to BUILD, not to fix ---"
# The other half of the same rule, and the one that breaks if the target is a
# single answer: `fix` is AFTER `build` in the order, so sending a failed build
# there skips `build` entirely — it is not finished, so the walk would never
# return to it and the task would ship unbuilt.
reset_fakes "build:30 0"
out=$(bt 122); rc=$?
want "it finishes"                     "0" "$rc"
want "build ran twice, its own retry"  "2" "$(grep -c '^build$' "$RAN")"
want "and fix ran once, after the build finally passed" "1" "$(grep -c '^fix$' "$RAN")"
want_in "it says it went back to build" 'back to build' "$out"

echo "--- a red self-check goes back to fix, and the gates run again ---"
reset_fakes "self-check:30 0"
out=$(bt 123); rc=$?
want "it finishes"  "0" "$rc"
want "fix, then the gates again" \
  "start size plan build fix compare self-check fix compare self-check review record ship" \
  "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_in "it says it went back to fix" 'back to fix' "$out"

echo "--- a refusal with no reason on the record says where the reason is (#199) ---"
# "Read the step's own line above" pointed at a line the park comment does not carry.
reset_fakes "self-check:24"
out=$(bt 124); rc=$?
want "it parks"                                  "20" "$rc"
want_not_in "never pointing at a line it lacks"  'line above' "$(cat "$FIX/park.log")"
want_in "it names the host"                      "$(hostname -s)" "$(cat "$FIX/park.log")"
want_in "and the run log"                        '124/log' "$(cat "$FIX/park.log")"

echo "--- a run that uses both budgets in full still finishes ---"
# The build step's ceiling is its own (5 tries) and the reviewer's is its own (2
# rounds). A single counter set to the build's number trips on the SUM: four build
# failures then two review rounds is six, inside both budgets and over that ceiling.
# The run then parks accusing a step of not counting, and never reaches its last
# review pass.
reset_fakes "build:30 30 30 30 0" "review:30 30 0"
out=$(bt 121); rc=$?
want "it finishes rather than accusing a step" "0" "$rc"
want_not_in "and never says the loop did not settle" 'did not settle' "$(cat "$FIX/park.log")"
# Five build calls for its own four failures plus the pass. A review rework now
# rewinds to `fix`, not to `build`, so the build step is not re-run for them — the
# task is built and what is wrong with it is the reviewer's list.
want "build ran for its own tries and no more"  "5" "$(grep -c '^build$' "$RAN")"
want "the fix step ran once per pass"           "3" "$(grep -c '^fix$' "$RAN")"
want "and the reviewer all three of its passes" "3" "$(grep -c '^review$' "$RAN")"

echo "--- a rework that never settles parks rather than spinning ---"
# The real build step parks itself at five tries. A step that returns 30 for ever
# must still terminate: an unbounded loop is a run that never finishes and never
# parks, which is indistinguishable from a hung agent.
reset_fakes "review:30"
bounded() { perl -e 'alarm 60; exec @ARGV or exit 127' -- "$@"; }
out=$(bounded env DRIVER_STEPS_DIR="$FAKE" bash "$BT" 107 2>&1); rc=$?
want "it parks rather than spinning"  "20" "$rc"
want_in "and says the loop did not settle" 'settle|rework' "$(cat "$FIX/park.log")"
rounds=$(grep -c '^review$' "$RAN")
if [ "$rounds" -le 11 ]; then ok "it stopped after $rounds rounds, not more"; else bad "ran $rounds rework rounds — the ceiling did not hold"; fi

echo "--- a step named in the order with no file refuses BY NAME ---"
# Silence is the failure being prevented: a walk that skips a step it cannot find
# reports exactly like a walk where that step passed.
reset_fakes
rm -f "$FAKE/review.sh"
out=$(bt 108); rc=$?
if [ "$rc" -ne 0 ]; then ok "it refuses"; else bad "a missing step file must not pass"; fi
want_in "naming the step"  'review' "$out"
# Pinned on the wording, not just on the non-zero. Deleting the existence check
# still refuses — sourcing a file that is not there fails too — so a test that
# only reads the exit code cannot tell "the order names a step that does not
# exist" from "that file would not load", and the operator is told the wrong
# thing about their own configuration.
want_in "and saying the ORDER names it" 'the order names' "$out"
want_not_in "and nothing shipped" '^ship$' "$(cat "$RAN")"

echo "--- a step file that defines no step function refuses too ---"
reset_fakes
echo '#!/usr/bin/env bash' > "$FAKE/record.sh"
out=$(bt 109); rc=$?
if [ "$rc" -ne 0 ]; then ok "it refuses"; else bad "an empty step file must not pass"; fi
want_in "naming the function it wanted" 'driver_step_record' "$out"

echo "--- an already-finished ticket is a no-op that says so ---"
# start still re-runs, because it is the re-entry check and re-checking a finished
# ticket's claim and labels costs nothing. Nothing else does, and the run says so
# rather than reporting a second ship.
reset_fakes
bt 110 >/dev/null
: > "$RAN"
out=$(bt 110); rc=$?
want "it finishes"                  "0" "$rc"
want "only the re-entry check ran"  "start" "$(tr -d '\n' < "$RAN")"
# Anchored on `nothing left` alone: `already` also appears in "N step(s) were already
# finished", the line a resumed run prints — so deleting the no-op branch left this
# green while the run reported a second ship.
want_in "and it says there is nothing left" 'nothing left' "$out"

echo "--- a broken-shaped answer parks, naming the schema to look at ---"
reset_fakes "plan:22"
out=$(bt 111); rc=$?
want "the run stops" "20" "$rc"
want_in "and points at the schema" 'schemas/plan.json' "$(cat "$FIX/park.log")"

echo "--- an API error twice is the machine's park: exit 33, driver cause, never the owner's ---"
# #13642: a false safeguards flag on the review reply parked for the owner as his question.
reset_fakes "review:33"
out=$(bt 112); rc=$?
want "the run's exit says machine"     "33" "$rc"
want_in "the park says machine fault"  'PARK machine fault' "$(cat "$FIX/park.log")"
want_in "and it is the driver's"       'cause=driver' "$(cat "$FIX/park.log")"

echo "--- a missing brief parks, and says the briefs are a separate deliverable ---"
# 23 is not a failure of the ticket. The briefs land under their own number, so a
# driver that met this before they did has to say which is missing rather than
# blaming the work.
reset_fakes "build:23"
out=$(bt 112); rc=$?
want "the run stops" "20" "$rc"
want_in "naming the brief file" 'briefs/build.md' "$(cat "$FIX/park.log")"

echo "--- a rework with nowhere to go back to parks, it does not loop on itself ---"
# An order without a build step cannot honour "go back to the build". Re-running
# the reviewer would be a loop over the same tree for ever.
reset_fakes "review:30"
out=$(bt 113 --steps "start plan review ship"); rc=$?
want "the run stops"  "20" "$rc"
want_in "and says there is no build step" 'no build step' "$(cat "$FIX/park.log")"
want "review ran once, not for ever" "1" "$(grep -c '^review$' "$RAN")"

echo "--- --steps is honoured, so an order can be shortened deliberately ---"
reset_fakes
# Through the FLAG, not through DRIVER_STEPS. The env var is read by driver-env
# and would pass with the flag deleted — which it did, until this line changed:
# the assertion was named for --steps and measuring something else.
out=$(bt 114 --steps "start plan"); rc=$?
want "it finishes"             "0" "$rc"
want "only those two ran"      "start plan" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"

echo "--- no park step: nothing may start ---"
# Park is the exit from every other step, so discovering it is missing at the
# moment it is needed is discovering it too late. It is checked before the walk.
reset_fakes
rm -f "$FAKE/park.sh"
out=$(bt 115); rc=$?
if [ "$rc" -ne 0 ]; then ok "it refuses before running anything"; else bad "a missing park step must not pass"; fi
want "and no step ran"        "" "$(tr -d '\n' < "$RAN")"
want_in "saying why it matters" "every other step's refusal" "$out"

echo "--- refusals of the call itself ---"
if bt >/dev/null 2>&1; then bad "no ticket must refuse"; else ok "no ticket refuses"; fi
if bt abc >/dev/null 2>&1; then bad "a non-number must refuse"; else ok "a non-number refuses"; fi
if bt 101 --nonsense >/dev/null 2>&1; then bad "an unknown flag must refuse"; else ok "an unknown flag refuses"; fi

# ---- the real seven ----------------------------------------------------------
# Everything above is control flow over recorders. This runs the orchestrator
# against the steps that actually ship, once, end to end: a real git repo, a real
# origin, real commits whose test goes red then green, and transcripts standing in
# only for the model. Nothing pins the wiring except a test that reads the wiring.
echo "--- the real seven, one whole pass ---"
rm -rf "$STATE/driver"; mkdir -p "$STATE/driver"
: > "$GH_LOG"; : > "$CLAUDE_LOG"
git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop

TICKET=201
fix_issue "$TICKET" OPEN "status:ready"

# The briefs the AI steps read, each naming the Skill the driver then insists on
# seeing in the transcript. Superpowers is CALLED here, never copied.
fix_brief plan   superpowers:writing-plans
fix_brief build  superpowers:subagent-driven-development
fix_brief review superpowers:requesting-code-review

# A worktree carrying the two commits the build step's proof is made of: one that
# adds a test which fails, one that makes it pass.
WT="$FIX/wt$TICKET"
git -C "$REPO" worktree add -q "$WT" -b "tkt-$TICKET/work" develop
mkdir -p "$WT/t"
cat > "$WT/t/check.sh" <<'SH'
#!/usr/bin/env bash
grep -q 'the-feature' "$(dirname "$0")/../feature.txt" 2>/dev/null
SH
git -C "$WT" add t/check.sh
git -C "$WT" -c user.email=t@example.invalid -c user.name=T commit -qm "test: the feature is present"
TSHA=$(git -C "$WT" rev-parse HEAD)
printf 'the-feature\n' > "$WT/feature.txt"
git -C "$WT" add feature.txt
git -C "$WT" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: the feature"
ISHA=$(git -C "$WT" rev-parse HEAD)

# THE ANSWERS ARE THE CONTRACT'S SHAPE, because the steps read the contract now.
# They were `status:"ok"` with top-level `files`/`tests` and a build `items` array —
# names briefs/schemas/*.json do not have — and this section is the only place the
# real seven ever ran, so the shapes the real steps read had nothing pinning them.
fix_ai plan "$(jq -nc \
  '{step:"plan", skills:["superpowers:writing-plans"], status:"planned",
    designSource:"ticket-body",
    premise:{verdict:"still-true", evidence:"feature.txt does not exist yet"},
    tasks:[{title:"the feature is present",
            files:[{path:"feature.txt", action:"create"}],
            tests:[{file:"t/check.sh", behaviour:"feature.txt carries the-feature",
                    redWhen:"feature.txt is deleted"}]}]}')" \
  superpowers:writing-plans
fix_ai build "$(jq -nc --arg ts "$TSHA" --arg is "$ISHA" \
  '{step:"build", skills:["superpowers:subagent-driven-development"], status:"built",
    task:"the feature is present",
    testFirst:{test:{file:"t/check.sh", behaviour:"feature.txt carries the-feature",
                     redWhen:"feature.txt is deleted"},
               command:"bash t/check.sh", testCommit:$ts, implCommit:$is,
               failedBefore:true, redOutput:"FAIL", passedAfter:true, greenOutput:"PASS"},
    changed:[{path:"feature.txt", action:"create"}],
    changelog:{skipped:"a fixture change"}}')" \
  superpowers:subagent-driven-development
fix_ai review '{"step":"review","skills":["superpowers:requesting-code-review"],"status":"reviewed","round":1,"verdict":"SHIP","findings":[]}' \
  superpowers:requesting-code-review

# The claim the start step re-enters through, and the worktree it works in.
driver_state_init "$TICKET" --worktree "$WT" --branch "tkt-$TICKET/work"
out=$(HARNESS_STATE_DIR="$STATE" bash "$BT" "$TICKET" 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
want "the real seven finish"        "0" "$rc"
# The branch on the record is the branch that ships. A second name here would put
# the worktree, the commits and the pull request on three different branches.
want "start kept the branch it was given" "tkt-$TICKET/work" "$(driver_state_get "$TICKET" branch)"
want "and recorded the ticket's subject for the PR title" "Ticket $TICKET" "$(driver_state_get "$TICKET" title)"
want_in "which is what the pull request is titled with" "Ticket $TICKET" "$(cat "$GH_LOG")"
want "every one is recorded"        "start,size,plan,build,fix,compare,self-check,review,record,ship" \
  "$(driver_state_get "$TICKET" 'done|join(",")')"
want_in "the plan named its Skill and the log showed it" 'superpowers:writing-plans ran' "$out"
want_in "the build proved red before green" 'red .*then green' "$out"
want_in "the gates were read by exit code"  'gate\(s\) green' "$out"
want "the branch really reached origin"     "1" \
  "$(git -C "$FIX/origin" rev-parse --verify "tkt-$TICKET/work" >/dev/null 2>&1 && echo 1)"
want_in "the pull request opened as a draft" 'pr create.*--draft' "$(cat "$GH_LOG")"
want_in "and was marked ready once reviewed" 'pr ready' "$(cat "$GH_LOG")"
want "the verdict recorded is the reviewer's" "SHIP" "$(driver_state_get "$TICKET" review_verdict)"

# ONE AGENT PER STEP, AND NEVER SEVERAL ON ONE TICKET (Dom, 2026-09-27). Splitting
# the work inside a ticket is Superpowers' job — the build brief invokes
# subagent-driven-development and THAT fans out, with a fresh helper per task. The
# driver fanning out itself is the thing being ruled out, and the only way to see
# it is to count the runner's invocations: three AI steps, three calls, no more.
want "the agent ran once per AI step and no more" "plan build review" \
  "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want "and three calls in total, not a fan-out" "3" "$(grep -c . "$CLAUDE_LOG")"
# The line that used to sit here grepped CLAUDE_LOG for `spawn|--parallel|&$`. That
# file is written by the runner stub as one bare step name per line, so nothing the
# driver could possibly do would put those strings in it: a driver that forked three
# parallel agents would log "build build build" and the assertion would still pass.
# The count above is what measures the rule; this measures that no step was reached
# through anything but its own single call.
want "no step was run twice in one pass" "0" "$(sort "$CLAUDE_LOG" | uniq -d | grep -c . || true)"

echo "--- a resumed run is still stopped by the label a person owns it with ---"
# This is the consequence of the re-entry rule, measured against the real start step.
# A park adds the hold label and releases the claim; the only gates that read either
# live in start. Skipped on a resume, the run pushes, marks the pull request ready
# and arms auto-merge on a ticket a person has taken — holding no claim, so a peer
# can cut a second worktree on the same branch while it does.
rm -rf "$STATE/driver"; mkdir -p "$STATE/driver"
: > "$GH_LOG"
fix_issue 203 OPEN "status:ready,needs:human-approval"
driver_state_init 203 --worktree "$WT" --branch "tkt-$TICKET/work"
for st in start plan build fix compare self-check review record; do driver_state_done 203 "$st"; done
out=$(HARNESS_STATE_DIR="$STATE" bash "$BT" 203 2>&1); rc=$?
want "it stops"                         "20" "$rc"
want_in "because a person owns it"      'needs:human-approval' "$out"
want_not_in "nothing was pushed ready"  'pr ready' "$(cat "$GH_LOG")"
want_not_in "and auto was never armed"  'pr merge' "$(cat "$GH_LOG")"

echo "--- the real steps park a real refusal: a skipped Skill is not a pass ---"
# The same transcript with the Skill call removed. Nothing else changes, so what
# this measures is the check and not the shape of the answer.
rm -rf "$STATE/driver"; mkdir -p "$STATE/driver"
fix_ai plan "$(jq -nc \
  '{step:"plan", skills:["superpowers:writing-plans"], status:"planned",
    designSource:"ticket-body",
    premise:{verdict:"still-true", evidence:"feature.txt does not exist yet"},
    tasks:[{title:"the feature is present",
            files:[{path:"feature.txt", action:"create"}],
            tests:[{file:"t/check.sh", behaviour:"feature.txt carries the-feature",
                    redWhen:"feature.txt is deleted"}]}]}')"
driver_state_init 202 --worktree "$WT" --branch "tkt-$TICKET/work"
fix_issue 202 OPEN "status:ready"
out=$(HARNESS_STATE_DIR="$STATE" bash "$BT" 202 2>&1); rc=$?
want "it stops"                    "20" "$rc"
want_in "because the Skill never ran" 'does not contain any of those Skill calls' "$out"
want_in "and the ticket is parked"    'parked' "$out"

echo "--- the re-plan command compare's park note gives re-runs plan, then carries on (#11208) ---"
# A plan that called a change visible and named no screen state parks at compare,
# and the note says: build-ticket N --restart --steps plan && build-ticket N.
# Without --restart, a done plan is skipped and compare refuses again for ever.
reset_fakes "compare:24 0"
out=$(bt 130); rc=$?
want "the first walk stops at compare" "start size plan build fix compare" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
: > "$RAN"
out=$(bt 130 --restart --steps plan); rc=$?
want "the first half of the command runs plan again" "plan" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
: > "$RAN"
out=$(bt 130); rc=$?
want "and the second carries on from compare" "start compare self-check review record ship" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"

echo "--- --repair: the repair order, on the PR, with the brief on the record ---"
REPAIR_ORDER="reenter repair fix self-check review record ship"
reset_fakes
printf 'REPAIR on PR #9: CI went red on: unit\n' > "$FIX/brief-a.md"
out=$(bt 401 --repair "$FIX/brief-a.md"); rc=$?
want "it finishes"                         "0" "$rc"
want "the repair order ran, and nothing of the build's" "$REPAIR_ORDER" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "the record is in repair mode"        "repair" "$(driver_state_get 401 mode)"
want "the brief is kept on the record, verbatim" "REPAIR on PR #9: CI went red on: unit" "$(cat "$(driver_state_get 401 repair_brief)" 2>/dev/null)"
rm -f "$FIX/brief-a.md"
want "and outlives the spawner's file"     "REPAIR on PR #9: CI went red on: unit" "$(cat "$(driver_state_get 401 repair_brief)" 2>/dev/null)"

echo "--- --repair refuses a brief it cannot read ---"
reset_fakes
out=$(bt 402 --repair "$FIX/no-such-brief.md"); rc=$?
want "a missing brief is a config refusal" "2" "$rc"
want_in "naming the file"                  'no-such-brief.md' "$out"
want "and nothing ran"                     "" "$(cat "$RAN")"
: > "$FIX/empty-brief.md"
out=$(bt 402 --repair "$FIX/empty-brief.md"); rc=$?
want "an empty one too"                    "2" "$rc"

echo "--- the same brief resumes; a new brief is a new repair round ---"
reset_fakes "repair:24 0"
printf 'REPAIR on PR #9: it clashes with develop\n' > "$FIX/brief-b.md"
bt 403 --repair "$FIX/brief-b.md" >/dev/null; rc=$?
want "the first pass parks at repair"      "20" "$rc"
: > "$RAN"
bt 403 --repair "$FIX/brief-b.md" >/dev/null; rc=$?
want "the same brief resumes and finishes" "0" "$rc"
want "reenter re-checks, then it carries on from repair" "$REPAIR_ORDER" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
# A finished repair leaves a review answer and counters behind. The next repair must
# get its own review rounds and must not read the last one's findings.
mkdir -p "$(driver_state_dir 403)/steps"; printf '{"verdict":"SHIP","findings":[]}\n' > "$(driver_state_dir 403)/steps/review.json"
driver_state_bump 403 review; driver_state_bump 403 review; driver_state_set 403 repair_base deadbeef
: > "$RAN"
printf 'REPAIR on PR #9: CI went red on: e2e\n' > "$FIX/brief-c.md"
bt 403 --repair "$FIX/brief-c.md" >/dev/null; rc=$?
want "a new brief runs the whole repair order again" "$REPAIR_ORDER" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "the last repair's review answer is archived, not read" "no" "$([ -f "$(driver_state_dir 403)/steps/review.json" ] && echo yes || echo no)"
want "it is kept under steps/archive"      "1" "$(ls "$(driver_state_dir 403)"/steps/archive/*/review.json 2>/dev/null | grep -c .)"
want "the review rounds start again"       "0" "$(driver_state_count 403 review)"
want "the repair's starting head is cleared for reenter" "" "$(driver_state_get 403 repair_base)"
want "the record carries the new brief"    "REPAIR on PR #9: CI went red on: e2e" "$(cat "$(driver_state_get 403 repair_brief)")"

echo "--- a plain run is not in repair mode ---"
reset_fakes
bt 404 >/dev/null
want "the record says build"               "build" "$(driver_state_get 404 mode)"

echo "--- a rework in the repair order goes back to fix, not to a build step it lacks ---"
reset_fakes "review:30 0"
printf 'REPAIR on PR #9: red\n' > "$FIX/brief-d.md"
out=$(bt 405 --repair "$FIX/brief-d.md"); rc=$?
want "it finishes after the rework"        "0" "$rc"
want "fix, self-check and review ran again" "reenter repair fix self-check review fix self-check review record ship" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"

echo "--- the real repair order, one whole pass: a red PR fixed onto its own branch ---"
# The recorders above prove the order; this proves the wiring. The steps that ship,
# a real origin, the real claim lock, a PR branch that is red, and transcripts
# standing in only for the model. The agent's hands commit the fix in the tree
# reenter cut, so nothing in this case knows that tree's path in advance.
rm -rf "$STATE/driver"; mkdir -p "$STATE/driver"; : > "$GH_LOG"; : > "$CLAUDE_LOG"
SRC="$FIX/src210"; git clone -q -b develop "$FIX/origin" "$SRC"
git -C "$SRC" checkout -q -b tkt-210/work
printf '#!/usr/bin/env bash\ngrep -qx fixed "$(dirname "$0")/state.txt"\n' > "$SRC/check.sh"; printf 'broken\n' > "$SRC/state.txt"
git -C "$SRC" add . && git -C "$SRC" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: 210"
git -C "$SRC" push -q origin tkt-210/work
PR_HEAD=$(git -C "$SRC" rev-parse HEAD)
fix_issue 210 OPEN "status:in-review"
jq -n '[{number:61, headRefName:"tkt-210/work", headRefOid:"x", isDraft:false, mergeStateStatus:"CLEAN",
         statusCheckRollup:[{name:"unit", status:"COMPLETED", conclusion:"FAILURE"}]}]' > "$FIX/gh/prs.json"
: > "$FIX/pr-created-61"; printf '{"number":61,"isDraft":false,"body":"The PR as its author wrote it.\\n\\nCloses #210"}\n' > "$FIX/gh/pr-view.json"
fix_brief repair superpowers:systematic-debugging
cat > "$BIN/claude-hands" <<'SH'
#!/usr/bin/env bash
case " $* " in *" --name repair "*)
  printf 'fixed\n' > state.txt; git add state.txt
  git -c user.email=t@example.invalid -c user.name=T commit -qm "fix: the state" >/dev/null 2>&1 ;;
esac
exec "$BIN/claude" "$@"
SH
chmod +x "$BIN/claude-hands"
fix_ai repair '{"step":"repair","skills":["superpowers:systematic-debugging"],"status":"repaired","cause":"state.txt was never set","fixes":[{"what":"set it","proof":"gate","change":[{"path":"state.txt","action":"modify"}],"command":"bash check.sh","noTestBecause":"the fixture check is the test"}]}' \
  superpowers:systematic-debugging
printf 'REPAIR on PR #61 at %s: CI went red on: unit\n' "$PR_HEAD" > "$FIX/brief-210.md"
out=$(DRIVER_CLAUDE="$BIN/claude-hands" HARNESS_STATE_DIR="$STATE" bash "$BT" 210 --repair "$FIX/brief-210.md" 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
want "the real repair order finishes"      "0" "$rc"
want "every repair step is recorded"       "reenter,repair,fix,self-check,review,record,ship" "$(driver_state_get 210 'done|join(",")')"
want "the model ran for repair and review only" "repair review" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want "the fix reached the PR's own branch on origin" "fixed" "$(git -C "$FIX/origin" show tkt-210/work:state.txt 2>/dev/null)"
want "as a fast-forward of the PR's head"  "yes" "$(git -C "$FIX/origin" merge-base --is-ancestor "$PR_HEAD" tkt-210/work && echo yes)"
want_not_in "no new branch was cut"        'tkt-210/ticket-210' "$(git -C "$FIX/origin" branch --list 'tkt-210*')"
want_not_in "no new pull request"          'pr create' "$(cat "$GH_LOG")"
want_not_in "the PR's own words are kept"  'pr edit' "$(cat "$GH_LOG")"
want_in "the repair is said on the PR"     'pr comment 61 .*state.txt was never set' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "and it is handed off"             'pr merge tkt-210/work .*--auto' "$(cat "$GH_LOG")"
want "the trunk point it forked from is on the record" "$(git -C "$REPO" rev-parse develop)" "$(driver_state_get 210 claimed_at_sha)"
rm -f "$FIX/gh/pr-view.json"; printf '[]\n' > "$FIX/gh/prs.json"

echo "--- a repeated brief after a shipped repair is a NEW round, not a silent no-op ---"
# The empty-note brief and the merge lane's notes repeat word for word. Keyed on the
# brief alone, the next clash on a repaired PR ran reenter, said "nothing left to
# do", exited 0, left the queue, and the PR stayed red.
reset_fakes
pr_head() { jq -n --arg h "$1" '[{number:61, headRefName:"tkt-410/work", headRefOid:$h, isDraft:false, mergeStateStatus:"DIRTY"}]' > "$FIX/gh/prs.json"; }
pr_head h1
printf 'Merge lane: PR #61 left the lane — it clashes. Fix it on the PR branch.\n' > "$FIX/brief-e.md"
bt 410 --repair "$FIX/brief-e.md" >/dev/null; rc=$?
want "the first repair ships"                "0" "$rc"
: > "$RAN"; pr_head h2
out=$(bt 410 --repair "$FIX/brief-e.md"); rc=$?
want "the same words after a ship run the whole order again" "$REPAIR_ORDER" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_not_in "and never claim there is nothing to do" 'nothing left to do' "$out"
: > "$RAN"
bt 410 --repair "$FIX/brief-e.md" >/dev/null
want "even with the head unchanged, a shipped round is never resumed as done" "$REPAIR_ORDER" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"

echo "--- a parked repair whose PR head moved is a new round; an unmoved one resumes ---"
reset_fakes "repair:24 0"
jq -n '[{number:62, headRefName:"tkt-411/work", headRefOid:"p1", isDraft:false, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"
printf 'REPAIR on PR #62: red\n' > "$FIX/brief-f.md"
bt 411 --repair "$FIX/brief-f.md" >/dev/null
: > "$RAN"; rm -f "$FIX"/n.*; fake_step repair 24 0
bt 411 --repair "$FIX/brief-f.md" >/dev/null
want "unmoved: it resumes at repair"         "reenter repair" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
: > "$RAN"
printf '{"step":"repair","status":"park","question":"stale"}\n' > "$(driver_state_dir 411)/steps/repair.json"
jq -n '[{number:62, headRefName:"tkt-411/work", headRefOid:"p2", isDraft:false, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"
bt 411 --repair "$FIX/brief-f.md" >/dev/null
want "moved: a new round, the whole order"   "$REPAIR_ORDER" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "and the parked round's answers are archived" "no" "$([ -f "$(driver_state_dir 411)/steps/repair.json" ] && echo yes || echo no)"
printf '[]\n' > "$FIX/gh/prs.json"

echo "--- end to end: a repair interrupted mid-conflict never ships its markers ---"
# The chain review round 2 traced: the model call dies with the merge in progress,
# the park commits it markers and all, the next pass sees no merge and the trunk
# already in, calls nothing and ships the markers. Each link is closed; this walks
# the whole chain with the real steps.
rm -rf "$STATE/driver"; mkdir -p "$STATE/driver"; : > "$GH_LOG"; : > "$CLAUDE_LOG"
SRC="$FIX/src212"; git clone -q -b develop "$FIX/origin" "$SRC"
git -C "$SRC" checkout -q -b tkt-212/work
printf 'ours\n' > "$SRC/clash212.txt"; git -C "$SRC" add . && git -C "$SRC" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: 212"
git -C "$SRC" push -q origin tkt-212/work; PR_HEAD=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" checkout -q develop; printf 'theirs\n' > "$SRC/clash212.txt"; git -C "$SRC" add . && git -C "$SRC" -c user.email=t@example.invalid -c user.name=T commit -qm "trunk 212"
git -C "$SRC" push -q origin develop
fix_issue 212 OPEN "status:in-review"
jq -n --arg h "$PR_HEAD" '[{number:63, headRefName:"tkt-212/work", headRefOid:$h, isDraft:false, mergeStateStatus:"DIRTY", statusCheckRollup:[]}]' > "$FIX/gh/prs.json"
: > "$FIX/pr-created-63"; printf '{"number":63,"isDraft":false,"body":"As written."}\n' > "$FIX/gh/pr-view.json"
cat > "$BIN/claude-hands" <<'SH'
#!/usr/bin/env bash
case " $* " in *" --name repair "*)
  if [ -f "$FIX/hands-resolve" ]; then
    printf 'theirs\nours\n' > clash212.txt; git add clash212.txt
    git -c user.email=t@example.invalid -c user.name=T commit -q --no-edit >/dev/null 2>&1
  fi ;;
esac
exec "$BIN/claude" "$@"
SH
chmod +x "$BIN/claude-hands"
rm -f "$FIX/ai/repair.jsonl" "$FIX/hands-resolve"   # pass 1: the model call dies with no answer
printf 'REPAIR on PR #63: it clashes with develop\n' > "$FIX/brief-212.md"
out=$(DRIVER_CLAUDE="$BIN/claude-hands" HARNESS_STATE_DIR="$STATE" bash "$BT" 212 --repair "$FIX/brief-212.md" 2>&1); rc=$?
WT212=$(driver_state_get 212 worktree)
# A call that dies with no transcript is the machine, retried once and then parked as such.
want "pass 1 parks, as the machine"          "33" "$rc"
want "the park committed nothing"            "$PR_HEAD" "$(git -C "$WT212" rev-parse HEAD)"
want "the merge is left in progress"         "yes" "$([ -f "$(git -C "$WT212" rev-parse --git-path MERGE_HEAD)" ] && echo yes || echo no)"
want "origin still has the PR's head"        "$PR_HEAD" "$(git -C "$FIX/origin" rev-parse tkt-212/work)"
: > "$FIX/hands-resolve"
fix_ai repair '{"step":"repair","skills":["superpowers:systematic-debugging"],"status":"repaired","cause":"develop and the PR both wrote clash212.txt","conflicts":[{"file":"clash212.txt","resolution":"both lines kept"}],"fixes":[{"what":"resolved the merge","proof":"gate","change":[{"path":"clash212.txt","action":"modify"}],"command":"true","noTestBecause":"a merge resolution that only needed both lines"}]}' \
  superpowers:systematic-debugging
: > "$CLAUDE_LOG"
out=$(DRIVER_CLAUDE="$BIN/claude-hands" HARNESS_STATE_DIR="$STATE" bash "$BT" 212 --repair "$FIX/brief-212.md" 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
want "pass 2 resumes the merge and ships"    "0" "$rc"
want "the model was handed the merge again"  "repair review" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want "what reached origin is resolved"       "theirs ours" "$(git -C "$FIX/origin" show tkt-212/work:clash212.txt 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
want_not_in "and carries no marker"          '<<<<<<<|>>>>>>>' "$(git -C "$FIX/origin" show tkt-212/work:clash212.txt 2>/dev/null)"
want "the trunk is in the PR's branch"       "yes" "$(git -C "$FIX/origin" merge-base --is-ancestor develop tkt-212/work && echo yes)"
rm -f "$FIX/gh/pr-view.json" "$FIX/hands-resolve"; printf '[]\n' > "$FIX/gh/prs.json"

echo "--- --repair-class: a healing run with no note still repairs, never rebuilds ---"
reset_fakes
bt 420 --repair-class approved-merge >/dev/null; rc=$?
want "it finishes"                           "0" "$rc"
want "the repair order ran"                  "$REPAIR_ORDER" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_in "its brief names the class"          'approved-merge' "$(cat "$(driver_state_get 420 repair_brief)" 2>/dev/null)"
want "and says it came from no caller"       "class" "$(driver_state_get 420 repair_brief_source)"
out=$(bt 421 --repair-class nonsense); rc=$?
want "an unknown class refuses"              "2" "$rc"

echo "--- --brief: a repair when the ticket has an open PR, a build with the note when not ---"
reset_fakes
jq -n '[{number:64, headRefName:"tkt-422/work", headRefOid:"b1", isDraft:false, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"
printf 'The owner answered q2: keep the old copy.\n' > "$FIX/brief-g.md"
bt 422 --brief "$FIX/brief-g.md" >/dev/null; rc=$?
want "with an open PR it finishes"           "0" "$rc"
want "as a repair"                           "$REPAIR_ORDER" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "the brief is the caller's"             "caller" "$(driver_state_get 422 repair_brief_source)"
want "verbatim"                              "The owner answered q2: keep the old copy." "$(cat "$(driver_state_get 422 repair_brief)")"
reset_fakes; printf '[]\n' > "$FIX/gh/prs.json"
bt 423 --brief "$FIX/brief-g.md" >/dev/null; rc=$?
want "with no PR it finishes"                "0" "$rc"
want "as a build, every step of it"          "start size plan build fix compare self-check review record ship" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "the record says build"                 "build" "$(driver_state_get 423 mode)"
want "and keeps the note for every step"     "The owner answered q2: keep the old copy." "$(cat "$(driver_state_get 423 run_brief)" 2>/dev/null)"
reset_fakes; echo "open-prs" > "$FIX/gh-fail"
out=$(bt 424 --brief "$FIX/brief-g.md"); rc=$?
rm -f "$FIX/gh-fail"
want "an unreadable PR list refuses"         "2" "$rc"
want_in "naming why"                         'could not ask' "$out"
want "and nothing ran"                       "" "$(cat "$RAN")"
reset_fakes
bt 425 --repair "$FIX/brief-g.md" >/dev/null
want "a --repair brief is the caller's"      "caller" "$(driver_state_get 425 repair_brief_source)"

echo "--- a run's brief expires: a new repair round does not inherit a build's ---"
reset_fakes; printf '[]\n' > "$FIX/gh/prs.json"
printf 'The owner answered q6: no.\n' > "$FIX/brief-h.md"
bt 426 --brief "$FIX/brief-h.md" >/dev/null
printf 'REPAIR on PR #65: red\n' > "$FIX/brief-i.md"
bt 426 --repair "$FIX/brief-i.md" >/dev/null
want "the new repair round cleared it"      "" "$(driver_state_get 426 run_brief)"

echo "--- a --brief whose lookup keeps failing is retried, then put back on the queue with its note ---"
# The coordinator took the queue entry off when it spawned; an exit 2 here with the
# brief gone would lose an owner's answer.
reset_fakes; echo "open-prs" > "$FIX/gh-fail"; : > "$GH_LOG"
printf 'The owner answered q7: two columns.\n' > "$FIX/brief-j.md"
out=$(DRIVER_LOOKUP_RETRY_SEC=0 bt 427 --brief "$FIX/brief-j.md"); rc=$?
rm -f "$FIX/gh-fail"
want "it still refuses"                      "2" "$rc"
want "after asking three times"              "3" "$(grep -c 'OpenPullRequests' "$GH_LOG")"
want "the ticket is back on the queue"       "427" "$(jq -r '.tickets[]? | select(.n == 427) | .n' "$STATE/coordinator/queue.json" 2>/dev/null)"
want "with its note"                         "The owner answered q7: two columns." "$(jq -r '.tickets[]? | select(.n == 427) | .note' "$STATE/coordinator/queue.json" 2>/dev/null)"
want_in "and it says so"                     'back on the queue' "$out"
reset_fakes; printf '[]\n' > "$FIX/gh/prs.json"
echo "open-prs" > "$FIX/gh-once"
cat > "$BIN/gh-flaky" <<'SH'
#!/usr/bin/env bash
if [ -f "$FIX/gh-once" ] && case "$*" in *OpenPullRequests*) true ;; *) false ;; esac; then rm -f "$FIX/gh-once"; echo "flake" >&2; exit 1; fi
exec "$BIN/gh" "$@"
SH
chmod +x "$BIN/gh-flaky"
SWARM_GH="$BIN/gh-flaky" DRIVER_LOOKUP_RETRY_SEC=0 bt 428 --brief "$FIX/brief-j.md" >/dev/null; rc=$?
want "one failed lookup, then an answer: it runs" "0" "$rc"

echo "--- a brief over 4 KB is cut, says so, and keeps the whole of it beside ---"
reset_fakes; printf '[]\n' > "$FIX/gh/prs.json"
head -c 6000 /dev/zero | tr '\0' 'x' > "$FIX/brief-big.md"
bt 429 --brief "$FIX/brief-big.md" >/dev/null
RB=$(driver_state_get 429 run_brief)
want "what the steps read is capped"         "yes" "$([ "$(wc -c < "$RB")" -lt 4400 ] && echo yes || echo "no ($(wc -c < "$RB"))")"
want_in "with a notice a reader sees"        'brief was 6000 bytes' "$(cat "$RB")"
want "and the whole brief is kept"           "6000" "$(wc -c < "${RB%.md}.full.md" 2>/dev/null | tr -d ' ')"

echo "--- an answered BUILD park resumes the build, PR or no PR — never a repair ---"
# A person-cause park during a build opens a draft PR. The answer comes back with a
# brief (or as a repair class, when the requeue saw the PR). Routed on the PR it ran
# reenter·repair·…·ship and skipped compare (only a person sanctions a deviation) and
# the build's own proof, then readied and armed the PR. The record decides.
BUILD_TAIL="start compare self-check review record ship"
park_at_compare() { # <ticket> — a build parked at compare, with the draft PR its park opened
  reset_fakes "compare:20 0"
  bt "$1" >/dev/null
  jq -n --arg b "tkt-$1/work" '[{number:70, headRefName:$b, headRefOid:"d1", isDraft:true, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"
  : > "$RAN"
}
printf 'The owner answered q8: the deviation is approved.\n' > "$FIX/brief-k.md"
park_at_compare 501
want "fixture: the build parked at compare"  "start,size,plan,build,fix" "$(driver_state_get 501 'done|join(",")')"
out=$(bt 501 --brief "$FIX/brief-k.md"); rc=$?
want "--brief: it finishes"                  "0" "$rc"
want "--brief: the build resumes at compare, ship only after it" "$BUILD_TAIL" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_not_in "--brief: no reenter, no repair" 'reenter|repair' "$(cat "$RAN")"
want "--brief: the record stays a build"     "build" "$(driver_state_get 501 mode)"
want "--brief: with the answer for every step" "The owner answered q8: the deviation is approved." "$(cat "$(driver_state_get 501 run_brief)" 2>/dev/null)"
park_at_compare 502
bt 502 --repair-class repair >/dev/null
want "--repair-class: the build resumes at compare" "$BUILD_TAIL" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
park_at_compare 503
bt 503 --repair "$FIX/brief-k.md" >/dev/null
want "--repair: the build resumes at compare" "$BUILD_TAIL" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "--repair: the brief becomes the build's" "The owner answered q8: the deviation is approved." "$(cat "$(driver_state_get 503 run_brief)" 2>/dev/null)"
reset_fakes "compare:20"
bt 504 >/dev/null
jq -n '[{number:71, headRefName:"tkt-504/work", headRefOid:"d2", isDraft:true, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"; : > "$RAN"
bt 504 --brief "$FIX/brief-k.md" >/dev/null; rc=$?
want "compare still refusing: it parks again" "20" "$rc"
want_not_in "and ship never runs"            'ship' "$(cat "$RAN")"

echo "--- a SHIPPED build's PR still goes to repair ---"
reset_fakes; bt 505 >/dev/null
jq -n '[{number:72, headRefName:"tkt-505/work", headRefOid:"s1", isDraft:false, mergeStateStatus:"DIRTY"}]' > "$FIX/gh/prs.json"; : > "$RAN"
bt 505 --brief "$FIX/brief-k.md" >/dev/null
want "a shipped build with a PR: the repair order" "$REPAIR_ORDER" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
printf '[]\n' > "$FIX/gh/prs.json"

echo "--- a stale record does not outrank the live PR: a fresh repair round from origin ---"
# The record outranks the PR only while it is that PR's: the same branch, still the
# draft its park opened, its head inside the record's work. A person or /claim moved
# on, and resuming the old build would rebuild over their work.
park_at_compare 511
jq -n '[{number:73, headRefName:"tkt-511/work", headRefOid:"d1", isDraft:false, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"
out=$(bt 511 --repair-class repair); rc=$?
want "a PR made ready since: the repair order" "$REPAIR_ORDER" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_in "and it says the record is stale"      'record is stale.*ready' "$out"
want "the old record is kept aside"            "1" "$(ls -d "$STATE/driver/511.stale-"* 2>/dev/null | wc -l | tr -d ' ')"
park_at_compare 512
driver_state_set 512 branch tkt-512/work
jq -n '[{number:74, headRefName:"tkt-512-other", headRefOid:"d1", isDraft:true, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"
out=$(bt 512 --repair-class repair); rc=$?
want_in "a PR on another branch: stale"        'record is stale.*tkt-512/work.*tkt-512-other' "$out"
park_at_compare 513
git -C "$REPO" commit -q --allow-empty -m "somebody else's commit"
moved=$(git -C "$REPO" rev-parse HEAD); git -C "$REPO" reset -q --hard HEAD~1
driver_state_set 513 worktree "$REPO"
jq -n --arg h "$moved" '[{number:75, headRefName:"tkt-513/work", headRefOid:$h, isDraft:true, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"
out=$(bt 513 --repair-class repair); rc=$?
want_in "a PR head the record never saw: stale" 'record is stale.*moved since' "$out"
park_at_compare 514
driver_state_set 514 worktree "$REPO"
jq -n --arg h "$(git -C "$REPO" rev-parse HEAD)" '[{number:76, headRefName:"tkt-514/work", headRefOid:$h, isDraft:true, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"
out=$(bt 514 --repair-class repair); rc=$?
want "the record's own draft at its own head: the build resumes" "$BUILD_TAIL" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_not_in "and is not called stale"          'stale' "$out"

echo "--- a draft PR the driver never built is adopted, never repaired and never sent to prose ---"
reset_fakes; rm -rf "$STATE/coordinator"
jq -n '[{number:77, headRefName:"tkt-515-x", headRefOid:"p1", isDraft:true, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"
printf 'Coordinator note (repair): REPAIR on PR #77: red\n' > "$FIX/brief-m.md"
out=$(bt 515 --repair "$FIX/brief-m.md"); rc=$?
want "a repair sent to it finishes as an adoption" "0" "$rc"
want "the adoption walks the repair order, gates and review before ship" "$REPAIR_ORDER" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_in "and says it adopts"                   'adopting it' "$out"
want "the record is marked adopted"            "0" "$(driver_adopted 515; echo $?)"
want "its brief source is adopt"               "adopt" "$(driver_state_get 515 repair_brief_source)"
want_in "the adoption brief names the draft"   '^Adopted: #515 .*draft the driver did not build' "$(cat "$(driver_state_get 515 repair_brief)")"
want_in "and carries the coordinator's note, unwrapped" 'REPAIR on PR #77: red' "$(cat "$(driver_state_get 515 repair_brief)")"
want "nothing went back on the queue for prose" "" "$(jq -r '.tickets[]? | select(.n == 515) | .n' "$STATE/coordinator/queue.json" 2>/dev/null)"
reset_fakes; rm -rf "$STATE/coordinator"
out=$(bt 515 --repair-class repair); rc=$?
want "a class run on it is adopted too"        "0" "$rc"
want "on the repair order"                     "$REPAIR_ORDER" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "and marked adopted"                      "0" "$(driver_adopted 515; echo $?)"
reset_fakes
out=$(bt 515 --adopt); rc=$?
want "--adopt with no brief finishes"          "0" "$rc"
want "and walks the repair order"              "$REPAIR_ORDER" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
_ab1=$(cat "$(driver_state_get 515 repair_brief)")
: > "$RAN"; out=$(bt 515 --adopt); rc=$?
want "a second --adopt on the same draft resumes on the same brief" "$_ab1" "$(cat "$(driver_state_get 515 repair_brief)")"
echo "--- an adoption is per run: a later repair of the PR it shipped is a plain repair ---"
reset_fakes
jq -n '[{number:77, headRefName:"tkt-515-x", headRefOid:"p2", isDraft:false, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"
bt 515 --adopt >/dev/null
printf 'REPAIR on PR #77: red again\n' > "$FIX/brief-m2.md"
bt 515 --repair "$FIX/brief-m2.md" >/dev/null
want "the record is no longer adopted"         "1" "$(driver_adopted 515; echo $?)"
want "the brief is the caller's"               "caller" "$(driver_state_get 515 repair_brief_source)"
echo "--- --adopt on a ticket whose record holds the driver's own unshipped build resumes that build ---"
park_at_compare 516
driver_state_set 516 worktree "$REPO"
jq -n --arg h "$(git -C "$REPO" rev-parse HEAD)" '[{number:78, headRefName:"tkt-516/work", headRefOid:$h, isDraft:true, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"
out=$(bt 516 --adopt); rc=$?
want "the build resumes, not an adoption"      "$BUILD_TAIL" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "and the record is not adopted"           "1" "$(driver_adopted 516; echo $?)"
printf '[]\n' > "$FIX/gh/prs.json"

echo "--- a new repair round starts its red counters at zero ---"
reset_fakes
jq -n '[{number:79, headRefName:"tkt-518/work", headRefOid:"r1", isDraft:false, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"
printf 'REPAIR on PR #79: red\n' > "$FIX/brief-o.md"
bt 518 --repair "$FIX/brief-o.md" >/dev/null
driver_state_bump 518 selfcheck_red; driver_state_bump 518 push_red
printf 'REPAIR on PR #79: red again\n' > "$FIX/brief-p.md"
bt 518 --repair "$FIX/brief-p.md" >/dev/null
want "the self-check red count is the round's" "0" "$(driver_state_count 518 selfcheck_red)"
want "and so is the refused-push count"        "0" "$(driver_state_count 518 push_red)"
printf '[]\n' > "$FIX/gh/prs.json"

echo "--- a brief put back on the queue is not wrapped twice ---"
reset_fakes; rm -rf "$STATE/coordinator"; echo "open-prs" > "$FIX/gh-fail"
printf 'Coordinator note (new): The owner answered q9: yes.\n' > "$FIX/brief-n.md"
DRIVER_LOOKUP_RETRY_SEC=0 bt 516 --brief "$FIX/brief-n.md" >/dev/null
rm -f "$FIX/gh-fail"
want "the note is the caller's words alone"    "The owner answered q9: yes." "$(jq -r '.tickets[]? | select(.n == 516) | .note' "$STATE/coordinator/queue.json" 2>/dev/null)"

echo "--- the open PRs come from the shared copy while it is young ---"
reset_fakes; jq -n '[{number:78, headRefName:"tkt-517-x", isDraft:false}]' > "$FIX/gh/prs.json"; : > "$GH_LOG"; rm -f "$STATE/swarm/prs.json"
( . "$HERE/../driver-env.sh"; DRIVER_PRS_MAX_AGE=300; driver_open_prs_for 517 >/dev/null; driver_open_prs_for 517 >/dev/null )
want "two reads, one call to GitHub"           "1" "$(grep -c 'OpenPullRequests' "$GH_LOG")"
printf '[]\n' > "$FIX/gh/prs.json"
echo "--- a question goes to whoever owns its answer: the PM for ticket shape, the owner otherwise ---"
# Every question used to park as the owner's: three of them on 2026-10-17/18 asked
# which repo a change belonged in, and each sat in the owner's sign-off queue. The
# step says who answers in `questionFor`; anything but `pm` is the owner's, because
# an unclassified question in the PM's lane is one the owner never sees.
ask_case() { # <ticket> <questionFor-or-empty>
  reset_fakes "plan:20"
  mkdir -p "$STATE/driver/$1/steps"
  jq -nc --arg f "$2" '{step:"plan", status:"park", question:"which repo does this belong in?"}
      + (if $f == "" then {} else {questionFor:$f} end)' > "$STATE/driver/$1/steps/plan.json"
  bt "$1" >/dev/null
  sed -n 's/.*| cause=//p' "$FIX/park.log" | tail -1
}
want "a pm question parks for the PM"            "pm"     "$(ask_case 140 pm)"
want "an owner question parks for the owner"     "person" "$(ask_case 141 owner)"
want "an unclassified question is the owner's"   "person" "$(ask_case 142 "")"
want "and so is a classification it cannot read" "person" "$(ask_case 143 "the PM, probably")"

echo "--- a resume re-plans when the ticket body changed since the plan ---"
# A resumed run reused its stored plan after the PM edited the ticket and re-ran
# tasks the PM had removed. The body read when the plan ran is hashed onto the
# record; a different body on resume sends the walk back to plan.
body_issue() { # <n> <body>
  mkdir -p "$FIX/gh"
  jq -n --arg n "$1" --arg b "$2" '{number:($n|tonumber), title:"t", state:"OPEN",
      labels:[{name:"status:ready"}], body:$b}' > "$FIX/gh/issue-$1.json"
}
reset_fakes "build:24 0"
body_issue 144 "first version of the ticket"
bt 144 >/dev/null
want "the first walk parks after the plan" "start size plan build" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
: > "$RAN"
body_issue 144 "the PM removed a task"
out=$(bt 144); rc=$?
want "an edited ticket is planned again" "start plan build fix compare self-check review record ship" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_in "and the run says why" 'changed since it was planned' "$out"

reset_fakes "build:24 0"
body_issue 145 "the same ticket"
bt 145 >/dev/null
: > "$RAN"
out=$(bt 145); rc=$?
want "an unchanged ticket keeps its plan" "start build fix compare self-check review record ship" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"

echo "--- GitHub unreadable at start: the ticket is left ready, never parked ---"
# 2026-10-19: the open-PR read 504'd every tick, start refused (24) and every ticket
# it reached was parked. The real start and park, so the label edit is what is read.
rm -f "$STATE/swarm/prs.json"; echo "open-prs" > "$FIX/gh-fail"; : > "$GH_LOG"
fix_issue 150 OPEN "status:ready"
out=$(DRIVER_LOOKUP_RETRY_SEC=0 bash "$BT" 150 2>&1); rc=$?
rm -f "$FIX/gh-fail"
want "it stops as unread"                      "26" "$rc"
want_not_in "and nothing is labelled parked"   'status:parked' "$(cat "$GH_LOG")"
want_not_in "or opened as a draft"             '^pr create' "$(cat "$GH_LOG")"
want_in "and it says the next tick tries again" 'next tick' "$out"
reset_fakes "reenter:26"; rm -rf "$STATE/coordinator"
printf 'REPAIR on PR #80: red\n' > "$FIX/brief-u.md"
bt 151 --repair "$FIX/brief-u.md" >/dev/null; rc=$?
want "a repair that cannot read its PR stops as unread" "26" "$rc"
want "without parking"                         "" "$(cat "$FIX/park.log")"
want "and its brief is back on the queue"      "REPAIR on PR #80: red" "$(jq -r '.tickets[]? | select(.n == 151) | .note' "$STATE/coordinator/queue.json" 2>/dev/null)"

echo "--- a claim another run holds is busy: requeued, never parked, and left alone ---"
# #13139 and #13146 (2026-10-19) parked as "reenter left no reason on the record":
# another run on this host held the claim. That clears when the holder ends.
reset_fakes "reenter:29"; rm -rf "$STATE/coordinator"
CLK="$HERE/../../scripts/claim-lock.sh"
bash "$CLK" acquire 152 --branch tkt-152/theirs --worktree "$FIX/theirs-152" >/dev/null 2>&1
printf 'REPAIR on PR #81: red\n' > "$FIX/brief-v.md"
out=$(bt 152 --repair "$FIX/brief-v.md"); rc=$?
want "it ends as a requeue"                    "28" "$rc"
want "without parking"                         "" "$(cat "$FIX/park.log")"
want_in "saying it is not parked"              'requeued.*not parked' "$out"
want "and its brief is back on the queue"      "REPAIR on PR #81: red" "$(jq -r '.tickets[]? | select(.n == 152) | .note' "$STATE/coordinator/queue.json" 2>/dev/null)"
want "the holder's claim is not released"      "$FIX/theirs-152" "$(bash "$CLK" show 152 2>/dev/null | jq -r '.worktree // ""')"
DRIVER_MAX_BUSY_REQUEUES=1 bt 152 --repair "$FIX/brief-v.md" >/dev/null; rc=$?
want "past its cap it parks"                   "20" "$rc"
want_in "saying how many runs it waited"       'reenter could not go on for 1 requeued runs in a row' "$(cat "$FIX/park.log")"
bash "$CLK" release 152 --force >/dev/null 2>&1

echo "--- a question about a claim another run holds is a requeue, not a PM park (#319) ---"
# #13191 (2026-10-20): "a peer holds the claim on #13191. Never adopt a live claim."
# parked as status:pm-decision. Nobody can answer a claim; the holder ends or the
# reconciler frees it, so it goes back on the queue as a step's DRIVER_E_BUSY does.
claim_q_case() { # <ticket> <question> <questionFor>
  reset_fakes "plan:20"; rm -rf "$STATE/coordinator"
  mkdir -p "$STATE/driver/$1/steps"
  jq -nc --arg q "$2" --arg f "$3" '{step:"plan", status:"park", question:$q, questionFor:$f}' \
    > "$STATE/driver/$1/steps/plan.json"
}
bash "$CLK" acquire 153 --branch tkt-153/theirs --worktree "$FIX/theirs-153" --pid $$ >/dev/null 2>&1
claim_q_case 153 "a peer holds the claim on #153. Never adopt a live claim." pm
out=$(bt 153); rc=$?
want "it ends as a requeue, as a step's 29 does"   "28" "$rc"
want "nothing parks"                               "" "$(cat "$FIX/park.log")"
want_not_in "no pm-decision label goes on"         'pm-decision|status:parked' "$(cat "$GH_LOG")"
want_in "saying it is not parked"                  'requeued.*not parked' "$out"
want_in "the question is the requeue's reason"     'peer holds the claim on #153' "$(driver_state_get 153 requeued)"
want "the ticket is back on the queue"             "153" "$(jq -r '.tickets[]? | select(.n == 153) | .n' "$STATE/coordinator/queue.json" 2>/dev/null)"
want "the holder's claim is not released"          "$FIX/theirs-153" "$(bash "$CLK" show 153 2>/dev/null | jq -r '.worktree // ""')"
bash "$CLK" release 153 --force >/dev/null 2>&1

claim_q_case 154 "which repo does this belong in?" pm
bt 154 >/dev/null; rc=$?
want "a real PM question still parks"              "20" "$rc"
want_in "as the PM's"                              'asked a question rather than guessing \| which repo does this belong in\? \| cause=pm' "$(cat "$FIX/park.log")"

echo "--- a repair that meets another run's claim is requeued with that claim kept (#319) ---"
reset_fakes; rm -rf "$STATE/coordinator"
{ echo '#!/usr/bin/env bash'
  echo 'driver_step_repair() { printf "%s\n" repair >> "$RAN"; driver_state_set "$1" claim_elsewhere 1; driver_state_set "$1" park_note "another run on this host holds the claim on #$1"; return "$DRIVER_E_BUSY"; }'
} > "$FAKE/repair.sh"
bash "$CLK" acquire 155 --branch tkt-155/theirs --worktree "$FIX/theirs-155" --pid $$ >/dev/null 2>&1
printf 'REPAIR on PR #82: red\n' > "$FIX/brief-w.md"
out=$(bt 155 --repair "$FIX/brief-w.md"); rc=$?
want "it ends as a requeue"                        "28" "$rc"
want "without parking"                             "" "$(cat "$FIX/park.log")"
want "the holder's claim is not released"          "$FIX/theirs-155" "$(bash "$CLK" show 155 2>/dev/null | jq -r '.worktree // ""')"
want "the keep-claim note is read once and cleared" "" "$(driver_state_get 155 claim_elsewhere)"
bash "$CLK" release 155 --force >/dev/null 2>&1

echo "--- a repair with nothing to repair ends the run clean: no park, no later step (#358) ---"
# The repair step returns 32 only when it has read the PR afresh and found it up to date,
# mergeable, with nothing red and auto-merge armed. Nothing after it has work to do.
reset_fakes "repair:32"; rm -rf "$STATE/coordinator"; : > "$GH_LOG"
printf 'REPAIR on PR #83: the clash\n' > "$FIX/brief-x.md"
out=$(bt 156 --repair "$FIX/brief-x.md"); rc=$?
want "it exits 0"                                  "0" "$rc"
want "no step after the repair runs"               "reenter repair" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "nothing parks"                               "" "$(cat "$FIX/park.log")"
want_not_in "no owner or PM label goes on"         'owner-decision|pm-decision|status:parked|needs:human' "$(cat "$GH_LOG")"
want_in "it says there was nothing to repair"      'nothing to repair' "$out"
: > "$RAN"
out=$(bt 156 --repair "$FIX/brief-x.md"); rc=$?
want "the same brief again is a fresh round, read afresh, never a resumed ship" "0" "$rc"
want "so the repair checks again and nothing else runs" "reenter repair" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "and still nothing parks"                     "" "$(cat "$FIX/park.log")"

echo "--- a repair whose PR merged under it ends clean at ship, saying so ---"
reset_fakes "ship:32"; rm -rf "$STATE/coordinator"; : > "$GH_LOG"
driver_state_init 157; driver_state_set 157 noop_note "PR #84 merged at 2026-10-21T07:14:34Z while it was being repaired; nothing left to do"
printf 'REPAIR on PR #84: red\n' > "$FIX/brief-y.md"
out=$(bt 157 --repair "$FIX/brief-y.md"); rc=$?
want "it exits 0"                                  "0" "$rc"
want "nothing parks"                               "" "$(cat "$FIX/park.log")"
want_in "it says the PR merged"                    'merged at 2026-10-21T07:14:34Z while it was being repaired' "$out"
want_not_in "not that the ticket stays in review"  'stays in review' "$out"

echo "--- a step asking whether to re-run a subagent that had not reported is the machine's park ---"
# The sibling of review's own retry: any step's "the subagent had not reported, run again?"
reset_fakes "fix:20"
mkdir -p "$STATE/driver/170/steps"
jq -nc '{step:"fix", status:"park", question:"The fix subagent had not reported when this step was told to return. Should the fix step run again?"}' \
  > "$STATE/driver/170/steps/fix.json"
: > "$GH_LOG"
out=$(bt 170); rc=$?
want "the run's exit says machine"           "33" "$rc"
want_in "the park says machine fault"        'PARK machine fault: a fix subagent had not reported' "$(cat "$FIX/park.log")"
want_in "and it is the driver's"             'cause=driver' "$(cat "$FIX/park.log")"
want_not_in "no owner or PM label goes on"   'needs:owner|pm-decision|human-approval' "$(cat "$GH_LOG")"
want_in "and the log line names the fault"   'machine fault agent-silent' "$out"

suite_end "$FAILED"
