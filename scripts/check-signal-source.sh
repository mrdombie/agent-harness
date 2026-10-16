#!/usr/bin/env bash
# check-signal-source.sh — a signal is read from its source, never from text that
# quotes it. A builder's log holds the CLI's own limit and error signals AND every
# CI log, file and reply it read, so a phrase matched anywhere in it matches the
# quotes too. Each such read lives in one marked reader per source:
#
#   swarm/swarm-env.sh         builder logs (claim-*.log), as CLI events
#   swarm/live-view/server.mjs the live view's run summaries, as CLI result events
#   hooks/usage-limit.sh       the StopFailure payload
#
# This fails on a limit or error phrase matched in any other script, on a reader
# marker in any other file, and on a listed reader whose markers are gone.
#
#   check-signal-source.sh [root]    default: the kit this script sits in
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
READERS="swarm/swarm-env.sh swarm/live-view/server.mjs hooks/usage-limit.sh"
SELF_REL="scripts/check-signal-source.sh"
# The CLI's own wording for a limit or a service error, and its event fields.
PHRASES='hit your|"status":"rejected"|rate_limit_event|usage_limit_reached|resetsAt|API Error|Connection refused|ECONNRESET|ETIMEDOUT|[Oo]verloaded|socket hang up|503 Service|HTTP 429'

fail=0
files=$(cd "$ROOT" && find . \( -name .git -o -name node_modules -o -path ./reference -o -name tests -o -name fixtures \) -prune -o \
          -type f \( -name '*.sh' -o -name '*.mjs' -o -name '*.js' -o -name '*.py' -o -name '*.jq' -o -name build-ticket \) -print \
        | sed 's|^\./||' | grep -v '\.test\.sh$' | sort)

for f in $files; do
  [ "$f" = "$SELF_REL" ] && continue
  listed=0; case " $READERS " in *" $f "*) listed=1 ;; esac
  out=$(awk -v phr="$PHRASES" -v listed="$listed" -v f="$f" '
    /cli-signal reader: begin/ { if (!listed) { print f ":" NR ": a reader marker outside the listed readers"; } inr = 1; seen = 1; next }
    /cli-signal reader: end/   { inr = 0; next }
    /^[[:space:]]*(#|\/\/)/    { next }
    !inr && $0 ~ phr           { print f ":" NR ": " substr($0, 1, 140) }
    END { if (listed && !seen) print f ": a listed reader with no cli-signal reader markers" }' "$ROOT/$f")
  [ -n "$out" ] && { printf '%s\n' "$out"; fail=1; }
done

if [ "$fail" = 1 ]; then
  echo "check-signal-source: a limit or error phrase is matched outside the CLI-signal readers above." >&2
  echo "  Read the signal from its source — a reader's events or flags — not from text that may quote it." >&2
fi
exit $fail
