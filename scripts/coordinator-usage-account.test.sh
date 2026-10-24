#!/usr/bin/env bash
# coordinator-usage-account.test.sh — a usage reading counts only under the account it was
# read under. On 2026-10-24 the plan login changed and both hosts held on the old account's
# 95% week. Now a log observed before the account changed is dropped, and a heartbeat or
# published reading from another account never paces this host.
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
A=$(( NOWE + 400000 ))
FIVE=$(( NOWE + 14000 ))
unset SWARM_USAGE_STEP_HOLD COORDINATOR_PACE_BURN SWARM_ACCOUNT
# The probe call is stubbed: nothing here may reach the model.
export SWARM_USAGE_PROBE_CMD=false
export SWARM_ACCOUNT_FILE="$C/account"

log7() { # <log> <7d use> <observed epoch>
  jq -nc --argjson u "$2" --argjson r "$A" --argjson f "$FIVE" \
    '{type:"rate_limit_event", rate_limit_info:{status:"allowed",
      unifiedWindows:{five_hour:{utilization:0.02, resetsAt:$f}, seven_day:{utilization:$u, resetsAt:$r}}}}' > "$STATE/logs/$1"
  python3 -c 'import os,sys; os.utime(sys.argv[1], (int(sys.argv[2]),) * 2)' "$STATE/logs/$1" "$3"
}
clean() { rm -rf "$C" "$STATE/logs"/* "$STATE/driver"; mkdir -p "$C"; }
# known <account> <since> — this host last read <account>, which took over at <since>.
known() { printf '%s\t%s\t%s\n' "$1" "$2" "$2" > "$SWARM_ACCOUNT_FILE"; }
host() { # <host> <account> <7d use> — another host's heartbeat, read a minute ago
  jq -nc --arg h "$1" --arg a "$2" --argjson u "$3" --argjson r "$A" --argjson t "$(( NOWE - 60 ))" \
    '{host:$h, account:$a, tick:$t, usage:{seven_day:{u:$u, reset:$r, at:$t}}}'
}
stephold() { ( export SWARM_NOW="$NOWE" SWARM_ACCOUNT="$2"; . "$1/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9; swarm_usage_step_hold ); }
pace() {     ( export SWARM_NOW="$NOWE" SWARM_ACCOUNT="$2" COORDINATOR_HOST=here SHEET_FLEET="$3"
               . "$1/scripts/coordinator-env.sh" >/dev/null 2>&1 || exit 9
               . "$1/scripts/coordinator-sheet.sh" >/dev/null 2>&1 || exit 9; coord_pace 0 "" here >/dev/null ); }
beat() {     ( export SWARM_NOW="$NOWE" SWARM_ACCOUNT="$2" COORDINATOR_HOST=here
               . "$1/scripts/coordinator-env.sh" >/dev/null 2>&1 || exit 9
               . "$1/scripts/coordinator-sheet.sh" >/dev/null 2>&1 || exit 9; coord_heartbeat 0 100 6 ); }

cases() { # <kit>
  local k="$1" got
  # The old account's 95% week, then a login on the new account: no hold.
  clean; known org-old $(( NOWE - 86400 )); log7 claim-1-old.log 0.95 $(( NOWE - 3600 ))
  got=$(stephold "$k" org-new); [ -z "$got" ] && echo "ok new-login-no-hold" || echo "bad new-login-no-hold: $got"
  got=$(awk -F'\t' '{ print $1 "/" ($2 == '"$NOWE"') }' "$SWARM_ACCOUNT_FILE")
  [ "$got" = "org-new/1" ] && echo "ok change-recorded" || echo "bad change-recorded: $got"
  # A reading after the change counts (the probe's log, say).
  log7 claim-2-new.log 0.96 $(( NOWE + 0 ))
  got=$(stephold "$k" org-new); [ -n "$got" ] && echo "ok new-reading-counts" || echo "bad new-reading-counts: none"
  # Same account all along: the 95% still holds.
  clean; known org-old $(( NOWE - 86400 )); log7 claim-1-old.log 0.95 $(( NOWE - 3600 ))
  got=$(stephold "$k" org-old); [ -n "$got" ] && echo "ok same-account-holds" || echo "bad same-account-holds: none"

  # Another host on another account is ignored; on this account it counts.
  clean; known org-new $(( NOWE - 86400 ))
  jq -nc --argjson h "$(host yomato org-other 0.97)" '{hosts:[$h]}' > "$C/fleet.json"
  got=$(stephold "$k" org-new); [ -z "$got" ] && echo "ok other-account-host-ignored" || echo "bad other-account-host-ignored: $got"
  jq -nc --argjson h "$(host yomato org-new 0.97)" '{hosts:[$h]}' > "$C/fleet.json"
  got=$(stephold "$k" org-new); [ -n "$got" ] && echo "ok same-account-host-counts" || echo "bad same-account-host-counts: none"

  # The pacer: another account's heartbeat never reaches pace.json, which names its account.
  clean; known org-new $(( NOWE - 86400 )); log7 claim-3-here.log 0.10 $(( NOWE - 120 ))
  pace "$k" org-new "[$(host yomato org-other 0.97)]"
  got=$(jq -r '"\(.account)/\(.usage.seven_day.u // "none")"' "$C/pace.json" 2>/dev/null)
  [ "$got" = "org-new/0.1" ] && echo "ok pace-ignores-other-account" || echo "bad pace-ignores-other-account: $got"
  got=$(beat "$k" org-new | jq -r '.account // "none"' 2>/dev/null)
  [ "$got" = "org-new" ] && echo "ok heartbeat-names-account" || echo "bad heartbeat-names-account: $got"
}

echo "--- the fixed kit ---"
out=$(cases "$KIT")
printf '%s\n' "$out" | sed 's/^/  /'
n=$(printf '%s\n' "$out" | grep -c '^bad')
[ "$n" = 0 ] && ok "every case passes" || bad "$n case(s) failed"
[ "$(printf '%s\n' "$out" | grep -c '^ok')" = 8 ] && ok "all 8 cases ran" || bad "not all 8 cases ran"

# plant <name> — a copy of the kit with one rule removed; the cases must go red.
plant() {
  local P="$FIX/kit-$1"; rm -rf "$P"; mkdir -p "$P"; cp -R "$KIT/swarm" "$KIT/scripts" "$KIT/hooks" "$KIT/driver" "$KIT/tests" "$KIT/.claude-plugin" "$P/" 2>/dev/null
  python3 - "$P" "$1" <<'PY' || { bad "plant $1 did not land"; return 1; }
import sys
root, which = sys.argv[1], sys.argv[2]
p = root + "/swarm/swarm-env.sh"; s = open(p).read()
if which == "since":
    old = '              [ "$m" -ge "$since" ] || continue\n'
    if s.count(old) != 1: sys.exit(1)
    s = s.replace(old, "")
elif which == "hosts":
    for old, new in [("select((.account // \"\") == $a) | ", ""), ("select(type == \"object\" and (.account // \"\") == $a and ", "select(type == \"object\" and ")]:
        if s.count(old) != 1: sys.exit(1)
        s = s.replace(old, new)
open(p, "w").write(s)
PY
  printf '%s' "$P"
}
echo "--- planted: a log from before the account changed still counts ---"
P=$(plant since) && {
  grep -q '"\$m" -ge "\$since"' "$P/swarm/swarm-env.sh" && bad "plant: the rule is still in the copy"
  out=$(cases "$P"); printf '%s\n' "$out" | sed 's/^/  /'
  printf '%s\n' "$out" | grep -q '^bad new-login-no-hold' && ok "planted → the old account's 95% holds again → red" || bad "planted → stayed green"
}
echo "--- planted: readings from any account count ---"
P=$(plant hosts) && {
  grep -q '(.account // "") == \$a' "$P/swarm/swarm-env.sh" && bad "plant: the rule is still in the copy"
  out=$(cases "$P"); printf '%s\n' "$out" | sed 's/^/  /'
  printf '%s\n' "$out" | grep -q '^bad other-account-host-ignored' && ok "planted → another account's host holds this one → red" || bad "planted → stayed green"
  printf '%s\n' "$out" | grep -q '^bad pace-ignores-other-account' && ok "planted → pace.json takes another account's reading → red" || bad "planted → pacer stayed green"
}

suite_end "$FAILED"
