#!/usr/bin/env bash
# owner-question.test.sh — a question from a run with no question tool reaches the
# owner's channel and holds the ticket; the answer frees it and travels with it.
# The tick's side (the next tick skips the ticket) is in coordinator-tick.test.sh.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
OQ="$HERE/owner-question.sh"; W="$HERE/needsme-watch.sh"
C="$STATE/coordinator"
cat > "$BIN/notify" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$FIX/notify.log"
SH
chmod +x "$BIN/notify"
export COORDINATOR_NOTIFY_CMD="$BIN/notify"
unset COORDINATOR_SHADOW
fresh() { rm -rf "$C"; : > "$GH_LOG"; : > "$FIX/notify.log"; }

echo "--- ask ---"
fresh; fix_issue 41 OPEN "status:claimed"
out=$(bash "$OQ" ask 41 "Fix A or B?" "Fix A (retry) or Fix B (drop the cache)?"); rc=$?
want "it exits 0"                          "0" "$rc"
want "the slug is made a key word"         "asked: decision:41:fix-a-or-b — #41 waits on the answer" "$out"
want_in "it reaches needs-you.md though the coordinator is in shadow" '^- \[ \] .*#41: Fix A \(retry\) or Fix B \(drop the cache\)\? <!-- key:decision:41:fix-a-or-b -->$' "$(cat "$C/needs-you.md")"
want "and pings the owner"                 "#41: Fix A (retry) or Fix B (drop the cache)?" "$(cat "$FIX/notify.log")"
want_in "the label exists before it is added" '^label create needs:owner-decision ' "$(cat "$GH_LOG")"
want_in "the ticket is labelled"           '^issue edit 41 .*--add-label needs:owner-decision' "$(cat "$GH_LOG")"
want_in "the question is on the ticket"    '^issue comment 41 .*Waiting on the owner' "$(cat "$GH_LOG")"
want "waiting names the key"               "decision:41:fix-a-or-b" "$(bash "$OQ" waiting 41)"
bash "$OQ" waiting 4; want "a ticket whose number prefixes it is not waiting" "1" "$?"
bash "$OQ" ask 41 "Fix A or B?" "Fix A (retry) or Fix B (drop the cache)?" >/dev/null
want "asked again while open: one line, not two" "1" "$(grep -c 'key:decision:41:' "$C/needs-you.md")"
fresh
jq '.labels.ownerDecision = "waiting:owner"' "$HARNESS_CFG_PATH" > "$FIX/h.json" && cp "$FIX/h.json" "$HARNESS_CFG_PATH"
bash "$OQ" ask 42 pick "One or two?" >/dev/null
want_in "labels.ownerDecision names the label" '^issue edit 42 .*--add-label waiting:owner' "$(cat "$GH_LOG")"
jq 'del(.labels.ownerDecision)' "$HARNESS_CFG_PATH" > "$FIX/h.json" && cp "$FIX/h.json" "$HARNESS_CFG_PATH"
want "a question is required" "2" "$(bash "$OQ" ask 41 x "" >/dev/null 2>&1; echo $?)"
want "a ticket number is required"         "2" "$(bash "$OQ" ask abc x "q" >/dev/null 2>&1; echo $?)"

echo "--- answer ---"
fresh; bash "$OQ" ask 41 pick "Fix A or Fix B?" >/dev/null; : > "$GH_LOG"
out=$(bash "$W" answer decision:41:pick $'Fix B,\nplease'); rc=$?
want "it exits 0"                          "0" "$rc"
want_in "the label comes off"              '^issue edit 41 .*--remove-label needs:owner-decision' "$(cat "$GH_LOG")"
want_in "the answer is on the ticket, on one line" '^issue comment 41 .*The owner answered.*: Fix B, please$' "$(cat "$GH_LOG")"
want "back on the queue, new, at the front" "41 new" "$(jq -r '.tickets[0] | "\(.n) \(.class)"' "$C/queue.json")"
want_in "the note carries the answer"      'Fix B, please' "$(jq -r '.tickets[0].note' "$C/queue.json")"
want_in "the answer is kept on disk first" $'\tdecision:41:pick\tFix B, please$' "$(cat "$C/answers.tsv")"
want "the line is ticked"                  "1" "$(grep -c '^- \[x\] .*key:decision:41:pick' "$C/needs-you.md")"
want "no longer waiting"                   "" "$(bash "$OQ" waiting 41)"
bash "$OQ" ask 41 pick "And now?" >/dev/null
want "asked again after an answer: a fresh key" "decision:41:pick-2" "$(bash "$OQ" waiting 41)"

fresh; bash "$OQ" ask 43 pick "Q?" >/dev/null
printf '[{"number":9}]\n' > "$FIX/gh/prs-tkt-43.json"
bash "$OQ" answer decision:43:pick "yes" >/dev/null
want "a ticket with an open PR goes back as repair" "repair" "$(jq -r '.tickets[] | select(.n == 43) | .class' "$C/queue.json")"

# The forge refusing the label change: the answer is still kept and the failure named.
fresh; bash "$OQ" ask 44 pick "Q?" >/dev/null
cat > "$BIN/gh-down" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in "issue edit") exit 1 ;; esac
exec "$BIN/gh" "$@"
SH
chmod +x "$BIN/gh-down"
err=$(SWARM_GH="$BIN/gh-down" bash "$OQ" answer decision:44:pick "no" 2>&1 >/dev/null); rc=$?
want "a failed label change exits 1"       "1" "$rc"
want_in "and names it"                     'could not take needs:owner-decision off #44' "$err"
want_in "the answer is kept anyway"        $'decision:44:pick\tno$' "$(cat "$C/answers.tsv")"
want "a key that is not a decision is refused" "2" "$(bash "$OQ" answer blind:x "y" >/dev/null 2>&1; echo $?)"

exit $FAILED
