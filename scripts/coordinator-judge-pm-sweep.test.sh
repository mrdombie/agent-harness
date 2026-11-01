#!/usr/bin/env bash
# coordinator-judge-pm-sweep.test.sh — a question parked on the PM is judged whichever
# host's build asked it. The owner host's judge reads the forge for open tickets
# carrying the PM label (one REST list a tick, no search) and launches a judge for each
# one no event here covers; the next tick does not judge it again. A park the claim
# release left as partial is still judged. A reader host does not sweep, and a read
# that fails judges nothing.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
J="$HERE/coordinator-judge.sh"
C="$STATE/coordinator"

cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
{ printf 'ARGV'; printf ' [%s]' "$@"; printf '\n'; } >> "$FIX/claude.log"
SH
chmod +x "$BIN/claude"
cat > "$BIN/ghfail" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
exit 1
SH
chmod +x "$BIN/ghfail"
export COORDINATOR_CLAUDE="$BIN/claude" COORDINATOR_JUDGES=5
export COORDINATOR_HOST=mac COORDINATOR_SHEET_OWNER=mac

PM_LIST="$FIX/gh/api-repos_acme_widgets_issues_labels_status%3Apm-decision_state_open_per_page_100.json"
pm_on() { # <ticket…> — the forge's open tickets wearing the PM label
  local n out='[]'
  for n in "$@"; do out=$(jq -c --argjson n "$n" '. + [{number:$n, labels:[{name:"status:pm-decision"}]}]' <<<"$out"); done
  printf '%s\n' "$out" > "$PM_LIST"
}
fresh() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/prs.json" "$FIX"/gh/issue-*.json "$PM_LIST"; mkdir -p "$C/judges"
  : > "$FIX/claude.log"; : > "$GH_LOG"; printf '[]\n' > "$FIX/gh/prs-all.json"
}
judge() { COORDINATOR_SHADOW=0 bash "$J" 2>&1; for _ in $(seq 1 30); do [ -s "$FIX/claude.log" ] && break; sleep 0.1; done; sleep 0.2; }
lists() { grep -c 'issues?labels=status%3Apm-decision' "$GH_LOG" || true; }

echo "--- a question parked by a build on another host is judged here ---"
fresh
# #701 parked (pm) on the Windows host; its claim was then released as work stranded.
fix_issue 701 OPEN "status:partial,status:pm-decision"
pm_on 701
out=$(judge)
want "the owner's judge launches for it"        "1" "$(grep -c 'judge-pm-question_701_' "$FIX/claude.log")"
want "one list read of the forge, no search"    "1" "$(lists)"
want "and it is not a search call"              "0" "$(grep -c 'search/issues' "$GH_LOG")"
want "it is marked judged"                      "1" "$(grep -c '^pm-question:701:' "$C/judged.did.ids")"
want_in "and it is judged first, as a question" "parked \\(pm\\)" "$(cat "$C/events.did.jsonl")"
want_in "the tick says it"                      "judging pm-question:701" "$out"

echo "--- the next tick does not judge it again ---"
: > "$FIX/claude.log"
judge >/dev/null
want "no second judge"                          "0" "$(grep -c ^ARGV "$FIX/claude.log")"
want "and no second event"                      "1" "$(grep -c '"ticket":"701"' "$C/events.did.jsonl")"

echo "--- answered, then asked again: a new question, judged again ---"
pm_on; judge >/dev/null
pm_on 701; : > "$FIX/claude.log"; SWARM_NOW=$(( $(date +%s) + 120 )) judge >/dev/null
want "the new park is judged"                   "1" "$(grep -c 'judge-pm-question_701_' "$FIX/claude.log")"
want "two episodes, two events"                 "2" "$(grep -c '"ticket":"701"' "$C/events.did.jsonl")"

echo "--- a park this host already holds an event for is not judged twice ---"
fresh
fix_issue 702 OPEN "status:parked,status:pm-decision"
jq -cn '{id:"stood-down:claim-702-x", at:(now|todate), kind:"stood-down", judge:true, ticket:"702", pr:"", detail:"run claim-702-x ended exit 20: parked (pm)"}' >> "$C/events.did.jsonl"
pm_on 702
judge >/dev/null
want "only this host's own event is judged"     "1" "$(grep -c ^ARGV "$FIX/claude.log")"
want_in "and it is that one"                    "stood-down:claim-702-x" "$(cat "$FIX/claude.log")"
want "no sweep event beside it"                 "0" "$(grep -c pm-question:702 "$C/events.did.jsonl")"

echo "--- a reader host leaves the sweep to the owner ---"
fresh
fix_issue 703 OPEN "status:pm-decision"; pm_on 703
out=$(COORDINATOR_HOST=win judge)
want "no list read"                             "0" "$(lists)"
want "no judge"                                 "0" "$(grep -c ^ARGV "$FIX/claude.log")"

echo "--- a read that fails judges nothing and forgets nothing ---"
fresh
fix_issue 704 OPEN "status:pm-decision"; pm_on 704
judge >/dev/null
: > "$FIX/claude.log"
out=$(SWARM_GH="$BIN/ghfail" judge)
want "no judge starts"                          "0" "$(grep -c ^ARGV "$FIX/claude.log")"
want_in "and it says why"                       "could not be read" "$out"
judge >/dev/null
want "the park it already judged stays judged"  "0" "$(grep -c ^ARGV "$FIX/claude.log")"

suite_end "$FAILED"
