#!/usr/bin/env bash
# trial2.test.sh — the ten findings the second shadow run measured, each with a
# case that fails without its fix.
#
# Like real-briefs.test.sh and for the same reason, the briefs, the contracts and
# the examples here are the ones THAT SHIP. Five of the first trial's Criticals
# hid behind a fixture writing both sides of the seam it was testing, and T2-1 hid
# behind the same thing again: `notInvoked` was a real key in the real
# briefs/facts.json that no fixture ever wrote and no code ever read.
#
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT

jq '.gates = {"local": ["echo lint-ok"]}
    | .worktreeRoot = "'"$FIX"'/trees"
    | .commit = {"parkType": "chore"}' \
  "$REPO/.claude/harness.json" > "$FIX/h.json" && mv "$FIX/h.json" "$REPO/.claude/harness.json"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "a project that says where its worktrees go"
git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop

fix_real_briefs
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../push-requires.sh" || exit 1
. "$HERE/../steps/park.sh" || exit 1
. "$HERE/../steps/start.sh" || exit 1
. "$HERE/../steps/plan.sh" || exit 1
. "$HERE/../steps/fix.sh" || exit 1
. "$HERE/../steps/compare.sh" || exit 1
. "$HERE/../steps/ship.sh" || exit 1

REAL_BRIEFS="$KIT/briefs"
PLAN_OK=$(jq -c . "$REAL_BRIEFS/examples/plan.valid.json")
PLAN_SKILLS=$(jq -r '.skills | join(" ")' "$REAL_BRIEFS/examples/plan.valid.json")

echo "--- T2-1 · a skill that is never a tool call does not park the ticket ---"
# What ended the 73-minute run. build task 3 of 6 answered
# ["superpowers:using-superpowers", …] and the claim check demanded to see a Skill
# call for a skill that arrives in the SYSTEM PROMPT. Tasks 1 and 2 did not name
# it and passed: a coin flip on the model's phrasing, unrelated to the work.
want_in "the real briefs declare it as never invoked" 'superpowers:using-superpowers' \
  "$(driver_never_invoked_skills | tr '\n' ' ')"
fix_issue 401 OPEN "status:ready"
driver_state_init 401
export DRIVER_TICKET=401
CLAIMS_INTRO=$(jq -c '.skills = ["superpowers:using-superpowers","superpowers:writing-plans"]' \
                 "$REAL_BRIEFS/examples/plan.valid.json")
fix_ai plan "$CLAIMS_INTRO" "superpowers:writing-plans"
rc=0; out=$(driver_ai_step 401 plan 2>&1) || rc=$?
want "naming Superpowers' own introduction is accepted" "0" "$rc"
want_not_in "and nothing accuses it of a skipped Skill" 'using-superpowers' "$out"
# THE CONTROL. A skill that IS a tool call and is absent from the log still refuses,
# so the case above measures the notInvoked list and not a check that stopped working.
CLAIMS_REAL=$(jq -c '.skills = ["superpowers:writing-plans","superpowers:systematic-debugging"]' \
                "$REAL_BRIEFS/examples/plan.valid.json")
fix_ai plan "$CLAIMS_REAL" "superpowers:writing-plans"
rc=0; out=$(driver_ai_step 401 plan 2>&1) || rc=$?
want "a claimed skill the transcript never shows still refuses" "21" "$rc"
want_in "and names it" 'systematic-debugging' "$out"
want_in "and the park's question is about the CLAIM, not about the brief" \
  'claims' "$(driver_state_get 401 park_note)"

echo "--- T2-5 · STANDARDS says there is none rather than naming the design law ---"
# The build step was told this project's coding standard is
# docs/design/design-philosophy.md, because `standards` fell back to `law`. A wrong
# document cannot be seen from inside a prompt; an absence can.
jq '.law = "docs/design/design-philosophy.md" | del(.standards)' \
  "$REPO/.claude/harness.json" > "$FIX/h2.json" && mv "$FIX/h2.json" "$REPO/.claude/harness.json"
want_not_in "no standards key means no design law stands in for one" \
  'design-philosophy' "$(driver_fact_standards)"
want_in "it says so instead" 'names no standards document' "$(driver_fact_standards)"
want_in "and the design law is still the SCREEN rules" \
  'design-philosophy' "$(driver_fact_surface_rules)"
jq '.standards = "docs/CODING_STANDARDS.md"' \
  "$REPO/.claude/harness.json" > "$FIX/h3.json" && mv "$FIX/h3.json" "$REPO/.claude/harness.json"
want "and a project that names one gets that one" "docs/CODING_STANDARDS.md" "$(driver_fact_standards)"

