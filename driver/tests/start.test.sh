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
CLAIMS="$FIX/claims"; : > "$CLAIMS"
cat > "$BIN/claim-lock" <<'SH'
#!/usr/bin/env bash
case "$1" in
  acquire) grep -qx "$2" "$CLAIMS" && exit 10; printf '%s\n' "$2" >> "$CLAIMS"; echo "acquired #$2" ;;
  holds)   grep -qx "$2" "$CLAIMS" ;;
  release) grep -vx "$2" "$CLAIMS" > "$CLAIMS.t"; mv "$CLAIMS.t" "$CLAIMS" ;;
  update)  : ;;
esac
SH
chmod +x "$BIN/claim-lock"; export CL="$BIN/claim-lock" CLAIMS

echo "--- a ready ticket starts ---"
fix_issue 101 OPEN "status:ready,type:feature"
out=$(driver_step_start 101 2>&1); rc=$?
want "it finishes"            "0" "$rc"
want "the claim was taken"    "101" "$(cat "$CLAIMS")"
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
printf '106\n' >> "$CLAIMS"
out=$(driver_step_start 106 2>&1); rc=$?
want "a peer's claim is never adopted" "24" "$rc"
want_in "and it says a peer holds it"  'peer' "$out"
want "no worktree was cut"             ""     "$(driver_state_get 106 worktree)"

echo "--- a ticket that does not resolve ---"
out=$(driver_step_start 999 2>&1); rc=$?
want "an unreadable ticket refuses" "24" "$rc"
want_in "and says it could not read it" 'could not be read' "$out"

echo "--- the claim is released when a gate says no, never squatted ---"
want "nothing claimed for the refused tickets" "101" "$(cat "$CLAIMS" | grep -v '^106$' | tr '\n' ' ' | sed 's/ $//')"

exit $FAILED
