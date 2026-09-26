#!/usr/bin/env bash
# queue.test.sh — the queue's order is the thing it exists to guarantee, so it is
# the thing this asserts: added order runs first-in-first-out, --front jumps it,
# re-adding keeps a place rather than losing it, and a drain stops at the cap.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
Q="$HERE/../queue.sh"
q() { bash "$Q" "$@" 2>&1; }

for n in 101 102 103 104; do fix_issue "$n" OPEN "status:ready,project:widgets"; done

echo "--- order: first in, first out ---"
q add 101 --programme widgets >/dev/null
q add 102 --programme widgets >/dev/null
q add 103 --programme widgets >/dev/null
want "next is the first added"     "101" "$(q next)"
want_in "list is in added order"  '1\. #101.*2\. #102.*3\. #103' "$(q list | tr '\n' ' ')"

echo "--- --front jumps the queue ---"
q add 104 --programme widgets --front >/dev/null
want "front runs next"            "104" "$(q next)"
want_in "the rest keep their order" '1\. #104.*2\. #101.*3\. #102.*4\. #103' "$(q list | tr '\n' ' ')"

echo "--- re-adding keeps the place ---"
out=$(printf 'read the latest comment first\n' | q add 102 --brief - )
want_in "re-add reports a position" 'queued #102' "$out"
want_in "102 did not move to the back" '2\. #101.*3\. #102' "$(q list | tr '\n' ' ')"
want_in "the brief is stored"      'brief: 102\.md' "$(q list | grep '#102')"

echo "--- remove ---"
q remove 103 >/dev/null
want_not_in "103 is gone" '#103' "$(q list)"

echo "--- drain stops at the free slots ---"
fix_live widgets 1                       # one agent already running, cap 3 → 2 slots
out=$(q drain --programme widgets)
want "two spawned, not four"      "2" "$(grep -c . "$SPAWNS")"
want_in "the front of the queue went first" '^104' "$(head -1 "$SPAWNS")"
want_in "then the next in line"   '^101' "$(sed -n 2p "$SPAWNS")"
want_in "the drain says what it did" 'launched 2 of 2 free slot' "$out"
want_in "spawned tickets leave the queue" '1\. #102' "$(q list | tr '\n' ' ')"

echo "--- the brief reaches the agent, the budget too ---"
: > "$SPAWNS"
fix_live widgets 0
out=$(q drain --programme widgets)
want_in "CLAIM_EXTRA carries the brief" 'brief=read the latest comment first' "$(cat "$SPAWNS")"
want_in "the budget is passed"          'budget=150' "$(cat "$SPAWNS")"

echo "--- a ticket a person owns is skipped, and stays queued ---"
: > "$SPAWNS"
fix_issue 201 OPEN "status:needs-human,project:widgets"
q add 201 --programme widgets >/dev/null
out=$(q drain --programme widgets)
want "nothing spawned"            "0" "$(grep -c . "$SPAWNS")"
want_in "and it says why"         '#201 status:needs-human — skip' "$out"
want_in "it is still queued"      '#201' "$(q list)"

echo "--- clear ---"
q clear >/dev/null
want_in "empty" 'the queue is empty' "$(q list)"

echo "--- refusals ---"
if q add >/dev/null 2>&1; then bad "add with no ticket must refuse"; else ok "add with no ticket refuses"; fi
if q add abc >/dev/null 2>&1; then bad "a non-number must refuse"; else ok "a non-number refuses"; fi
if q add 101 --brief /no/such/file >/dev/null 2>&1; then bad "a missing brief must refuse"; else ok "a missing brief refuses"; fi

exit $FAILED