echo "--- T2-8 · a plan can record that a picture was approved ---"
# #10867's picture was approved on 2026-09-28 and the plan had to answer
# `ticket-body`, because the enum had no value for the one fact this project's
# process turns on.
PIC=$(jq -c '.designSource = "approved-picture"
             | .designRef = "https://github.com/acme/widgets/issues/401#issuecomment-1"' \
        "$REAL_BRIEFS/examples/plan.valid.json")
fix_ai plan "$PIC" "$PLAN_SKILLS"
rc=0; out=$(driver_step_plan 401 2>&1) || rc=$?
want "an approved picture is a plan this driver accepts" "0" "$rc"
want "and the source is recorded" "approved-picture" "$(driver_state_get 401 design_source)"
want_in "with what it points at"  'issuecomment-1' "$(driver_state_get 401 design_ref)"
# THE CONTROL: claiming one without saying where is refused by the contract.
PIC_BARE=$(jq -c '.designSource = "approved-picture"' "$REAL_BRIEFS/examples/plan.valid.json")
fix_ai plan "$PIC_BARE" "$PLAN_SKILLS"
rc=0; out=$(driver_step_plan 401 2>&1) || rc=$?
want "a picture with no reference is refused" "22" "$rc"
want_in "by the contract that carries the rule" 'designRef' "$out"

echo "--- T2-9 · the programme brief resolves without a working tree ---"
# PROGRAMMES_DIR is ${REPO_ROOT:+…} and REPO_ROOT is EMPTY for a bare clone, so
# every step on the trial was told "this project keeps no programme state
# directory" while the run's own worktree held 29 of them.
# NAMED BY EPIC NUMBER, WITH THE LABEL IN THE BODY — which is how the project this
# was measured on writes them: all 29 of its files are `state-<epic>.md` and the
# programme is a `**Label:**` line inside. A fixture that invents
# `state-one-desk.md` is a suite green about a feature that resolves nothing.
mkdir -p "$REPO/docs/programmes"
printf '# Programme #10011\n\n**Label:** `project:one-desk`\n\nlocked: one room\n' \
  > "$REPO/docs/programmes/state-10011.md"
printf '# Programme #9000\n\n**Label:** `project:echo`\n\nlocked: no video\n' \
  > "$REPO/docs/programmes/state-9000.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "programme state files"
fix_issue 402 OPEN "status:ready,project:one-desk"
driver_state_init 402
SAVED_PD="${PROGRAMMES_DIR:-}"; PROGRAMMES_DIR=""
out=$(driver_fact_programme 402 2>&1)
PROGRAMMES_DIR="$SAVED_PD"
want_not_in "a bare clone is not told the directory does not exist" \
  'keeps no programme state directory' "$out"
want_in "it names the file for THIS programme"  'state-10011.md' "$out"
want_not_in "and not another programme's"       'state-9000.md' "$out"
# AND NOT ANY MARKDOWN THAT HAPPENS TO CARRY THE NAME.
printf 'notes about one-desk\n' > "$REPO/docs/programmes/one-desk-notes.md"
fix_issue 412 OPEN "status:ready,project:nothing-here"
driver_state_init 412
SAVED_PD="${PROGRAMMES_DIR:-}"; PROGRAMMES_DIR=""
out2=$(driver_fact_programme 412 2>&1)
PROGRAMMES_DIR="$SAVED_PD"
want_not_in "a programme with no state file gets no other programme's" '\.md' "$out2"
want_in "and is told how many are there" 'state file' "$out2"

echo "--- and the brief is the BRIEF when this project has something that prints one ---"
# These files are append-only and grow for as long as the programme is open; a step
# handed the whole thing designs from the programme's history rather than from its
# own ticket.
printf '#!/usr/bin/env sh\necho "TLDR: one room, and the gap map is closed"\n' > "$FIX/brief.sh"
chmod +x "$FIX/brief.sh"
jq --arg c "$FIX/brief.sh {{EPIC}}" '.programmes = {"brief": $c}' \
  "$REPO/.claude/harness.json" > "$FIX/hp.json" && mv "$FIX/hp.json" "$REPO/.claude/harness.json"
SAVED_PD="${PROGRAMMES_DIR:-}"; PROGRAMMES_DIR=""
out3=$(driver_fact_programme 402 2>&1)
PROGRAMMES_DIR="$SAVED_PD"
want_in "the brief command ran for this programme's epic" 'one room, and the gap map' "$out3"
jq 'del(.programmes)' "$REPO/.claude/harness.json" > "$FIX/hq.json" && mv "$FIX/hq.json" "$REPO/.claude/harness.json"

echo "--- T2-10 · the step's working plan is kept out of the change ---"
# park.sh's `git add -A -- .` swept a 1,361-line superpowers plan into the parked
# commit and created docs/superpowers on a branch of a repo that has no such
# directory.
WT="$FIX/wt403"
git -C "$REPO" worktree add -q "$WT" -b "tkt-403/work" develop
mkdir -p "$WT/docs/superpowers/plans"
printf 'the working plan\n' > "$WT/docs/superpowers/plans/2026-09-28-a.md"
printf 'the real change\n'  > "$WT/feature.txt"
driver_state_init 403 --worktree "$WT" --branch "tkt-403/work"
driver_sweep_scratch 403 "$WT" >/dev/null
want "the plan is gone from the worktree" "" \
  "$(ls "$WT/docs/superpowers" 2>/dev/null)"
want "and kept where a person can read it" "1" \
  "$(grep -rl 'the working plan' "$(driver_state_dir 403)/scratch" 2>/dev/null | grep -c .)"
want "the change itself is untouched" "the real change" "$(cat "$WT/feature.txt")"
# EVERY SWEEP KEEPS ITS OWN. A fixed destination made the second sweep delete the
# first step's plan, which is "moved, not deleted" doing the deleting.
mkdir -p "$WT/docs/superpowers/plans"
printf 'the second working plan\n' > "$WT/docs/superpowers/plans/2026-09-28-b.md"
driver_sweep_scratch 403 "$WT" >/dev/null
want "the first sweep's plan survives the second" "1" \
  "$(grep -rl 'the working plan' "$(driver_state_dir 403)/scratch" 2>/dev/null | grep -c .)"
want "and the second is kept too" "1" \
  "$(grep -rl 'the second working plan' "$(driver_state_dir 403)/scratch" 2>/dev/null | grep -c .)"
# A TRACKED PATH IS THE CHANGE. If the project genuinely keeps files there, sweeping
# them would be deleting the work.
git -C "$WT" -c user.email=t@e.invalid -c user.name=T rm -q --cached -r . >/dev/null 2>&1 || true
mkdir -p "$WT/docs/superpowers"
printf 'this project really keeps one\n' > "$WT/docs/superpowers/kept.md"
git -C "$WT" add -f docs/superpowers/kept.md
git -C "$WT" -c user.email=t@e.invalid -c user.name=T commit -qm "docs: a real file there"
driver_sweep_scratch 403 "$WT" >/dev/null
want "a tracked path is left alone" "this project really keeps one" \
  "$(cat "$WT/docs/superpowers/kept.md" 2>/dev/null)"
# AND NEVER THE SHARED CHECKOUT. The tree a step runs in falls back to the shared
# clone when this run has none on the record, and that clone is where peer windows
# work — sweeping there moves another agent's untracked files out from under them.
mkdir -p "$REPO/docs/superpowers/plans"
printf "a peer window's plan\n" > "$REPO/docs/superpowers/plans/peer.md"
rm -rf "$STATE/driver/411"; fix_issue 411 OPEN "status:ready"
driver_state_init 411
export DRIVER_TICKET=411
fix_ai plan "$PLAN_OK" "$PLAN_SKILLS"
driver_ai_step 411 plan >/dev/null 2>&1
want "a step with no worktree of its own does not sweep the shared checkout" \
  "a peer window's plan" "$(cat "$REPO/docs/superpowers/plans/peer.md" 2>/dev/null)"
rm -rf "$REPO/docs/superpowers"

echo "--- T2-6 · a park leaves a status label ---"
# #10867's timeline at 2026-09-28T10:29:58Z: status:claimed off, the hold on,
# status:parked never applied — so it carried no status label at all and dropped
# out of every status-keyed board.
fix_issue 404 OPEN "status:claimed"
git -C "$REPO" worktree add -q "$FIX/wt404" -b "tkt-404/work" develop
printf 'work\n' > "$FIX/wt404/w.txt"
driver_state_init 404 --worktree "$FIX/wt404" --branch "tkt-404/work"
: > "$GH_LOG"
driver_park 404 "a refusal a person must answer" "which is it?" person >/dev/null 2>&1
want_in "the ticket is marked parked" 'add-label status:parked' "$(cat "$GH_LOG")"
want_in "and a question adds the hold a person clears" 'add-label needs:human-approval' "$(cat "$GH_LOG")"

echo "--- T2-7 · a park the driver caused does not hide behind a human-only label ---"
# #10907's needs:human-approval was applied by trial 1's park, whose cause was the
# kit's own defect. Trial 2 then refused at `start` in 40 seconds, 0 of 7 steps,
# because an agent clearing an approval label to unblock itself is the one thing
# AGENTS forbids. Nobody was ever going to clear it: nobody knew it was there.
fix_issue 405 OPEN "status:claimed"
git -C "$REPO" worktree add -q "$FIX/wt405" -b "tkt-405/work" develop
printf 'work\n' > "$FIX/wt405/w.txt"
driver_state_init 405 --worktree "$FIX/wt405" --branch "tkt-405/work"
: > "$GH_LOG"
out=$(driver_park 405 "the answer did not meet its contract" "is the brief in step?" driver 2>&1)
want_in "it is still marked parked"       'add-label status:parked' "$(cat "$GH_LOG")"
want_not_in "and the hold is NOT applied" 'needs:human-approval' "$(cat "$GH_LOG")"
want_in "the brief says nobody has to answer it" 'Needs:\*\* nothing from you' "$(cat "$GH_LOG")"
# AND IT DOES NOT ALSO ASK. The diagnostic is real and useful; printed under
# "Needs:" it read as a question somebody must answer, one line above a Resume
# line saying nobody has to.
want_in "the diagnostic is kept, under its own heading" 'What stopped it' "$(cat "$GH_LOG")"
want_not_in "and is not what the ticket is said to need" \
  'Needs:\*\* is the brief in step' "$(cat "$GH_LOG")"
# And the driver can pick it up again itself.
fix_issue 405 OPEN "status:parked"
rc=0; out=$(driver_step_start 405 2>&1) || rc=$?
want "a parked ticket is resumable"  "0" "$rc"
fix_issue 406 OPEN "status:parked,needs:human-approval"
driver_state_init 406
rc=0; out=$(driver_step_start 406 2>&1) || rc=$?
want "and a hold still stops one"    "24" "$rc"
want_in "saying a person owns it"    'needs:human-approval' "$out"

echo "--- the worktree is cut where the project says, not in \$TMPDIR ---"
# macOS prunes /var/folders, and between the build and the push the tree is the
# only copy of the work: the trial ended with 9 commits inside one.
rm -rf "$STATE/driver/407"; fix_issue 407 OPEN "status:ready"
driver_state_init 407
rc=0; driver_step_start 407 >/dev/null 2>&1 || rc=$?
want "start finishes" "0" "$rc"
NEW_WT=$(driver_state_get 407 worktree)
want_in "and the tree is under the project's worktreeRoot" "^$FIX/trees/" "$NEW_WT"

echo "--- a park whose push is refused still leaves the work durable ---"
# The push IS the handover, and this project's own pre-push can refuse one — on
# 2026-09-28 the UI attestation gate did, and 9 commits stayed in a worktree the
# system prunes.
PWT=$(driver_state_get 407 worktree)
printf 'nine commits worth\n' > "$PWT/w.txt"
git -C "$PWT" add -A
git -C "$PWT" -c user.email=t@e.invalid -c user.name=T commit -qm "feat: the work"
# A pre-push that refuses, exactly as check:ui-gate-attested does. `core.hooksPath`
# is set to a RELATIVE directory, which resolves per worktree — `rev-parse
# --git-path hooks` returns the COMMON hooks directory, so writing there would have
# made every other worktree in this suite unable to push too.
mkdir -p "$PWT/.drvhooks"
printf '#!/usr/bin/env sh\necho "x check:ui-gate-attested — no matching verdict" >&2\nexit 1\n' > "$PWT/.drvhooks/pre-push"
chmod +x "$PWT/.drvhooks/pre-push"
git -C "$PWT" config core.hooksPath .drvhooks
: > "$GH_LOG"
out=$(driver_park 407 "a gate refused the push" "" driver 2>&1)
want_in "the park says the push failed" 'could not be pushed' "$out"
want_in "and bundles the commits"       'bundled at' "$out"
BUNDLE=$(printf '%s' "$out" | grep -o "$FIX/trees/backups/[^ ]*\.bundle" | head -1)
want "the bundle is a real file" "1" "$([ -s "$BUNDLE" ] && echo 1)"
git -C "$REPO" fetch -q "$BUNDLE" 'tkt-407*:refs/restored' 2>/dev/null \
  || git -C "$REPO" bundle verify "$BUNDLE" >/dev/null 2>&1
want "and git reads it back" "0" "$?"

echo "--- T2-3 · the fix step is a no-op until a review has found something ---"
fix_issue 408 OPEN "status:claimed"
git -C "$REPO" worktree add -q "$FIX/wt408" -b "tkt-408/work" develop
driver_state_init 408 --worktree "$FIX/wt408" --branch "tkt-408/work"
: > "$CLAUDE_LOG"
rc=0; out=$(driver_step_fix 408 2>&1) || rc=$?
want "with no review it finishes"        "0" "$rc"
want_in "saying there is nothing to fix" 'nothing to fix' "$out"
want "and starts no agent"               "0" "$(grep -c . "$CLAUDE_LOG")"
printf '%s\n' '{"step":"review","skills":[],"status":"reviewed","round":1,"verdict":"SHIP","findings":[{"id":"F1","file":"a.ts","line":2,"grade":"minor","summary":"spacing","reason":"polish","fix":"nudge"}]}' \
  > "$(driver_state_dir 408)/steps/review.json"
rc=0; out=$(driver_step_fix 408 2>&1) || rc=$?
want "a review with only minors is nothing to fix either" "0" "$rc"
want "and still starts no agent" "0" "$(grep -c . "$CLAUDE_LOG")"

echo "--- T2-3 · a rework round is SENT the findings ---"
# briefs/fix.md carried {{BLOCKERS}} and nothing ever sent it anything:
# `grep -rn BLOCKERS driver/` was empty outside the tests.
printf '%s\n' '{"step":"review","skills":[],"status":"reviewed","round":1,"verdict":"BLOCKED","findings":[{"id":"F9","file":"apps/web/save.tsx","line":41,"grade":"critical","summary":"the save button calls nothing","reason":"a person loses their work and is told it saved","fix":"wire onClick to the mutation"}]}' \
  > "$(driver_state_dir 408)/steps/review.json"
# The fix answer names two commits, the way the build step's does, so the driver
# can re-run its test rather than take the claim.
WT8="$FIX/wt408"
mkdir -p "$WT8/t"
cat > "$WT8/t/save.sh" <<'SH'
#!/usr/bin/env bash
grep -q 'wired' "$(dirname "$0")/../save.txt" 2>/dev/null
SH
git -C "$WT8" add t/save.sh
git -C "$WT8" -c user.email=t@e.invalid -c user.name=T commit -qm "test: the save button is wired"
TS8=$(git -C "$WT8" rev-parse HEAD)
printf 'wired\n' > "$WT8/save.txt"
git -C "$WT8" add save.txt
git -C "$WT8" -c user.email=t@e.invalid -c user.name=T commit -qm "fix: wire it"
IS8=$(git -C "$WT8" rev-parse HEAD)
fix_ai fix "$(jq -nc --arg ts "$TS8" --arg is "$IS8" \
  '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
    cleared:[{blockerId:"F9",
              change:[{path:"apps/web/save.tsx", action:"modify"}],
              test:{file:"t/save.sh", behaviour:"the save button calls the mutation",
                    redWhen:"the onClick handler is removed"},
              command:"bash t/save.sh", testCommit:$ts, implCommit:$is,
              failedBefore:true, passedAfter:true}]}')" \
  superpowers:receiving-code-review
