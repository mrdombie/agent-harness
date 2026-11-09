#!/usr/bin/env bash
# resume-partial.test.sh — a run that ends and leaves a branch with no pull request is
# marked partial by the reconciler, and the coordinator queues it as half-built work.
# start then refused it as "not status:ready … a status somebody chose", so it waited for
# a person to relabel it (two tickets on 2026-11-09). start takes partial as its own,
# cuts the tree from the stranded branch on origin, and after driver.maxPartialResumes
# resumes in a row with no ship between parks it for the PM.
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
claimed() { awk -v t="$1" '$1==t{f=1} END{print f+0}' "$CLAIMS"; }

# Origin, and another machine's clone of it: the dead run's branch reaches this host
# only through origin, as the reconciler's does.
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"; git -C "$REPO" push -q origin develop
git clone -q "$FIX/origin" "$FIX/peer" 2>/dev/null
# stranded <ticket> [branch] — a branch with one commit of half-built work, on origin, no PR.
stranded() {
  local t="$1" b="${2:-tkt-$1/half-built}"
  git -C "$FIX/peer" checkout -q -b "$b" origin/develop
  echo "half of $t" > "$FIX/peer/half-$t.txt"
  git -C "$FIX/peer" add -A
  git -C "$FIX/peer" -c user.email=t@example.invalid -c user.name=Tester commit -qm "half of $t"
  git -C "$FIX/peer" push -q origin "$b"
}
partial_ticket() { fix_issue "$1" OPEN "status:partial,P1"; printf '[]\n' > "$FIX/gh/prs.json"; }
tip() { git -C "$FIX/origin" rev-parse "refs/heads/$1" 2>/dev/null; }

echo "--- start: a partial ticket starts, on the branch its last run left ---"
partial_ticket 401; stranded 401
rc=0; out=$(driver_step_start 401 2>&1) || rc=$?
wt=$(driver_state_get 401 worktree); fixture_path wt "$FIX"
want "it starts"                              "0" "$rc"
want "on the stranded branch"                 "tkt-401/half-built" "$(driver_state_get 401 branch)"
want "with the half-built work in its tree"   "half of 401" "$(cat "$wt/half-401.txt" 2>/dev/null)"
want "at origin's tip of it"                  "$(tip tkt-401/half-built)" "$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
want "the tree is on that branch"             "tkt-401/half-built" "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
want_in "and it says where it resumed from"   'resumed from the branch its last run left' "$out"
want "the claim is taken"                     "1" "$(claimed 401)"
want "the resume is counted"                  "1" "$(driver_state_count 401 partial_resume)"

echo "--- start: on the host that built it, the tree it already has is kept ---"
partial_ticket 402
git -C "$REPO" worktree add -q "$FIX/wt402" -b "tkt-402/work" develop
driver_state_init 402 --worktree "$FIX/wt402" --branch "tkt-402/work"
rc=0; driver_step_start 402 >/dev/null 2>&1 || rc=$?
want "it starts"                              "0" "$rc"
want "in the same tree"                       "$FIX/wt402" "$(driver_state_get 402 worktree)"
want "on the same branch"                     "tkt-402/work" "$(driver_state_get 402 branch)"

echo "--- start: a record's branch is kept, whatever else origin holds for the ticket ---"
partial_ticket 403; stranded 403 "tkt-403/a-other"; stranded 403 "tkt-403/mine"
driver_state_init 403 --branch "tkt-403/mine"
rc=0; driver_step_start 403 >/dev/null 2>&1 || rc=$?
want "it starts"                              "0" "$rc"
want "on the record's branch"                 "tkt-403/mine" "$(driver_state_get 403 branch)"
want "at origin's tip of it"                  "$(tip tkt-403/mine)" "$(git -C "$(driver_state_get 403 worktree)" rev-parse HEAD 2>/dev/null)"

echo "--- start: partial with no branch left on origin builds from the trunk ---"
partial_ticket 404
rc=0; driver_step_start 404 >/dev/null 2>&1 || rc=$?
want "it starts"                              "0" "$rc"
want "cut at the trunk"                       "$(git -C "$REPO" rev-parse origin/develop)" "$(git -C "$(driver_state_get 404 worktree)" rev-parse HEAD 2>/dev/null)"

echo "--- start: a rebuild is from the trunk, stranded branch or not ---"
partial_ticket 405; stranded 405
rc=0; DRIVER_FRESH=1 driver_step_start 405 >/dev/null 2>&1 || rc=$?
want "it starts"                              "0" "$rc"
want "without the half-built work"            "absent" "$([ -e "$(driver_state_get 405 worktree)/half-405.txt" ] && echo there || echo absent)"

echo "--- start: an origin that cannot be read is left for the next tick, nothing claimed ---"
partial_ticket 406; stranded 406
git -C "$REPO" remote set-url origin "$FIX/no-such-origin"
rc=0; driver_step_start 406 >/dev/null 2>&1 || rc=$?
git -C "$REPO" remote set-url origin "$FIX/origin"
want "it is unread"                           "26" "$rc"
want "and no claim is held"                   "0" "$(claimed 406)"
want "and no resume is counted"               "0" "$(driver_state_count 406 partial_resume)"

