#!/usr/bin/env bash
# resume-in-review.test.sh — a build of the driver's own that parked keeps its work on a
# draft PR. The answer that resumes it marks the ticket in review, and
# build-ticket resumes the build. start then refused "not status:ready", parked, the label
# went back to ready, and the coordinator spawned it again — for ever (#13580, #17907 on
# 2026-11-03). start reads that in-review as the build's own only on that resume, with its
# draft on the record's branch; a fresh start on an in-review ticket is still refused.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/start.sh" || exit 1

# The claim seam, a recorder: rows are <ticket> <owner> <branch> <worktree>.
CLAIMS="$FIX/claims"; : > "$CLAIMS"
cat > "$BIN/claim-lock" <<'SH'
#!/usr/bin/env bash
me="${CLAIM_AGENT:-tester@fixture}"
field() { awk -v t="$1" -v n="$2" '$1==t{print $n; exit}' "$CLAIMS"; }
t="$2"
argval() { local k="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$1" in
  acquire) [ -n "$(field "$t" 2)" ] && exit 10
           printf '%s\t%s\t%s\t%s\n' "$t" "$me" "$(argval --branch "$@")" "$(argval --worktree "$@")" >> "$CLAIMS" ;;
  holds) o=$(field "$t" 2); [ -n "$o" ] || exit 11; [ "$o" = "$me" ] || exit 12 ;;
  show) o=$(field "$t" 2); [ -n "$o" ] || exit 11
        jq -n --arg a "$o" --arg b "$(field "$t" 3)" --arg w "$(field "$t" 4)" '{agent:$a, branch:$b, worktree:$w}' ;;
  release) awk -v t="$t" '$1!=t' "$CLAIMS" > "$CLAIMS.t"; mv "$CLAIMS.t" "$CLAIMS" ;;
  update) : ;;
esac
SH
chmod +x "$BIN/claim-lock"; export CL="$BIN/claim-lock" CLAIMS

# parked_build <ticket> [pr-branch] — the record a build parked at review leaves: its tree
# and branch, start..fix done and no ship; its draft PR open (on its own branch unless
# told otherwise); the ticket in review, as a resume marks it.
parked_build() {
  local t="$1" b="tkt-$1/work"
  git -C "$REPO" worktree add -q "$FIX/wt$t" -b "$b" develop
  driver_state_init "$t" --worktree "$FIX/wt$t" --branch "$b"
  local s; for s in start size plan build fix compare self-check simplify; do driver_state_done "$t" "$s"; done
  jq -n --arg b "${2:-$b}" --arg h "$(git -C "$FIX/wt$t" rev-parse HEAD)" \
    '[{number:90, headRefName:$b, headRefOid:$h, isDraft:true, mergeStateStatus:"CLEAN"}]' > "$FIX/gh/prs.json"
  fix_issue "$t" OPEN "status:in-review,P1"
}

echo "--- start: the resumed build's own in-review is not refused ---"
parked_build 301
rc=0; out=$(DRIVER_UNSHIPPED_BUILD=1 driver_step_start 301 2>&1) || rc=$?
want "it starts"                              "0" "$rc"
want_in "and says why the status is its own"  'own draft on tkt-301/work' "$out"
want "on the tree it already had"             "$FIX/wt301" "$(driver_state_get 301 worktree)"

echo "--- start: a fresh start on an in-review ticket is still refused ---"
parked_build 302
rc=0; out=$(DRIVER_UNSHIPPED_BUILD=0 driver_step_start 302 2>&1) || rc=$?
want "it refuses"                             "24" "$rc"
want_in "as a status somebody chose"          'not status:ready' "$out"
rc=0; (unset DRIVER_UNSHIPPED_BUILD; driver_step_start 302 >/dev/null 2>&1) || rc=$?
want "and with nothing said about a resume"   "24" "$rc"

echo "--- start: a resume whose open PR is on another branch is not its own ---"
parked_build 303 "tkt-303/someone-else"
rc=0; DRIVER_UNSHIPPED_BUILD=1 driver_step_start 303 >/dev/null 2>&1 || rc=$?
want "it refuses"                             "24" "$rc"

