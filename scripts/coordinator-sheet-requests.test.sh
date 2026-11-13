#!/usr/bin/env bash
# coordinator-sheet-requests.test.sh — the fleet sheet says how much of GitHub's hourly
# allowance is used. One token serves every machine and session: on 2026-11-11 it ran
# at 4,920 REST requests an hour of 5,000 and nobody could see it until every tool went
# blind. The line is built from the readings the machines' heartbeats already carry.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
unset COORDINATOR_SHADOW COORDINATOR_SHEET_OWNER COORDINATOR_HOST SWARM_NOW

NOWE=1794419000
render() { ( . "$HERE/coordinator-env.sh" >/dev/null 2>&1; . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1
             coord_sheet_render "$1" "$NOWE" ); }
gh1() { jq -nc --arg r "$1" --argjson rem "$2" --argjson reset "$3" '{resource: $r, remaining: $rem, limit: 5000, reset: $reset}'; }  # <resource> <remaining> <reset>
host() { # <host> [reading…]
  local h="$1"; shift
  printf '%s\n' "$@" | jq -sc --arg h "$h" '{host: $h, version: "0.7.1", freeGb: 100, builds: 1, tick: 1794418990, behind: false} + (if length == 0 then {} else {gh: .} end)'; }
sheet() { printf '%s\n' "$@" | jq -sc '{order: [], building: [], fleet: .}'; }  # <host json…>
line() { printf '%s\n' "$1" | grep '^GitHub requests used this hour' || true; }
R=$(( NOWE + 1800 ))

echo "--- one machine's reading ---"
mac=$(host mac "$(gh1 core 80 "$R")" "$(gh1 graphql 4208 "$R")")
out=$(render "$(sheet "$mac")")
want "the sheet says what is used of each allowance" \
  "GitHub requests used this hour, on the token every machine shares: REST 4920 of 5000, GraphQL 792 of 5000" "$(line "$out")"
want_in "under the machines it lists"                 'mac · harness 0\.7\.1' "$out"

echo "--- two machines on the one token: the most spent reading of the newest window ---"
mac=$(host mac "$(gh1 core 3000 "$R")"); box=$(host box "$(gh1 core 2400 "$R")")
out=$(render "$(sheet "$mac" "$box")")
want "the lower remaining is the newer truth"         "GitHub requests used this hour, on the token every machine shares: REST 2600 of 5000" "$(line "$out")"
mac=$(host mac "$(gh1 core 4900 $(( R + 3600 )))"); box=$(host box "$(gh1 core 10 "$R")")
out=$(render "$(sheet "$mac" "$box")")
want "a reading from the window before is not this hour's" "GitHub requests used this hour, on the token every machine shares: REST 100 of 5000" "$(line "$out")"

echo "--- nothing to say is no line, never a made-up zero ---"
mac=$(printf '' | jq -nc '{host: "mac", version: "0.7.1", freeGb: 100, builds: 1, tick: 1794418990, behind: false}')
out=$(render "$(sheet "$mac")")
want "a machine with no reading"                      "" "$(line "$out")"
want_in "is still listed"                             'mac · harness 0\.7\.1' "$out"
mac=$(host mac "$(gh1 core 80 $(( NOWE - 60 )))")
out=$(render "$(sheet "$mac")")
want "a window already over"                          "" "$(line "$out")"
want_in "and the machines are still listed"           'mac · harness 0\.7\.1' "$out"

suite_end "$FAILED"
