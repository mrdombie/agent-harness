#!/usr/bin/env bash
# coordinator-queue.test.sh — a scope resolves the way /work resolves one, a
# scope that resolves to nothing is refused, and the order is class first.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
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

echo "--- 'all' is every claimable ticket, labelled or not ---"
out=$(bash "$Q" seed all 2>&1)
want_in "it says what it seeded"           'seeded 4 ticket\(s\) for all' "$out"
want "every ticket, the unlabelled one included" "900:new 502:repair 501:new 503:new" "$(order)"
want "a ticket carrying no scope label is in scope" "0" "$(bash "$Q" in-scope 900 >/dev/null 2>&1; echo $?)"

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
want "approved-merge sorts after repair, before new of its priority; no priority runs last" "502:repair 501:approved-merge 503:new 777:approved-merge" "$(order)"
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

echo "--- a comma list seeds the union of its scopes ---"
printf '%s\n' "501	P1	OPS		-	one" "502	P1	OPS		[FINISH PR]	two" "503	P2	OPS		-	three" "504	P2	OPS		-	four" "900	P0	OPS		-	elsewhere" \
  | sed 's/	-	/		/' > "$FIX/claimable.tsv"
printf '[{"name":"project:widgets"},{"name":"flow-gap"},{"name":"area:GADGETS"}]\n' > "$FIX/gh/labels.json"
fix_issue_list "area:GADGETS" '[{"number":503},{"number":504}]'
rm -f "$QF"; bash "$Q" add 888 --class repair --note "pinned before the list" >/dev/null
out=$(bash "$Q" seed "widgets, area:GADGETS,flow-gap,widgets" 2>&1)
want_in "it names every label it seeded"   'for project:widgets, area:GADGETS, flow-gap$' "$out"
want "the union, de-duplicated, by priority, repair first within one, newest first; no priority last" "502:repair 501:new 504:new 503:new 888:repair" "$(order)"
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

echo "--- priority first; within one: repair, half-built, features, bugs, polish; newest first ---"
# Claimable order is oldest first; the queue must not keep it.
printf '%s\n' \
  "601	P1	OPS			polish(inbox): tighten the row gap	type:bug,project:widgets" \
  "602	P1	OPS			Inbox drops a reply	type:bug,project:widgets" \
  "603	P1	OPS			Saved views screen	type:feature,project:widgets" \
  "604	P1	OPS			Analytics screen half done	status:partial,project:widgets" \
  "605	P1	OPS			Inbox loses the draft	type:bug,project:widgets" \
  "606	P0	OPS			Calendar screen	type:feature,project:widgets" \
  "607	P0	OPS			polish: row hover colour	project:widgets" \
  "608	P3	OPS			Old rough edge	P3,project:widgets" \
  "609	P1	OPS		[RESUME PR]	Pipeline screen	project:widgets" \
  "610	P1	OPS		[FINISH PR]	clashing PR	type:bug,project:widgets" \
  "611	P1	OPS		[FINISH PR]	another clash	type:feature,project:widgets" > "$FIX/claimable.tsv"
rm -f "$QF"; bash "$Q" seed widgets >/dev/null
want "P0 before P1 whatever the class; repairs keep claimable order; new by kind, newest" \
  "606:new 607:new 610:repair 611:repair 609:new 604:new 603:new 605:new 602:new 601:new 608:new" "$(order)"
want "each entry keeps its priority"       "0 1 3" "$(jq -r '[.tickets[] | select(.n==606 or .n==610 or .n==608) | .prin] | sort | join(" ")' "$QF")"
want "and whether it is polish"            "true false" "$(jq -r '[(.tickets[] | select(.n==608)), (.tickets[] | select(.n==606))] | map(.polish) | join(" ")' "$QF")"
want "the kind is recorded"                "feature" "$(jq -r '.tickets[] | select(.n==606) | .kind' "$QF")"

echo "--- an entry put at the front keeps the front across a refresh ---"
bash "$Q" add 608 --front >/dev/null
bash "$Q" add 700 --front --note "outside the claimable list" >/dev/null
bash "$Q" refresh >/dev/null
want "the P0s, then fronts (the last one put there first), the rest re-sorted" \
  "606:new 607:new 700:new 608:new 610:repair 611:repair 609:new 604:new 603:new 605:new 602:new 601:new" "$(order)"
