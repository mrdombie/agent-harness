#!/usr/bin/env bash
# same-file-same-change.test.sh — a Major or a Minor in a file the change itself touched
# is fixed in that change, in its one fix round, never filed as a follow-up — merge first
# included (the owner, 2026-10-23: one ticket spawned 24 findings over 8 follow-up PRs, all
# in the same four files). A finding in a file the change did not touch is still a
# follow-up; a Critical blocks as before; from round 2 only a Major in a touched file is held.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/review.sh" || exit 1
. "$HERE/../steps/fix.sh" || exit 1
fix_brief review superpowers:requesting-code-review "Review round {{ROUND}}. The change: {{DIFF}} Renders: {{RENDERS}}"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/sf"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/pl"
chmod +x "$FIX/sf" "$FIX/pl"
export DRIVER_SCREEN_FINDINGS="$FIX/sf" DRIVER_POLISH_LIST="$FIX/pl"
jq '.release = {mergeFirst: true, done: false}' "$HARNESS_CFG_PATH" > "$FIX/mf-on.json"
on() { HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" "$@"; }

sf_tree() { # <ticket> — a P1 branch whose change touches a.sh alone
  git -C "$REPO" worktree add -q "$FIX/sf$1" -b "tkt-$1/work" develop
  printf 'a\n' > "$FIX/sf$1/a.sh"; git -C "$FIX/sf$1" add -A; git -C "$FIX/sf$1" commit -qm "feat: a"
  driver_state_init "$1" --worktree "$FIX/sf$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "status:claimed,P1"
}
rj() { printf '%s/steps/review.json' "$(driver_state_dir "$1")"; }
fu() { printf '%s/steps/review.followups.jsonl' "$(driver_state_dir "$1")"; }
ids() { jq -r .id "$(fu "$1")" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
mixed='{"verdict":"BLOCKED","findings":[
  {"id":"m1","file":"a.sh","line":3,"grade":"major","summary":"the retry announces before the answer","reason":"misled","fix":"wait"},
  {"id":"n1","file":"./a.sh","line":4,"grade":"minor","summary":"the label is vague","reason":"r","fix":"f"},
  {"id":"m2","file":"lib/other.sh","line":2,"grade":"major","summary":"an old file drops the error","reason":"r","fix":"f"},
  {"id":"x1","file":"a.sh","line":5,"grade":"nit","summary":"taste","reason":"r","fix":"f"}]}'

echo "--- merge first: a Major and a Minor in a touched file go to fix; one elsewhere is a follow-up ---"
sf_tree 901
fix_ai review "$mixed" superpowers:requesting-code-review
rc=0; out=$(on driver_step_review 901 2>&1) || rc=$?
want "the review sends work back"          "30" "$rc"
want "the touched file's two block"        "m1 n1" "$(on jq -r "[.findings[] | $(on driver_blocking_select 1) | .id] | join(\" \")" "$(rj 901)")"
want "the untouched file's is a follow-up" "m2" "$(ids 901)"
want_in "and the run says why"             'same file, same change' "$out"

echo "--- a SHIP over a Major in a touched file is sent back, not refused ---"
sf_tree 902
fix_ai review '{"verdict":"SHIP","findings":[{"id":"m1","file":"a.sh","line":3,"grade":"major","summary":"s","reason":"r","fix":"f"}]}' superpowers:requesting-code-review
rc=0; on driver_step_review 902 >/dev/null 2>&1 || rc=$?
want "it goes to fix"                      "30" "$rc"
want "nothing is filed"                    "" "$(ids 902)"