rc=0; out=$(driver_step_fix 408 2>&1) || rc=$?
want "the fix round finishes"  "0" "$rc"
PROMPT="$(driver_state_dir 408)/steps/fix.prompt"
want "no placeholder survives into the fix prompt" "0" "$(grep -c '{{' "$PROMPT" || true)"
want_in "the finding reaches the fixer verbatim" 'the save button calls nothing' "$(cat "$PROMPT")"
want_in "with its grade"                         'critical' "$(cat "$PROMPT")"
want_in "and the reviewer's proposed fix"        'wire onClick to the mutation' "$(cat "$PROMPT")"
want_in "and it was proved red before green"     'red .*then green' "$out"

echo "--- T2-3 · a fix whose test is green before the fix is refused ---"
# The same defect the build step exists to catch, reached one round later.
fix_ai fix "$(jq -nc --arg ts "$TS8" --arg is "$IS8" \
  '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
    cleared:[{blockerId:"F9",
              change:[{path:"apps/web/save.tsx", action:"modify"}],
              test:{file:"t/save.sh", behaviour:"anything", redWhen:"nothing"},
              command:"true", testCommit:$ts, implCommit:$is,
              failedBefore:true, passedAfter:true}]}')" \
  superpowers:receiving-code-review
rc=0; out=$(driver_step_fix 408 2>&1) || rc=$?
want "a test that passes without the fix refuses" "24" "$rc"
want_in "and says so"  'passes without the change' "$out"

echo "--- T2-3 · a blocker nobody answered is not a clean round ---"
fix_ai fix "$(jq -nc --arg ts "$TS8" --arg is "$IS8" \
  '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
    cleared:[{blockerId:"F-other",
              change:[{path:"x.ts", action:"modify"}],
              test:{file:"t/save.sh", behaviour:"anything", redWhen:"nothing"},
              command:"bash t/save.sh", testCommit:$ts, implCommit:$is,
              failedBefore:true, passedAfter:true}]}')" \
  superpowers:receiving-code-review
rc=0; out=$(driver_step_fix 408 2>&1) || rc=$?
want "an unanswered blocker refuses" "24" "$rc"
want_in "naming it"                  'F9' "$out"

