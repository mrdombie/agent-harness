#!/usr/bin/env bash
# coordinator-usage-window.test.sh — a usage reading "only rises" inside ONE window,
# and a window is named by its reset. On 2026-10-22 the plan account was switched: the
# new account read seven_day 0% (one reset), the old account's logs and the other
# host's heartbeat still read 95-97% (a reset an hour later), and the pacer kept the
# highest reading near the latest reset, so every build held until 27 Oct. Now the
# newest observed reading names the window; a reading with another reset is dropped.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
FAILED=0
KIT="$HERE/.."
C="$STATE/coordinator"
NOWE=$(date +%s)
A=$(( NOWE + 400000 ))        # the old account's week resets here
B=$(( A - 3600 ))             # the new account's, an hour earlier
FIVE=$(( NOWE + 14000 ))
unset SWARM_USAGE_STEP_HOLD COORDINATOR_PACE_BURN

# <log> <7d use> <7d reset> <observed epoch> — one builder log, its mtime the observation.
log7() {
  jq -nc --argjson u "$2" --argjson r "$3" --argjson f "$FIVE" \
    '{type:"rate_limit_event", rate_limit_info:{status:"allowed",
      unifiedWindows:{five_hour:{utilization:0.02, resetsAt:$f}, seven_day:{utilization:$u, resetsAt:$r}}}}' > "$STATE/logs/$1"
  python3 -c 'import os,sys; os.utime(sys.argv[1], (int(sys.argv[2]),) * 2)' "$STATE/logs/$1" "$4"
}
clean() { rm -rf "$C" "$STATE/logs"/* "$STATE/driver"; mkdir -p "$C"; }
# fleet <host> <7d use> <7d reset> [observed epoch] — a heartbeat in fleet.json; no epoch = an older harness's.
fleet() {
  jq -nc --arg h "$1" --argjson u "$2" --argjson r "$3" --arg a "${4:-}" --argjson t "$NOWE" \
    '{hosts:[{host:$h, tick:$t, usage:{seven_day:({u:$u, reset:$r} + (if $a == "" then {} else {at:($a|tonumber)} end))}}]}' > "$C/fleet.json"
}
fresh()    { ( export SWARM_NOW="$NOWE"; . "$1/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9; swarm_usage_freshest seven_day ); }
stephold() { ( export SWARM_NOW="$NOWE"; . "$1/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9; swarm_usage_step_hold ); }
pace()     { ( export SWARM_NOW="$NOWE" COORDINATOR_HOST=here; . "$1/scripts/coordinator-env.sh" >/dev/null 2>&1 || exit 9
               . "$1/scripts/coordinator-sheet.sh" >/dev/null 2>&1 || exit 9; coord_pace 0 "" here >/dev/null ); }

# The cases, run against a kit; each prints "ok <name>" or "bad <name>: <got>".
cases() { # <kit>
  local k="$1" got
  clean; log7 claim-1-old.log 0.95 "$A" $(( NOWE - 3600 )); log7 claim-2-new.log 0.00 "$B" $(( NOWE - 600 ))
  got=$(fresh "$k"); [ "$got" = "0"$'\t'"$B" ] && echo "ok switch-newest-wins" || echo "bad switch-newest-wins: $got"
  got=$(stephold "$k"); [ -z "$got" ] && echo "ok switch-no-hold" || echo "bad switch-no-hold: $got"

  clean; log7 claim-1-old.log 0.95 "$A" $(( NOWE - 3600 )); log7 claim-2-new.log 0.90 "$A" $(( NOWE - 600 ))
  got=$(fresh "$k"); [ "$got" = "0.95"$'\t'"$A" ] && echo "ok same-window-only-rises" || echo "bad same-window-only-rises: $got"

  clean; log7 claim-2-new.log 0.00 "$B" $(( NOWE - 600 )); fleet yomato 0.95 "$A"
  got=$(stephold "$k"); [ -z "$got" ] && echo "ok old-heartbeat-no-hold" || echo "bad old-heartbeat-no-hold: $got"
  clean; log7 claim-2-new.log 0.00 "$B" $(( NOWE - 600 )); fleet yomato 0.97 "$A" $(( NOWE - 1200 ))
  got=$(stephold "$k"); [ -z "$got" ] && echo "ok older-heartbeat-no-hold" || echo "bad older-heartbeat-no-hold: $got"
  clean; log7 claim-2-new.log 0.00 "$B" $(( NOWE - 600 )); fleet yomato 0.97 "$A" $(( NOWE - 60 ))
  got=$(fresh "$k"); [ "$got" = "0.97"$'\t'"$A" ] && echo "ok newer-heartbeat-wins" || echo "bad newer-heartbeat-wins: $got"

  # This host's own heartbeat echoes pace.json back: it must keep the time it was READ.
  clean; log7 claim-1-old.log 0.95 "$A" $(( NOWE - 3600 ))
  pace "$k"
  got=$(jq -r '.usage.seven_day.at // "none"' "$C/pace.json" 2>/dev/null)
  [ "$got" = "$(( NOWE - 3600 ))" ] && echo "ok pace-keeps-observed" || echo "bad pace-keeps-observed: $got"
  jq -c '{hosts:[{host:"here", tick:.at, usage:.usage}]}' "$C/pace.json" > "$C/fleet.json" 2>/dev/null
  log7 claim-2-new.log 0.00 "$B" $(( NOWE - 600 ))
  got=$(stephold "$k"); [ -z "$got" ] && echo "ok echo-no-hold" || echo "bad echo-no-hold: $got"
}

echo "--- the fixed kit ---"
out=$(cases "$KIT")
printf '%s\n' "$out" | sed 's/^/  /'
n=$(printf '%s\n' "$out" | grep -c '^bad')
[ "$n" = 0 ] && ok "every case passes" || bad "$n case(s) failed"
[ "$(printf '%s\n' "$out" | grep -c '^ok')" = 8 ] && ok "all 8 cases ran" || bad "not all 8 cases ran"

# plant <name> <python edit> — a copy of the kit with one rule removed; the cases must go red.
plant() {
  local P="$FIX/kit-$1"; rm -rf "$P"; mkdir -p "$P"; cp -R "$KIT/swarm" "$KIT/scripts" "$KIT/hooks" "$P/" 2>/dev/null
  [ -d "$KIT/tests" ] && cp -R "$KIT/tests" "$P/"
  python3 - "$P" "$2" <<'PY' || { bad "plant $1 did not land"; return 1; }
import sys
root, which = sys.argv[1], sys.argv[2]
if which == "window":
    p = root + "/swarm/swarm-env.sh"; s = open(p).read()
    old = "              if (n == 1 || A[n] > na || (A[n] == na && R[n] > nr)) { na = A[n]; nr = R[n] }\n"
    if old not in s: sys.exit(1)
    s = s.replace(old, "              if (R[n] > nr) nr = R[n]\n")
elif which == "observed":
    p = root + "/scripts/coordinator-env.sh"; s = open(p).read()
    old = "reset: ($r7 | tonumber), at: ($a7 | tonumber)}"
    if old not in s: sys.exit(1)
    s = s.replace(old, "reset: ($r7 | tonumber)}")
open(p, "w").write(s)
PY
  printf '%s' "$P"
}
echo "--- planted: the window named by the latest reset, not the newest reading ---"
P=$(plant window window) && {
  grep -q 'A\[n\] > na' "$P/swarm/swarm-env.sh" && bad "plant: the rule is still in the copy"
  out=$(cases "$P"); printf '%s\n' "$out" | sed 's/^/  /'
  printf '%s\n' "$out" | grep -q '^bad switch-newest-wins' && ok "planted → the switch case goes red" || bad "planted → the switch case stayed green"
  printf '%s\n' "$out" | grep -q '^bad old-heartbeat-no-hold' && ok "planted → the heartbeat case goes red" || bad "planted → the heartbeat case stayed green"
}
echo "--- planted: pace.json drops when the reading was observed ---"
P=$(plant observed observed) && {
  grep -q 'at: (\$a7' "$P/scripts/coordinator-env.sh" && bad "plant: the field is still in the copy"
  out=$(cases "$P"); printf '%s\n' "$out" | sed 's/^/  /'
  printf '%s\n' "$out" | grep -q '^bad pace-keeps-observed' && ok "planted → pace.json loses the observed time → red" || bad "planted → stayed green"
}

echo "--- held with no fresh reading, the host reads the account again (swarm_usage_probe) ---"
# 2026-10-24: a login change left both hosts held on the old account's 95% week; held builders log nothing.
clean; log7 claim-old.log 0.95 "$A" $(( NOWE - 3600 ))
cat > "$FIX/probe" <<SH
#!/usr/bin/env bash
echo "\$PWD" >> "$FIX/probe.log"
jq -nc --argjson r "$B" --argjson f "$FIVE" '{type:"rate_limit_event", rate_limit_info:{status:"allowed",
  unifiedWindows:{five_hour:{utilization:0.01, resetsAt:\$f}, seven_day:{utilization:0, resetsAt:\$r}}}}'
SH
chmod +x "$FIX/probe"; : > "$FIX/probe.log"
probe() { ( export SWARM_NOW="$NOWE" SWARM_USAGE_PROBE_CMD="$FIX/probe"; . "$KIT/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9; swarm_usage_probe ) && echo probed || echo skipped; }
want_in "held on the old week before"           'seven_day	95' "$(stephold "$KIT")"
want "an hour with no reading: it probes"        "probed" "$(probe)"
want "  one call"                                "1" "$(grep -c . "$FIX/probe.log")"
want "  the new reading clears the hold"         "" "$(stephold "$KIT")"
want "a second time within 15 min: no call"      "skipped 1" "$(probe) $(grep -c . "$FIX/probe.log")"
clean; log7 claim-new.log 0.95 "$A" $(( NOWE - 60 )); : > "$FIX/probe.log"
want "a reading a minute old: no call"           "skipped 0" "$(probe) $(grep -c . "$FIX/probe.log")"

suite_end "$FAILED"
