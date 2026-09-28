#!/usr/bin/env bash
# claim-liveness.test.sh — the second liveness answer, and the one the reconciler
# was missing when it released #10867 out from under a run that was still working it.
#
# The claim carries a pid. That is the right question for an agent session and the
# wrong one for the step-runner: a step is a process, so between two invocations
# there is no process at all and the pid on the claim names one that exited at the
# end of the last step. The driver's run record is what says otherwise.
#
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/claim-liveness.sh" || exit 1

FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
FAILED=0
ok()   { printf 'OK       %s\n' "$1"; }
bad()  { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }

record() { # <ticket> <iso-stamp>
  mkdir -p "$FIX/driver/$1"
  jq -n --arg t "$1" --arg at "$2" '{ticket:$t, done:["start"], updated_at:$at}' \
    > "$FIX/driver/$1/state.json"
}
stamp() { # <seconds ago>
  date -u -r "$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ
}
verdict() { claim_run_fresh "$1" "$FIX" "${2:-4}" && echo live || echo gone; }

echo "--- a run that touched its record a minute ago is working ---"
record 10867 "$(stamp 60)"
want "a fresh record is a live run" "live" "$(verdict 10867)"

echo "--- and one that has not been touched in a day is not ---"
record 10868 "$(stamp 90000)"
want "a day-old record is not a live run" "gone" "$(verdict 10868)"

echo "--- the window is the window ---"
record 10869 "$(stamp 18000)"   # 5 hours
want "five hours is outside the default four" "gone" "$(verdict 10869)"
want "and inside a six-hour window"           "live" "$(verdict 10869 6)"

echo "--- every way of not knowing is a 'no', never a 'yes' ---"
# The direction matters. Failing open here calls a dead run live for ever, and the
# ticket is then never reclaimable by anyone.
want "a ticket with no record at all"      "gone" "$(verdict 99999)"
mkdir -p "$FIX/driver/10870"; printf '{}\n' > "$FIX/driver/10870/state.json"
want "a record with no updated_at"         "gone" "$(verdict 10870)"
record 10871 "not-a-date"
want "a stamp neither date dialect reads"  "gone" "$(verdict 10871)"
record 10872 "$(stamp 60)"
want "a window that is not a number"       "gone" "$(verdict 10872 "4h")"
want "and no state dir at all"             "gone" "$(claim_run_fresh 10872 "" 4 && echo live || echo gone)"

echo "--- the reconciler reads it where a dead pid used to end the matter ---"
# Not a replica of the check: the line in the reconciler itself.
R="$(cd "$(dirname "$0")" && pwd)/reconcile-claims.sh"
grep -q 'claim_run_fresh "$n" "$STATE_DIR" "$STALE_HOURS"' "$R" \
  && ok "reconcile-claims.sh asks it before releasing" \
  || bad "reconcile-claims.sh does not call claim_run_fresh — the release path is unchanged"
# And it is asked AFTER the pid is found dead, not instead of it: a live pid must
# still be the cheap answer.
awk '/holder_alive "\$host" "\$pid"/ {p=NR} /claim_run_fresh/ {c=NR} END {exit !(p && c && c > p)}' "$R" \
  && ok "and only once the pid is gone" \
  || bad "the run check does not sit after the pid check"

exit $FAILED