echo "--- start: an unreadable PR list is left for the next tick, never parked as a refusal ---"
parked_build 304; echo "open-prs" > "$FIX/gh-fail"
rc=0; DRIVER_LOOKUP_RETRY_SEC=0 DRIVER_UNSHIPPED_BUILD=1 driver_step_start 304 >/dev/null 2>&1 || rc=$?
rm -f "$FIX/gh-fail"
want "it is unread"                           "26" "$rc"
printf '[]\n' > "$FIX/gh/prs.json"

# ---- the loop, through build-ticket, from a copy of the kit ------------------------
# Every step but start is a recorder; start is the kit's own, with the claim seam above.
KIT="$FIX/kit"; FAKE="$FIX/fakesteps"; RAN="$FIX/ran.log"; export RAN
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$ROOT/tests" "$KIT/"; }
fakes() {
  rm -rf "$FAKE"; mkdir -p "$FAKE"; : > "$RAN"; : > "$FIX/park.log"
  local s
  for s in size plan build fix compare self-check simplify review record ship quick; do
    printf '#!/usr/bin/env bash\ndriver_step_%s() { printf "%%s\\n" %s >> "$RAN"; return 0; }\n' "${s//-/_}" "$s" > "$FAKE/$s.sh"
  done
  printf '#!/usr/bin/env bash\n. "%s/driver/steps/start.sh"\nCL="%s"\n' "$KIT" "$BIN/claim-lock" > "$FAKE/start.sh"
  printf '#!/usr/bin/env bash\ndriver_park() { printf "PARK %%s | %%s\\n" "$2" "${3:-}" >> "$FIX/park.log"; return 20; }\n' > "$FAKE/park.sh"
}
N=310
case_loop() { # the coordinator's resume of a build parked at review, with a brief
  N=$((N + 1)); fakes; parked_build "$N"
  printf 'Finish PR #90: it is a draft nothing is building.\n' > "$FIX/brief-$N.md"
  local rc=0
  DRIVER_STEPS_DIR="$FAKE" bash "$KIT/driver/build-ticket" "$N" --brief "$FIX/brief-$N.md" >"$FIX/out-$N" 2>&1 || rc=$?
  R="rc=$rc ran=$(tr '\n' ' ' < "$RAN" | sed 's/ $//') park=$(grep -c 'not status:ready' "$FIX/park.log")"
}
kit_copy
case_loop; want "the unplanted kit: the build resumes past start to ship" "rc=0 ran=review record ship park=0" "$R"
want_in "  and says it resumes the build" 'resuming the build with this brief' "$(cat "$FIX/out-$N")"
M=330
case_inherited() { # a record with nothing done (no unshipped build), the variable set from outside
  M=$((M + 1)); fakes; parked_build "$M"
  jq '.done = []' "$(driver_state_dir "$M")/state.json" > "$FIX/s.json" && mv "$FIX/s.json" "$(driver_state_dir "$M")/state.json"
  local rc=0
  DRIVER_UNSHIPPED_BUILD=1 DRIVER_STEPS_DIR="$FAKE" bash "$KIT/driver/build-ticket" "$M" >/dev/null 2>&1 || rc=$?
  R="rc=$rc park=$(grep -c 'not status:ready' "$FIX/park.log")"
}
case_inherited; want "the unplanted kit: an inherited DRIVER_UNSHIPPED_BUILD is no resume" "rc=20 park=1" "$R"

# plant <label> <file under the kit> <exact text> <replacement> <case> <the result the line prevents>
plant() {
  kit_copy
  python3 -I -c 'import sys; p, l, r = sys.argv[1], sys.argv[2], sys.argv[3]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, r, 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" "$4" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  "$5"; want "planted ($1): the case now fails" "$6" "$R"
}
plant "build-ticket no longer says it resumes" driver/build-ticket \
  'UNSHIPPED_BUILD=1; DRIVER_UNSHIPPED_BUILD=1' 'UNSHIPPED_BUILD=1' case_loop "rc=20 ran= park=1"
plant "start no longer reads in-review as the resume's own" driver/steps/start.sh \
  '          own=1
          driver_say' '          driver_say' case_loop "rc=20 ran= park=1"

plant "build-ticket keeps an inherited value" driver/build-ticket \
  'DRIVER_UNSHIPPED_BUILD=0; export DRIVER_UNSHIPPED_BUILD' 'export DRIVER_UNSHIPPED_BUILD' case_inherited "rc=0 park=0"

suite_end "$FAILED"
