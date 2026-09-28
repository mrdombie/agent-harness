#!/usr/bin/env bash
# push-gates.e2e.test.sh — a screen change walked through driver/build-ticket and
# PUSHED, against a consuming project's own pre-push gates. Not a copy of them.
#
# WHY THIS SUITE IS DIFFERENT FROM EVERY OTHER ONE HERE. The rest of the driver's
# tests stub the world, which is right for control flow and is exactly how T2-2
# stayed invisible: the driver could not push a screen change on the project it
# runs on, and twelve green suites said nothing, because none of them had ever met
# that project's hooks. The trial found it by losing 73 minutes and 9 commits.
#
# So this one takes the REAL files off the consuming project's trunk —
# `scripts/check-ui-gate-attested`, `scripts/check-design-critic-attested`,
# `scripts/lib/ui-diff-fingerprint` and `scripts/record-verdict.sh` — puts them in
# a scratch clone behind a real `pre-push`, and asserts the branch the driver
# produces is ACCEPTED by them. The only thing stubbed is the model: a suite must
# not start an agent, and the reviewers are agents.
#
# WHAT IT NEEDS, AND WHAT IT DOES WITHOUT ONE. The kit names no project, so the
# checkout comes from HARNESS_E2E_REPO, or from the operator's HARNESS_MAIN_REPO.
# With neither — or with one that carries none of those gates — this SKIPS and says
# so in a line nobody can mistake for a pass. It is not run on a machine that has
# no consuming project to run it against.
#
# Run: bash "$0"
#      HARNESS_E2E_REPO=/path/to/the/project bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../.." && pwd)"

PROJECT="${HARNESS_E2E_REPO:-${HARNESS_MAIN_REPO:-}}"
[ -n "$PROJECT" ] || PROJECT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)"
GATE_FILES="scripts/lib/ui-diff-fingerprint.ts
scripts/check-ui-gate-attested/index.ts
scripts/check-design-critic-attested/index.ts
scripts/record-verdict.sh"
REF=""
for r in origin/develop develop origin/main main HEAD; do
  git -C "$PROJECT" rev-parse --verify -q "$r" >/dev/null 2>&1 || continue
  ok=1
  while IFS= read -r f; do
    git -C "$PROJECT" cat-file -e "$r:$f" 2>/dev/null || { ok=0; break; }
  done <<EOF
$GATE_FILES
EOF
  [ "$ok" -eq 1 ] && { REF="$r"; break; }
done
if [ -z "$REF" ]; then
  echo "SKIPPED — no consuming project with attestation gates to run against."
  echo "SKIPPED — looked in '${PROJECT:-<nothing>}' for: $(printf '%s' "$GATE_FILES" | tr '\n' ' ')"
  echo "SKIPPED — set HARNESS_E2E_REPO to a checkout that has them. NOTHING WAS PROVED."
  exit 0
fi
if [ ! -d "$PROJECT/node_modules/.bin" ]; then
  echo "SKIPPED — '$PROJECT' has no installed node_modules, so its gates cannot run. NOTHING WAS PROVED."
  exit 0
fi
echo "running against $PROJECT at $REF"

. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
fix_real_briefs

# ---- the scratch clone: the project's real gates, and nothing else of it -------
rm -rf "$REPO"; mkdir -p "$REPO"
while IFS= read -r f; do
  mkdir -p "$REPO/$(dirname "$f")"
  git -C "$PROJECT" show "$REF:$f" > "$REPO/$f"
done <<EOF
$GATE_FILES
EOF
chmod +x "$REPO/scripts/record-verdict.sh"
ln -sfn "$PROJECT/node_modules" "$REPO/node_modules"
printf 'node_modules\n' > "$REPO/.gitignore"
printf '{ "name": "driver-e2e-scratch", "private": true }\n' > "$REPO/package.json"
# THE GATE FILES ARE RUN DIRECTLY, not through an `npm run <name>`. Two reasons and
# both matter: the kit must never assume a project HAS a named script — `npm run
# <missing>` prints nothing and exits 1, which reads as a gate failure rather than
# as a missing gate, and `check:project-agnostic` ratchets exactly that — and
# running the file the suite copied in is what makes this a test of the gate rather
# than of a name that could point anywhere.
UIGATE="npx --no-install tsx scripts/check-ui-gate-attested/index.ts"
DCGATE="npx --no-install tsx scripts/check-design-critic-attested/index.ts"
# The pre-push, as a project writes it: each gate its own command, its own exit
# code, nothing batched.
mkdir -p "$REPO/.husky"
cat > "$REPO/.husky/pre-push" <<HOOK
#!/usr/bin/env sh
$UIGATE --base origin/develop --head HEAD || exit 1
$DCGATE --base origin/develop --head HEAD || exit 1
HOOK
chmod +x "$REPO/.husky/pre-push"

