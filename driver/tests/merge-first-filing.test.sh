#!/usr/bin/env bash
# merge-first-filing.test.sh — merge-first review findings are never filed (the owner,
# 2026-11-02: the 3-voter review replaces finding tickets and polish lists). A finding the
# round does not block goes nowhere a person has to clear: one in a file the change did not
# touch is pre-existing and goes to the nightly sweep's queue; one in a file it touched is
# dropped and noted in the PR. No follow-up ticket, no polish list — on a ticket that is
# itself a follow-up too. A Critical still blocks.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/review.sh" || exit 1
. "$HERE/../steps/ship.sh" || exit 1
fix_brief review superpowers:requesting-code-review "Review round {{ROUND}}. The change: {{DIFF}} Renders: {{RENDERS}}"
cat > "$FIX/sf" <<'SH'
#!/usr/bin/env bash
case "$1" in screens) echo home ;; esac
exit 0
SH
printf '#!/usr/bin/env bash\ncase "$1" in add) printf "%%s\\n" "$*" >> "$FIX/pl.adds" ;; esac\nexit 0\n' > "$FIX/pl"
chmod +x "$FIX/sf" "$FIX/pl"; : > "$FIX/pl.adds"
export DRIVER_SCREEN_FINDINGS="$FIX/sf" DRIVER_POLISH_LIST="$FIX/pl" SWEEP_QUEUE="$FIX/sweep.jsonl"
jq '.release = {mergeFirst: true, done: false} | .design = ((.design // {}) + {surfacePaths: ["components/**"]})' "$HARNESS_CFG_PATH" > "$FIX/mf-on.json"
on() { HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" "$@"; }

ff_tree() { # <ticket> <labels> — a branch whose change touches a.sh alone
  git -C "$REPO" worktree add -q "$FIX/ff$1" -b "tkt-$1/work" develop
  printf 'a\n' > "$FIX/ff$1/a.sh"; git -C "$FIX/ff$1" add -A; git -C "$FIX/ff$1" commit -qm "feat: a"
  driver_state_init "$1" --worktree "$FIX/ff$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "$2"
}
fu() { jq -r .id "$(driver_state_dir "$1")/steps/review.followups.jsonl" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
dj() { printf '%s/steps/review.deferred.jsonl' "$(driver_state_dir "$1")"; }
lists() { jq -r '"\(.id)=\(.list)"' "$(dj "$1")" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'; }
swept() { local n; n=$(grep -c . "$SWEEP_QUEUE" 2>/dev/null); echo "${n:-0}"; }
# Every finding is in a file the change did not touch, so none is fixed in place.
answer='{"verdict":"BLOCKED","findings":[
  {"id":"m1","file":"lib/other.sh","line":3,"grade":"major","summary":"the save is dropped","reason":"r","fix":"f"},
  {"id":"n1","file":"app/page.tsx","line":9,"grade":"minor","summary":"the gap is 12 not 16","reason":"r","fix":"f"},
  {"id":"n2","file":"lib/x.ts","line":2,"grade":"minor","summary":"the log line is vague","reason":"r","fix":"f"},
  {"id":"n3","file":"components/Card.tsx","line":4,"grade":"minor","summary":"the badge sits 2px low","reason":"r","fix":"f"}]}'
# Round 2: a Minor in the change's own file does not block, and is not pre-existing.
inchange='{"verdict":"BLOCKED","findings":[
  {"id":"i1","file":"a.sh","line":1,"grade":"minor","summary":"the a is lower case","reason":"r","fix":"f"},
  {"id":"o1","file":"lib/other.sh","line":3,"grade":"minor","summary":"the old log is vague","reason":"r","fix":"f"}]}'