bash "$Q" refresh >/dev/null
want "and still so after a second refresh" \
  "606:new 607:new 700:new 608:new 610:repair 611:repair 609:new 604:new 603:new 605:new 602:new 601:new" "$(order)"

echo "--- priority decides across classes (owner call 2026-10-19) ---"
printf '%s\n' \
  "620	P3	OPS		[FINISH PR]	a clash on a rough edge	P3,type:bug,project:widgets" \
  "621	P0	OPS			Login drops the session	P0,type:bug,project:widgets" \
  "622	P1	OPS		[FINISH PR]	a clash on the inbox	P1,type:bug,project:widgets" \
  "623	P1	OPS			Inbox drops a reply	P1,type:bug,project:widgets" \
  "624	P1	OPS			Saved views screen	P1,type:feature,project:widgets" > "$FIX/claimable.tsv"
rm -f "$QF"; bash "$Q" seed widgets >/dev/null
want "a P0 new ticket outranks a P3 repair; a P1 repair outranks a P1 new ticket" \
  "621:new 622:repair 624:new 623:new 620:repair" "$(order)"
bash "$Q" add 626 --class approved-merge >/dev/null
want "an entry whose ticket cannot be read at add ranks as no priority" "626:approved-merge" "$(order | awk '{print $NF}')"
fix_issue 625 OPEN "P0,status:in-review"
bash "$Q" add 625 --class approved-merge >/dev/null
want "add reads the ticket's labels, so list ranks it as the tick will" "625:approved-merge 621:new" "$(order | cut -d' ' -f1-2)"
want "and keeps them on the entry"         "0 half-built false" "$(jq -r '.tickets[] | select(.n==625) | "\(.prin) \(.kind) \(.tooling)"' "$QF")"
. "$HERE/coordinator-env.sh"
ISSUES='{"625":{"number":625,"state":"OPEN","title":"x","labels":["P0","status:in-review"]}}'
want "with the tick's read, it ranks by its own ticket's priority" \
  "625	approved-merge	0	0	0	1	0	0	|621	new	0	0	0	0	0	0	|622	repair	1	0	0	0	0	0	" \
  "$(COORD_QUEUE="$QF" coord_queue_ordered --wide | head -3 | tr '\n' '|' | sed 's/|$//')"
unset ISSUES

echo "--- at one priority, product work goes ahead of our own tooling (owner call 2026-10-19) ---"
printf '%s\n' \
  "630	P1	OPS			Harness gate feature	P1,type:feature,project:harness-kit,project:widgets" \
  "631	P1	OPS			Inbox drops a reply	P1,type:bug,project:widgets" \
  "632	P2	OPS			Calendar loses an event	P2,type:bug,project:widgets" \
  "633	P1	OPS			feat(gates): a faster pre-push	P1,type:feature,project:widgets" \
  "634	P1	OPS		[FINISH PR]	a clash on the ops console	P1,type:bug,area:OPS-CONSOLE,project:widgets" \
  "635	P1	OPS		[FINISH PR]	a clash on the inbox	P1,type:bug,project:widgets" > "$FIX/claimable.tsv"
rm -f "$QF"; bash "$Q" seed widgets >/dev/null
want "a P1 product bug outranks a P1 tooling feature; a P1 tooling ticket outranks a P2 product ticket" \
  "635:repair 634:repair 631:new 633:new 630:new 632:new" "$(order)"
want "tooling by label or by title scope is recorded" "true true false" \
  "$(jq -r '[(.tickets[] | select(.n==630)), (.tickets[] | select(.n==633)), (.tickets[] | select(.n==631))] | map(.tooling) | join(" ")' "$QF")"
rm -f "$QF"; COORDINATOR_TOOLING_LABELS="code-health" bash "$Q" seed widgets >/dev/null
want "coordinator.toolingLabels decides which labels are tooling" \
  "634:repair 635:repair 630:new 631:new 633:new 632:new" "$(order)"

