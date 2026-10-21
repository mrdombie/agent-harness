#!/usr/bin/env bash
# branch-ticket.test.sh — every branch shape a run uses names its ticket, the jq and
# shell forms agree, and no script reads a ticket out of a branch by itself.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
. "$HERE/branch-ticket.sh"
BRANCH_PREFIX="tkt-"

# <branch> <ticket, or - for none>
CASES='tkt-42/slug 42
tkt-42 42
tkt-42-slug 42
42/slug 42
fix/42-slug 42
feat/42-slug 42
tkt-4/x 4
main -
develop -
tkt-/x -
42-slug -
release/2026.10 -
dependabot/npm/x -'

while read -r b t; do
  [ "$t" = - ] && t=""
  want "shell: $b" "$t" "$(branch_ticket "$b")"
  want "jq:    $b" "$t" "$(jq -rn --arg b "$b" --arg pre "$BRANCH_PREFIX" "$BRANCH_TICKET_JQ"'$b | branch_ticket($pre)')"
done <<<"$CASES"

# Anchored: ticket 42 is not ticket 421.
want "jq: 421/slug is not ticket 42" "false" \
  "$(jq -rn --arg pre tkt- "$BRANCH_TICKET_JQ"'"421/slug" | branch_is_ticket($pre; "42")')"
want "jq: an empty ticket matches nothing" "false" \
  "$(jq -rn --arg pre tkt- "$BRANCH_TICKET_JQ"'"main" | branch_is_ticket($pre; "")')"

# A prefix is literal, never a pattern: a dot in it matches only a dot.
BRANCH_PREFIX="a.b-"
want "shell: a literal prefix" "7" "$(branch_ticket a.b-7/x)"
want "shell: a prefix dot is not a wildcard" "" "$(branch_ticket axb-7x)"

# THE GUARD. A script that reads a ticket from a branch on its own knows only the
# shapes its author remembered — the reconciler knew two of three and released live
# work. Every reader goes through branch-ticket.sh.
hits=$(grep -nE 'ltrimstr\(\$pre\)|"\^\(?" \+ \$pre|startswith\(\$pre\)|index\(\$0, p\) == 1|\^sh-' \
  "$HERE"/*.sh "$HERE"/../swarm/*.sh 2>/dev/null | grep -v '/branch-ticket\.sh:' | grep -v '\.test\.sh:')
want "no script matches a branch to a ticket by hand" "" "$hits"

suite_end "$FAILED"
