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
mkdir -p "$REPO/docs/programmes"
printf 'one desk\n' > "$REPO/docs/programmes/state-one-desk.md"
printf 'echo\n'     > "$REPO/docs/programmes/state-echo.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "programme state files"
fix_issue 402 OPEN "status:ready,project:one-desk"
driver_state_init 402
SAVED_PD="${PROGRAMMES_DIR:-}"; PROGRAMMES_DIR=""
out=$(driver_fact_programme 402 2>&1)
PROGRAMMES_DIR="$SAVED_PD"
want_not_in "a bare clone is not told the directory does not exist" \
  'keeps no programme state directory' "$out"
want_in "it names the file for THIS programme"  'state-one-desk.md' "$out"
want_not_in "and not another programme's"       'state-echo.md' "$out"
# AND NOT ANY MARKDOWN THAT HAPPENS TO CARRY THE NAME. A looser fallback is the
# wrong-document defect this hunk fixes, one size down.
printf 'somebody notes\n' > "$REPO/docs/programmes/one-desk-notes.md"
fix_issue 412 OPEN "status:ready,project:nothing-here"
driver_state_init 412
SAVED_PD="${PROGRAMMES_DIR:-}"; PROGRAMMES_DIR=""
out2=$(driver_fact_programme 412 2>&1)
PROGRAMMES_DIR="$SAVED_PD"
want_not_in "a programme with no state file gets no other programme's" '\.md' "$out2"
want_in "and is told how many are there" 'state file' "$out2"

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
want_in "the brief says nobody has to answer it" 'nothing here is yours to answer' \
  "$(grep -o 'nothing here is yours to answer' "$GH_LOG" || swarm_gh issue comment 2>/dev/null; true)"
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

echo "--- T2-4 · a declared renderer that produces nothing is a refusal ---"
# A measurement that could not be made is not a screen that is fine.
jq '.design.render = "sh -c \"echo the dev server is not up >&2; exit 7\""' \
  "$REPO/.claude/harness.json" > "$FIX/h5.json" && mv "$FIX/h5.json" "$REPO/.claude/harness.json"
rc=0; out=$(driver_step_compare 409 2>&1) || rc=$?
want "it refuses"             "24" "$rc"
want_in "naming the exit code" 'exited 7' "$out"
want_in "and the park note says the screen was never observed" \
  'never observed' "$(driver_state_get 409 park_note)"

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
want "it sends the work round again" "30" "$rc"
want_in "saying the gates have not read that change" 'gates have not read' "$out"

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
chmod +x "$FIX/reviewer" "$FIX/recorder"
jq --arg r "$FIX/reviewer" --arg w "$FIX/recorder" \
   '.push = {"requires":[{"name":"ui-gate","review":$r,"record":($w + " --sha {{SHA}}")}]}' \
   "$REPO/.claude/harness.json" > "$FIX/h7.json" && mv "$FIX/h7.json" "$REPO/.claude/harness.json"
git -C "$FIX/wt410" config user.email t@e.invalid
git -C "$FIX/wt410" config user.name T
BEFORE=$(git -C "$FIX/wt410" rev-parse HEAD)
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "the requirement is satisfied" "0" "$rc"
want_in "the reviewer ran"          "the 'ui-gate' reviewer ran" "$out"
want_in "and its verdict was recorded" 'Gate: SHIP' "$(git -C "$FIX/wt410" log -1 --format=%B)"
want "on a new commit"  "1" "$(git -C "$FIX/wt410" rev-list --count "$BEFORE..HEAD")"

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

echo "--- T2-2 · a reviewer that says SPIT-BACK is not recorded, and it stops there ---"
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

echo "--- T2-2 · a project that declares none is not refused ---"
jq 'del(.push)' "$REPO/.claude/harness.json" > "$FIX/h8.json" && mv "$FIX/h8.json" "$REPO/.claude/harness.json"
rc=0; driver_push_requires 410 >/dev/null 2>&1 || rc=$?
want "no push.requires is normal" "0" "$rc"
jq '.push = "scripts/record-verdict.sh"' "$REPO/.claude/harness.json" > "$FIX/h9.json" && mv "$FIX/h9.json" "$REPO/.claude/harness.json"
rc=0; out=$(driver_push_requires 410 2>&1) || rc=$?
want "but a push written as a string refuses rather than running nothing" "24" "$rc"
want_in "and says what shape it reads" 'reads a list' "$out"

exit $FAILED
