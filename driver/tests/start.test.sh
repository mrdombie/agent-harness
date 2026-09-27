#!/usr/bin/env bash
# start.test.sh — start is the step that refuses. Everything it does is cheap and
# reversible; everything it protects is neither. So the assertions here are
# mostly about saying no: to a closed ticket, to one a person holds, to one the
# PM has gated, and to one a peer already claimed.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/start.sh" || exit 1

# The claim seam: a recorder, so the suite never writes a ref to a real origin.
#
# IT CARRIES THE REAL EXIT CODES, and that is the whole point of it. `holds` in
# claim-lock.sh answers "do WE own it" — 0 ours, 11 free, 12 a PEER holds it — and a
# stub that returns 0 for a claim held by anybody cannot tell those apart. The
# earlier version was `grep -qx "$2" "$CLAIMS"`, one line, and it made the case
# labelled "a peer already holds the claim" exercise the we-own-it branch instead,
# while asserting on the word "peer". Each row is <ticket> <owner>.
CLAIMS="$FIX/claims"; : > "$CLAIMS"
cat > "$BIN/claim-lock" <<'SH'
#!/usr/bin/env bash
me="${CLAIM_AGENT:-tester@fixture}"
owner() { awk -v t="$2" '$1==t{print $2; exit}' "$CLAIMS"; }
case "$1" in
  acquire) [ -n "$(owner "$@")" ] && exit 10; printf '%s\t%s\n' "$2" "$me" >> "$CLAIMS"; echo "acquired #$2" ;;
  holds)   o=$(owner "$@"); [ -n "$o" ] || exit 11; [ "$o" = "$me" ] || exit 12 ;;
  release) awk -v t="$2" '$1!=t' "$CLAIMS" > "$CLAIMS.t"; mv "$CLAIMS.t" "$CLAIMS" ;;
  update)  : ;;
esac
SH
chmod +x "$BIN/claim-lock"; export CL="$BIN/claim-lock" CLAIMS
claimed_tickets() { awk '{print $1}' "$CLAIMS" | tr '\n' ' ' | sed 's/ $//'; }

echo "--- a ready ticket starts ---"
fix_issue 101 OPEN "status:ready,type:feature"
out=$(driver_step_start 101 2>&1); rc=$?
want "it finishes"            "0" "$rc"
want "the claim was taken"    "101" "$(claimed_tickets)"
WT=$(driver_state_get 101 worktree)
want "a worktree exists"      "1" "$([ -d "$WT" ] && echo 1)"
want "on its own branch"      "tkt-101/ticket-101" "$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
want "cut from the trunk"     "$(git -C "$REPO" rev-parse develop)" "$(git -C "$WT" rev-parse HEAD)"
want "the branch is recorded" "tkt-101/ticket-101" "$(driver_state_get 101 branch)"
want_in "and it says what it did" 'worktree' "$out"

echo "--- the trunk SHA the ticket was claimed at is frozen ---"
want "claimed_at is recorded" "$(git -C "$REPO" rev-parse develop)" "$(driver_state_get 101 claimed_at_sha)"

echo "--- a second start on the same ticket does not cut a second worktree ---"
before="$WT"
rc=0; driver_step_start 101 >/dev/null 2>&1 || rc=$?
want "it still finishes"      "0"        "$rc"
want "same worktree"          "$before"  "$(driver_state_get 101 worktree)"

echo "--- a closed ticket ---"
fix_issue 102 CLOSED "status:ready"
out=$(driver_step_start 102 2>&1); rc=$?
want "closed refuses"   "24" "$rc"
want_in "and says so"   'CLOSED' "$out"

echo "--- a ticket a person is holding ---"
fix_issue 103 OPEN "status:ready,needs:human-approval"
out=$(driver_step_start 103 2>&1); rc=$?
want "a held ticket refuses" "24" "$rc"
want_in "naming the label"   'needs:human-approval' "$out"

echo "--- a gated ticket: the PM flips that, not the driver ---"
fix_issue 104 OPEN "status:gated"
out=$(driver_step_start 104 2>&1); rc=$?
want "gated refuses"  "24" "$rc"
want_in "and says whose call it is" 'PM' "$out"

echo "--- a ticket that is not ready ---"
fix_issue 105 OPEN "status:drafting"
out=$(driver_step_start 105 2>&1); rc=$?
want "drafting refuses" "24" "$rc"
want_in "naming the status it wanted" 'status:ready' "$out"

echo "--- a peer already holds the claim ---"
fix_issue 106 OPEN "status:ready"
printf '106\tsomebody@else\n' >> "$CLAIMS"
out=$(driver_step_start 106 2>&1); rc=$?
want "a peer's claim is never adopted" "24" "$rc"
want_in "and it says a peer holds it"  'peer' "$out"
want "no worktree was cut"             ""     "$(driver_state_get 106 worktree)"

echo "--- OUR OWN claim, taken but not yet recorded, is not a peer's ---"
# The window is real: a run killed between `acquire` and recording the worktree
# spans a fetch and a worktree add. Read as a peer's claim, that state parks the
# ticket, the park adds the hold label and releases the claim, and a person now has
# to clear a label for a state that was our own half-finished run — while the message
# sends them looking for an agent that does not exist.
fix_issue 107 OPEN "status:ready"
printf '107\t%s\n' "${CLAIM_AGENT:-tester@fixture}" >> "$CLAIMS"
out=$(driver_step_start 107 2>&1); rc=$?
want "it carries on with the claim it holds" "0" "$rc"
want_not_in "and never blames a peer"        'peer' "$out"
want "a worktree was cut"                    "1" \
  "$([ -d "$(driver_state_get 107 worktree)" ] && echo 1)"
want "the claim is still held once, not twice" "1" \
  "$(awk '$1==107' "$CLAIMS" | grep -c .)"

echo "--- a ticket that does not resolve ---"
out=$(driver_step_start 999 2>&1); rc=$?
want "an unreadable ticket refuses" "24" "$rc"
want_in "and says it could not read it" 'could not be read' "$out"

echo "--- the claim is released when a gate says no, never squatted ---"
want "nothing claimed for the refused tickets" "101 107" \
  "$(awk '$1!=106{print $1}' "$CLAIMS" | tr '\n' ' ' | sed 's/ $//')"

exit $FAILED
