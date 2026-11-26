#!/usr/bin/env bash
# coordinator-judge-pm-answer.test.sh — a PM question the judge answers is carried out,
# not logged for the PM to do by hand. The judge (a stand-in claude) reads its brief and
# writes the answer where the brief says; when it ends, the parent carries the answer and
# the "Blocked until" line the unblocker reads, is blocked on the child it filed (or set
# ready), and no longer wears the PM label, and the child is queued. An owner's item is
# never touched; a step that fails leaves the label on, with one comment and a line in the
# PM's channel.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
# No live claim: the unblocker reads claims before it releases a wait.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claims"; chmod +x "$BIN/claims"; export UNBLOCK_CLAIMS="$BIN/claims"
J="$HERE/coordinator-judge.sh"
C="$STATE/coordinator"

# The judge: the answer goes where the brief says; a brief that names no place for it
# gets what the judge did before, a log line for the PM.
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
{ printf 'ARGV'; printf ' [%s]' "$@"; printf '\n'; } >> "$FIX/claude.log"
brief=""; prev=""
for a in "$@"; do [ "$prev" = -p ] && brief="$a"; prev="$a"; done
f=$(printf '%s\n' "$brief" | sed -n 's/^PM answer file: //p' | tail -n 1)
if [ -n "$f" ] && [ -f "$FIX/verdict.json" ]; then cp "$FIX/verdict.json" "$f"
else printf '%s\tjudged\tPM shape question, answer forced by rule\tlogged as agent work for the PM\n' "$(date -u +%FT%TZ)" >> "$COORD_DIR/judgements.log"; fi
SH
# The forge, as far as this needs: labels stick (gh-labels), a comment is kept on the
# ticket, a filed ticket exists as #999. $FIX/gh/create-fail: filing fails.
cat > "$BIN/gh-pm" <<'SH'
#!/usr/bin/env bash
body=""; title=""; labs="[]"; prev=""
for a in "$@"; do
  case "$prev" in --body) body="$a" ;; --title) title="$a" ;; --label) labs=$(jq -c --arg l "$a" '. + [{name:$l}]' <<<"$labs") ;; esac
  prev="$a"
done
case "$1 $2" in
  "issue comment")
    printf '%s\n' "$*" >> "$GH_LOG"
    f="$FIX/gh/issue-$3.json"; [ -f "$f" ] || exit 1
    jq --arg b "$body" '.comments = ((.comments // []) + [{body:$b}])' "$f" > "$f.t" && mv "$f.t" "$f"; exit 0 ;;
  "issue create")
    printf '%s\n' "$*" >> "$GH_LOG"
    [ -f "$FIX/gh/create-fail" ] && exit 1
    jq -n --arg t "$title" --arg b "$body" --argjson l "$labs" '{number:999, state:"OPEN", title:$t, body:$b, labels:$l}' > "$FIX/gh/issue-999.json"
    echo "https://github.com/acme/widgets/issues/999"; exit 0 ;;
esac
exec "$BIN/gh-labels" "$@"
SH
chmod +x "$BIN/claude" "$BIN/gh-pm"
export SWARM_GH="$BIN/gh-pm" COORDINATOR_CLAUDE="$BIN/claude" COORDINATOR_JUDGES=5
export COORDINATOR_HOST=win COORDINATOR_SHEET_OWNER=mac