echo "--- round 2 (the fix touched new code): a Major in a touched file blocks, a Minor is a follow-up ---"
sf_tree 903
fix_ai review "$mixed" superpowers:requesting-code-review
on driver_step_review 903 >/dev/null 2>&1
printf 'z\n' > "$FIX/sf903/z.sh"; git -C "$FIX/sf903" add -A; git -C "$FIX/sf903" commit -qm "fix: z"; driver_state_bump 903 fix
fix_ai review '{"verdict":"BLOCKED","findings":[
  {"id":"z1","file":"z.sh","line":1,"grade":"major","summary":"the helper swallows the error","reason":"r","fix":"f"},
  {"id":"z2","file":"z.sh","line":2,"grade":"minor","summary":"the helper name is vague","reason":"r","fix":"f"}]}' superpowers:requesting-code-review
rc=0; on driver_step_review 903 >/dev/null 2>&1 || rc=$?
want "the Major goes to fix"               "30" "$rc"
want "only the Major blocks"               "z1" "$(on jq -r "[.findings[] | $(on driver_blocking_select 2) | .id] | join(\" \")" "$(rj 903)")"
want "the Minor joins the follow-ups"      "m2 z2" "$(ids 903)"

echo "--- the fix step may not defer a same-change finding ---"
sf_tree 904
printf '{"deferred":[{"blockerId":"m1","reason":"another ticket"}]}' > "$FIX/fix904.json"
on _driver_fix_drop_nonblocking 904 "$FIX/fix904.json" '[{"id":"m1","grade":"major","sameChange":true}]' 1 >/dev/null 2>&1
want "its deferral stands, so the step refuses it" "1" "$(jq '.deferred | length' "$FIX/fix904.json")"
printf '{"deferred":[{"blockerId":"m2","reason":"another ticket"}]}' > "$FIX/fix904.json"
on _driver_fix_drop_nonblocking 904 "$FIX/fix904.json" '[{"id":"m2","grade":"major","sameChange":false}]' 1 >/dev/null 2>&1
want "one elsewhere is let go"             "0" "$(jq '.deferred | length' "$FIX/fix904.json")"

echo "--- plants: each line out of a copy of the kit, its case fails ---"
KIT="$FIX/kit"; N=950
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$KIT/"; }
case_review() { # merge first, $mixed: the step's exit and what waits to be filed
  N=$((N + 1)); sf_tree "$N"; fix_ai review "$mixed" superpowers:requesting-code-review
  local rc=0; HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/review.sh" && driver_step_review "$2"' _ "$KIT" "$N" >/dev/null 2>&1 || rc=$?
  R="rc=$rc fu=$(ids "$N")"
}
case_fix() {
  printf '{"deferred":[{"blockerId":"m1","reason":"r"}]}' > "$FIX/fixk.json"
  HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/fix.sh" && _driver_fix_drop_nonblocking 904 "$2" "[{\"id\":\"m1\",\"grade\":\"major\",\"sameChange\":true}]" 1' _ "$KIT" "$FIX/fixk.json" >/dev/null 2>&1
  R="kept=$(jq '.deferred | length' "$FIX/fixk.json")"
}
kit_copy
case_review; want "the unplanted kit: the touched file's findings go to fix" "rc=30 fu=m2" "$R"
case_fix;    want "the unplanted kit: a same-change deferral stands"         "kept=1" "$R"
plant() { # <label> <file under the kit> <exact text to delete> <case> <the result the line prevents>
  kit_copy
  python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  "$4"; want "planted ($1): the case now fails" "$5" "$R"
}
plant "the review marks same-change findings" driver/steps/review.sh \
  '  _driver_review_same_change "$t" "$ans_file" "$round" "$wt" "${dargs[@]}"' case_review "rc=0 fu=m1 n1 m2"
plant "the selector blocks them" driver/driver-env.sh \
  ' or ((.sameChange // false) == true and (.grade // "") != "nit")' case_review "rc=0 fu=m2"
plant "the defer leaves them" driver/steps/review.sh \
  ' | select((.sameChange // false) != true)' case_review "rc=30 fu=m1 n1 m2"
plant "the fix step holds them" driver/steps/fix.sh \
  '($f.sameChange // false) != true and ' case_fix "kept=0"

suite_end "$FAILED"