# The reviewers. These are the agents — the one thing a suite may not start — so
# they are files the test writes, and what they print is what the PROJECT'S OWN
# recorder reads. The recorder is real, so nothing here can write a verdict the
# reviewer did not say.
cat > "$FIX/ui-gate-reviewer" <<'SH'
#!/usr/bin/env sh
echo "VERDICT: SHIP"
echo "every control is wired; brand tokens only; no fabricated data."
SH
cat > "$FIX/design-critic-reviewer" <<'SH'
#!/usr/bin/env sh
echo "VERDICT: SHIP"
echo "on-theme, alive, nothing that reads as generated."
SH
chmod +x "$FIX/ui-gate-reviewer" "$FIX/design-critic-reviewer"

mkdir -p "$REPO/.claude"
jq -n --arg wr "$FIX/trees" --arg ui "$FIX/ui-gate-reviewer" --arg dc "$FIX/design-critic-reviewer" '{
  repo: "acme/widgets", integrationBranch: "develop", branchPrefix: "tkt-",
  stateDir: "/nonexistent-must-be-overridden", sisterRepos: [],
  worktreeRoot: $wr,
  standards: "docs/CODING_STANDARDS.md",
  gates: { local: ["echo gates-ok"] },
  design: { surfacePaths: ["apps/web/**"],
            philosophy: "docs/design/design-philosophy.md",
            render: "printf \"desk light\\tshots/a.png\\tlight\\t/dashboard/desk\\ndesk dark\\tshots/b.png\\tdark\\t/dashboard/desk\\n\"" },
  push: { requires: [
    { name: "ui-gate",       review: $ui, record: "bash scripts/record-verdict.sh ui-gate --sha {{SHA}} --base {{BASE}}" },
    { name: "design-critic", review: $dc, record: "bash scripts/record-verdict.sh design-critic --sha {{SHA}} --base {{BASE}}" } ] },
  labels: { drafting:"status:drafting", ready:"status:ready", claimed:"status:claimed",
            inReview:"status:in-review", gated:"status:gated", partial:"status:partial",
            blocked:"status:blocked", externalBlocked:"status:external-blocked",
            parked:"status:parked", needsHuman:"status:needs-human",
            pmDecision:"status:pm-decision", pmTrack:"status:pm-track",
            hold:"needs:human-approval", decision:["status:pm-decision"] }
}' > "$REPO/.claude/harness.json"

mkdir -p "$REPO/apps/web/src/app/dashboard" "$REPO/t"
printf 'export default function Desk() { return <main>desk</main> }\n' \
  > "$REPO/apps/web/src/app/dashboard/page.tsx"
git -C "$REPO" init -q -b develop
git -C "$REPO" config user.email t@example.invalid
git -C "$REPO" config user.name Tester
# Relative, so it resolves per worktree rather than in the shared git directory.
git -C "$REPO" config core.hooksPath .husky
git -C "$REPO" add scripts package.json .gitignore .husky .claude apps
git -C "$REPO" commit -qm "the project's own attestation gates"
git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop

TICKET=501
fix_issue "$TICKET" OPEN "status:ready"

# ---- the branch the driver will walk ------------------------------------------
# The build step PROVES a test red then green from two commits, so the two commits
# have to exist. The model is stubbed; the git history is real, and the change is a
# real screen file — which is what makes the project's gates fire at all.
WT="$FIX/trees/tkt-$TICKET-work"
mkdir -p "$FIX/trees"
git -C "$REPO" worktree add -q "$WT" -b "tkt-$TICKET/desk-header" develop
ln -sfn "$PROJECT/node_modules" "$WT/node_modules"
mkdir -p "$WT/t"
cat > "$WT/t/desk.sh" <<'SH'
#!/usr/bin/env bash
grep -q 'Post state' "$(dirname "$0")/../apps/web/src/app/dashboard/page.tsx" 2>/dev/null
SH
git -C "$WT" add t/desk.sh
git -C "$WT" commit -qm "test: the desk masthead names the post state"
TSHA=$(git -C "$WT" rev-parse HEAD)
printf 'export default function Desk() { return <main>Post state: draft</main> }\n' \
  > "$WT/apps/web/src/app/dashboard/page.tsx"
