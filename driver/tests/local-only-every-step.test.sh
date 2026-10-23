#!/usr/bin/env bash
# local-only-every-step.test.sh — under `gates.localOnly` every driver step runs only
# gates.local and the one named proof file (the owner, 2026-10-22: CI is the one gate).
# A project whose gates.changed holds test:changed and a full typecheck, and whose
# gates.ratchets names a ratchet, is walked through a whole build (start → ship) and a
# whole repair, with every npm call recorded: neither the changed list's extras nor the
# ratchet nor the hook's verify:push ever runs; the proof file does; every push names
# its head, so the hook skips. On 2026-10-23 builders parked seven times on checks CI
# runs (clone-ratchet, test:changed, composition, ui-tests-interact) that a step ran here.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'

# Every project command goes through npm here, and npm records itself.
RAN="$FIX/lo-ran.log"; : > "$RAN"; export RAN
printf '#!/usr/bin/env bash\nprintf "npm %%s\\n" "$*" >> "$RAN"\nexit 0\n' > "$BIN/npm"; chmod +x "$BIN/npm"
ran() { cat "$RAN"; }
LEAK='test:changed|run typecheck$|clone-ratchet|verify:push'

jq '.gates = {localOnly: true,
              local: ["npm run lint:changed", "npm run typecheck:changed", "npm run format:changed"],
              changed: ["npm run lint:changed", "npm run typecheck", "npm run test:changed"],
              ratchets: [{check: "check:clone-ratchet", tighten: "npm run check:clone-ratchet -- --update",
                          baseline: ["scripts/clone/baseline.json"]}]}' \
  "$HARNESS_CFG_PATH" > "$FIX/lo.json" && mv "$FIX/lo.json" "$HARNESS_CFG_PATH"
git -C "$REPO" commit -qam "config: local only"
git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop
# The project's pre-push, the shape every consuming project's has: a head the driver
# names is skipped, anything else runs the push suite.
HOOKS="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/hooks"; mkdir -p "$HOOKS"
cat > "$HOOKS/pre-push" <<SH
#!/usr/bin/env bash
while read -r l s r rs; do
  [ "\$s" = "\${HARNESS_LOCAL_GATES_HEAD:-}" ] && { echo skipped >> "$FIX/lo-hook.log"; exit 0; }
done
echo suite >> "$FIX/lo-hook.log"
npm run verify:push:fast
SH
chmod +x "$HOOKS/pre-push"; : > "$FIX/lo-hook.log"

fix_brief plan   superpowers:writing-plans
fix_brief build  superpowers:subagent-driven-development
fix_brief review superpowers:requesting-code-review
fix_brief repair superpowers:systematic-debugging
fix_ai review '{"step":"review","skills":["superpowers:requesting-code-review"],"status":"reviewed","round":1,"verdict":"SHIP","findings":[]}' \
  superpowers:requesting-code-review

# k <fn> <args…> — a kit function run from ${SUT_KIT:-the kit}.
k() { bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; k="$1"; shift
  . "$k/driver/driver-env.sh" && . "$k/driver/state.sh" && . "$k/driver/facts.sh" && . "$k/driver/steps/self-check.sh" && "$@"' _ "${SUT_KIT:-$ROOT}" "$@"; }

# ---- the cases ----------------------------------------------------------------
N=800
case_build() { # a whole build, start → ship: R is "<rc> <leaks> proof=<n> hook=<last>"
  N=$((N + 1)); local t=$N wt="$FIX/wt$N" ts is
  : > "$RAN"; : > "$FIX/lo-hook.log"; rm -rf "$STATE/driver/$t"
  fix_issue "$t" OPEN "status:ready"
  git -C "$REPO" worktree add -q "$wt" -b "tkt-$t/work" develop
  mkdir -p "$wt/t"
  printf '#!/usr/bin/env bash\necho PROOF >> "%s"\ngrep -q the-feature "$(dirname "$0")/../feature.txt" 2>/dev/null\n' "$RAN" > "$wt/t/check.sh"
  git -C "$wt" add t/check.sh; git -C "$wt" commit -qm "test: the feature"; ts=$(git -C "$wt" rev-parse HEAD)
  printf 'the-feature\n' > "$wt/feature.txt"; git -C "$wt" add feature.txt; git -C "$wt" commit -qm "feat: the feature"; is=$(git -C "$wt" rev-parse HEAD)
  fix_ai plan "$(jq -nc '{step:"plan", skills:["superpowers:writing-plans"], status:"planned", designSource:"ticket-body",
      premise:{verdict:"still-true", evidence:"feature.txt does not exist yet"},
      tasks:[{title:"the feature is present", files:[{path:"feature.txt", action:"create"}],
              tests:[{file:"t/check.sh", behaviour:"feature.txt carries the-feature", redWhen:"feature.txt is deleted"}]}]}')" \
    superpowers:writing-plans
  fix_ai build "$(jq -nc --arg ts "$ts" --arg is "$is" '{step:"build", skills:["superpowers:subagent-driven-development"], status:"built",
      task:"the feature is present",
      testFirst:{test:{file:"t/check.sh", behaviour:"feature.txt carries the-feature", redWhen:"feature.txt is deleted"},
                 command:"bash t/check.sh", testCommit:$ts, implCommit:$is,
                 failedBefore:true, redOutput:"FAIL", passedAfter:true, greenOutput:"PASS"},
      changed:[{path:"feature.txt", action:"create"}], changelog:{skipped:"a fixture change"}}')" \
    superpowers:subagent-driven-development
  k driver_state_init "$t" --worktree "$wt" --branch "tkt-$t/work"
  local rc=0; HARNESS_STATE_DIR="$STATE" bash "${SUT_KIT:-$ROOT}/driver/build-ticket" "$t" > "$FIX/build-$t.out" 2>&1 || rc=$?
  R="$rc leaks=[$(grep -E "$LEAK" "$RAN" | tr '\n' ',')] proof=$(grep -c '^PROOF$' "$RAN") hook=$(tail -1 "$FIX/lo-hook.log")"
}