fresh() {
  rm -rf "$C" "$FIX"/gh/issue-*.json "$FIX/gh/create-fail" "$FIX/verdict.json"; mkdir -p "$C/judges"
  : > "$FIX/claude.log"; : > "$GH_LOG"; printf '[]\n' > "$FIX/gh/prs-all.json"
}
park() { # <ticket> <labels> — the driver's stand-down on a PM question
  fix_issue "$1" OPEN "$2"
  jq -cn --arg t "$1" '{id:("stood-down:claim-" + $t + "-x"), at:(now|todate), kind:"stood-down", judge:true, ticket:$t, pr:"",
    detail:("run claim-" + $t + "-x ended exit 20: parked (pm): shall the doc go out as its own docs-only ticket that merges first?")}' >> "$C/events.did.jsonl"
}
judge() { # launch, then wait for the judge's run to end
  COORDINATOR_SHADOW=0 bash "$J" > "$FIX/judge.out" 2>&1
  for _ in $(seq 1 100); do ls "$C"/judges/*.ended >/dev/null 2>&1 && break; sleep 0.1; done
}
labels_of() { jq -r '[.labels[].name] | sort | join(",")' "$FIX/gh/issue-$1.json"; }
comments_of() { jq -r '[.comments // [] | .[].body] | join("\n---\n")' "$FIX/gh/issue-$1.json"; }
n_comments() { jq -r '.comments // [] | length' "$FIX/gh/issue-$1.json"; }
SPLIT='{"ticket":701,"answer":"yes. The approved model goes out first as its own docs-only change, because the design check reads the doc at the merge base.","then":"blocked",
  "child":{"title":"Record the approved data model (docs only, lands before #701)","body":"Docs only.","labels":["type:chore"]}}'

echo "--- a PM shape question the judge answers: carried out, not logged for the PM ---"
fresh
park 701 "P0,project:alpha,type:feature,status:parked,status:pm-decision"
printf '%s\n' "$SPLIT" > "$FIX/verdict.json"
judge
want "the judge ran once"                          "1" "$(grep -c ^ARGV "$FIX/claude.log")"
want "a child ticket is filed"                     "1" "$(grep -c '^issue create' "$GH_LOG")"
want "the child is ready, in the parent's families, its own type" \
  "P0,project:alpha,status:ready,type:chore" "$(labels_of 999 2>/dev/null)"
want_in "the child says what it lands before"      'Lands before #701' "$(jq -r .body "$FIX/gh/issue-999.json" 2>/dev/null)"
want "the parent is blocked, the PM label is off"  "P0,project:alpha,status:blocked,type:feature" "$(labels_of 701)"
want_in "the parent carries the answer"            '^\*\*PM answer:\*\* yes\. The approved model goes out first' "$(comments_of 701)"
want_in "and the wait the unblocker reads"         '^Blocked until #999 merges\.$' "$(comments_of 701)"
want_in "the child is on the queue"                '999' "$(cat "$C/queue.json" 2>/dev/null)"
want_in "the judgement says it was carried out"    'PM answer carried out' "$(cat "$C/judgements.log" 2>/dev/null)"
want_not_in "and never 'agent work for the PM'"    'logged as agent work for the PM' "$(cat "$C/judgements.log" 2>/dev/null)"

echo "--- the unblocker reads that wait: held while the child is open, released when it lands ---"
fix_issue_list status:blocked "$(jq -c '[.]' "$FIX/gh/issue-701.json")"
out=$(SWARM_GH="$BIN/gh-pm" bash "$HERE/unblock-waiting.sh" --dry-run 2>&1)
want_in "still open: the child"                    'waits: #701 — still open: #999' "$out"
jq '.state = "CLOSED" | .stateReason = "COMPLETED"' "$FIX/gh/issue-999.json" > "$FIX/c.json" && mv "$FIX/c.json" "$FIX/gh/issue-999.json"
printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_issues_701_timeline_per_page_100.json"   # no person's hold on #701
out=$(SWARM_GH="$BIN/gh-pm" bash "$HERE/unblock-waiting.sh" --dry-run 2>&1)
want_in "the child landed: released"               'would unblock #701' "$out"

echo "--- an answer that waits on nothing: the parent is ready and queued first ---"
fresh
park 702 "P1,status:parked,status:pm-decision"
printf '%s\n' '{"ticket":702,"answer":"go ahead in this repo, as the ticket says.","then":"ready"}' > "$FIX/verdict.json"
judge
want "the parent is ready, the PM label off"       "P1,status:ready" "$(labels_of 702)"
want "no child is filed"                           "0" "$(grep -c '^issue create' "$GH_LOG")"
want_in "the parent carries the answer"            '\*\*PM answer:\*\* go ahead' "$(comments_of 702)"
want_not_in "and no wait line"                     'Blocked until' "$(comments_of 702)"
want_in "the parent is on the queue"               '702' "$(cat "$C/queue.json" 2>/dev/null)"

echo "--- an existing ticket to wait on: blocked until it merges, nothing filed ---"
fresh
park 703 "P1,status:parked,status:pm-decision"
printf '%s\n' '{"ticket":703,"answer":"it waits for the model change.","then":"blocked","blockedOn":[650,"#651"]}' > "$FIX/verdict.json"
judge
want "blocked, PM label off"                       "P1,status:blocked" "$(labels_of 703)"
want_in "waits on both"                            '^Blocked until #650, #651 merge\.$' "$(comments_of 703)"
want "nothing filed"                               "0" "$(grep -c '^issue create' "$GH_LOG")"

echo "--- an owner's item is never acted on ---"
for lab in needs:owner-decision needs:human-approval; do
  fresh
  park 704 "P0,status:parked,status:pm-decision,$lab"
  sed 's/"ticket":701/"ticket":704/' <<<"$SPLIT" > "$FIX/verdict.json"
  judge
  want "$lab: labels untouched"                    "P0,$lab,status:parked,status:pm-decision" "$(labels_of 704)"
  want "$lab: nothing filed"                       "0" "$(grep -c '^issue create' "$GH_LOG")"
  want "$lab: no comment"                          "0" "$(n_comments 704)"
  want_in "$lab: the judgement says refused"       'PM answer refused, nothing touched' "$(cat "$C/judgements.log" 2>/dev/null)"
done

echo "--- an answer for a ticket other than the event's is refused ---"
fresh
park 705 "P0,status:parked,status:pm-decision"
fix_issue 706 OPEN "P0,status:parked,status:pm-decision"
sed 's/"ticket":701/"ticket":706/' <<<"$SPLIT" > "$FIX/verdict.json"
judge
want "the other ticket is untouched"              "P0,status:parked,status:pm-decision" "$(labels_of 706)"
want "and the event's ticket too"                 "P0,status:parked,status:pm-decision" "$(labels_of 705)"
want "nothing filed"                              "0" "$(grep -c '^issue create' "$GH_LOG")"

echo "--- a step that fails: the label stays, one comment says why, the PM's channel hears ---"
fresh
park 707 "P0,status:parked,status:pm-decision"
sed 's/"ticket":701/"ticket":707/' <<<"$SPLIT" > "$FIX/verdict.json"
: > "$FIX/gh/create-fail"
judge
want "the PM label stays"                         "P0,status:parked,status:pm-decision" "$(labels_of 707)"
want "exactly one comment"                        "1" "$(n_comments 707)"
want_in "it says what did not happen"             'PM answer not carried out:\*\* the child ticket could not be filed' "$(comments_of 707)"
want_in "the PM's channel hears"                  'pm-answer-failed:707:' "$(cat "$C/agent-work.log" 2>/dev/null)"
want_in "the judgement says so"                   'PM answer not carried out' "$(cat "$C/judgements.log" 2>/dev/null)"

echo "--- a judge that wrote no answer changes nothing ---"
fresh
park 708 "P0,status:parked,status:pm-decision"
judge
want "labels untouched"                           "P0,status:parked,status:pm-decision" "$(labels_of 708)"
want "no comment"                                 "0" "$(n_comments 708)"

suite_end "$FAILED"