echo "--- start: stranded again after 3 resumes in a row, it parks for the PM by name ---"
# resumed <ticket> <n> — a partial ticket whose record already counts n resumes.
resumed() {
  partial_ticket "$1"; stranded "$1"
  driver_state_init "$1"; local k=0
  while [ "$k" -lt "$2" ]; do driver_state_bump "$1" partial_resume; k=$((k + 1)); done
}
resumed 407 2
rc=0; driver_step_start 407 >/dev/null 2>&1 || rc=$?
want "the third resume still starts"          "0" "$rc"
want "and is counted"                         "3" "$(driver_state_count 407 partial_resume)"
resumed 408 3
rc=0; out=$(driver_step_start 408 2>&1) || rc=$?
want "the fourth does not"                    "20" "$rc"
want "it is the PM's"                         "pm" "$(driver_state_get 408 park_cause)"
want_in "the note says how many, and why"     'Resumed from its stranded branch 3 times in a row, and every run ended with the branch and no pull request' "$(driver_state_get 408 park_note)"
want_in "and so does the run"                 'partial again after 3 resumes in a row' "$out"
want "no claim is taken"                      "0" "$(claimed 408)"
want "no tree is cut"                         "" "$(driver_state_get 408 worktree)"
resumed 409 1
rc=0; DRIVER_MAX_PARTIAL_RESUMES=1 driver_step_start 409 >/dev/null 2>&1 || rc=$?
want "the cap is the project's to set"        "20" "$rc"
# A ready ticket is no resume of a stranded branch, whatever its record counted.
fix_issue 410 OPEN "status:ready,P1"; driver_state_init 410
for _ in 1 2 3; do driver_state_bump 410 partial_resume; done
rc=0; driver_step_start 410 >/dev/null 2>&1 || rc=$?
want "a ready ticket is never stopped by it"  "0" "$rc"
want "nor counted"                            "3" "$(driver_state_count 410 partial_resume)"

# ---- through build-ticket, from a copy of the kit --------------------------------
# Every step but start is a recorder; start is the kit's own, with the claim seam above.
KIT="$FIX/kit"; FAKE="$FIX/fakesteps"; RAN="$FIX/ran.log"; export RAN
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$ROOT/tests" "$KIT/"; }
fakes() {
  rm -rf "$FAKE"; mkdir -p "$FAKE"; : > "$RAN"; : > "$FIX/park.log"
  local s
  for s in size plan build fix compare self-check review record ship quick; do
    printf '#!/usr/bin/env bash\ndriver_step_%s() { printf "%%s\\n" %s >> "$RAN"; return 0; }\n' "${s//-/_}" "$s" > "$FAKE/$s.sh"
  done
  printf '#!/usr/bin/env bash\n. "%s/driver/steps/start.sh"\nCL="%s"\n' "$KIT" "$BIN/claim-lock" > "$FAKE/start.sh"
  printf '#!/usr/bin/env bash\ndriver_park() { printf "PARK %%s | %%s | %%s\\n" "$2" "${3:-}" "${4:-}" >> "$FIX/park.log"; return 20; }\n' > "$FAKE/park.sh"
}
N=420
case_run() { # the coordinator's run of a partial ticket whose branch is on origin
  N=$((N + 1)); fakes; partial_ticket "$N"; stranded "$N"
  local rc=0 w
  DRIVER_STEPS_DIR="$FAKE" bash "$KIT/driver/build-ticket" "$N" >"$FIX/out-$N" 2>&1 || rc=$?
  w=$(driver_state_get "$N" worktree)
  R="rc=$rc shipped=$(grep -cx ship "$RAN") refused=$(grep -c 'not status:ready' "$FIX/park.log") work=$([ -n "$w" ] && [ -e "$w/half-$N.txt" ] && echo there || echo absent) counted=$(driver_state_count "$N" partial_resume)"
}
case_fourth() { # the same, its record already counting 3 resumes
  N=$((N + 1)); fakes; resumed "$N" 3
  local rc=0
  DRIVER_STEPS_DIR="$FAKE" bash "$KIT/driver/build-ticket" "$N" >"$FIX/out-$N" 2>&1 || rc=$?
  R="rc=$rc shipped=$(grep -cx ship "$RAN") parked=$(grep -c '3 times in a row.*| pm$' "$FIX/park.log")"
}
kit_copy
case_run;    want "the unplanted kit: a partial ticket builds through to ship, on its work" "rc=0 shipped=1 refused=0 work=there counted=1" "$R"
case_fourth; want "the unplanted kit: the fourth in a row parks for the PM, nothing built"  "rc=20 shipped=0 parked=1" "$R"

# plant <label> <file under the kit> <exact text> <replacement> <case> <the result the line prevents>
plant() {
  kit_copy
  python3 -I -c 'import sys; p, l, r = sys.argv[1], sys.argv[2], sys.argv[3]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, r, 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" "$4" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  "$5"; want "planted ($1): the case now fails" "$6" "$R"
}
plant "start no longer takes partial as its own" driver/steps/start.sh \
  '    *",${LBL_PARTIAL:-$LBL_READY},"*) own=1; [ -z "${LBL_PARTIAL:-}" ] || partial=1 ;;
' '' case_run "rc=20 shipped=0 refused=1 work=absent counted=0"
plant "the tree is cut from the trunk again" driver/steps/start.sh \
  '    [ -z "$stranded" ] || cut="origin/$stranded"
' '' case_run "rc=0 shipped=1 refused=0 work=absent counted=1"
plant "the count is never kept" driver/steps/start.sh \
  '  [ "$partial" != 1 ] || driver_state_bump "$t" partial_resume
' '' case_run "rc=0 shipped=1 refused=0 work=there counted=0"
plant "the stop no longer reads the count" driver/steps/start.sh \
  'if [ "${pn:-0}" -ge "$pmax" ]; then' 'if false; then' case_fourth "rc=0 shipped=1 parked=0"

suite_end "$FAILED"
