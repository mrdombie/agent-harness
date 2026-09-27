#!/usr/bin/env bash
# record.test.sh — "verdicts are real" means one thing precisely: the recorded
# verdict comes from the reviewer's own answer file and from nowhere else. A
# verdict a builder can pass in is a verdict a builder can invent.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/record.sh" || exit 1
CLAIMS="$FIX/claim-updates"; : > "$CLAIMS"
cat > "$BIN/claim-lock" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAIMS"
SH
chmod +x "$BIN/claim-lock"; export CL="$BIN/claim-lock" CLAIMS
fix_issue 101 OPEN "status:claimed"
driver_state_init 101 --worktree "$REPO"
driver_state_set 101 claimed_at_sha deadbeefcafe

echo "--- the verdict comes off the reviewer's own file ---"
driver_state_put 101 review '{"verdict":"SHIP","findings":[]}'
driver_state_bump 101 review
out=$(driver_step_record 101 2>&1); rc=$?
want "it finishes" "0" "$rc"
want_in "SHIP is written to the claim"  'review_verdict=SHIP' "$(cat "$CLAIMS")"
want_in "with the round count"          'review_rounds=1'     "$(cat "$CLAIMS")"
want_in "and the SHA it was claimed at" 'deadbeefcafe'        "$(cat "$CLAIMS")"

echo "--- a verdict offered on the command line is ignored ---"
: > "$CLAIMS"
driver_state_put 101 review '{"verdict":"BLOCKED","findings":[{"grade":"major","summary":"x"}]}'
out=$(driver_step_record 101 SHIP 2>&1); rc=$?
want_in "the reviewer's BLOCKED is what lands" 'review_verdict=BLOCKED' "$(cat "$CLAIMS")"
want_not_in "the argument never reaches the record" 'review_verdict=SHIP' "$(cat "$CLAIMS")"

echo "--- no reviewer file at all: nothing is recorded ---"
: > "$CLAIMS"
driver_state_init 202 --worktree "$REPO"
out=$(driver_step_record 202 2>&1); rc=$?
want "it refuses"      "24" "$rc"
want_in "and says why" 'no review' "$out"
want "nothing was written" "" "$(cat "$CLAIMS")"

exit $FAILED