echo "--- T2-3 · a deferred blocker is a person's call, not the driver's ---"
# The contract has a `deferred` shape and the brief tells the fixer to use it, so
# a fixer that disagrees with a grade is answering legitimately. It is not the
# driver's to settle: parked as the driver's own the ticket resumes unattended and
# the next round is free to defer it again.
driver_state_set 408 park_cause ""
fix_ai fix "$(jq -nc --arg ts "$TS8" --arg is "$IS8" \
  '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
    cleared:[{blockerId:"F9",
              change:[{path:"apps/web/save.tsx", action:"modify"}],
              test:{file:"t/save.sh", behaviour:"the save button calls the mutation",
                    redWhen:"the onClick handler is removed"},
              command:"bash t/save.sh", testCommit:$ts, implCommit:$is,
              failedBefore:true, passedAfter:true}],
    deferred:[{blockerId:"F9", reason:"the control is dead on develop too",
               followUp:"filed as its own ticket"}]}')" \
  superpowers:receiving-code-review
rc=0; out=$(driver_step_fix 408 2>&1) || rc=$?
want "a deferred blocker refuses"  "24" "$rc"
want_in "saying a blocker is not deferrable" 'not deferrable' "$out"
want "and it is a park only a person can answer" "person" "$(driver_state_get 408 park_cause)"

echo "--- T2-4 · compare says what it did, and sets the renders the reviewer reads ---"
# `driver_state_get renders` was read in review.sh:95 and set nowhere, so RENDERS
# was "(none)" on every screen ticket there has ever been.
fix_issue 409 OPEN "status:claimed"
git -C "$REPO" worktree add -q "$FIX/wt409" -b "tkt-409/work" develop
driver_state_init 409 --worktree "$FIX/wt409" --branch "tkt-409/work"
rc=0; out=$(driver_step_compare 409 2>&1) || rc=$?
want "with no surfacePaths declared it finishes" "0" "$rc"
want_in "and says the project told it nothing"   'no design.surfacePaths' "$out"
want_in "which is what the reviewer is told too" 'no design.surfacePaths' "$(driver_state_get 409 renders)"

jq '.design = {"surfacePaths": ["apps/web/**"]}' \
  "$REPO/.claude/harness.json" > "$FIX/h4.json" && mv "$FIX/h4.json" "$REPO/.claude/harness.json"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "what this project calls a screen"
git -C "$REPO" push -q origin develop
git -C "$FIX/wt409" fetch -q origin develop
printf 'not a screen\n' > "$FIX/wt409/server.txt"
git -C "$FIX/wt409" add -A
git -C "$FIX/wt409" -c user.email=t@e.invalid -c user.name=T commit -qm "feat: backend only"
rc=0; out=$(driver_step_compare 409 2>&1) || rc=$?
want "a change touching no screen finishes"   "0" "$rc"
want_in "and says which it was"               'touches no screen' "$out"

mkdir -p "$FIX/wt409/apps/web/src/app"
printf 'a screen\n' > "$FIX/wt409/apps/web/src/app/page.tsx"
git -C "$FIX/wt409" add -A
git -C "$FIX/wt409" -c user.email=t@e.invalid -c user.name=T commit -qm "feat: a screen"
# FROM A DIRECTORY THAT ITSELF HAS AN apps/web. The pathspec has to reach git
# UNEXPANDED: unquoted it is glob-expanded against the DRIVER'S cwd, and measured
# in a real checkout `packages/ui/**` became six top-level entries — so a file two
# levels down matched nothing and a screen change was reported as touching no
# screen. Run from the fixture repo, which has no apps/web, the bug is invisible.
# The decoy's apps/web holds a DIFFERENT subdirectory from the worktree's. Expanded
# there, `apps/web/**` becomes `apps/web/legacy` — a path the change does not touch —
# so the screen change matches nothing and is reported as touching no screen. A decoy
# whose layout happens to agree with the worktree's hides this completely.
mkdir -p "$FIX/decoy/apps/web/legacy"
: > "$FIX/decoy/apps/web/legacy/old.tsx"
rc=0; out=$(cd "$FIX/decoy" && driver_step_compare 409 2>&1) || rc=$?
want "a screen change with no renderer still finishes" "0" "$rc"
want_in "but says NOBODY OBSERVED IT"  'NOBODY OBSERVED THIS SCREEN' "$(driver_state_get 409 renders)"
want_in "naming the screen file"       'apps/web/src/app/page.tsx' "$(driver_state_get 409 renders)"
want_not_in "and not a file from the directory the driver happened to be in" \
  'legacy' "$(driver_state_get 409 renders)"

echo "--- T2-4 · surfacePaths are git pathspecs: an exclude drops test files (#11206) ---"
git -C "$REPO" worktree add -q "$FIX/wt415" -b "tkt-415/work" develop
driver_state_init 415 --worktree "$FIX/wt415" --branch "tkt-415/work"
fix_issue 415 OPEN "status:claimed"
mkdir -p "$FIX/wt415/apps/web/src"
printf 'a test\n' > "$FIX/wt415/apps/web/src/thing.test.ts"
git -C "$FIX/wt415" add -A
git -C "$FIX/wt415" -c user.email=t@e.invalid -c user.name=T commit -qm "test: only a test"
jq '.design = {"surfacePaths": ["apps/web/**", ":(exclude)**/*.test.ts"]}' \
  "$REPO/.claude/harness.json" > "$FIX/h5e.json" && mv "$FIX/h5e.json" "$REPO/.claude/harness.json"
rc=0; out=$(driver_step_compare 415 2>&1) || rc=$?
want "a test-only change finishes"      "0" "$rc"
want_in "as touching no screen"          'touches no screen' "$out"
jq '.design = {"surfacePaths": [":(exclude)**/*.test.ts"]}' \
  "$REPO/.claude/harness.json" > "$FIX/h5e.json" && mv "$FIX/h5e.json" "$REPO/.claude/harness.json"
rc=0; out=$(driver_step_compare 415 2>&1) || rc=$?
want "a list of only excludes refuses"   "24" "$rc"
want_in "saying git would read it as everything" 'only exclude pathspecs' "$out"
jq '.design = {"surfacePaths": [":(exclude,glob)**/*.test.ts", ""]}' \
  "$REPO/.claude/harness.json" > "$FIX/h5e.json" && mv "$FIX/h5e.json" "$REPO/.claude/harness.json"
rc=0; out=$(driver_step_compare 415 2>&1) || rc=$?
want "so does a long-form exclude beside a blank entry" "24" "$rc"
jq '.design = {"surfacePaths": ["apps/web/**"]}' \
  "$REPO/.claude/harness.json" > "$FIX/h5e.json" && mv "$FIX/h5e.json" "$REPO/.claude/harness.json"

echo "--- T2-4 · a declared renderer that produces nothing is a refusal ---"
# A measurement that could not be made is not a screen that is fine.
jq '.design.render = "sh -c \"echo the dev server is not up >&2; exit 7\""' \
  "$REPO/.claude/harness.json" > "$FIX/h5.json" && mv "$FIX/h5.json" "$REPO/.claude/harness.json"
rc=0; out=$(driver_step_compare 409 2>&1) || rc=$?
want "it refuses"             "24" "$rc"
want_in "naming the exit code" 'exited 7' "$out"
want_in "and the park note says the screen was never observed" \
  'never observed' "$(driver_state_get 409 park_note)"

echo "--- T2-4 · exit 3 is a renderer that knows no screen here, not a failure ---"
# The project's renderer registers some screens, not every file its surface paths
# cover. A change outside them is not a broken renderer — it is an absence, said
# loudly, exactly as a project with no renderer at all.
jq '.design.render = "sh -c \"echo no registered surface covers these files >&2; exit 3\""' \
  "$REPO/.claude/harness.json" > "$FIX/h5b.json" && mv "$FIX/h5b.json" "$REPO/.claude/harness.json"
