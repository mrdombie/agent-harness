#!/usr/bin/env bash
# real-briefs.test.sh — the driver against the briefs, schemas, examples and hooks
# THAT SHIP. Every other suite here points DRIVER_BRIEFS at a temp directory the
# fixture wrote, and on the 2026-09-27 trial that is exactly what hid five Criticals:
# every one of them was the seam between the driver and the briefs, and both sides of
# the seam were fixtures. `bash driver/tests/ai-step.test.sh` exited 0 with all five
# live. A lab full of replicas proves the kit and never the product.
#
# So this suite changes one thing and nothing else: the briefs are the real ones, the
# contracts are the real ones, and the answers are the real examples. Only the model
# is stubbed, because a suite must not start an agent.
#
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT

# harness.json AS THE KIT'S OWN README DOCUMENTS IT. The fixture writes a flat
# `gates` map, which is the shape self-check happened to read — so the documented
# shape had never been run through it. `worktree.prepare` is the F7 fact.
jq '.gates = {"local": ["echo lint-ok", "echo test-ok"],
              "group": "gates:repo",
              "requiredChecks": ["Typecheck + Unit tests", "Code gates"]}
    | .worktree = {"prepare": ["sh -c \"echo generated > .prepared\""]}
    | .commit = {"parkType": "chore"}' \
  "$REPO/.claude/harness.json" > "$FIX/h.json" && mv "$FIX/h.json" "$REPO/.claude/harness.json"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "the documented gates shape"

fix_real_briefs
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../steps/plan.sh" || exit 1
. "$HERE/../steps/self-check.sh" || exit 1
. "$HERE/../steps/park.sh" || exit 1
. "$HERE/../steps/start.sh" || exit 1

REAL_BRIEFS="$KIT/briefs"
PLAN_OK=$(jq -c . "$REAL_BRIEFS/examples/plan.valid.json")
PLAN_SKILLS=$(jq -r '.skills | join(" ")' "$REAL_BRIEFS/examples/plan.valid.json")

echo "--- F4 · the brief reaches the model FILLED IN ---"
# Measured on the trial: plan.prompt was byte-identical for two different tickets
# (md5 a92aa3c6a023ca64c5abda4b0bfd36cc) and six placeholders arrived as text.
fix_issue 301 OPEN "status:ready"
fix_issue 302 OPEN "status:ready"
driver_state_init 301; driver_state_init 302
export DRIVER_TICKET=301
fix_ai plan "$PLAN_OK" "$PLAN_SKILLS"
rc=0; driver_ai_step 301 plan >/dev/null 2>&1 || rc=$?
want "the real plan brief is accepted" "0" "$rc"
P1="$(driver_state_dir 301)/steps/plan.prompt"
want "no placeholder survives into the prompt" "0" "$(grep -c '{{' "$P1" || true)"
want_in "and the ticket itself is in it" "Ticket 301" "$(cat "$P1")"
export DRIVER_TICKET=302
rc=0; driver_ai_step 302 plan >/dev/null 2>&1 || rc=$?
P2="$(driver_state_dir 302)/steps/plan.prompt"
want "two tickets do not get one prompt" "different" \
  "$([ "$(md5 -q "$P1" 2>/dev/null || md5sum "$P1" | cut -d' ' -f1)" \
     = "$(md5 -q "$P2" 2>/dev/null || md5sum "$P2" | cut -d' ' -f1)" ] && echo same || echo different)"

echo "--- F4 · a fact with no value STOPS the step ---"
# The refusal is the whole design: an odd-looking prompt cannot be seen from outside
# a run, and a stopped step can. Proved by deleting one gathered fact.
export DRIVER_TICKET=301
rm -f "$(driver_fact_dir 301 plan)/PROJECT_FACTS"
# A gatherer would rewrite it, so the probe points the step at a brief whose only
# placeholder is one nothing gathers.
mkdir -p "$FIX/onebrief/schemas"
printf '# Step 2 · Plan\n\nYou are given {{NOT_A_FACT}}.\n\n## Return\n\nJSON only, valid against `schemas/plan.json`.\n' > "$FIX/onebrief/plan.md"
cp "$REAL_BRIEFS/schemas/plan.json" "$FIX/onebrief/schemas/plan.json"
out=$(DRIVER_BRIEFS="$FIX/onebrief" DRIVER_SCHEMAS="$FIX/onebrief/schemas" \
        driver_ai_step 301 plan 2>&1); rc=$?
