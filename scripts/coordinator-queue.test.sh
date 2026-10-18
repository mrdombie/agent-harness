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

echo "--- a pinned repair's class and note win over its seeded row ---"
rm -f "$QF"
bash "$Q" add 503 --class repair --front --note "re-capture the tooltip at 375" >/dev/null
bash "$Q" seed widgets >/dev/null
want "a seed of a scope holding it as new keeps it a repair" "repair" "$(jq -r '.tickets[] | select(.n==503) | .class' "$QF")"
want "and keeps the owner's note" "re-capture the tooltip at 375" "$(jq -r '.tickets[] | select(.n==503) | .note' "$QF")"
bash "$Q" refresh >/dev/null
want "so does a refresh" "repair|re-capture the tooltip at 375" "$(jq -r '.tickets[] | select(.n==503) | "\(.class)|\(.note)"' "$QF")"

echo "--- a re-seed that read the queue before an add does not write over it ---"
# The merge's jq is held open, so the add lands between the re-seed's read and its write.
REAL_JQ=$(command -v jq)
cat > "$BIN/jq" <<STUB
#!/usr/bin/env bash
case " \$* " in *" --arg rows "*) touch "$FIX/in-merge"; while [ ! -e "$FIX/release" ]; do sleep 0.05; done ;; esac
exec "$REAL_JQ" "\$@"
STUB
chmod +x "$BIN/jq"
rm -f "$FIX/in-merge" "$FIX/release"
bash "$Q" refresh >/dev/null 2>&1 & rp=$!
i=0; while [ ! -e "$FIX/in-merge" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
bash "$Q" add 501 --class repair --note "use the quieter paper colour" >/dev/null 2>&1 & ap=$!
i=0; while kill -0 "$ap" 2>/dev/null && [ $i -lt 40 ]; do sleep 0.05; i=$((i+1)); done
touch "$FIX/release"; wait "$rp"; wait "$ap"; want "the add exits 0" "0" "$?"
rm -f "$BIN/jq"
want "the add made during the re-seed is still a repair" "repair" "$(jq -r '.tickets[] | select(.n==501) | .class' "$QF")"
want "with its note" "use the quieter paper colour" "$(jq -r '.tickets[] | select(.n==501) | .note' "$QF")"
want "and the lock is let go" "" "$(ls -d "$STATE/coordinator/.queue.lock" 2>/dev/null)"

echo "--- a seed whose reads fail changes nothing ---"
before=$(cat "$QF")
out=$(COORDINATOR_CLAIMABLE=false bash "$Q" refresh 2>&1); rc=$?
want "refused"                             "2" "$rc"
want_in "and says why"                     'queue left as it was' "$out"
want "the queue and its notes are intact"  "$before" "$(cat "$QF")"

echo "--- a comma list seeds the union of its scopes ---"
printf '%s\n' "501	P1	OPS		-	one" "502	P1	OPS		[FINISH PR]	two" "503	P2	OPS		-	three" "504	P2	OPS		-	four" "900	P0	OPS		-	elsewhere" \
  | sed 's/	-	/		/' > "$FIX/claimable.tsv"
printf '[{"name":"project:widgets"},{"name":"flow-gap"},{"name":"area:GADGETS"}]\n' > "$FIX/gh/labels.json"
fix_issue_list "area:GADGETS" '[{"number":503},{"number":504}]'
rm -f "$QF"; bash "$Q" add 888 --class repair --note "pinned before the list" >/dev/null
out=$(bash "$Q" seed "widgets, area:GADGETS,flow-gap,widgets" 2>&1)
want_in "it names every label it seeded"   'for project:widgets, area:GADGETS, flow-gap$' "$out"
want "the union, de-duplicated, repair first, then claimable order" "502:repair 888:repair 501:new 503:new 504:new" "$(order)"
want "a ticket under two scopes is queued once" "1" "$(jq '[.tickets[] | select(.n==503)] | length' "$QF")"
want "the labels are recorded"             'project:widgets|area:GADGETS|flow-gap' "$(jq -r '.labels | join("|")' "$QF")"
want "the pinned repair survives the seed" "repair" "$(jq -r '.tickets[] | select(.n==888) | .class' "$QF")"

echo "--- refresh re-seeds every scope in the list ---"
fix_issue_list "area:GADGETS" '[{"number":503},{"number":504},{"number":900}]'
bash "$Q" refresh >/dev/null
want "a ticket new to the second scope arrives" "900" "$(jq -r '.tickets[] | select(.n==900) | .n' "$QF")"
want "the first scope's tickets stay"      "501" "$(jq -r '.tickets[] | select(.n==501) | .n' "$QF")"
fix_issue_list "area:GADGETS" '[{"number":503},{"number":504}]'

echo "--- one scope that resolves to nothing refuses the whole list ---"
before=$(cat "$QF")
out=$(bash "$Q" seed "widgets,nonsense,area:GADGETS" 2>&1); rc=$?
want "refused"                             "2" "$rc"
want_in "and names the one that failed"    "'nonsense' is neither" "$out"
want "the queue is untouched"              "$before" "$(cat "$QF")"
out=$(bash "$Q" seed " , ," 2>&1); rc=$?
want "a list of nothing is refused"        "2" "$rc"

echo "--- in-scope: a ticket under any one scope is in ---"
fix_issue 504 OPEN "area:GADGETS,status:ready"
fix_issue 501 OPEN "project:widgets"
fix_issue 905 OPEN "area:ELSEWHERE"
bash "$Q" in-scope 504; want "under the second scope: in" "0" "$?"
bash "$Q" in-scope 501; want "under the first scope: in"  "0" "$?"
bash "$Q" in-scope 905; want "under none: out"            "1" "$?"
bash "$Q" in-scope 906 2>/dev/null; want "unreadable: not in" "2" "$?"
bash "$Q" seed 501 >/dev/null
bash "$Q" in-scope 501; want "a ticket scope matches its own number" "0" "$?"
jq '.labels = null | .label = "area:GADGETS"' "$QF" > "$QF.t" && mv "$QF.t" "$QF"
bash "$Q" in-scope 504; want "a queue from before lists still reads its one label" "0" "$?"

echo "--- add and remove ---"
bash "$Q" add 777 --class approved-merge >/dev/null
out=$(bash "$Q" add 12 --class urgent 2>&1); rc=$?
want "an unknown class is refused"         "2" "$rc"
bash "$Q" remove 777 >/dev/null
want "removed"                             "" "$(jq -r '.tickets[] | select(.n==777) | .n' "$QF")"

exit $FAILED
