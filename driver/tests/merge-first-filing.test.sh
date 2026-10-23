#!/usr/bin/env bash
# merge-first-filing.test.sh — how merge-first review findings are filed (the owner,
# 2026-10-23: 187 fix-after-merge tickets in a day, 119 of them Minors, 26 findings on a PR
# that itself fixed a finding, chains 4 deep). A Minor on a SCREEN file goes on that
# screen's polish list; a Minor in tests, docs, tooling or backend stays a P3 follow-up. On
# a ticket that is itself a follow-up (release.followUpLabel) a Major is dropped with a note
# on the PR, a non-screen Minor is filed as before, and a Critical blocks. A screen Minor no
# screen resolves for is filed too, never dropped. Findings in files
# the change touched are fixed in place first.
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
# A .tsx file is on the home screen, and the ticket itself carries screen:home.
# $FIX/sf.none: no screen resolves, for the file or the ticket.
[ -f "$FIX/sf.none" ] && exit 0
case "$1" in screens) if [ -n "${3:-}" ]; then grep -q 'tsx' "$3" && echo home; else echo home; fi ;; esac
exit 0
SH
printf '#!/usr/bin/env bash\ncase "$1" in add) printf "%%s\\n" "$*" >> "$FIX/pl.adds" ;; esac\nexit 0\n' > "$FIX/pl"
chmod +x "$FIX/sf" "$FIX/pl"; : > "$FIX/pl.adds"
export DRIVER_SCREEN_FINDINGS="$FIX/sf" DRIVER_POLISH_LIST="$FIX/pl"
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
# Every finding is in a file the change did not touch, so none is fixed in place.
answer='{"verdict":"BLOCKED","findings":[
  {"id":"m1","file":"lib/other.sh","line":3,"grade":"major","summary":"the save is dropped","reason":"r","fix":"f"},
  {"id":"n1","file":"app/page.tsx","line":9,"grade":"minor","summary":"the gap is 12 not 16","reason":"r","fix":"f"},
  {"id":"n2","file":"lib/x.ts","line":2,"grade":"minor","summary":"the log line is vague","reason":"r","fix":"f"},
  {"id":"n3","file":"components/Card.tsx","line":4,"grade":"minor","summary":"the badge sits 2px low","reason":"r","fix":"f"}]}'

echo "--- a screen Minor goes on its polish list; a non-screen Minor is a follow-up ---"
ff_tree 801 "status:claimed,P1"
fix_ai review "$answer" superpowers:requesting-code-review
rc=0; on driver_step_review 801 >/dev/null 2>&1 || rc=$?
want "the review ships"                        "0" "$rc"
want "the Major and the non-screen Minor wait to be filed" "m1 n2" "$(fu 801)"
want_in "the screen's Minor is on its polish list" '^add home \[Minor\] the gap is 12 not 16' "$(cat "$FIX/pl.adds")"
want_in "and so is one in the screen set (design.surfacePaths)" '^add home \[Minor\] the badge sits 2px low' "$(cat "$FIX/pl.adds")"
want_not_in "the non-screen Minor is not on the ticket's screen's list" 'log line is vague' "$(cat "$FIX/pl.adds")"

echo "--- on a follow-up's own PR a Major is dropped, with a note ---"
ff_tree 802 "status:claimed,P1,fix-after-merge"
fix_ai review "$answer" superpowers:requesting-code-review
rc=0; out=$(on driver_step_review 802 2>&1) || rc=$?
want "the review ships"                        "0" "$rc"
want "only the non-screen Minor waits to be filed" "n2" "$(fu 802)"
want "the Major is recorded as dropped"        "dropped" "$(jq -r 'select(.id == "m1") | .list' "$(dj 802)")"
want_in "and the run says so"                  "1 Major\(s\) dropped because this ticket is itself a follow-up" "$out"
want_in "the PR's section says why"            'not filed: this ticket is itself a fix-after-merge follow-up' "$(on _driver_ship_deferred 802)"

echo "--- a Critical still blocks there ---"
ff_tree 803 "status:claimed,P1,fix-after-merge"
fix_ai review '{"verdict":"BLOCKED","findings":[{"id":"c1","file":"lib/other.sh","line":1,"grade":"critical","summary":"another workspace sees the rows","reason":"r","fix":"f"}]}' superpowers:requesting-code-review
rc=0; on driver_step_review 803 >/dev/null 2>&1 || rc=$?
want "it goes to fix"                          "30" "$rc"

echo "--- plants: each line out of a copy of the kit, its case fails ---"
KIT="$FIX/kit"; N=850
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$KIT/"; }
case_k() { # <labels> — R: what waits to be filed
  N=$((N + 1)); ff_tree "$N" "$1"; fix_ai review "$answer" superpowers:requesting-code-review
  HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/review.sh" && driver_step_review "$2"' _ "$KIT" "$N" >/dev/null 2>&1
  R="fu=$(fu "$N")"
}
case_plain() { case_k "status:claimed,P1"; }
case_unmapped() { # a Minor on a screen file no screen resolves for, the ticket no screen label
  N=$((N + 1)); ff_tree "$N" "status:claimed,P1"; : > "$FIX/sf.none"; : > "$FIX/pl.adds"
  fix_ai review '{"verdict":"BLOCKED","findings":[{"id":"u1","file":"components/Drawer.tsx","line":7,"grade":"minor","summary":"the drawer has no close at 390px","reason":"r","fix":"f"}]}' superpowers:requesting-code-review
  HARNESS_CFG="$FIX/mf-on.json" HARNESS_CFG_PATH="$FIX/mf-on.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/review.sh" && driver_step_review "$2"' _ "$KIT" "$N" >/dev/null 2>&1
  rm -f "$FIX/sf.none"
  R="fu=$(fu "$N") polish=$(grep -c . "$FIX/pl.adds")"
}
case_fam()   { case_k "status:claimed,P1,fix-after-merge"; }
plant() { # <label> <file under the kit> <exact text> <case> <the result the line prevents> [what replaces it]
  kit_copy
  python3 -I -c 'import sys; p, l, r = sys.argv[1], sys.argv[2], sys.argv[3]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, r, 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" "${6:-}" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  "$4"; want "planted ($1): the case now fails" "$5" "$R"
}
kit_copy
case_plain; want "the unplanted kit: the Major and the non-screen Minor" "fu=m1 n2" "$R"
case_fam;   want "the unplanted kit: on a follow-up, the non-screen Minor alone" "fu=n2" "$R"
case_unmapped; want "the unplanted kit: a screen Minor no screen resolves for is a follow-up, never dropped" "fu=u1 polish=0" "$R"
plant "an unlisted screen Minor is filed" driver/steps/review.sh \
  '            _driver_review_follow_up "$t" "$x" "$round" && { list="follow-up"; filed=$((filed + 1)); }' case_unmapped "fu= polish=0" '            :'
plant "only a screen file's Minor is polish" driver/steps/review.sh \
  'driver_is_screen_file "$(driver_state_get "$t" worktree)" "$(printf '"'"'%s'"'"' "$x" | jq -r '"'"'.file // ""'"'"')"' case_plain "fu=m1" true
plant "a follow-up's Major is dropped" driver/steps/review.sh '[ "$fam" = yes ]' case_fam "fu=m1 n2" false

suite_end "$FAILED"