echo "--- a process fix is seeded first of all, whatever its priority or class ---"
printf '%s\n' \
  "636	P0	OPS		[FINISH PR]	a P0 clash	P0,type:bug,project:widgets" \
  "637	P0	OPS			a P0 feature	P0,type:feature,project:widgets" \
  "638	P3	OPS			the claim flow skips a step	P3,process,project:widgets" > "$FIX/claimable.tsv"
rm -f "$QF"; bash "$Q" seed widgets >/dev/null
want "the P3 process fix heads a P0 repair and a P0 feature" "638:new 636:repair 637:new" "$(order)"
want "the queue file holds it first too"   "638" "$(jq -r '.tickets[0].n' "$QF")"
want "and the entry says it is one"        "true false" \
  "$(jq -r '[(.tickets[] | select(.n==638)), (.tickets[] | select(.n==637))] | map(.process) | join(" ")' "$QF")"

echo "--- polish is a P3 label or a polish list, nothing else ---"
printf '%s\n' \
  "640	P1	OPS			polish(inbox): tighten the row gap	P1,type:bug,polish,project:widgets" \
  "641	P3	OPS			Old rough edge	P3,project:widgets" \
  "642	-	OPS			Polish list: Inbox	polish-list,screen:inbox,status:ready" > "$FIX/claimable.tsv"
rm -f "$QF"; bash "$Q" seed widgets >/dev/null
want "a P1 titled polish with a polish label is not polish; a P3 and a list are" "false true true" \
  "$(jq -r '[(.tickets[] | select(.n==640)), (.tickets[] | select(.n==641)), (.tickets[] | select(.n==642))] | map(.polish) | join(" ")' "$QF")"
want "the kind follows the same rule"      "other" "$(jq -r '.tickets[] | select(.n==640) | .kind' "$QF")"

echo "--- polish lists are in every scope ---"
want "a polish list outside the seeded labels is queued" "642" "$(jq -r '.tickets[] | select(.n==642) | .n' "$QF")"
want "the recorded scope is still what was seeded" "project:widgets" "$(jq -r '.label' "$QF")"
fix_issue 643 OPEN "polish-list,screen:calendar"
bash "$Q" in-scope 643; want "in-scope says a polish list is in" "0" "$?"
rm -f "$QF"; bash "$Q" seed 640 >/dev/null
want "a scope of one ticket stays exactly that ticket" "640:new" "$(order)"
bash "$Q" in-scope 643; want "and a polish list is not in it" "1" "$?"

echo "--- a resume or an answer (add --first) is first only within its priority ---"
printf '%s\n' \
  "650	P0	OPS			Login drops the session	P0,type:bug,project:widgets" \
  "651	P0	OPS			Inbox loses a draft	P0,type:bug,project:widgets" \
  "652	P1	OPS			Saved views	P1,type:bug,project:widgets" > "$FIX/claimable.tsv"
fix_issue 653 OPEN "P3,status:ready,type:feature,project:widgets"
rm -f "$QF"; bash "$Q" seed widgets >/dev/null
bash "$Q" add 653 --first --note "Resume: run r1 was cut off" >/dev/null
bash "$Q" add 652 --first --note "The owner answered" >/dev/null
want "a pinned P3 does not jump the P0s; a pinned P1 leads its own priority" "651:new 650:new 652:new 653:new" "$(order)"
bash "$Q" refresh >/dev/null
want "and the same after a refresh"        "651:new 650:new 652:new 653:new" "$(order)"
fix_issue 654 OPEN "P3,status:ready,project:widgets"
bash "$Q" add 654 --front --note "PM: this first" >/dev/null
bash "$Q" refresh >/dev/null
want "the PM's --front leads after the P0s (owner, 2026-10-30: urgent first)" "651:new 650:new 654:new 652:new 653:new" "$(order)"

