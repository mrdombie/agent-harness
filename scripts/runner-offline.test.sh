#!/usr/bin/env bash
# runner-offline.test.sh — a CI lane whose every runner is offline past the limit is
# named once per outage; a lane with one runner online, an unwatched lane, or an
# unreadable list names nothing; a lane back online says so once.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
S="$HERE/runner-offline.sh"
C="$STATE/coordinator"; mkdir -p "$C"
export COORDINATOR_RUNNER_LANES="linux-pr develop" COORDINATOR_RUNNER_OFFLINE_MIN=15
runners() {  # name:status:label,label ...
  printf '{"runners":['; local first=1 r n s l
  for r in "$@"; do
    IFS=: read -r n s l <<<"$r"
    [ $first = 1 ] || printf ','; first=0
    printf '{"name":"%s","status":"%s","labels":[%s]}' "$n" "$s" \
      "$(printf '%s' "$l" | tr ',' '\n' | sed 's/.*/{"name":"&"}/' | paste -sd, -)"
  done
  printf ']}'
}
run() { COORDINATOR_NOW="$1" bash "$S" "$FIX/r.json"; }
T0=1763300000

echo "--- every runner on a lane offline: named only once the limit has passed ---"
runners "a1:offline:linux-pr,develop" "a2:offline:linux-pr" "m1:online:mac" > "$FIX/r.json"
want "under the limit says nothing" "" "$(run $T0)"
out=$(run $((T0 + 16*60)))
want_in "past the limit names the lane" $'^down\tlinux-pr\trunners-offline:linux-pr:'"$T0"$'\t' "$(printf '%s\n' "$out" | grep linux-pr)"
want_in "the message names the runners" 'a1,a2' "$out"
want "the develop lane is named too" "1" "$(printf '%s\n' "$out" | grep -c $'^down\tdevelop')"
again=$(run $((T0 + 40*60)))
want "the key stays the same for one outage" "runners-offline:linux-pr:$T0" "$(printf '%s\n' "$again" | awk -F'\t' '$2=="linux-pr"{print $3}')"

echo "--- one runner back online: the lane is back, once, and the next outage is a new key ---"
runners "a1:online:linux-pr,develop" "a2:offline:linux-pr" > "$FIX/r.json"
want "back is said for each lane" $'back\tlinux-pr\nback\tdevelop' "$(run $((T0 + 41*60)))"
want "and only once" "" "$(run $((T0 + 42*60)))"
runners "a1:offline:linux-pr,develop" "a2:offline:linux-pr" > "$FIX/r.json"
run $((T0 + 50*60)) >/dev/null
want_in "a new outage has a new key" "runners-offline:linux-pr:$((T0 + 50*60))" "$(run $((T0 + 70*60)))"

echo "--- a lane nobody watches, a lane with no runners, an unreadable list: nothing ---"
rm -f "$C"/runner-down.*
runners "m1:offline:mac" > "$FIX/r.json"
want "an unwatched lane is never named" "" "$(run $((T0 + 99*60)))"
echo 'not json' > "$FIX/r.json"
want "an unreadable list is not all offline" "" "$(run $((T0 + 99*60)))"
runners "a1:offline:linux-pr" > "$FIX/r.json"
want "no lanes set watches nothing" "" "$(COORDINATOR_RUNNER_LANES='' COORDINATOR_NOW=$((T0+99*60)) bash "$S" "$FIX/r.json")"

suite_end "$FAILED"
