#!/usr/bin/env bash
# mf-fix-deferred.test.sh — under merge first only a Critical parks (the owner, 2026-10-23).
# A Major the fix round defers, because it cannot be fixed here (a schema change the spec
# rules out, say), is filed as a fix-after-merge follow-up and the change ships; on a ticket
# that is itself a follow-up it is dropped with a note. A deferred Critical still parks.
# Seen on the origin project's #5059 and #13037, both answered by hand.
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
jq '.release = {mergeFirst: true, done: false}' "$HARNESS_CFG_PATH" > "$FIX/mf-on.json"
export HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/pl"; printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/sf"; chmod +x "$FIX/pl" "$FIX/sf"
export DRIVER_POLISH_LIST="$FIX/pl" DRIVER_SCREEN_FINDINGS="$FIX/sf"

c() { git -C "$1" -c user.email=t@e.invalid -c user.name=T commit -qm "$2"; git -C "$1" rev-parse HEAD; }
N=0
setup() { # <labels> <deferred grade> — a fix round that clears F1 and defers D1; R: rc, follow-ups, park
  N=$((N + 1)); local t=$((930 + N)) wt="$FIX/wt$N"
  git -C "$REPO" worktree add -q "$wt" -b "tkt-$t/work" develop
  driver_state_init "$t" --worktree "$wt" --branch "tkt-$t/work"; fix_issue "$t" OPEN "$1"
  printf '#!/usr/bin/env bash\ngrep -q "mode=new" mode.txt || { echo " FAIL  mode"; exit 1; }\n' > "$wt/mode.test.sh"
  printf 'mode=old\n' > "$wt/mode.txt"; git -C "$wt" add mode.test.sh mode.txt; local ts is; ts=$(c "$wt" "test: mode")
  printf 'mode=new\n' > "$wt/mode.txt"; git -C "$wt" add mode.txt; is=$(c "$wt" "fix: mode")
  local s; s="$(driver_state_dir "$t")/steps"; mkdir -p "$s"
  jq -n --arg g "$2" '{step:"review", skills:[], status:"reviewed", round:1, verdict:"BLOCKED", findings:[
      {id:"F1", file:"mode.txt", line:1, grade:"major", sameChange:true, summary:"the mode is still old", reason:"r", fix:"f"},
      {id:"D1", file:"mode.txt", line:2, grade:$g, sameChange:true, summary:"the count is stale after an edit", reason:"r", fix:"add a column"}]}' > "$s/review.json"
  jq '.counters.review = 1 | .counters.fix = 0' "$(driver_state_dir "$t")/state.json" > "$FIX/st" && mv "$FIX/st" "$(driver_state_dir "$t")/state.json"
  fix_ai fix "$(jq -nc --arg ts "$ts" --arg is "$is" '{step:"fix", skills:["superpowers:receiving-code-review"], status:"fixed", round:1,
      cleared:[{blockerId:"F1", change:[{path:"mode.txt", action:"modify"}], test:{file:"mode.test.sh", behaviour:"b", redWhen:"r"},
                command:"bash mode.test.sh", testCommit:$ts, implCommit:$is, failedBefore:true, passedAfter:true}],
      deferred:[{blockerId:"D1", reason:"it needs a schema change the spec rules out", followUp:"a follow-up ticket"}]}')" superpowers:receiving-code-review
  local rc=0; OUT=$(driver_step_fix "$t" 2>&1) || rc=$?
  R="rc=$rc fu=$(jq -r .id "$s/review.followups.jsonl" 2>/dev/null | tr '\n' ' ' | sed 's/ $//') park=$([ -n "$(driver_state_get "$t" park_note)" ] && echo yes || echo no)"
  T=$t
}

echo "--- a deferred Major is a follow-up, and the round passes ---"
setup "status:claimed,P1" major
want "filed, not parked"                       "rc=0 fu=D1 park=no" "$R"
want "it leaves the review's findings"         "F1" "$(jq -r '[.findings[].id] | join(" ")' "$(driver_state_dir "$T")/steps/review.json")"
want_in "and the run says it ships"            'D1 \(major\) could not be fixed here — merge first: filed as a follow-up' "$OUT"
want "it is noted for the PR"                  "follow-up" "$(jq -r 'select(.id == "D1") | .list' "$(driver_state_dir "$T")/steps/review.deferred.jsonl")"

echo "--- on a ticket that is itself a follow-up it is dropped, with a note ---"
setup "status:claimed,P1,fix-after-merge" major
want "dropped, not parked"                     "rc=0 fu= park=no" "$R"
want "noted as dropped"                        "dropped" "$(jq -r 'select(.id == "D1") | .list' "$(driver_state_dir "$T")/steps/review.deferred.jsonl")"

echo "--- a deferred Critical still parks ---"
setup "status:claimed,P1" critical
want "refused and parked"                      "rc=24 fu= park=yes" "$R"

echo "--- plant: the merge-first filing out of a copy of the kit, a Major parks again ---"
KIT="$FIX/kit"; rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$KIT/"
python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "false", 1)); sys.exit(0 if n == 1 else 1)' \
  "$KIT/driver/steps/fix.sh" '[ "${left:-[]}" != "[]" ] && driver_merge_first' || want "plant landed" "landed" "missed"
. "$KIT/driver/steps/fix.sh"
setup "status:claimed,P1" major
want "planted: the Major parks"                "rc=24 fu= park=yes" "$R"

suite_end "$FAILED"
