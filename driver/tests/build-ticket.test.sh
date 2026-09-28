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
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
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
    echo 'driver_park() { printf "PARK %s | %s\n" "$2" "${3:-}" >> "$FIX/park.log"; return 20; }'
  } > "$FAKE/park.sh"
}
reset_fakes() { # <exit-code-plan…>  — plan is "step:codes" pairs
  rm -rf "$FAKE" "$STATE/driver"; mkdir -p "$FAKE" "$STATE/driver"
  : > "$RAN"; : > "$FIX/park.log"; rm -f "$FIX"/n.*
  fake_park
  local s
  for s in start plan build fix compare self-check review record ship; do fake_step "$s" 0; done
  local pair
  for pair in "$@"; do fake_step "${pair%%:*}" "${pair#*:}"; done
}
bt() { DRIVER_STEPS_DIR="$FAKE" bash "$BT" "$@" 2>&1; }

echo "--- every step runs, in the declared order ---"
reset_fakes
out=$(bt 101); rc=$?
want "it finishes"        "0" "$rc"
want "all nine ran once" "start plan build fix compare self-check review record ship" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_in "and it says so"  'shipped|finished|done' "$out"

echo "--- and each one is recorded as finished ---"
export HARNESS_STATE_DIR="$STATE"
. "$HERE/../state.sh" || exit 1
want "the record lists them in order" "start,plan,build,fix,compare,self-check,review,record,ship" \
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
want "it got as far as plan"      "start plan" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "start is recorded finished" "start" "$(driver_state_get 102 'done|join(",")')"
: > "$RAN"
out=$(bt 102); rc=$?
want "the second run finishes"    "0" "$rc"
want_in "start ran again — it is the re-entry check" '^start$' "$(cat "$RAN")"
want "and nothing else was repeated" "start plan build fix compare self-check review record ship" \
  "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "and plan ran in the resumed run" "1" "$(grep -c '^plan$' "$RAN")"
# NOTHING was skipped in that run and it correctly says nothing: start re-ran as the
# re-entry check, and plan onwards had never finished. The skip line belongs to a run
# that really skipped something, which the next case builds.
want_not_in "it claims no skipping it did not do" 'were already finished' "$out"

echo "--- a run that really does skip says how many, not counting the re-entry check ---"
reset_fakes "build:24 0"
bt 119 >/dev/null
want "start and plan finished" "start,plan" "$(driver_state_get 119 'done|join(",")')"
: > "$RAN"
out=$(bt 119); rc=$?
want "it finishes"                     "0" "$rc"
want_in "and counts the one real skip" 'resumed: 1 step\(s\)' "$out"
want_in "start ran again all the same" '^start$' "$(cat "$RAN")"

echo "--- --restart runs the lot again ---"
: > "$RAN"
out=$(bt 102 --restart); rc=$?
want "it finishes"            "0" "$rc"
want "every step ran again"   "start plan build fix compare self-check review record ship" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"

echo "--- a refusal parks, with the reason, and does not fall through ---"
reset_fakes "self-check:24"
out=$(bt 103); rc=$?
want "the run stops"                 "20" "$rc"
want "it stopped AT the refusal"     "start plan build fix compare self-check" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_not_in "review never ran"       'review' "$(cat "$RAN")"
want_in "it parked"                  'PARK' "$(cat "$FIX/park.log")"
want_in "naming the step"            'self-check' "$(cat "$FIX/park.log")"

echo "--- a note a step left behind becomes the question the park asks ---"
# A refusal's exit code says which check said no; it cannot say WHAT. A step that knows
# — what a review graded critical or major, a follow-up that could not be filed — leaves the text
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
want "it stopped AT the refusal"     "start plan build fix compare self-check" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_not_in "review never ran"       'review' "$(cat "$RAN")"
want_in "it parked"                  'PARK' "$(cat "$FIX/park.log")"
want_in "naming the step"            'self-check' "$(cat "$FIX/park.log")"

echo "--- a note a step left behind becomes the question the park asks ---"
# A refusal's exit code says which check said no; it cannot say WHAT. A step that knows
# — what a review graded critical or major, a follow-up that could not be filed — leaves the text
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

echo "--- a review that grades something critical or major sends the work back to FIX ---"
# BLOCKED on round 1, clean on round 2. It goes back to `fix` — the only step that
# reads review.json — not to `build`, which would re-run the original plan task
# blind to what the reviewer just found. That was T2-3: the two-round ceiling
# bounded a loop that could not act on anything.
reset_fakes "review:30 0"
out=$(bt 106); rc=$?
want "it finishes"  "0" "$rc"
want "the rework repeats fix, compare, the gates and review" \
  "start plan build fix compare self-check review fix compare self-check review record ship" \
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
if [ "$rounds" -le 8 ]; then ok "it stopped after $rounds rounds, not more"; else bad "ran $rounds rework rounds — the ceiling did not hold"; fi

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
want "every one is recorded"        "start,plan,build,fix,compare,self-check,review,record,ship" \
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

exit $FAILED