want "an unfilled placeholder refuses" "24" "$rc"
want_in "and names it"                 'NOT_A_FACT' "$out"

echo "--- F4 · a fact that resolves to NOTHING is the same refusal ---"
# Found while building this: a gatherer whose jq was mis-quoted produced an empty
# string, `printf '%s\n' ""` wrote one blank line, the loader could not tell that
# from a blank fact, and the brief went out reading "- The ticket: " with the step
# perfectly happy. An empty value is written as zero bytes so the refusal covers it.
printf 'x {{ONLY}} y\n' > "$FIX/onebrief/plan.md"
printf '\n## Return\n\nJSON only, valid against `schemas/plan.json`.\n' >> "$FIX/onebrief/plan.md"
driver_fact_put 301 plan ONLY ""
out=$(DRIVER_BRIEFS="$FIX/onebrief" DRIVER_SCHEMAS="$FIX/onebrief/schemas" \
        driver_ai_step 301 plan 2>&1); rc=$?
want "an empty fact refuses too" "24" "$rc"
want_in "and names it"           'ONLY' "$out"
driver_fact_put 301 plan ONLY "a real value"
rc=0; DRIVER_BRIEFS="$FIX/onebrief" DRIVER_SCHEMAS="$FIX/onebrief/schemas" \
        driver_ai_step 301 plan >/dev/null 2>&1 || rc=$?
want "and a real value is accepted" "0" "$rc"

echo "--- F1 · the answer is read from structured_output, not the last message ---"
# The kit's own Stop hook replaces the final message with the sign-off banner. This is
# that transcript exactly: four lines of banner in `.result`, the answer beside it.
BANNER='🏷️ Working on: One home for post-state words (project:one-desk)
   Paused on: the driver — plan returned, nothing built yet
   Also running: 3 claims
   Resume: /claim 10867'
# The previous case's answer file is removed first: left there, "the answer really is
# the JSON" reads the last good answer and passes about a step that refused.
rm -f "$(driver_state_dir 301)/steps/plan.json"
fix_ai_banner plan "$PLAN_OK" "$BANNER" "$PLAN_SKILLS"
rc=0; driver_ai_step 301 plan >/dev/null 2>&1 || rc=$?
want "a banner in the last message does not hide the answer" "0" "$rc"
want "and the answer really is the JSON" "plan" \
  "$(jq -r '.step' "$(driver_state_dir 301)/steps/plan.json")"

echo "--- F1 · the Stop hooks are told to stand down ---"
want_in "the runner is given the driver's own marker" "301:plan" "$(cat "$CLAUDE_ENV_LOG")"
for h in signoff-backstop ask-dont-narrate; do
  printf '{"session_id":"probe-%s","last_assistant_message":"your call whether to do X","stop_hook_active":false}' "$h" \
    | HARNESS_DRIVER_RUN=301:plan bash "$KIT/hooks/$h.sh" >/dev/null 2>&1
  want "$h stands down on a driver run" "0" "$?"
done

echo "--- F8 · the step runs in the ticket's worktree ---"
WT="$FIX/wt301"
git -C "$REPO" worktree add -q "$WT" -b "tkt-301/work" develop
driver_state_set 301 worktree "$WT"
: > "$CLAUDE_ENV_LOG"
fix_ai plan "$PLAN_OK" "$PLAN_SKILLS"
driver_ai_step 301 plan >/dev/null 2>&1
want "the agent's cwd is the worktree, not the shared checkout" "$WT" \
  "$(awk -F'\t' 'END{print $2}' "$CLAUDE_ENV_LOG")"