driver_state_set 409 park_note ""
rc=0; out=$(driver_step_compare 409 2>&1) || rc=$?
want "it finishes"                     "0" "$rc"
want_in "saying no render was taken"   'knows no screen' "$out"
want_in "and the reviewer is told NOBODY OBSERVED IT, in the renderer's words" \
  'NOBODY OBSERVED THIS SCREEN.*no registered surface' "$(driver_state_get 409 renders)"
want "and nothing was parked"          "" "$(driver_state_get 409 park_note)"

echo "--- T2-4 · no approved picture: renders kept, no parity check, no park (#11205) ---"
# A debugged change has no picture. Asked to compare anyway, the step listed "no
# approved picture exists" as a difference that stands and parked every bug fix for
# a person, whatever its renders showed.
jq '.design.render = "printf \"desk light\\tshots/a.png\\tlight\\t/dashboard/desk\\n\""' \
  "$REPO/.claude/harness.json" > "$FIX/h5c.json" && mv "$FIX/h5c.json" "$REPO/.claude/harness.json"
driver_state_set 409 design_ref ""
driver_state_set 409 design_source debugged
driver_state_set 409 park_note ""
: > "$CLAUDE_LOG"
rc=0; out=$(driver_step_compare 409 2>&1) || rc=$?
want "it finishes"                       "0" "$rc"
want_in "saying there is nothing to compare against" 'no approved picture' "$out"
want_not_in "and not claiming a parity check"        'parity against' "$out"
want "no model was asked"                "" "$(grep -x compare "$CLAUDE_LOG")"
want_in "the renders are kept for review" 'shots/a.png' "$(driver_state_get 409 renders)"
want "and nothing was parked"            "" "$(driver_state_get 409 park_note)"
driver_state_set 409 design_source approved-picture
rc=0; out=$(driver_step_compare 409 2>&1) || rc=$?
want "a plan claiming a picture it never named refuses" "24" "$rc"
want_in "saying skipping would hide it"  'names none' "$out"
driver_state_set 409 design_source debugged
driver_state_set 409 park_note ""

echo "--- T2-4 · the plan's screen states reach the renderer (#11208) ---"
# A page's standard shots rarely show the state a change touches. The plan names
# the state; the renderer gets it, as JSON, to capture exactly that.
jq '.design.render = "sh -c '"'"'printf \"ticket light\\tshots/t.png\\tlight\\t%s\\n\" \"$DRIVER_RENDER_STATES\"'"'"'"' \
  "$REPO/.claude/harness.json" > "$FIX/h5s.json" && mv "$FIX/h5s.json" "$REPO/.claude/harness.json"
driver_state_set 409 design_ref ""
driver_state_set 409 design_source debugged
driver_state_set 409 park_note ""
driver_state_set 409 screen_states '[{"route":"/dashboard/desk","setup":["open the X tab"],"shows":"the footer names 280 once"}]'
rc=0; out=$(driver_step_compare 409 2>&1) || rc=$?
want "it finishes"                       "0" "$rc"
want_in "the renderer was handed the states" 'the footer names 280 once' "$(driver_state_get 409 renders)"

echo "--- T2-4 · a renderer that takes steps, and a plan that named no state, refuses ---"
jq '.design.renderSteps = "click the \"<name>\" <role>"' \
  "$REPO/.claude/harness.json" > "$FIX/h5s.json" && mv "$FIX/h5s.json" "$REPO/.claude/harness.json"
driver_state_set 409 screen_states '[]'
: > "$CLAUDE_LOG"
rc=0; out=$(driver_step_compare 409 2>&1) || rc=$?
want "it refuses"                        "24" "$rc"
want_in "saying the plan named no state"  'named no screen state' "$out"
want_in "and the park says re-run the plan" 're-run the plan step' "$(driver_state_get 409 park_note)"
driver_state_set 409 screen_states '[{"route":"/dashboard/desk","setup":["click the \"Save\" button"],"shows":"saved"}]'
rc=0; driver_step_compare 409 >/dev/null 2>&1 || rc=$?
want "with a state named it runs"        "0" "$rc"

echo "--- T2-4 · SCREEN_STEPS is the project's vocabulary, inline or from a file ---"
want_in "inline"  'click the "<name>" <role>' "$(driver_fact_screen_steps 409)"
printf '# steps\n- click the "<name>" <role>\n' > "$FIX/wt409/render-steps.md"
jq '.design.renderSteps = "render-steps.md"' \
  "$REPO/.claude/harness.json" > "$FIX/h5s.json" && mv "$FIX/h5s.json" "$REPO/.claude/harness.json"
want_in "or the file it names, read from the ticket's tree" '# steps' "$(driver_fact_screen_steps 409)"
jq 'del(.design.renderSteps)' \
  "$REPO/.claude/harness.json" > "$FIX/h5s.json" && mv "$FIX/h5s.json" "$REPO/.claude/harness.json"
want_in "absent, it says the renderer takes none" 'takes no setup steps' "$(driver_fact_screen_steps 409)"
rm -f "$FIX/wt409/render-steps.md"
driver_state_set 409 park_note ""

echo "--- T2-4 · with renders it compares against what was approved ---"
jq '.design.render = "printf \"desk light\\tshots/a.png\\tlight\\t/dashboard/desk\\ndesk dark\\tshots/b.png\\tdark\\t/dashboard/desk\\n\""' \
  "$REPO/.claude/harness.json" > "$FIX/h6.json" && mv "$FIX/h6.json" "$REPO/.claude/harness.json"
driver_state_set 409 design_source approved-picture
driver_state_set 409 design_ref "https://claude.ai/artifact/desk-v3 — approved on #409"
fix_ai compare '{"step":"compare","skills":["superpowers:verification-before-completion"],"status":"compared","approved":{"ref":"https://claude.ai/artifact/desk-v3"},"renders":[{"name":"desk light","path":"shots/a.png","theme":"light"},{"name":"desk dark","path":"shots/b.png","theme":"dark"}],"differences":[]}' \
  superpowers:verification-before-completion
rc=0; out=$(driver_step_compare 409 2>&1) || rc=$?
want "it finishes"                    "0" "$rc"
want_in "having taken two renders"    '2 render\(s\)' "$out"
CP="$(driver_state_dir 409)/steps/compare.prompt"
want "no placeholder survives into the compare prompt" "0" "$(grep -c '{{' "$CP" || true)"
want_in "the approved picture reaches it" 'desk-v3' "$(cat "$CP")"
want_in "and the route the renders came from" '/dashboard/desk' "$(cat "$CP")"
want_in "the reviewer now reads real renders" 'shots/a.png' "$(driver_state_get 409 renders)"

echo "--- T2-4 · a difference that stands is not the driver's to wave through ---"
fix_ai compare '{"step":"compare","skills":["superpowers:verification-before-completion"],"status":"compared","approved":{"ref":"https://claude.ai/artifact/desk-v3"},"renders":[{"name":"desk light","path":"shots/a.png","theme":"light"}],"differences":[{"what":"the masthead keeps a breadcrumb the design never showed","fixed":false,"reason":"it was already there"}]}' \
  superpowers:verification-before-completion
rc=0; out=$(driver_step_compare 409 2>&1) || rc=$?
want "it refuses"  "24" "$rc"
want_in "naming the difference" 'breadcrumb' "$out"
want_in "and saying only a person sanctions one" 'person sanctions' "$(driver_state_get 409 park_note)"
# AND IT IS A PERSON'S PARK. A driver-caused park leaves the ticket resumable and
# the step re-runs unattended, so the next answer of `fixed: true` would be an
# agent sanctioning its own deviation from a design somebody approved.
want "the park is marked as one only a person can answer" "person" "$(driver_state_get 409 park_cause)"