echo "--- a new entry carrying a REPAIR brief is a repair ---"
fix_issue 655 OPEN "P2,status:in-review,project:widgets"
bash "$Q" add 655 --first --note "$(printf 'Sign-off comes last.\n\nREPAIR on PR #9 at abc: it clashes with develop.')" >/dev/null
want "added as new with a REPAIR note, it is queued as repair" "repair" "$(jq -r '.tickets[] | select(.n==655) | .class' "$QF")"
jq '.tickets += [{n: 656, class: "new", pinned: true, note: "REPAIR on PR #10: CI went red", prin: 2}]' "$QF" > "$QF.t" && mv "$QF.t" "$QF"
fix_issue 656 OPEN "P2,status:in-review,project:widgets"
bash "$Q" refresh >/dev/null
want "one already queued as new comes out of a refresh as repair" "repair" "$(jq -r '.tickets[] | select(.n==656) | .class' "$QF")"
want "a Resume note stays new"             "new" "$(jq -r '.tickets[] | select(.n==653) | .class' "$QF")"

echo "--- the queue holds only rows somebody can start ---"
printf '%s\n' \
  "660	P1	OPS			can start	P1,status:ready,project:widgets" \
  "661	P1	OPS			folded into a batch	P1,status:ready,status:batched,project:widgets" \
  "662	P1	OPS			parked yet ready	P1,status:parked,status:ready,project:widgets" \
  "663	P1	OPS			blocked	P1,status:blocked,project:widgets" \
  "664	P1	OPS			held for the owner	P1,status:ready,needs:human-approval,project:widgets" \
  "665	P1	OPS		[FINISH PR]	a held PR that clashes	P1,status:in-review,needs:human-approval,project:widgets" > "$FIX/claimable.tsv"
rm -f "$QF"; bash "$Q" seed widgets >/dev/null
fix_issue 666 CLOSED "P1,status:ready,project:widgets"
fix_issue 667 OPEN "P1,status:ready,project:widgets"
fix_issue 668 OPEN "P1,status:batched,project:widgets"
for t in 666 667 668; do bash "$Q" add "$t" --note "pinned" >/dev/null; done
out=$(bash "$Q" refresh 2>&1)
want "only the rows that can start: a ready one, a held PR's repair, an open pinned one" "665:repair 667:new 660:new" "$(order)"
want_in "and the count says so"            'seeded 3 ticket' "$out"
want "the file holds the same rows"        "3" "$(jq '.tickets | length' "$QF")"
rm -f "$FIX/gh/issue-667.json"
bash "$Q" refresh >/dev/null
want "a pinned row that could not be read is kept" "665:repair 667:new 660:new" "$(order)"

echo "--- a repo:<other> ticket is that repo's: never seeded here (this repo is acme/widgets) ---"
printf '%s\n' \
  "670	P1	OPS			ours	P1,status:ready,project:widgets" \
  "671	P1	OPS			the harness's	P1,status:ready,effort:M,repo:agent-harness,project:widgets" \
  "672	P1	OPS			named for us	P1,status:ready,repo:widgets,project:widgets" \
  "673	P1	OPS		[FINISH PR]	the harness's red	P1,status:in-review,repo:acme/agent-harness,project:widgets" > "$FIX/claimable.tsv"
rm -f "$QF"; out=$(bash "$Q" seed widgets 2>&1)
want "only this repo's rows are seeded"      "672:new 670:new" "$(order)"
want_in "each skip says whose it is"         'skip #671: belongs to agent-harness' "$out"
want_in "an owner/name label too"            'skip #673: belongs to agent-harness' "$out"
fix_issue 674 OPEN "P1,status:ready,repo:agent-harness,project:widgets"
bash "$Q" add 674 --note "pinned" >/dev/null
out=$(bash "$Q" refresh 2>&1)
want "a pinned one is dropped at refresh too" "672:new 670:new" "$(order)"
jq '.sisterRepos = ["widgets-support"]' "$HARNESS_CFG_PATH" > "$FIX/h-sister.json"
printf '%s\n' "675	P1	OPS			the sister's	P1,status:ready,repo:widgets-support,project:widgets" \
  "676	P1	OPS			the harness's	P1,status:ready,repo:agent-harness,project:widgets" > "$FIX/claimable.tsv"
