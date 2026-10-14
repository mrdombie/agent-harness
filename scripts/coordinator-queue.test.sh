#!/usr/bin/env bash
# coordinator-queue.test.sh — a scope resolves the way /work resolves one, a
# scope that resolves to nothing is refused, and the order is class first.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
Q="$HERE/coordinator-queue.sh"
QF="$STATE/coordinator/queue.json"

# claimable-issues.sh stands in as a file the test writes: number \t pri \t area \t repo \t mode \t title
cat > "$BIN/claimable" <<'STUB'
#!/usr/bin/env bash
cat "$FIX/claimable.tsv" 2>/dev/null
STUB
chmod +x "$BIN/claimable"; export COORDINATOR_CLAIMABLE="$BIN/claimable"
printf '%s\n' "501	P1	OPS		-	one" "502	P1	OPS		[FINISH PR]	two" "503	P2	OPS		-	three" "900	P0	OPS		-	elsewhere" \
  | sed 's/	-	/		/' > "$FIX/claimable.tsv"
printf '[{"name":"project:widgets"},{"name":"flow-gap"}]\n' > "$FIX/gh/labels.json"
fix_issue_list "project:widgets" '[{"number":501},{"number":502},{"number":503}]'
fix_issue_list "flow-gap" '[{"number":503}]'
order() { bash "$Q" list | sed -n 's/^ *[0-9]*\. #\([0-9]*\) *\([a-z-]*\).*/\1:\2/p' | tr '\n' ' ' | sed 's/ $//'; }

echo "--- a programme subject resolves to its project: label ---"
out=$(bash "$Q" seed widgets 2>&1)
want_in "it says what it seeded"           'seeded 3 ticket\(s\) for project:widgets' "$out"
want "repair first, then the rest in claimable order" "502:repair 501:new 503:new" "$(order)"
want "a ticket outside the scope is not queued" "" "$(jq -r '.tickets[] | select(.n==900) | .n' "$QF")"

echo "--- a label that exists is that label ---"
bash "$Q" seed flow-gap >/dev/null
want "only the label's tickets"            "503:new" "$(order)"

echo "--- a bare number is that one ticket ---"
bash "$Q" seed 501 >/dev/null
want "one ticket"                          "501:new" "$(order)"
want "and the scope says so"               "ticket 501" "$(jq -r .label "$QF")"

echo "--- a scope that resolves to nothing is refused, never widened ---"
before=$(cat "$QF")
out=$(bash "$Q" seed nonsense 2>&1); rc=$?
want "refused"                             "2" "$rc"
want_in "and names what it tried"          'project:nonsense' "$out"
want "the queue is untouched"              "$before" "$(cat "$QF")"

echo "--- approved-merge and notes survive a refresh ---"
bash "$Q" seed widgets >/dev/null
bash "$Q" add 501 --class approved-merge --note "owner approved the render" >/dev/null
bash "$Q" add 777 --class approved-merge >/dev/null
bash "$Q" refresh >/dev/null
want "approved-merge sorts after repair, before new" "502:repair 501:approved-merge 777:approved-merge 503:new" "$(order)"
want "the note is kept"                    "owner approved the render" "$(jq -r '.tickets[] | select(.n==501) | .note' "$QF")"

echo "--- a judge's re-queue survives the next tick's refresh ---"
bash "$Q" add 888 --class repair --note "red checks, outside the scope" >/dev/null
bash "$Q" refresh >/dev/null
want "a pinned repair outside the claimable list is kept" "repair" "$(jq -r '.tickets[] | select(.n==888) | .class' "$QF")"

echo "--- a seed whose reads fail changes nothing ---"
before=$(cat "$QF")
out=$(COORDINATOR_CLAIMABLE=false bash "$Q" refresh 2>&1); rc=$?
want "refused"                             "2" "$rc"
want_in "and says why"                     'queue left as it was' "$out"
want "the queue and its notes are intact"  "$before" "$(cat "$QF")"

echo "--- add and remove ---"
out=$(bash "$Q" add 12 --class urgent 2>&1); rc=$?
want "an unknown class is refused"         "2" "$rc"
bash "$Q" remove 777 >/dev/null
want "removed"                             "" "$(jq -r '.tickets[] | select(.n==777) | .n' "$QF")"

exit $FAILED