echo "--- outside the change: every non-blocking finding goes to the sweep, none is filed ---"
ff_tree 801 "status:claimed,P1"
fix_ai review "$answer" superpowers:requesting-code-review
: > "$SWEEP_QUEUE"
rc=0; on driver_step_review 801 >/dev/null 2>&1 || rc=$?
want "the review ships"                        "0" "$rc"
want "nothing waits to be filed"               "" "$(fu 801)"
want "nothing goes on a polish list"           "" "$(cat "$FIX/pl.adds")"
want "each is recorded as sent to the sweep"   "m1=sweep n1=sweep n2=sweep n3=sweep" "$(lists 801)"
want "and the sweep's queue holds all four"    "4" "$(swept)"
want_in "the PR's section says where each went" 'the save is dropped \(round 1; major — outside the files of this change: to the nightly sweep\)' "$(on _driver_ship_deferred 801)"

echo "--- on a follow-up's own PR the same: nothing is filed ---"
ff_tree 802 "status:claimed,P1,fix-after-merge"
fix_ai review "$answer" superpowers:requesting-code-review
rc=0; on driver_step_review 802 >/dev/null 2>&1 || rc=$?
want "the review ships"                        "0" "$rc"
want "nothing waits to be filed"               "" "$(fu 802)"
want "the Major goes to the sweep like any other" "sweep" "$(jq -r 'select(.id == "m1") | .list' "$(dj 802)")"

echo "--- in the change's own file, a non-blocking finding is dropped, not swept ---"
ff_tree 804 "status:claimed,P1"; driver_state_bump 804 review
fix_ai review "$inchange" superpowers:requesting-code-review
: > "$SWEEP_QUEUE"
rc=0; on driver_step_review 804 >/dev/null 2>&1 || rc=$?
want "the review ships"                        "0" "$rc"
want "the in-change Minor is dropped, the other swept" "i1=dropped o1=sweep" "$(lists 804)"
want "only the pre-existing one reaches the sweep" "1" "$(swept)"
want "and nothing waits to be filed"           "" "$(fu 804)"

echo "--- a Critical still blocks there ---"
ff_tree 803 "status:claimed,P1,fix-after-merge"
fix_ai review '{"verdict":"BLOCKED","findings":[{"id":"c1","file":"lib/other.sh","line":1,"grade":"critical","summary":"another workspace sees the rows","reason":"r","fix":"f"}]}' superpowers:requesting-code-review
rc=0; on driver_step_review 803 >/dev/null 2>&1 || rc=$?
want "it goes to fix"                          "30" "$rc"

echo "--- plants: each line out of a copy of the kit, its case fails ---"
KIT="$FIX/kit"; N=850
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$KIT/"; }
kit_review() { # <ticket>
  HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/review.sh" && driver_step_review "$2"' _ "$KIT" "$1" >/dev/null 2>&1
}
case_out() { # R: what reached the sweep, and what waits to be filed
  N=$((N + 1)); ff_tree "$N" "status:claimed,P1"; fix_ai review "$answer" superpowers:requesting-code-review
  : > "$SWEEP_QUEUE"; kit_review "$N"
  R="swept=$(swept) fu=$(fu "$N")"
}
case_in() { # R: where the round-2 findings went
  N=$((N + 1)); ff_tree "$N" "status:claimed,P1"; driver_state_bump "$N" review
  fix_ai review "$inchange" superpowers:requesting-code-review
  : > "$SWEEP_QUEUE"; kit_review "$N"
  R="$(lists "$N")"
}
plant() { # <label> <file under the kit> <exact text> <case> <the result the line prevents> [what replaces it]
  kit_copy
  python3 -I -c 'import sys; p, l, r = sys.argv[1], sys.argv[2], sys.argv[3]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, r, 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" "${6:-}" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  "$4"; want "planted ($1): the case now fails" "$5" "$R"
}
kit_copy
case_out; want "the unplanted kit: four to the sweep, nothing filed" "swept=4 fu=" "$R"
case_in;  want "the unplanted kit: the in-change Minor dropped, the other swept" "i1=dropped o1=sweep" "$R"
plant "the deferred go to the sweep" driver/steps/review.sh \
  '[ "${nsweep:-0}" -eq 0 ] || _driver_review_to_sweep "$t" "$sweep" "$round"' case_out "swept=0 fu=" ':'
plant "a finding in the change's own file is marked inChange" driver/steps/review.sh \
  'else . + {inChange: true} end' case_in "i1=sweep o1=sweep" 'else . end'

suite_end "$FAILED"
