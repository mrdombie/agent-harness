#!/usr/bin/env bash
# spec-names-api.sh < ticket-body — exit 0 when the body names an API route the
# work still NEEDS, 1 when it names none.
#
# Not the "## Backend contract" heading: /agent-harness:claim requires that heading on
# every screen ticket, including the ones whose contract is "None". Not any route
# either: a contract that lists routes marked EXISTS consumes only what is
# already there, and a UI-only PR is exactly right for it. A line counts when it
# names a route (/api/..., a Next.js app/api/ path, an apps/api/ source path) and
# is not marked EXISTS, unless the same line also says NET-NEW.
ROUTE='(^|[^A-Za-z0-9_])(/api/|apps/api/)|app/api/'
while IFS= read -r line || [ -n "$line" ]; do
  printf '%s\n' "$line" | grep -qE "$ROUTE" || continue
  if printf '%s\n' "$line" | grep -qiE 'net-new'; then exit 0; fi
  printf '%s\n' "$line" | grep -qiE '(^|[^A-Za-z])exists([^A-Za-z]|$)' && continue
  exit 0
done
exit 1
