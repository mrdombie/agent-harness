#!/usr/bin/env bash
# fix-class.test.sh — a review finding that names a class of mistake is fixed in every
# instance, not only the line the reviewer stood on. The fix step hands the fixer the
# class and each place it occurs, in the finding's own entry.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../steps/fix.sh" || exit 1

WT="$FIX/wt911"
git -C "$REPO" worktree add -q "$WT" -b "tkt-911/work" develop
driver_state_init 911 --worktree "$WT" --branch "tkt-911/work"
fix_issue 911 OPEN "status:claimed"
S="$(driver_state_dir 911)/steps"; mkdir -p "$S"
CLS='{"id":"C1","file":"src/panel.tsx","line":14,"grade":"major","tag":"important","votes":{"agree":2,"of":2},"class":"a failed read shown as empty","instances":["src/panel.tsx:14","src/rail.tsx:61","src/list.tsx:8"],"summary":"the panel shows empty on a failed read","reason":"a person whose queue failed sees nothing to do","fix":"render the failed state"}'
ONE='{"id":"O1","file":"src/save.ts","line":3,"grade":"major","summary":"the save is dropped","reason":"r","fix":"f"}'
printf '{"step":"review","skills":["code-review"],"status":"reviewed","round":1,"verdict":"BLOCKED","findings":[%s,%s]}\n' "$CLS" "$ONE" > "$S/review.json"
jq '.counters.review = 1 | .counters.fix = 0' "$(driver_state_dir 911)/state.json" > "$FIX/st" && mv "$FIX/st" "$(driver_state_dir 911)/state.json"

# The fixer answers with a question, so the step stops after handing the findings over.
fix_ai fix '{"step":"fix","skills":["superpowers:receiving-code-review"],"status":"park","round":1,"cleared":[],"deferred":[],"question":"stop here","questionFor":"pm","questionKind":"other"}' superpowers:receiving-code-review
driver_step_fix 911 >/dev/null 2>&1
handed=$(cat "$(driver_fact_dir 911 fix)/BLOCKERS" 2>/dev/null)

echo "--- a class finding is handed on as a class, with every instance ---"
want_in "the class is named"                 'class: a failed read shown as empty' "$handed"
want_in "every instance is listed"           'src/panel.tsx:14, src/rail.tsx:61, src/list.tsx:8' "$handed"
want_in "and the fixer is told to fix each"  'fix every instance' "$handed"
echo "--- a finding with no class is handed on as before ---"
one=$(printf '%s\n' "$handed" | awk '/^- id O1/ {p=1; print; next} /^- id / {p=0} p')
want_in "the plain finding is there"         'id O1' "$one"
want_not_in "and carries no class line"      'class:' "$one"

echo "--- plant: the class line out of a copy of the kit, the case fails ---"
KIT="$FIX/kit"; rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$KIT/"
python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' \
  "$KIT/driver/steps/fix.sh" '\(if .class then "\n  class: \(.class) — fix every instance, not only this line: \((.instances // []) | join(", "))" else "" end)' \
  && planted=1 || planted=0
want "plant landed" 1 "$planted"
rm -rf "$(driver_fact_dir 911 fix)"
bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/ai-step.sh" && . "$1/driver/steps/fix.sh" && driver_step_fix 911' _ "$KIT" >/dev/null 2>&1
planted_out=$(cat "$(driver_fact_dir 911 fix)/BLOCKERS" 2>/dev/null)
want_in "planted: the step still ran and handed the findings over" 'id C1' "$planted_out"
want_not_in "planted: the class is no longer handed on" 'class: a failed read' "$planted_out"

suite_end "$FAILED"