echo "--- F1 · the schema handed to the model is DERIVED from the contract ---"
# `--json-schema` goes to the API as a tool input schema, which 400s on `allOf` at the
# top level (measured 2026-09-28). The relaxed copy is derived, never written twice.
SENT="$FIX/claude-schema-plan.json"
want "a schema was sent at all" "object" "$(jq -r 'type' "$SENT" 2>/dev/null)"
want "and it carries no allOf the API refuses" "null" "$(jq -r '.allOf // "null"' "$SENT")"
want "nor a top-level if"                      "null" "$(jq -r '.if // "null"' "$SENT")"
want "while the CONTRACT still has both"       "2" \
  "$(jq -r '[(.allOf // empty), (.if // empty)] | length' "$REAL_BRIEFS/schemas/plan.json")"
want "and a task's title property survives the relaxing" "true" \
  "$(jq -r '.properties.tasks.items.properties | has("title")' "$SENT")"

echo "--- F3 · the skill check is live on the real briefs ---"
# No shipped brief has `skill:` front matter, so the old front-matter read left every
# AI step ungated. The set comes from briefs/facts.json now.
want "the real plan brief has no skill front matter" "" "$(driver_brief_skill "$REAL_BRIEFS/plan.md")"
want_in "and facts.json declares them" "superpowers:writing-plans" "$(driver_declared_skills plan | tr '\n' ' ')"
fix_ai plan "$PLAN_OK"     # a transcript with no Skill call at all
out=$(driver_ai_step 301 plan 2>&1); rc=$?
want "no Skill call refuses"     "21" "$rc"
want_in "and names what it wanted" 'superpowers:writing-plans' "$out"
fix_ai plan "$PLAN_OK" "superpowers:requesting-code-review"
rc=0; driver_ai_step 301 plan >/dev/null 2>&1 || rc=$?
want "a skill from another step does not satisfy it" "21" "$rc"
# The half every brief's Return section promises and nothing checked: a skill CLAIMED
# in the answer that the transcript does not show.
CLAIMS_TWO=$(jq -c '.skills = ["superpowers:writing-plans","superpowers:systematic-debugging"]' \
               "$REAL_BRIEFS/examples/plan.valid.json")
fix_ai plan "$CLAIMS_TWO" "superpowers:writing-plans"
out=$(driver_ai_step 301 plan 2>&1); rc=$?
want "a claimed skill the log never shows refuses" "21" "$rc"
want_in "and names the one it could not see" 'systematic-debugging' "$out"

echo "--- F2 · the plan step reads the contract's own keys ---"
# The kit's OWN valid example, through the REAL plan step. It validated, read
# `.tests` as length 0, and parked on "it names no test" — three times over.
fix_ai plan "$PLAN_OK" "$PLAN_SKILLS"
out=$(driver_step_plan 301 2>&1); rc=$?
want "the shipped example is a plan this driver can enforce" "0" "$rc"
want_in "and the tests it counts are the ones in it" '1 test' "$out"
want "the plan's own designSource is recorded" "ticket-body" "$(driver_state_get 301 design_source)"
SCHEMA_NO_MODEL=$(jq -c '.schemaChange = true' "$REAL_BRIEFS/examples/plan.valid.json")
fix_ai plan "$SCHEMA_NO_MODEL" "$PLAN_SKILLS"
out=$(driver_step_plan 301 2>&1); rc=$?
want "a schema change with no approved model still refuses" "22" "$rc"
want_in "through the contract that now carries the rule" 'dataModelSpec' "$out"

echo "--- F5 · self-check reads the gates shape the README documents ---"
rc=0; out=$(driver_step_self_check 301 2>&1) || rc=$?
want "the documented shape runs green"          "0" "$rc"
want_in "both local commands ran"               '2 gate\(s\) green' "$out"
want_not_in "requiredChecks was never run as a command" 'Typecheck' "$out"
want_not_in "nor was the group name"            'gates:repo' "$out"
want_not_in "and nothing was not-found"         'not found' "$out"

