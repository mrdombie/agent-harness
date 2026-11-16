#!/usr/bin/env bash
# git-actions.test.sh — resetTo, the git step a fix or build answer may ask the driver for.
# A fix round rebuilt its commits, merged the rebuilt line into the branch (same files) and
# asked resetTo the rebuilt tip: refused as "not one of this branch's own commits", and a
# finished round parked. That ask is now left as it is; every other refusal stands.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../git-actions.sh" || exit 1

# origin with develop, and a clone on the ticket's branch.
ORI="$FIX/ga-origin.git"; W="$FIX/ga-work"
git init -q --bare -b develop "$ORI"
git clone -q "$ORI" "$W" 2>/dev/null
g() { git -C "$W" -c user.email=t@example.invalid -c user.name=Tester "$@"; }
put() { printf '%s\n' "$2" > "$W/$1"; g add -A; g commit -q -m "$3"; }
g checkout -q -b develop 2>/dev/null || true
put base.txt base "base"; g push -q origin develop
g checkout -q -b tkt-9/work
put a.txt one "own 1"; OWN1=$(g rev-parse HEAD)
put a.txt two "own 2"; OWN2=$(g rev-parse HEAD)
g push -q origin tkt-9/work
driver_state_set 9 worktree "$W"; driver_state_set 9 branch tkt-9/work

ask() { # <sha> → RC, OUT, HEAD after
  jq -n --arg s "$1" '{gitActions: [{action: "resetTo", sha: $s}]}' > "$FIX/ga-ans.json"
  driver_state_set 9 park_note ""
  RC=0; OUT=$(driver_git_actions 9 "$W" "$FIX/ga-ans.json" fix 2>&1) || RC=$?
  NOW=$(g rev-parse HEAD)
}

# The rebuilt line: same files as the head, on a side line, merged in without fast-forward.
g checkout -q --detach "$OWN1"
put a.txt two "own 2, rebuilt"; REBUILT=$(g rev-parse HEAD)
g checkout -q tkt-9/work
g merge -q --no-ff --no-edit "$REBUILT"; MERGED=$(g rev-parse HEAD)
want "the fixture: the rebuilt tip holds the head's files" "$(g rev-parse "$MERGED^{tree}")" "$(g rev-parse "$REBUILT^{tree}")"

ask "$REBUILT"
want "merged in, same files → not refused"        "0" "$RC"
want "…and the head does not move"                 "$MERGED" "$NOW"
want_in "…and the run says nothing is reset"       "nothing is reset" "$OUT"
want "…and no park note is left"                   "" "$(driver_state_get 9 park_note)"

# Merged in but DIFFERENT files: still refused.
g checkout -q --detach "$OWN1"
put b.txt side "a side commit with other files"; SIDE=$(g rev-parse HEAD)
g checkout -q tkt-9/work
g merge -q --no-ff --no-edit "$SIDE"; MERGED2=$(g rev-parse HEAD)
put c.txt later "own 3"; TIP=$(g rev-parse HEAD)
ask "$SIDE"
want "merged in, other files → refused"            "1" "$RC"
want "…and the head does not move"                 "$TIP" "$NOW"
want_in "…in the old words"                        "not one of this branch's own commits" "$OUT"

# Same files but NOT in the branch: still refused.
g checkout -q --detach "$OWN1"
g read-tree -u --reset "$TIP"; g commit -q -m "the tip's files, never merged"; LOOSE=$(g rev-parse HEAD)
g checkout -q tkt-9/work
ask "$LOOSE"
want "same files, never merged → refused"          "1" "$RC"
want "…and the head does not move"                 "$TIP" "$NOW"

# An own first-parent commit behind origin's branch is still refused; ahead of it still resets.
ask "$OWN1"
want "an own commit behind origin's branch → refused" "1" "$RC"
want_in "…as dropping pushed work"                 "would drop pushed work" "$OUT"
ask "$MERGED2"
want "an own commit ahead of origin's branch → reset" "0 $MERGED2" "$RC $NOW"

# Planted: with the same-files test never true, the rebuilt tip is refused again.
PK="$FIX/ga-kit"; mkdir -p "$PK"; cp "$HERE/../git-actions.sh" "$PK/git-actions.sh"
python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); o = "[ -n \"$a\" ] && [ \"$a\" = \"$b\" ]"; n = s.count(o); open(p, "w").write(s.replace(o, "false")); sys.exit(0 if n == 1 else 1)' "$PK/git-actions.sh" \
  && { . "$PK/git-actions.sh"
       HT=$(g rev-parse HEAD); g checkout -q --detach "$OWN1"
       g read-tree -u --reset "$HT"; g commit -q -m "rebuilt again"; RB2=$(g rev-parse HEAD)
       g checkout -q tkt-9/work; g merge -q --no-ff --no-edit "$RB2"
       want "the plant's fixture: same files as the head" "$(g rev-parse "HEAD^{tree}")" "$(g rev-parse "$RB2^{tree}")"
       ask "$RB2"; want "planted (same-files never true): the rebuilt tip is refused again" "1" "$RC"; } \
  || bad "plant: the edit did not land"

suite_end "$FAILED"