case_repair() { # a whole repair whose fix names a ratchet as its gate: R is "<rc> <leaks>"
  N=$((N + 1)); local t=$N src="$FIX/src$N" head
  : > "$RAN"; : > "$FIX/lo-hook.log"; rm -rf "$STATE/driver/$t"; : > "$GH_LOG"
  git clone -q -b develop "$FIX/origin" "$src"
  git -C "$src" checkout -q -b "tkt-$t/work"
  printf 'broken\n' > "$src/state.txt"; git -C "$src" add .; git -C "$src" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: $t"
  git -C "$src" push -q origin "tkt-$t/work"; head=$(git -C "$src" rev-parse HEAD)
  fix_issue "$t" OPEN "status:in-review"
  jq -n --arg b "tkt-$t/work" '[{number:61, headRefName:$b, headRefOid:"x", isDraft:false, mergeStateStatus:"CLEAN",
         statusCheckRollup:[{name:"Code gates", status:"COMPLETED", conclusion:"FAILURE"}]}]' > "$FIX/gh/prs.json"
  : > "$FIX/pr-created-61"; printf '{"number":61,"isDraft":false,"body":"Closes #%s"}\n' "$t" > "$FIX/gh/pr-view.json"
  cat > "$BIN/claude-hands" <<'SH'
#!/usr/bin/env bash
case " $* " in *" --name repair "*)
  printf 'fixed\n' > state.txt; git add state.txt
  git -c user.email=t@example.invalid -c user.name=T commit -qm "fix: the baseline" >/dev/null 2>&1 ;;
esac
exec "$BIN/claude" "$@"
SH
  chmod +x "$BIN/claude-hands"
  fix_ai repair '{"step":"repair","skills":["superpowers:systematic-debugging"],"status":"repaired","cause":"the clone baseline clashed","fixes":[{"what":"re-measured the clone baseline","proof":"gate","change":[{"path":"state.txt","action":"modify"}],"command":"npm run check:clone-ratchet","noTestBecause":"a ratchet baseline"}]}' \
    superpowers:systematic-debugging
  printf 'REPAIR on PR #61 at %s: CI went red on: Code gates\n' "$head" > "$FIX/brief-$t.md"
  local rc=0; DRIVER_CLAUDE="$BIN/claude-hands" HARNESS_STATE_DIR="$STATE" bash "${SUT_KIT:-$ROOT}/driver/build-ticket" "$t" --repair "$FIX/brief-$t.md" > "$FIX/repair-$t.out" 2>&1 || rc=$?
  rm -f "$FIX/gh/pr-view.json"; printf '[]\n' > "$FIX/gh/prs.json"
  R="$rc leaks=[$(grep -E "$LEAK" "$RAN" | tr '\n' ',')]"
}

case_park() { # a park push, with no local head on the record: R is the hook's word
  N=$((N + 1)); local t=$N wt="$FIX/wt$N"
  : > "$RAN"; : > "$FIX/lo-hook.log"
  git -C "$REPO" worktree add -q "$wt" -b "tkt-$t/work" develop
  printf 'p\n' > "$wt/p.txt"; git -C "$wt" add p.txt; git -C "$wt" commit -qm "wip: p"
  k driver_state_init "$t" --worktree "$wt" --branch "tkt-$t/work"
  k driver_push "$t" "$wt" "tkt-$t/work" park >/dev/null 2>&1
  R="hook=$(tail -1 "$FIX/lo-hook.log") leaks=[$(grep -E "$LEAK" "$RAN" | tr '\n' ',')]"
}

