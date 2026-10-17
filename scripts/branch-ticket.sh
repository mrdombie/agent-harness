#!/usr/bin/env bash
# branch-ticket.sh — which ticket a branch belongs to. The one definition; source it.
#
# A run names its branch in any of three shapes, and every one is that ticket's work:
#   <prefix><n>…      the configured branchPrefix, e.g. tkt-42/slug
#   <n>/…             the bare number, e.g. 42/slug
#   <word>/<n>-…      an older shape, e.g. fix/42-slug
# A reader that knows fewer shapes sees live work as abandoned: it releases a ticket
# whose pull request is open, or never sends a red one to be healed.
#
#   branch_ticket <branch>           prints the ticket number, or nothing
#   branch_tickets                   stdin: one branch a line; prints "<n>\t<branch>"
#   jq -r --arg pre "$BRANCH_PREFIX" "$BRANCH_TICKET_JQ"' .headRefName | branch_ticket($pre)'
# All read $BRANCH_PREFIX; the jq form takes it as $pre.

BRANCH_TICKET_JQ='
def branch_ticket($pre):
  if ($pre != "" and startswith($pre) and (ltrimstr($pre) | test("^[0-9]+([^0-9]|$)")))
    then ltrimstr($pre) | capture("^(?<n>[0-9]+)").n
  elif test("^[0-9]+/") then capture("^(?<n>[0-9]+)/").n
  elif test("^[a-z]+/[0-9]+-") then capture("^[a-z]+/(?<n>[0-9]+)-").n
  else "" end;
def branch_is_ticket($pre; $t): $t != "" and branch_ticket($pre) == $t;
'

# Same rules as the jq form; branch-ticket.test.sh holds the two to one table.
branch_tickets() {
  awk -v p="${BRANCH_PREFIX:-}" '
    {
      b = $0; n = ""
      if (p != "" && index(b, p) == 1) {
        s = substr(b, length(p) + 1)
        if (match(s, /^[0-9]+/)) n = substr(s, 1, RLENGTH)
      }
      if (n == "" && match(b, /^[0-9]+\//)) n = substr(b, 1, RLENGTH - 1)
      if (n == "" && match(b, /^[a-z]+\/[0-9]+-/)) { s = substr(b, index(b, "/") + 1); match(s, /^[0-9]+/); n = substr(s, 1, RLENGTH) }
      if (n != "") print n "\t" b
    }'
}

branch_ticket() { printf '%s\n' "$1" | branch_tickets | cut -f1; }