echo "--- F7 · the worktree is prepared for this project ---"
rm -rf "$STATE/driver/303"; fix_issue 303 OPEN "status:ready"
git -C "$REPO" remote add origin "$FIX/origin" 2>/dev/null || true
git init -q --bare "$FIX/origin" 2>/dev/null || true
git -C "$REPO" push -q origin develop 2>/dev/null || true
driver_state_init 303
rc=0; driver_step_start 303 >/dev/null 2>&1 || rc=$?
want "start finishes" "0" "$rc"
NEW_WT=$(driver_state_get 303 worktree)
want "and the project's prepare command ran in the new tree" "generated" \
  "$(cat "$NEW_WT/.prepared" 2>/dev/null | tr -d '\n')"
echo "--- F7 · a prepare command that fails is a refusal, not a surprise at the push ---"
jq '.worktree.prepare = ["sh -c \"echo no client here >&2; exit 3\""]' \
  "$REPO/.claude/harness.json" > "$FIX/h2.json" && mv "$FIX/h2.json" "$REPO/.claude/harness.json"
rm -rf "$STATE/driver/304"; fix_issue 304 OPEN "status:ready"
driver_state_init 304
out=$(driver_step_start 304 2>&1); rc=$?
want "an unprepared tree refuses"  "24" "$rc"
want_in "and says which command"   'exit 3' "$out"
jq '.worktree.prepare = ["sh -c \"echo generated > .prepared\""]' \
  "$REPO/.claude/harness.json" > "$FIX/h3.json" && mv "$FIX/h3.json" "$REPO/.claude/harness.json"

echo "--- F6 · park commits with a type this project allows, and reads the answer ---"
# The trial's park hit `type must be one of [feat, fix, …]` on `wip`, swallowed it with
# `|| true`, then blamed the push. The work was left staged in a temp worktree and the
# brief told the reader it was "only in /var/folders/…".
PWT="$FIX/wtpark"
git -C "$REPO" worktree add -q "$PWT" -b "tkt-305/work" develop
mkdir -p "$PWT/.husky/_"
cat > "$PWT/.husky/_/commit-msg" <<'HOOK'
#!/usr/bin/env sh
grep -qE '^(feat|fix|refactor|chore|docs|test|perf|style|revert|ci|build)(\(|:)' "$1" && exit 0
echo "✖ type must be one of [feat, fix, refactor, chore, docs, test, perf, style, revert, ci, build] [type-enum]" >&2
exit 1
HOOK
chmod +x "$PWT/.husky/_/commit-msg"
git -C "$PWT" config core.hooksPath .husky/_
printf 'work in progress\n' > "$PWT/wip.txt"
fix_issue 305 OPEN "status:claimed"
driver_state_init 305 --worktree "$PWT" --branch "tkt-305/work"
: > "$GH_LOG"
out=$(driver_park 305 "a refusal to prove the park commits" "carry on?" 2>&1); rc=$?
want "park always parks"                    "20" "$rc"
want "and the work is COMMITTED, not staged" "" "$(git -C "$PWT" status --porcelain)"
want_in "with a type the project allows"    'chore' "$(git -C "$PWT" log -1 --format=%s)"
want_in "it names what it staged"           'wip.txt' "$out"
want_in "and the ticket stops reading as claimed" 'remove-label status:claimed' "$(cat "$GH_LOG")"

echo "--- F6 · a commit that is refused is reported as a commit that was refused ---"
cat > "$PWT/.husky/_/commit-msg" <<'HOOK'
#!/usr/bin/env sh
echo "✖ subject may not be empty [subject-empty]" >&2
exit 1
HOOK
chmod +x "$PWT/.husky/_/commit-msg"
printf 'more\n' > "$PWT/wip2.txt"
out=$(driver_park 305 "a refusal whose commit cannot land" 2>&1); rc=$?
want "it still parks"                      "20" "$rc"
want_in "and blames the commit, not the push" 'could NOT be committed' "$out"
want_in "quoting the hook that refused it"    'subject-empty' "$out"

exit $FAILED