rm -f "$QF"; HARNESS_CFG_PATH="$FIX/h-sister.json" bash "$Q" seed widgets >/dev/null 2>&1
want "a sister repo's ticket is seeded; another repo's is not" "675:new" "$(order)"

echo "--- a label gh is still writing about is found (grep -q under pipefail) ---"
mv "$BIN/gh" "$BIN/gh.fixture"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "label list" ]; then
  echo "area:create"; sleep 0.3; for i in $(seq 1 3000); do echo "area:create-$i"; done; exit 0
fi
exec "$(dirname "$0")/gh.fixture" "$@"
SH
chmod +x "$BIN/gh"
fix_issue_list "area:create" '[]'
out=$(bash "$Q" seed area:create 2>&1); rc=$?
want "the label is found while gh is still writing" "0" "$rc"
mv -f "$BIN/gh.fixture" "$BIN/gh"

echo "--- add --class new on a ticket with an open PR stores a repair, and warns ---"
rm -f "$STATE/swarm/prs.json"
printf '[{"number":41,"headRefName":"tkt-690-x","isDraft":true}]\n' > "$FIX/gh/prs-all.json"
out=$(bash "$Q" add 690 --class new 2>&1)
want "stored as repair"                    "repair" "$(jq -r '.tickets[] | select(.n==690) | .class' "$QF")"
want_in "with a warning naming the PR"     'warning: #690 has an open PR #41 — queued as repair, not new' "$out"
out=$(bash "$Q" add 691 2>&1)
want "a ticket with no open PR stays new"  "new" "$(jq -r '.tickets[] | select(.n==691) | .class' "$QF")"
want_not_in "and no warning"               'warning' "$out"
bash "$Q" remove 690 >/dev/null; bash "$Q" remove 691 >/dev/null
printf '[]\n' > "$FIX/gh/prs-all.json"; rm -f "$STATE/swarm/prs.json"

echo "--- add and remove ---"
bash "$Q" add 777 --class approved-merge >/dev/null
out=$(bash "$Q" add 12 --class urgent 2>&1); rc=$?
want "an unknown class is refused"         "2" "$rc"
bash "$Q" remove 777 >/dev/null
want "removed"                             "" "$(jq -r '.tickets[] | select(.n==777) | .n' "$QF")"

echo "--- a follow-up ranks by its priority, after every other ticket there, never on top (owner call 2026-10-23) ---"
rm -f "$QF"
fix_issue 801 OPEN "P0,type:feature,status:ready"
fix_issue 802 OPEN "P1,type:bug,status:ready"
fix_issue 803 OPEN "P1,type:bug,status:ready,fix-after-merge"
fix_issue 804 OPEN "P3,type:bug,status:ready,fix-after-merge"
fix_issue 805 OPEN "P1,type:bug,status:ready"
# As scripts/follow-up.sh adds one, and before the P1 it must still rank behind.
bash "$Q" add 803 --note "follow-up of PR #42: major at a.tsx:3" >/dev/null
bash "$Q" add 801 >/dev/null; bash "$Q" add 802 >/dev/null
bash "$Q" add 804 --note "follow-up of PR #42: minor at b.ts:1" >/dev/null
bash "$Q" add 805 --first >/dev/null
want "a P0 first; at P1 the others, then the follow-up; the P3 follow-up last" \
  "801:new 805:new 802:new 803:new 804:new" "$(order)"
. "$HERE/coordinator-env.sh"
ISSUES='{"803":{"number":803,"state":"OPEN","title":"x","labels":["P1","fix-after-merge"]},"802":{"number":802,"state":"OPEN","title":"y","labels":["P1"]}}'
want "with the tick's read, the label decides the same way" "802 803" \
  "$(COORD_QUEUE="$QF" coord_queue_ordered | cut -f1 | grep -E '^80[23]$' | tr '\n' ' ' | sed 's/ $//')"
unset ISSUES
want "a follow-up's note alone ranks it so, with no labels read" "1" \
  "$(COORD_QUEUE="$QF" ISSUES='' coord_queue_ordered | cut -f1 | tr '\n' ' ' | grep -c '802 803')"

suite_end "$FAILED"