echo "--- a difference the compare step FIXED goes round, it does not ship ---"
# The gates ran before this step and the renders were taken before the agent
# edited anything, so `fixed: true` describes code no gate has read and pixels
# nobody has seen.
driver_state_set 409 park_cause ""
fix_ai compare '{"step":"compare","skills":["superpowers:verification-before-completion"],"status":"compared","approved":{"ref":"https://claude.ai/artifact/desk-v3"},"renders":[{"name":"desk light","path":"shots/a.png","theme":"light"}],"differences":[{"what":"the masthead lost its hairline","fixed":true}]}' \
  superpowers:verification-before-completion
rc=0; out=$(driver_step_compare 409 2>&1) || rc=$?
want "it refuses rather than passing" "24" "$rc"
want_in "having rendered a second time" 'pass 2' "$out"
want_in "and saying no render describes the code as it stands" 'has been observed' "$out"
driver_state_set 409 park_cause ""

echo "--- T2-2 · the project's pre-push reviews are run and recorded ---"
# The unit half. The end-to-end half — a screen change pushed through
# driver/build-ticket and accepted by a consuming project's REAL attestation
# gates — is push-gates.e2e.test.sh.
fix_issue 410 OPEN "status:claimed"
git -C "$REPO" worktree add -q "$FIX/wt410" -b "tkt-410/work" develop
driver_state_init 410 --worktree "$FIX/wt410" --branch "tkt-410/work"
cat > "$FIX/reviewer" <<'SH'
#!/usr/bin/env sh
echo "VERDICT: SHIP"
echo "no dead controls, brand tokens only"
echo "run=${HARNESS_DRIVER_RUN:-unset}"
SH
cat > "$FIX/recorder" <<'SH'
#!/usr/bin/env sh
# Stands in for scripts/record-verdict.sh: reads the REVIEWER's own words, refuses
# anything that is not a SHIP, and refuses a review of a commit that is not HEAD.
sha=""; while [ $# -gt 0 ]; do case "$1" in --sha) sha="$2"; shift 2 ;; *) shift ;; esac; done
v=$(grep -oE 'VERDICT:[[:space:]]*(SHIP|SPIT-BACK)' | head -1 | awk '{print $2}')
[ -n "$v" ] || { echo "no VERDICT line in the reviewer's output" >&2; exit 1; }
[ "$v" = "SHIP" ] && [ "$sha" = "$(git rev-parse HEAD)" ] || { echo "refusing to record $v at $sha" >&2; exit 1; }
git commit --allow-empty --no-verify -q -m "chore: gate" -m "Gate: SHIP (agent)"
echo "recorded"
SH
cat > "$FIX/owed" <<'SH'
#!/usr/bin/env sh
# Stands in for check:ui-gate-attested: owed until the HEAD commit carries the
# trailer, exit 0 once it does — the contract finish and the pre-push both read.
git log -1 --format=%B | grep -q 'Gate: SHIP' && { echo "✓ attested"; exit 0; }
echo "✗ check:ui-gate-attested — this diff touches UI with no matching verdict."
exit 1
SH
chmod +x "$FIX/reviewer" "$FIX/recorder" "$FIX/owed"
jq --arg r "$FIX/reviewer" --arg w "$FIX/recorder" --arg o "$FIX/owed" \
   '.review = {"attest":{"ui-gate":{"owed":$o,"review":$r,"record":($w + " --sha {{SHA}}")}}}' \
   "$REPO/.claude/harness.json" > "$FIX/h7.json" && mv "$FIX/h7.json" "$REPO/.claude/harness.json"
git -C "$FIX/wt410" config user.email t@e.invalid
git -C "$FIX/wt410" config user.name T
BEFORE=$(git -C "$FIX/wt410" rev-parse HEAD)
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "the requirement is satisfied" "0" "$rc"
want_in "the reviewer ran"          "the 'ui-gate' reviewer ran" "$out"
want_in "and its verdict was recorded" 'Gate: SHIP' "$(git -C "$FIX/wt410" log -1 --format=%B)"
want "on a new commit"  "1" "$(git -C "$FIX/wt410" rev-list --count "$BEFORE..HEAD")"
want_in "and the reviewer ran as a driver step, so the Stop hooks stand down" \
  "run=410:attest-ui-gate" "$(cat "$(driver_state_dir 410)/steps/verdict-ui-gate.txt")"

echo "--- T2-2 · a verdict recorded before a later commit is recorded again ---"
# A recorder binds a verdict to the commit it reviewed. review is finished by the
# time anything else commits — a park's own work-in-progress commit is the real
# case — so a resumed run walks straight to `ship` and the push is refused for
# ever with nothing able to re-record.
want "the head the verdicts describe is on the record" "$(git -C "$FIX/wt410" rev-parse HEAD)" \
  "$(driver_state_get 410 push_requires_at)"
printf 'a later change\n' > "$FIX/wt410/later.txt"
git -C "$FIX/wt410" add later.txt
git -C "$FIX/wt410" commit -qm "chore: parked"
: > "$GH_LOG"
rc=0; out=$(driver_step_ship 410 2>&1) || rc=$?
want_in "ship notices the branch moved and re-records" "the 'ui-gate' reviewer ran" "$out"
want "and the record follows the new head" "$(git -C "$FIX/wt410" rev-parse HEAD)" \
  "$(driver_state_get 410 push_requires_at)"

echo "--- T2-2 · a recorder that refuses files no follow-up ticket ---"
# Filing the Minors opens an issue and has no idempotency guard, so a recorder that
# refused AFTER it parked with `review` unfinished — and every resume re-ran the
# whole review and filed the same follow-up again.
. "$HERE/../steps/review.sh" || exit 1
fix_issue 413 OPEN "status:claimed"
git -C "$REPO" worktree add -q "$FIX/wt413" -b "tkt-413/work" develop
git -C "$FIX/wt413" config user.email t@e.invalid
git -C "$FIX/wt413" config user.name T
driver_state_init 413 --worktree "$FIX/wt413" --branch "tkt-413/work"
fix_ai review '{"step":"review","skills":["superpowers:requesting-code-review"],"status":"reviewed","round":1,"verdict":"SHIP","findings":[{"id":"m1","file":"a.ts","line":3,"grade":"minor","summary":"spacing","reason":"polish","fix":"nudge"}]}' superpowers:requesting-code-review
printf '#!/usr/bin/env sh\necho "VERDICT: SPIT-BACK"\n' > "$FIX/reviewer"; chmod +x "$FIX/reviewer"
jq --arg r "$FIX/reviewer" --arg w "$FIX/recorder" --arg o "$FIX/owed" \
   '.review = {"attest":{"ui-gate":{"owed":$o,"review":$r,"record":($w + " --sha {{SHA}}")}}}' \
   "$REPO/.claude/harness.json" > "$FIX/hr.json" && mv "$FIX/hr.json" "$REPO/.claude/harness.json"
: > "$GH_LOG"
rc=0; out=$(driver_step_review 413 2>&1) || rc=$?
want "the review refuses on the recorder" "24" "$rc"
want_not_in "and no follow-up ticket was filed" 'issue create' "$(cat "$GH_LOG")"

echo "--- T2-2 · a reviewer that says SPIT-BACK is not recorded, and it stops there ---"
git -C "$FIX/wt410" commit --allow-empty -qm "chore: a change nobody has reviewed"
cat > "$FIX/reviewer" <<'SH'
#!/usr/bin/env sh
echo "VERDICT: SPIT-BACK"
echo "the save button calls nothing"
SH
chmod +x "$FIX/reviewer"
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "it refuses"  "24" "$rc"
want_in "carrying the recorder's own words" 'refusing to record SPIT-BACK' "$out"
want_in "and the park note names the gate"  "ui-gate" "$(driver_state_get 410 park_note)"

echo "--- T2-2 · a reviewer that says nothing is not a reviewer that approved ---"
printf '#!/usr/bin/env sh\nexit 0\n' > "$FIX/reviewer"; chmod +x "$FIX/reviewer"
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "it refuses"  "24" "$rc"
want_in "saying there is no verdict to record" 'no output' "$out"

echo "--- T2-2 · a recorder that hangs is a timeout, not a refusal ---"
printf '#!/usr/bin/env sh\necho "VERDICT: SHIP"\n' > "$FIX/reviewer"; chmod +x "$FIX/reviewer"
printf '#!/usr/bin/env sh\nsleep 30\n' > "$FIX/recorder"; chmod +x "$FIX/recorder"
rc=0; out=$(DRIVER_CMD_TIMEOUT=2 driver_push_requires 410 2>&1) || rc=$?
want "it is a timeout"  "25" "$rc"
want_in "and says the recorder did not return" 'recorder did not return' "$out"
printf '#!/usr/bin/env sh\nsleep 30\n' > "$FIX/reviewer"; chmod +x "$FIX/reviewer"
rc=0; out=$(DRIVER_CMD_TIMEOUT=2 driver_push_requires 410 2>&1) || rc=$?
want "so is a reviewer that hangs" "25" "$rc"

echo "--- T2-2 · a reviewer that is not owed on this diff is not run (#11161) ---"
# Trial 3: a test-only diff was sent to ui-gate, which rightly found no UI and gave
# no verdict, and the ticket parked here though the pre-push would have passed it.
printf '#!/usr/bin/env sh\necho "VERDICT: SHIP"\n' > "$FIX/reviewer"; chmod +x "$FIX/reviewer"
cat > "$FIX/recorder" <<'SH'
#!/usr/bin/env sh
git commit --allow-empty --no-verify -q -m "chore: gate" -m "Gate: SHIP (agent)"; echo recorded
SH
chmod +x "$FIX/recorder"
jq --arg r "$FIX/reviewer" --arg w "$FIX/recorder" \
   '.review = {"attest":{"ui-gate":{"owed":"echo \"✓ check:ui-gate-attested — no UI surface in this diff\"","review":$r,"record":$w}}}' \
   "$REPO/.claude/harness.json" > "$FIX/hn.json" && mv "$FIX/hn.json" "$REPO/.claude/harness.json"
rm -f "$(driver_state_dir 410)/steps/verdict-ui-gate.txt"
BEFORE=$(git -C "$FIX/wt410" rev-parse HEAD)
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "nothing owed is satisfied" "0" "$rc"
want_in "and says so, in the project's words" "'ui-gate' is not owed on this diff — ✓ check:ui-gate-attested — no UI surface" "$out"
want_not_in "the reviewer never ran" "reviewer ran" "$out"
want "and nothing was recorded" "$BEFORE" "$(git -C "$FIX/wt410" rev-parse HEAD)"

echo "--- T2-2 · owed is asked with {{BASE}} and {{SHA}} filled ---"
jq --arg r "$FIX/reviewer" --arg w "$FIX/recorder" \
   '.review = {"attest":{"ui-gate":{"owed":"echo base={{BASE}} sha={{SHA}}","review":$r,"record":$w}}}' \
   "$REPO/.claude/harness.json" > "$FIX/hn.json" && mv "$FIX/hn.json" "$REPO/.claude/harness.json"
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want_in "the base is the trunk" "base=(origin/)?develop" "$(cat "$(driver_state_dir 410)/steps/owed-ui-gate.txt")"
want_in "and the sha is HEAD" "sha=$(git -C "$FIX/wt410" rev-parse HEAD)" "$(cat "$(driver_state_dir 410)/steps/owed-ui-gate.txt")"

echo "--- T2-2 · recorded is not attested: the project's check is asked again ---"
cat > "$FIX/recorder" <<'SH'
#!/usr/bin/env sh
git commit --allow-empty --no-verify -q -m "chore: gate" -m "Wrong-Trailer: SHIP"; echo recorded
SH
chmod +x "$FIX/recorder"
jq --arg r "$FIX/reviewer" --arg w "$FIX/recorder" --arg o "$FIX/owed" \
   '.review = {"attest":{"ui-gate":{"owed":$o,"review":$r,"record":$w}}}' \
   "$REPO/.claude/harness.json" > "$FIX/hn.json" && mv "$FIX/hn.json" "$REPO/.claude/harness.json"
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "a recorder that wrote the wrong thing refuses" "24" "$rc"
want_in "saying the check still says owed" "still says it is owed" "$out"
want_in "and the park note carries the check's own line" "check:ui-gate-attested" "$(driver_state_get 410 park_note)"

echo "--- T2-2 · a check for whether a reviewer is owed that hangs is a timeout ---"
jq '.review = {"attest":{"ui-gate":{"owed":"sleep 30","review":"true","record":"true"}}}' \
   "$REPO/.claude/harness.json" > "$FIX/hn.json" && mv "$FIX/hn.json" "$REPO/.claude/harness.json"
rc=0; out=$(DRIVER_CMD_TIMEOUT=2 driver_push_requires 410 2>&1) || rc=$?
want "it is a timeout" "25" "$rc"

echo "--- T2-2 · an owed row the driver cannot run refuses, and says so (#11162) ---"
# Trial 3: design-critic was an owed-only row, skipped in silence; #10955 reached
# SHIP and learned at the push that it needed a verdict no step gives.
jq --arg o "$FIX/owed" '.review = {"attest":{"design-critic":{"owed":$o}}}' \
   "$REPO/.claude/harness.json" > "$FIX/hn.json" && mv "$FIX/hn.json" "$REPO/.claude/harness.json"
git -C "$FIX/wt410" commit --allow-empty -qm "chore: unreviewed"
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "an owed row with nothing to run refuses" "24" "$rc"
want_in "naming the row" "'design-critic' is owed on this diff" "$out"
want_in "and the park note says only a person can earn it" "only a person can earn it" "$(driver_state_get 410 park_note)"
rc=0; out=$(driver_push_requires_unpayable 410 2>&1) || rc=$?
want "the cheap pre-check refuses the same" "24" "$rc"
want_in "before the review is paid for" "before the review is paid for" "$out"
jq '.review = {"attest":{"design-critic":{"owed":"true"}}}' \
   "$REPO/.claude/harness.json" > "$FIX/hn.json" && mv "$FIX/hn.json" "$REPO/.claude/harness.json"
rc=0; driver_push_requires 410 >/dev/null 2>&1 || rc=$?
want "an owed-only row that is not owed passes" "0" "$rc"
rc=0; driver_push_requires_unpayable 410 >/dev/null 2>&1 || rc=$?
want "and so does the pre-check" "0" "$rc"
jq '.review = {"attest":{"design-critic":"false"}}' \
   "$REPO/.claude/harness.json" > "$FIX/hn.json" && mv "$FIX/hn.json" "$REPO/.claude/harness.json"
rc=0; driver_push_requires_unpayable 410 >/dev/null 2>&1 || rc=$?
want "a bare-string row that is owed refuses too" "24" "$rc"

echo "--- T2-2 · the review step asks before the model runs ---"
fix_issue 414 OPEN "status:claimed"
git -C "$REPO" worktree add -q "$FIX/wt414" -b "tkt-414/work" develop
driver_state_init 414 --worktree "$FIX/wt414" --branch "tkt-414/work"
: > "$CLAUDE_LOG"
rc=0; out=$(driver_step_review 414 2>&1) || rc=$?
want "the review step refuses" "24" "$rc"
want "and no model was started" "" "$(cat "$CLAUDE_LOG")"

echo "--- T2-2 · a reviewer named as an agent is run directly, lean, and paid for (#11172) ---"
# The command form ran `claude -p /agent-harness:ui-gate`: a whole session whose job
# was to start the frontend-gate agent — two fixed loads for one review, and the
# first one's spend nowhere on the record.
git -C "$FIX/wt410" commit --allow-empty -qm "chore: a change the agent has not reviewed"
cat > "$FIX/recorder" <<'SH'
#!/usr/bin/env sh
grep -q '^VERDICT: SHIP' || { echo "no VERDICT line" >&2; exit 1; }
git commit --allow-empty --no-verify -q -m "chore: gate" -m "Gate: SHIP (agent)"; echo recorded
SH
chmod +x "$FIX/recorder"
jq -nc '{type:"assistant", message:{content:[{type:"text", text:"reviewing"}],
          usage:{input_tokens:100, cache_read_input_tokens:20000, cache_creation_input_tokens:0}}}' > "$FIX/ai/attest-ui-gate.jsonl"
