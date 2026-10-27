#!/usr/bin/env bash
# one-read.test.sh — a build reads its own ticket once before the first model call.
# One shared token serves every builder; a sample on 2026-10-27 caught one start
# reading the same ticket 7 times (labels, body, title, state, closing PRs), each a
# separate call. Start, size, the claim and the plan's facts all read one copy.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
BT="$HERE/../build-ticket"

git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop

# The model call leaves a line in the gh log, so the log reads in order: every
# ticket read above the first marker happened before any model ran.
cat > "$BIN/claude-mark" <<'SH'
#!/usr/bin/env bash
printf '== model\n' >> "$GH_LOG"
exec "$BIN/claude" "$@"
SH
chmod +x "$BIN/claude-mark"
export DRIVER_CLAUDE="$BIN/claude-mark"
fix_brief plan superpowers:writing-plans

reads_before_model() { # <ticket>
  awk -v t="$1" '/^== model/{exit} $1=="issue" && $2=="view" && $3==t {n++} END{print n+0}' "$GH_LOG"
}

echo "--- a fresh start reads its ticket once before the plan's model call ---"
TICKET=301
fix_issue "$TICKET" OPEN "status:ready,type:feature,project:x"
: > "$GH_LOG"
out=$(HARNESS_STATE_DIR="$STATE" bash "$BT" "$TICKET" 2>&1)
want_in "the run reached the model" '^== model' "$(cat "$GH_LOG")"
want "one ticket read before it" "1" "$(reads_before_model "$TICKET")"
[ "$(reads_before_model "$TICKET")" = 1 ] || { printf '%s\n' "$out" | tail -5 | sed 's/^/    /'; grep -n "issue view $TICKET" "$GH_LOG" | sed 's/^/    gh: /'; }
want_in "the claim was taken" "claimed, worktree at" "$out"
want_in "the status was still set from the labels start read" 'issue edit 301 .*--remove-label status:ready --add-label status:claimed' "$(cat "$GH_LOG")"
want_in "and the plan was handed the labels the ticket now wears" 'Labels: .*status:claimed' "$(cat "$STATE/driver/301/steps/plan.facts/"* 2>/dev/null)"
want_not_in "not the ones it wore before the claim" 'Labels: .*status:ready' "$(cat "$STATE/driver/301/steps/plan.facts/"* 2>/dev/null)"
CALLS=$(find "$STATE" -name gh-calls.log | head -1)
want_in "the claim's GitHub calls are logged as the builder's" $'build-ticket\tissue edit' "$(cat "$CALLS" 2>/dev/null)"
want_not_in "and none as a script of its own" $'\t(claim-lock|issue-status)\t' "$(cat "$CALLS" 2>/dev/null)"

echo "--- and what start read is what the record carries ---"
. "$HERE/../state.sh" || exit 1
want "the title" "Ticket $TICKET" "$(driver_state_get "$TICKET" title)"

echo "--- a ticket a person holds is still refused off that one read ---"
TICKET=302
fix_issue "$TICKET" OPEN "status:ready,needs:human-approval"
: > "$GH_LOG"
out=$(HARNESS_STATE_DIR="$STATE" bash "$BT" "$TICKET" 2>&1)
want_in "refused for the hold" 'needs:human-approval' "$out"
want "nothing reached a model" "0" "$(grep -c '^== model' "$GH_LOG")"

echo "--- a later step reads afresh: the copy ends at the first model call ---"
TICKET=303
fix_issue "$TICKET" OPEN "status:ready"
: > "$GH_LOG"
HARNESS_STATE_DIR="$STATE" bash "$BT" "$TICKET" >/dev/null 2>&1
after=$(awk -v t="$TICKET" '/^== model/{m=1; next} m && $1=="issue" && $2=="view" && $3==t {n++} END{print n+0}' "$GH_LOG")
want "the park after the model read the ticket from GitHub" "1" "$([ "$after" -ge 1 ] && echo 1 || echo 0)"
want "no copy is left when the run ends" "0" "$(find "$STATE/driver/$TICKET" -name 'ticket-snap*' 2>/dev/null | grep -c .)"

echo "--- the claim lock's own reads go through the shared backoff and its log ---"
fix_issue 304 OPEN "status:ready"
: > "$CALLS"
GH_CALLER=build-ticket bash "$HERE/../../scripts/claim-lock.sh" acquire 304 --branch tkt-304/x >/dev/null 2>&1
want_in "its read of the closing PRs is logged as the builder's" $'build-ticket\tissue view' "$(cat "$CALLS")"
want "and is skipped when the caller hands them over" "0" \
  "$(: > "$CALLS"; bash "$HERE/../../scripts/claim-lock.sh" release 304 --force >/dev/null 2>&1; : > "$CALLS"
     CLAIM_CLOSING_PRS="" GH_CALLER=build-ticket bash "$HERE/../../scripts/claim-lock.sh" acquire 304 --branch tkt-304/x >/dev/null 2>&1
     grep -c 'issue view' "$CALLS")"
echo $(( $(date +%s) + 600 )) > "$(dirname "$CALLS")/gh-backoff"
: > "$GH_LOG"
bash "$HERE/../../scripts/claim-lock.sh" release 304 --force >/dev/null 2>&1
GH_CALLER=build-ticket bash "$HERE/../../scripts/claim-lock.sh" acquire 304 --branch tkt-304/x >/dev/null 2>&1
want "and none reaches GitHub while the token is backing off" "0" "$(grep -c 'issue view 304' "$GH_LOG")"
rm -f "$(dirname "$CALLS")/gh-backoff"

suite_end "$FAILED"
