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
  for s in start plan build self-check review record ship; do fake_step "$s" 0; done
  local pair
  for pair in "$@"; do fake_step "${pair%%:*}" "${pair#*:}"; done
}
bt() { DRIVER_STEPS_DIR="$FAKE" bash "$BT" "$@" 2>&1; }

echo "--- every step runs, in the declared order ---"
reset_fakes
out=$(bt 101); rc=$?
want "it finishes"        "0" "$rc"
want "all seven ran once" "start plan build self-check review record ship" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_in "and it says so"  'shipped|finished|done' "$out"

echo "--- and each one is recorded as finished ---"
export HARNESS_STATE_DIR="$STATE"
. "$HERE/../state.sh" || exit 1
want "the record lists them in order" "start,plan,build,self-check,review,record,ship" \
  "$(driver_state_get 101 'done|join(",")')"

echo "--- nothing is lost on a stop: a resumed run picks up where it stopped ---"
# `plan` refuses the first time, so the run parks after `start`. The second run
# must not re-run `start` — that is the whole difference between resuming and
# restarting, and re-running start is what re-takes a claim and re-cuts a tree.
reset_fakes "plan:24 0"
bt 102 >/dev/null; rc=$?
want "the first run refuses"      "20" "$rc"
want "it got as far as plan"      "start plan" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "start is recorded finished" "start" "$(driver_state_get 102 'done|join(",")')"
: > "$RAN"
out=$(bt 102); rc=$?
want "the second run finishes"    "0" "$rc"
want_not_in "start did not run again" '^start$' "$(cat "$RAN")"
want "it resumed at plan"         "plan build self-check review record ship" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_in "and says what it skipped" 'resum|already' "$out"

echo "--- --restart runs the lot again ---"
: > "$RAN"
out=$(bt 102 --restart); rc=$?
want "it finishes"            "0" "$rc"
want "every step ran again"   "start plan build self-check review record ship" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"

echo "--- a refusal parks, with the reason, and does not fall through ---"
reset_fakes "self-check:24"
out=$(bt 103); rc=$?
want "the run stops"                 "20" "$rc"
want "it stopped AT the refusal"     "start plan build self-check" "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want_not_in "review never ran"       'review' "$(cat "$RAN")"
want_in "it parked"                  'PARK' "$(cat "$FIX/park.log")"
want_in "naming the step"            'self-check' "$(cat "$FIX/park.log")"

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

echo "--- a review that finds blockers sends the work back to the build ---"
# BLOCKED on round 1, clean on round 2: build, self-check and review all run
# twice, and `record` and `ship` still run once at the end.
reset_fakes "review:30 0"
out=$(bt 106); rc=$?
want "it finishes"  "0" "$rc"
want "the rework repeats build, self-check and review" \
  "start plan build self-check review build self-check review record ship" \
  "$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
want "and plan was not repeated" "1" "$(grep -c '^plan$' "$RAN")"
want_in "it says it is a rework round" 'rework|again|round' "$out"

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
reset_fakes
bt 110 >/dev/null
: > "$RAN"
out=$(bt 110); rc=$?
want "it finishes"           "0" "$rc"
want "nothing ran again"     "" "$(tr -d '\n' < "$RAN")"
want_in "and it says so"     'nothing left|already' "$out"

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
: > "$GH_LOG"
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

fix_ai plan '{"step":"plan","skills":["superpowers:writing-plans"],"status":"ok","files":["feature.txt"],"tests":[{"file":"t/check.sh"}]}' \
  superpowers:writing-plans
fix_ai build "$(jq -nc --arg ts "$TSHA" --arg is "$ISHA" \
  '{step:"build", skills:["superpowers:subagent-driven-development"], status:"ok",
    items:[{id:"1", test_file:"t/check.sh", test_command:"bash t/check.sh",
            test_commit:$ts, impl_commit:$is}]}')" \
  superpowers:subagent-driven-development
fix_ai review '{"step":"review","skills":["superpowers:requesting-code-review"],"status":"ok","verdict":"SHIP","blockers":[]}' \
  superpowers:requesting-code-review

# The claim the start step re-enters through, and the worktree it works in.
driver_state_init "$TICKET" --worktree "$WT" --branch "tkt-$TICKET/work"
out=$(HARNESS_STATE_DIR="$STATE" bash "$BT" "$TICKET" 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
want "the real seven finish"        "0" "$rc"
# The branch on the record is the branch that ships. A second name here would put
# the worktree, the commits and the pull request on three different branches.
want "start kept the branch it was given" "tkt-$TICKET/work" "$(driver_state_get "$TICKET" branch)"
want "every one is recorded"        "start,plan,build,self-check,review,record,ship" \
  "$(driver_state_get "$TICKET" 'done|join(",")')"
want_in "the plan named its Skill and the log showed it" 'superpowers:writing-plans ran' "$out"
want_in "the build proved red before green" 'red .*then green' "$out"
want_in "the gates were read by exit code"  'gate\(s\) green' "$out"
want "the branch really reached origin"     "1" \
  "$(git -C "$FIX/origin" rev-parse --verify "tkt-$TICKET/work" >/dev/null 2>&1 && echo 1)"
want_in "the pull request opened as a draft" 'pr create.*--draft' "$(cat "$GH_LOG")"
want_in "and was marked ready once reviewed" 'pr ready' "$(cat "$GH_LOG")"
want "the verdict recorded is the reviewer's" "SHIP" "$(driver_state_get "$TICKET" review_verdict)"

echo "--- the real steps park a real refusal: a skipped Skill is not a pass ---"
# The same transcript with the Skill call removed. Nothing else changes, so what
# this measures is the check and not the shape of the answer.
rm -rf "$STATE/driver"; mkdir -p "$STATE/driver"
fix_ai plan '{"step":"plan","skills":[],"status":"ok","files":["feature.txt"],"tests":[{"file":"t/check.sh"}]}'
driver_state_init 202 --worktree "$WT" --branch "tkt-$TICKET/work"
fix_issue 202 OPEN "status:ready"
out=$(HARNESS_STATE_DIR="$STATE" bash "$BT" 202 2>&1); rc=$?
want "it stops"                    "20" "$rc"
want_in "because the Skill never ran" 'does not contain that Skill call' "$out"
want_in "and the ticket is parked"    'parked' "$out"

exit $FAILED