jq -nc '{type:"result", subtype:"success", is_error:false, result:"VERDICT: SHIP\nno dead controls", total_cost_usd:0.4, num_turns:3}' >> "$FIX/ai/attest-ui-gate.jsonl"
jq --arg w "$FIX/recorder" --arg o "$FIX/owed" \
   '.review = {"attest":{"ui-gate":{"owed":$o,"agent":"agent-harness:frontend-gate","record":$w}}}' \
   "$REPO/.claude/harness.json" > "$FIX/hg.json" && mv "$FIX/hg.json" "$REPO/.claude/harness.json"
SPENT=$(jq -r '.spend // 0' "$(driver_state_dir 410)/state.json")
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "the agent's verdict is recorded" "0" "$rc"
args="$(cat "$FIX/claude-args-attest-ui-gate.txt")"
want_in "the agent is run directly"           '^--agent$'                     "$args"
want_in "by name"                             '^agent-harness:frontend-gate$' "$args"
want_in "with the lean tool list"             '^--tools$'                     "$args"
want_not_in "read-only: a reviewer does not edit" '^Edit$'                       "$args"
want_not_in "not through a wrapper skill"     'ui-gate$'                      "$(grep -x '/agent-harness:ui-gate' "$FIX/claude-args-attest-ui-gate.txt")"
want_in "it was given the diff"               '```diff'                       "$(cat "$FIX/claude-stdin-attest-ui-gate.txt")"
want_in "and asked to lead with a verdict"    'VERDICT: SHIP'                 "$(cat "$FIX/claude-stdin-attest-ui-gate.txt")"
want "the recorder read the agent's answer, verbatim" "VERDICT: SHIP
no dead controls" "$(cat "$(driver_state_dir 410)/steps/verdict-ui-gate.txt")"
want "its spend is on the record"            "0.4"  "$(jq -r '.usage["attest-ui-gate"][0].cost' "$(driver_state_dir 410)/state.json")"
want "and counted in the run's spend"        "yes"  "$(jq -r --argjson b "$SPENT" 'if (.spend - $b) > 0.39 then "yes" else "no" end' "$(driver_state_dir 410)/state.json")"
want_in "as a driver step, so the Stop hooks stand down" "410:attest-ui-gate" "$(grep '^attest-ui-gate' "$FIX/claude-env.log" | tail -1)"
rc=0; driver_push_requires_unpayable 410 >/dev/null 2>&1 || rc=$?
want "an agent row is not an owed-only row" "0" "$rc"
jq '.review.attest["ui-gate"] = {"agent":"agent-harness:frontend-gate"}' \
   "$REPO/.claude/harness.json" > "$FIX/hg.json" && mv "$FIX/hg.json" "$REPO/.claude/harness.json"
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "an agent with no recorder is half a row and refuses" "24" "$rc"
want_in "naming it as half a row" "ui-gate name one of review/agent and record" "$out"
jq --arg w "$FIX/recorder" '.review.attest["ui-gate"] = {"review":"true","agent":"agent-harness:frontend-gate","record":$w}' \
   "$REPO/.claude/harness.json" > "$FIX/hg.json" && mv "$FIX/hg.json" "$REPO/.claude/harness.json"