case_tighten() { # a ratchet's headroom on a gate's output: R is "<rc> <leaks>"
  : > "$RAN"; N=$((N + 1))
  printf '✗ check:clone-ratchet\n  Lock the cleanup in: npm run check:clone-ratchet -- --update\n' > "$FIX/tighten.out"
  k driver_state_init "$N" --worktree "$REPO"
  local rc=0; k _driver_ratchet_tighten "$N" "$REPO" "$FIX/tighten.out" ship >/dev/null 2>&1 || rc=$?
  R="$rc leaks=[$(grep -E "$LEAK" "$RAN" | tr '\n' ',')]"
}

case_facts() { # what every model step is told: R is "proof=<0|1> project=<0|1>"
  local p f want='Run only the fast local checks; CI is the one gate.*never a ratchet or check script \(check:clone-ratchet\), never verify:push'
  p=$(k driver_fact_proof_limits 2>/dev/null); f=$(k driver_fact_project 2>/dev/null)
  R="proof=$(printf '%s' "$p" | grep -cE "$want") project=$(printf '%s' "$f" | grep -cE "$want")"
}

echo "--- a whole build under gates.localOnly ---"
case_build
want "it ships, runs nothing CI keeps, proves its file, and the hook skips" "0 leaks=[] proof=2 hook=skipped" "$R"
want_in "the local set ran"                       '^npm run lint:changed$' "$(ran)"
want_in "the proof's typecheck is the local one"  '^npm run typecheck:changed$' "$(ran)"

echo "--- a whole repair whose fix names a ratchet ---"
case_repair
want "it ships and the ratchet never runs here"   "0 leaks=[]" "$R"
want_in "and says CI runs it"                     'not in gates.local, so it is not run here' "$(cat "$FIX/repair-$N.out")"

echo "--- a park push names its head too ---"
case_park
want "the hook skips and verify:push never runs"  "hook=skipped leaks=[]" "$R"

echo "--- a ratchet's headroom is never lowered here ---"
case_tighten
want "nothing is tightened and nothing runs"      "1 leaks=[]" "$R"

echo "--- every model step is told the same ---"
case_facts
want "proof limits and the project facts say it"  "proof=1 project=1" "$R"
has() { grep -cF -- "$2" "$ROOT/briefs/$1.md" | sed 's/^[1-9][0-9]*$/yes/'; }
for b in build fix repair; do want "the $b brief carries the proof limits" yes "$(has "$b" '{{PROOF_LIMITS}}')"; done
want "the quick brief carries the project facts" yes "$(has quick '{{PROJECT_FACTS}}')"
for b in fix repair quick; do want "the $b brief says the fast local checks only" yes "$(has "$b" 'gates.localOnly')"; done

echo "--- plants: each line out of a copy of the kit, its case fails ---"
KIT="$FIX/kit"
plant() { # <label> <file under the kit> <exact text to delete>
  rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$KIT/"
  python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" \
    || { want "plant landed: $1" "landed" "missed"; return 1; }
}
export SUT_KIT="$KIT"
plant "every push names its head" driver/driver-env.sh '  if [ -z "$lg" ] && driver_gates_local_only && driver_gates_local_set; then
    lg=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
  fi
' && { case_park; want "planted (every push names its head): the hook runs verify:push" "hook=suite leaks=[npm run verify:push:fast,]" "$R"; }
plant "no ratchet lowered here" driver/steps/self-check.sh '  if driver_gates_local_only; then
    driver_say "   ratchet: $label — gates.localOnly: no ratchet runs here; CI runs it"
    return 1
  fi
' && { case_tighten; want_in "planted (no ratchet lowered here): the ratchet runs" 'clone-ratchet -- --update' "$R"; }
plant "a repair gate is gates.local" driver/steps/repair.sh '    elif driver_gates_local_only && ! driver_cmd_local "$tcmd"; then
      # A ratchet, a check script or a test run named as the gate is CI'"'"'s under localOnly.
      own_fixes=$((own_fixes+1))
      driver_say "   repair '"'"'$bid'"'"' — $tcmd is not in gates.local, so it is not run here (gates.localOnly): CI runs it on the push"
' && { case_repair; want "planted (a repair gate is gates.local): the ratchet runs" "0 leaks=[npm run check:clone-ratchet,]" "$R"; }
plant "the proof typecheck is gates.local" driver/steps/build.sh '    elif .gates.localOnly == true then
      # Under gates.localOnly every other list is for CI: only gates.local names the check.
      ([(.gates.local // []) | if type == "array" then .[] | select(tc) else empty end] | first // "")
' && { case_build; want_in "planted (the proof typecheck is gates.local): the full typecheck runs" 'leaks=\[npm run typecheck,' "$R"; }
plant "the facts say it" driver/facts.sh ' Run only the fast local checks; CI is the one gate.' \
  && { case_facts; want "planted (the facts say it): neither says it" "proof=0 project=0" "$R"; }
unset SUT_KIT

suite_end "$FAILED"
