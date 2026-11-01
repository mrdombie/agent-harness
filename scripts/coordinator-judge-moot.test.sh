#!/usr/bin/env bash
# coordinator-judge-moot.test.sh — a judgement event a rule can settle starts no model:
# a merged or closed PR, a head that moved on, a closed ticket, a ticket already queued
# or running. A still-red PR at its head still gets a judge, and that judge runs headless.
# A read that fails settles nothing and starts nothing.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
J="$HERE/coordinator-judge.sh"
Q="$HERE/coordinator-queue.sh"
C="$STATE/coordinator"

cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
{ printf 'ARGV'; printf ' [%s]' "$@"; printf '\n'
  echo "HEADLESS=${HARNESS_HEADLESS:-unset}"; } >> "$FIX/claude.log"
SH
chmod +x "$BIN/claude"
cat > "$BIN/ghfail" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$BIN/ghfail"
export COORDINATOR_CLAUDE="$BIN/claude" COORDINATOR_JUDGES=5

head_of() { printf 'sha%sabcdef' "$1"; }
open_pr() { # <n> — an open PR whose head is head_of <n>
  jq -n --argjson n "$1" --arg h "$(head_of "$1")" '{number:$n, headRefName:("tkt-x-" + ($n|tostring)), headRefOid:$h}'
}
ev() { # <kind> <ticket> <pr> <sha-or-run>
  local id
  if [ "$1" = red-pr ]; then id="red-pr:$3:$4"; else id="stood-down:$4"; fi
  jq -cn --arg id "$id" --arg k "$1" --arg t "$2" --arg p "$3" \
    '{id:$id, at:(now|todate), kind:$k, judge:true, ticket:$t, pr:$p, detail:"ci red"}' >> "$C/events.did.jsonl"
}
fresh() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/prs.json" "$FIX"/gh/issue-*.json; mkdir -p "$C/judges"
  : > "$FIX/claude.log"; printf '[]\n' > "$FIX/gh/prs-all.json"
}
judge() { COORDINATOR_SHADOW=0 bash "$J" 2>&1; for _ in $(seq 1 30); do [ -s "$FIX/claude.log" ] && break; sleep 0.1; done; sleep 0.2; }
settled() { [ -f "$C/judgements.log" ] || { echo 0; return; }; grep -c "	$1	moot by rule: $2" "$C/judgements.log" || true; }

echo "--- a rule settles what a judge would only confirm ---"
fresh
jq -s . <(open_pr 45) <(open_pr 46) <(open_pr 47) > "$FIX/gh/prs-all.json"
fix_issue 41 MERGED ""; fix_issue 601 OPEN status:in-review
fix_issue 44 CLOSED ""; fix_issue 604 OPEN status:in-review
fix_issue 45 OPEN ""; fix_issue 605 OPEN status:in-review
fix_issue 46 OPEN ""; fix_issue 606 OPEN status:in-review
fix_issue 47 OPEN ""; fix_issue 607 OPEN status:in-review
fix_issue 608 CLOSED status:done
ev red-pr 601 41 "$(head_of 41)"          # merged
ev red-pr 604 44 "$(head_of 44)"          # closed
ev red-pr 605 45 oldsha45                 # head moved on
ev red-pr 606 46 "$(head_of 46)"          # already queued
ev stood-down 608 "" claim-608-x          # ticket closed
ev red-pr 607 47 "$(head_of 47)"          # still red at its head: a judge's
bash "$Q" add 606 --class repair >/dev/null
out=$(judge)
want "a merged PR starts no judge"           "1" "$(settled "red-pr:41:$(head_of 41)" 'PR #41 is MERGED')"
want "a closed PR starts no judge"           "1" "$(settled "red-pr:44:$(head_of 44)" 'PR #44 is CLOSED')"
want "a head that moved on starts no judge"  "1" "$(settled "red-pr:45:oldsha45" 'PR #45 moved on to sha45abcd')"
want "an already-queued ticket starts none"  "1" "$(settled "red-pr:46:$(head_of 46)" '#606 is already on the queue')"
want "a closed ticket's stand-down, none"    "1" "$(settled "stood-down:claim-608-x" '#608 is closed')"
want "each settled event is judged once"     "1" "$(grep -cx "red-pr:41:$(head_of 41)" "$C/judged.did.ids")"
want "only the still-red PR starts a judge"  "1" "$(grep -c ^ARGV "$FIX/claude.log")"
want_in "and it is that one"                 "red-pr:47:$(head_of 47)" "$(cat "$FIX/claude.log")"
want "the judge runs headless"               "HEADLESS=judge:red-pr:47:$(head_of 47)" "$(grep ^HEADLESS "$FIX/claude.log")"
want_in "the tick says what it settled"      "settled red-pr:41:$(head_of 41) by rule" "$out"

echo "--- a live run for the ticket settles it too ---"
fresh
jq -s . <(open_pr 48) > "$FIX/gh/prs-all.json"
fix_issue 48 OPEN ""; fix_issue 609 OPEN status:claimed
printf '{"run_id":"claim-609-live","ticket":"609","child_pid":%s}\n' "$$" > "$STATE/runs/claim-609-live.json"
ev red-pr 609 48 "$(head_of 48)"
judge >/dev/null
want "a ticket with a live run starts no judge" "1" "$(settled "red-pr:48:$(head_of 48)" '#609 has a live run')"
want "and no model ran"                         "0" "$(grep -c ^ARGV "$FIX/claude.log")"

echo "--- a read that fails settles nothing and starts nothing ---"
fresh
fix_issue 41 MERGED ""
ev red-pr 601 41 "$(head_of 41)"
out=$(SWARM_GH="$BIN/ghfail" judge)
want "no judge starts"                       "0" "$(grep -c ^ARGV "$FIX/claude.log")"
want "nothing is marked judged"              "0" "$(grep -c . "$C/judged.did.ids" 2>/dev/null || true)"
want_in "and it says why"                    'GitHub could not be read' "$out"

echo "--- shadow settles nothing and reads nothing ---"
fresh
fix_issue 41 MERGED ""
ev red-pr 601 41 "$(head_of 41)"; mv "$C/events.did.jsonl" "$C/events.would.jsonl"
out=$(bash "$J" 2>&1)
want_in "shadow still only says it would judge" "would judge red-pr:41" "$out"
want "and writes no settled line"               "0" "$(settled "red-pr:41:$(head_of 41)" 'PR')"

suite_end "$FAILED"