git -C "$WT" add apps/web/src/app/dashboard/page.tsx
git -C "$WT" commit -qm "feat: the desk masthead names the post state"
ISHA=$(git -C "$WT" rev-parse HEAD)

fix_ai plan "$(jq -nc \
  '{step:"plan", skills:["superpowers:writing-plans"], status:"planned",
    designSource:"approved-picture",
    designRef:"https://claude.ai/artifact/desk-v3 — approved on the ticket",
    premise:{verdict:"still-true", evidence:"the masthead names no post state"},
    tasks:[{title:"the desk masthead names the post state",
            files:[{path:"apps/web/src/app/dashboard/page.tsx", action:"modify"}],
            tests:[{file:"t/desk.sh", behaviour:"the masthead renders the post state",
                    redWhen:"the post state is removed from the masthead"}]}]}')" \
  superpowers:writing-plans
fix_ai build "$(jq -nc --arg ts "$TSHA" --arg is "$ISHA" \
  '{step:"build", skills:["superpowers:subagent-driven-development"], status:"built",
    task:"the desk masthead names the post state",
    testFirst:{test:{file:"t/desk.sh", behaviour:"the masthead renders the post state",
                     redWhen:"the post state is removed from the masthead"},
               command:"bash t/desk.sh", testCommit:$ts, implCommit:$is,
               failedBefore:true, redOutput:"FAIL", passedAfter:true, greenOutput:"PASS"},
    changed:[{path:"apps/web/src/app/dashboard/page.tsx", action:"modify"}],
    changelog:{skipped:"a fixture change"}}')" \
  superpowers:subagent-driven-development
fix_ai compare "$(jq -nc \
  '{step:"compare", skills:["superpowers:verification-before-completion"], status:"compared",
    approved:{ref:"https://claude.ai/artifact/desk-v3 — approved on the ticket"},
    renders:[{name:"desk light", path:"shots/a.png", theme:"light"},
             {name:"desk dark",  path:"shots/b.png", theme:"dark"}],
    differences:[]}')" \
  superpowers:verification-before-completion
fix_ai review "$(jq -nc \
  '{step:"review", skills:["superpowers:requesting-code-review"], status:"reviewed",
    round:1, verdict:"SHIP", findings:[]}')" \
  superpowers:requesting-code-review

export HARNESS_STATE_DIR="$STATE"
. "$HERE/../state.sh" || exit 1
driver_state_init "$TICKET" --worktree "$WT" --branch "tkt-$TICKET/desk-header"

echo "--- the control: this project's own gate refuses the branch as it stands ---"
# Without this the whole suite could pass against a gate that is not running —
# a missing tsx, a base that does not resolve, a glob that matches nothing.
( cd "$WT" && $UIGATE --base origin/develop --head HEAD ) \
  > "$FIX/control.txt" 2>&1; crc=$?
want "the real ui-gate attestation refuses an unattested screen diff" "1" "$crc"
want_in "naming the file it saw"  'apps/web/src/app/dashboard/page.tsx' "$(cat "$FIX/control.txt")"
( cd "$WT" && git push -q -u origin "tkt-$TICKET/desk-header" ) >"$FIX/prepush.txt" 2>&1; prc=$?
want "and the pre-push hook refuses the push" "1" "$prc"
want "so nothing reached origin"  "" \
  "$(git -C "$FIX/origin" rev-parse --verify -q "tkt-$TICKET/desk-header" 2>/dev/null)"

