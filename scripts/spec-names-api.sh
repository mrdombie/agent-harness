#!/usr/bin/env bash
# spec-names-api.sh < ticket-body — exit 0 when the ticket's API contract names
# API work still to do, 1 when it names none.
#
# Reads ONLY the "## Backend contract" / "## API contract" section. The rest of a
# ticket names source paths in repro steps, checklists and test commands, and
# none of that says an API is missing. Inside the section a line counts when:
#   - it says NET-NEW (and not "NET-NEW: none"), whether or not it names a route —
#     a new read with no URL yet is still work a UI-only PR would orphan;
#   - or it names a route (/api/..., an app/api/ route file) that is not marked
#     EXISTS — and "EXISTS — extended/changed" is a change, so it counts.
# Not the heading itself: /agent-harness:claim requires it on every screen ticket,
# including the ones whose contract is "None". Measured against 400 tickets on the
# origin project (review of this script, 2026-10-02): 130 counted, and every
# sampled one dropped had a contract saying no endpoint or only existing ones.
ROUTE='(^|[^A-Za-z0-9_])/api/|app/api/'
in=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '## Backend contract'*|'## API contract'*) in=1; continue ;;
    '## '*) in=0 ;;
  esac
  [ "$in" = 1 ] || continue
  if printf '%s\n' "$line" | grep -qiE 'net-new' \
     && ! printf '%s\n' "$line" | grep -qiE 'net-new[^|]*(\*\*)?[:|]?[ *|]*(none|unknown)|no net-new|not net-new|nothing net-new'; then
    exit 0
  fi
  printf '%s\n' "$line" | grep -qE "$ROUTE" || continue
  # EXISTS is skipped unless the same line says the route changes. Negations
  # ("unchanged", "no signature change", "do not modify") are not changes: a
  # plain substring match counted 24 of them on the origin project's tickets.
  if printf '%s\n' "$line" | grep -qiE '(^|[^A-Za-z])exists([^A-Za-z]|$)' \
     && ! { printf '%s\n' "$line" | grep -iE 'extend|chang|modif|new field|new param' \
            | grep -viqE 'unchang|no [a-z ]*chang|not? (be )?(chang|modif)|do not modif|without chang|shape unchang'; }; then
    continue
  fi
  exit 0
done
exit 1