: > "$CLAUDE_LOG"
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "a row naming both a command and an agent refuses" "24" "$rc"
want_in "saying so" "both a review command and an agent" "$out"
want "and runs neither" "" "$(cat "$CLAUDE_LOG")"

echo "--- T2-2 · a reviewer that judges pictures refuses when none were taken ---"
git -C "$FIX/wt410" commit --allow-empty -qm "chore: unreviewed again"
cat > "$FIX/recorder" <<'SH'
#!/usr/bin/env sh
grep -q '^VERDICT: SHIP' || { echo "no VERDICT line" >&2; exit 1; }
git commit --allow-empty --no-verify -q -m "chore: gate" -m "Gate: SHIP (agent)"; echo recorded
SH
chmod +x "$FIX/recorder"
jq --arg w "$FIX/recorder" --arg o "$FIX/owed" \
   '.review = {"attest":{"design-critic":{"owed":$o,"agent":"agent-harness:design-critic","record":$w,"needsRenders":true}}}' \
   "$REPO/.claude/harness.json" > "$FIX/hr2.json" && mv "$FIX/hr2.json" "$REPO/.claude/harness.json"
driver_state_set 410 renders "(none — this project's design.render command says this change touches no screen it can capture)"
: > "$CLAUDE_LOG"
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "it refuses"                          "24" "$rc"
want_in "saying only a person can earn it" "judges rendered screens and none were taken" "$out"
want "and the reviewer was never run"      "" "$(cat "$CLAUDE_LOG")"
want_in "the park note carries why"        "no render was taken" "$(driver_state_get 410 park_note)"
jq -nc '{type:"result", subtype:"success", is_error:false, result:"VERDICT: SHIP\non-theme", total_cost_usd:0.2, num_turns:2}' > "$FIX/ai/attest-design-critic.jsonl"
driver_state_set 410 renders "$(printf 'desk light\tshots/a.png\tlight\t/dashboard/desk')"
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "with a render on the record it runs, and records" "0" "$rc"
want_in "the renders reach the reviewer"   'shots/a.png' "$(cat "$FIX/claude-stdin-attest-design-critic.txt")"

echo "--- T2-2 · one row per reviewer, shared with the interactive finish ---"
# `/agent-harness:finish` reads the same rows for a different question, so a second
# key naming the same reviewers would be two places for them to disagree about
# which ones exist. A row that answers only finish's question is advisory here.
jq '.review = {"attest":{"ui-gate":"echo owed"}}' \
  "$REPO/.claude/harness.json" > "$FIX/h8.json" && mv "$FIX/h8.json" "$REPO/.claude/harness.json"
: > "$CLAUDE_LOG"
rc=0; driver_push_requires 410 >/dev/null 2>&1 || rc=$?
want "a bare owed command is not the driver's to run" "0" "$rc"
want_in "and finish still reads it" 'ui-gate' \
  "$(jq -r '(.review.attest // {}) | to_entries[] | "\(.key)\t\(if (.value | type) == "string" then .value else (.value.owed // "") end)"' "$REPO/.claude/harness.json")"
jq '.review.attest["ui-gate"] = {"owed":"echo owed","review":"echo VERDICT: SHIP"}' \
  "$REPO/.claude/harness.json" > "$FIX/h9.json" && mv "$FIX/h9.json" "$REPO/.claude/harness.json"
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "a row with a reviewer and no recorder refuses" "24" "$rc"
want_in "naming it" 'ui-gate' "$out"
jq 'del(.review)' "$REPO/.claude/harness.json" > "$FIX/ha.json" && mv "$FIX/ha.json" "$REPO/.claude/harness.json"
rc=0; driver_push_requires 410 >/dev/null 2>&1 || rc=$?
want "and a project that attests nothing is normal" "0" "$rc"
jq '.review = "scripts/record-verdict.sh"' "$REPO/.claude/harness.json" > "$FIX/hb.json" && mv "$FIX/hb.json" "$REPO/.claude/harness.json"
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "a review written as a string refuses rather than running nothing" "24" "$rc"
want_in "and says what shape it reads" 'owed, review, record' "$out"

exit $FAILED