echo "--- the walk ---"
out=$(bash "$HERE/../build-ticket" "$TICKET" 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
want "the run finishes"  "0" "$rc"
want "every step is recorded" "start,plan,build,fix,compare,self-check,review,record,ship" \
  "$(driver_state_get "$TICKET" 'done|join(",")')"

echo "--- T2-2 · the verdicts are the reviewers' own, and the push is accepted ---"
MSGS=$(git -C "$WT" log --format=%B "origin/develop..HEAD")
want_in "a UI-Gate trailer is on the branch"       'UI-Gate: SHIP \(agent\) [0-9a-f]{12}' "$MSGS"
want_in "and a Design-Critic trailer beside it"    'Design-Critic: SHIP \(agent\) [0-9a-f]{12}' "$MSGS"
want "THE BRANCH REACHED ORIGIN"  "1" \
  "$(git -C "$FIX/origin" rev-parse --verify -q "tkt-$TICKET/desk-header" >/dev/null 2>&1 && echo 1)"
# Read again, from the pushed head, by the project's own gates — not by this suite's
# reading of a trailer. A regex that matches is not a gate that passed.
( cd "$WT" && $UIGATE --base origin/develop --head HEAD ) \
  > "$FIX/after-ui.txt" 2>&1
want "the real ui-gate attestation now passes"       "0" "$?"
want_in "saying which verdict it read"  'verdict SHIP \(agent\)' "$(cat "$FIX/after-ui.txt")"
( cd "$WT" && $DCGATE --base origin/develop --head HEAD ) \
  > "$FIX/after-dc.txt" 2>&1
want "and so does the real design-critic attestation" "0" "$?"

echo "--- and the driver never writes a verdict the reviewer did not say ---"
# The reviewer comes back SPIT-BACK on a fresh branch. The project's own recorder
# refuses it, so no trailer is written, so the push stays refused — and the ticket
# parks carrying the reviewer's words rather than a hand-off that cannot land.
cat > "$FIX/ui-gate-reviewer" <<'SH'
#!/usr/bin/env sh
echo "VERDICT: SPIT-BACK"
echo "the save control on the masthead calls nothing."
SH
chmod +x "$FIX/ui-gate-reviewer"
TICKET2=502
fix_issue "$TICKET2" OPEN "status:ready"
WT2="$FIX/trees/tkt-$TICKET2-work"
git -C "$REPO" worktree add -q "$WT2" -b "tkt-$TICKET2/desk-header" develop
ln -sfn "$PROJECT/node_modules" "$WT2/node_modules"
mkdir -p "$WT2/t"
cp "$WT/t/desk.sh" "$WT2/t/desk.sh"
git -C "$WT2" add t/desk.sh
git -C "$WT2" commit -qm "test: the desk masthead names the post state"
TS2=$(git -C "$WT2" rev-parse HEAD)
printf 'export default function Desk() { return <main>Post state: draft</main> }\n' \
  > "$WT2/apps/web/src/app/dashboard/page.tsx"
git -C "$WT2" add apps/web/src/app/dashboard/page.tsx
git -C "$WT2" commit -qm "feat: the desk masthead names the post state"
IS2=$(git -C "$WT2" rev-parse HEAD)
fix_ai build "$(jq -nc --arg ts "$TS2" --arg is "$IS2" \
  '{step:"build", skills:["superpowers:subagent-driven-development"], status:"built",
    task:"the desk masthead names the post state",
    testFirst:{test:{file:"t/desk.sh", behaviour:"the masthead renders the post state",
                     redWhen:"the post state is removed from the masthead"},
               command:"bash t/desk.sh", testCommit:$ts, implCommit:$is,
               failedBefore:true, redOutput:"FAIL", passedAfter:true, greenOutput:"PASS"},
    changed:[{path:"apps/web/src/app/dashboard/page.tsx", action:"modify"}],
    changelog:{skipped:"a fixture change"}}')" \
  superpowers:subagent-driven-development
driver_state_init "$TICKET2" --worktree "$WT2" --branch "tkt-$TICKET2/desk-header"
: > "$GH_LOG"
out2=$(bash "$HERE/../build-ticket" "$TICKET2" 2>&1); rc2=$?
want "the run parks"  "20" "$rc2"
want_in "carrying the reviewer's own refusal" 'SPIT-BACK' "$out2"
want_not_in "no trailer was written"  'UI-Gate:' "$(git -C "$WT2" log --format=%B origin/develop..HEAD)"
want_not_in "and nothing was marked ready" 'pr ready' "$(cat "$GH_LOG")"
want_in "the park carries a status label"  'add-label status:parked' "$(cat "$GH_LOG")"

exit $FAILED
