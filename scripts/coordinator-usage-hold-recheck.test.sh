#!/usr/bin/env bash
# coordinator-usage-hold-recheck.test.sh — a usage hold on file is asked again. On 2026-11-11
# a hold written at 04:58Z on a week at 100% stood for 4 hours while the same account read
# 56%, allowed, until a person moved the file: the log listing behind every usage reader was
# `ls -t <glob>`, which past ARG_MAX lists nothing, and nothing ever asked the account again.
# Now the tick makes one probe call at most per probe interval while a hold is on and moves
# the hold aside when the held window reads allowed under the hold's own account; a window
# still rejected, another window's reading, or another account's keeps it. Then the plants:
# delete the tick's re-check, the listing, the probe's precedence or the ceiling test and
# its case goes red.
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
WEEK=$(( NOWE + 2 * 86400 ))        # the week's reset: the wall, and every later reading of it
FIVE=$(( NOWE + 14000 ))
unset SWARM_USAGE_STEP_HOLD COORDINATOR_PACE_BURN SWARM_ACCOUNT SWARM_USAGE_HOLD_FILE SWARM_USAGE_PROBE_MIN
export SWARM_ACCOUNT_FILE="$C/account" SWARM_USAGE_CEILING=0.95
HOLD="$STATE/usage-hold"
PROBES="$FIX/probes.log"

# The stand-in for `claude -p`: counts its calls and prints the event the case wrote.
cat > "$BIN/probe" <<SH
#!/usr/bin/env bash
echo call >> "$PROBES"
cat "$FIX/probe.json" 2>/dev/null
SH
chmod +x "$BIN/probe"
export SWARM_USAGE_PROBE_CMD="$BIN/probe"

clean() { rm -rf "$C" "$STATE/logs"/* "$STATE/logs"/.usage-* "$STATE/driver" "$HOLD"; mkdir -p "$C"; : > "$PROBES"; rm -f "$FIX/probe.json"; }
at() { python3 -c 'import os,sys; os.utime(sys.argv[1], (int(sys.argv[2]),) * 2)' "$1" "$2"; }
known() { printf '%s\t%s\t%s\n' "$1" $(( NOWE - 86400 )) $(( NOWE - 86400 )) > "$SWARM_ACCOUNT_FILE"; }
# hold <account> <window> [age seconds] — the wall, written an hour ago unless told.
hold() { printf '%s\tthe plan'"'"'s usage limit (rate-limit event) (#17613 build)\t%s\t%s\n' "$WEEK" "$1" "$2" > "$HOLD"; at "$HOLD" $(( NOWE - ${3:-3600} )); }
# event <status> <window> <utilization> — one rate_limit_event, the shape measured on 2026-11-11.
event() {
  local reset="$WEEK"; [ "$2" = five_hour ] && reset="$FIVE"
  jq -nc --arg s "$1" --arg w "$2" --argjson u "$3" --argjson r "$reset" \
    '{type:"rate_limit_event", rate_limit_info:{status:$s, resetsAt:$r, rateLimitType:$w,
      unifiedWindows:{($w):{utilization:$u, resetsAt:$r, status:$s}}}}'
}
probe_reads() { event "$@" > "$FIX/probe.json"; }
# steplog <name> <observed epoch> <status> <window> <utilization> — a builder step's log.
steplog() { mkdir -p "$STATE/driver/1/steps"; event "$3" "$4" "$5" > "$STATE/driver/1/steps/$1.log"; at "$STATE/driver/1/steps/$1.log" "$2"; }
env_do() { ( export SWARM_NOW="$NOWE" SWARM_ACCOUNT="$2"; . "$1/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9; shift 2; "$@" ); }
recheck() { env_do "$1" "$2" swarm_usage_hold_recheck; }
held()    { env_do "$1" "$2" swarm_usage_hold 2>/dev/null; }
stephold() { env_do "$1" "$2" swarm_usage_step_hold; }
calls() { grep -c . "$PROBES"; }

cases() { # <kit>
  local k="$1" got
  # allowed: the week that walled at 04:58 reads 56%, allowed, an hour on.
  clean; known org-a; hold org-a seven_day; steplog wall $(( NOWE - 3540 )) rejected seven_day 1
  probe_reads allowed seven_day 0.56
  got=$(recheck "$k" org-a)
  if [ -e "$HOLD" ]; then echo "bad allowed-cleared: the hold is still on file ($got)"
  elif held "$k" org-a >/dev/null; then echo "bad allowed-cleared: still held"
  else echo "ok allowed-cleared"; fi
  [ "$(calls)" = 1 ] && echo "ok allowed-one-call" || echo "bad allowed-one-call: $(calls) calls"
  ls "$STATE/logs" | grep -q '^usage-hold\.stale-org-a-' && echo "ok allowed-moved-aside" || echo "bad allowed-moved-aside: $(ls "$STATE/logs")"
  # rejected: the same call still meets the wall.
  clean; known org-a; hold org-a seven_day; probe_reads rejected seven_day 1
  got=$(recheck "$k" org-a)
  [ -e "$HOLD" ] && held "$k" org-a >/dev/null && echo "ok rejected-held" || echo "bad rejected-held: cleared ($got)"
  printf '%s' "$got" | grep -q 'was re-checked with one probe call and stays — seven_day is still rejected' \
    && echo "ok rejected-says-why" || echo "bad rejected-says-why: $got"
  # within the interval nothing asks again.
  recheck "$k" org-a >/dev/null
  [ "$(calls)" = 1 ] && echo "ok rejected-one-call-per-interval" || echo "bad rejected-one-call-per-interval: $(calls) calls"
  # over the ceiling: allowed, but a run started now would die at the wall.
  clean; known org-a; hold org-a seven_day; probe_reads allowed_warning seven_day 0.97
  recheck "$k" org-a >/dev/null
  [ -e "$HOLD" ] && echo "ok over-ceiling-held" || echo "bad over-ceiling-held: cleared"
  # another window: the hold is on the week, the call reads only the session.
  clean; known org-a; hold org-a seven_day; probe_reads allowed five_hour 0.10
  recheck "$k" org-a >/dev/null
  [ -e "$HOLD" ] && held "$k" org-a >/dev/null && echo "ok other-window-held" || echo "bad other-window-held: cleared"
  # another account's reading: a host on org-b published the week at 10% after the hold.
  clean; known org-a; hold org-a seven_day
  jq -n --argjson r "$WEEK" --argjson t $(( NOWE - 60 )) \
    '{hosts:[{host:"other", account:"org-b", usage:{seven_day:{u:0.10, reset:$r, at:$t}}}]}' > "$C/fleet.json"
  probe_reads rejected seven_day 1
  recheck "$k" org-a >/dev/null
  [ -e "$HOLD" ] && held "$k" org-a >/dev/null && echo "ok other-account-reading-held" || echo "bad other-account-reading-held: cleared"
  # the login unknown: the call could be any account's, so none is made.
  clean; hold org-a seven_day; probe_reads allowed seven_day 0.10
  recheck "$k" "" >/dev/null
  [ -e "$HOLD" ] && [ "$(calls)" = 0 ] && echo "ok account-unknown-no-call" || echo "bad account-unknown-no-call: $(calls) calls, hold $([ -e "$HOLD" ] && echo kept || echo cleared)"
  # a wall hit a minute ago is not asked about yet.
  clean; known org-a; hold org-a seven_day 60; probe_reads allowed seven_day 0.10
  recheck "$k" org-a >/dev/null
  [ -e "$HOLD" ] && [ "$(calls)" = 0 ] && echo "ok young-hold-no-call" || echo "bad young-hold-no-call: $(calls) calls"
  # the fall inside one window: a step read the week at 99% after the hold was written; the
  # probe then reads the same week (same reset) at 56%. The later, exact reading stands.
  clean; known org-a; hold org-a seven_day; steplog warn $(( NOWE - 3000 )) allowed_warning seven_day 0.99
  probe_reads allowed seven_day 0.56
  recheck "$k" org-a >/dev/null
  got=$(stephold "$k" org-a) && echo "bad probe-supersedes-older: step hold $got" || echo "ok probe-supersedes-older"
}
N_CASES=12

echo "--- the fixed kit ---"
out=$(cases "$KIT")
printf '%s\n' "$out" | sed 's/^/  /'
n=$(printf '%s\n' "$out" | grep -c '^bad')
[ "$n" = 0 ] && ok "every case passes" || bad "$n case(s) failed"
want "all $N_CASES cases ran" "$N_CASES" "$(printf '%s\n' "$out" | grep -c '^ok')"

echo "--- the sheet says when the hold was last re-checked ---"
clean; known org-a; hold org-a seven_day; probe_reads rejected seven_day 1
recheck "$KIT" org-a >/dev/null
s=$(SWARM_ACCOUNT=org-a bash "$KIT/swarm/hold-status.sh")
want "held on usage" "usage" "$(jq -r '.kind' <<<"$s")"
want_in "re-checked at an instant" '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T' "$(jq -r '.rechecked' <<<"$s")"
want "with what the call read" "seven_day is still rejected" "$(jq -r '.recheck' <<<"$s")"
grep -q 'h.rechecked ? `Last re-checked' "$KIT/swarm/live-view/index.html" && ok "the banner prints it" || bad "the banner never prints rechecked"
hold org-a seven_day 0    # a new wall, written after that re-check: it was another hold's
s=$(SWARM_ACCOUNT=org-a bash "$KIT/swarm/hold-status.sh")
want "a re-check older than the hold is not shown" "null" "$(jq -r '.rechecked' <<<"$s")"

echo "--- more logs than one command line holds ---"
# 2026-11-11: 13,616 logs. `ls -t <glob>` is not even run past ARG_MAX, and reads as no logs.
# flood — 16,000 old step logs under long names: more bytes of names than ARG_MAX here.
flood() {
  python3 - "$STATE/driver" $(( NOWE - 9000 )) <<'PY'
import os, sys
root, old = sys.argv[1], int(sys.argv[2])
pad = "x" * 150
for d in range(16):
    p = os.path.join(root, "%05d" % d, "steps"); os.makedirs(p)
    for i in range(1000):
        f = os.path.join(p, "build-task-%04d-%s.log" % (i, pad)); open(f, "w").close(); os.utime(f, (old, old))
PY
}
many() { # <kit> — the newest of the flood, by the kit's own listing
  ( export SWARM_NOW="$NOWE" SWARM_ACCOUNT=org-a; . "$1/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9
    swarm_newest_logs 1 "$SWARM_LOGS"/claim-*.log "$STATE/driver"/*/steps/*.log )
}
clean; known org-a
flood
steplog newest $(( NOWE - 60 )) allowed seven_day 0.56
want "the newest of 16,000 is found" "$STATE/driver/1/steps/newest.log" "$(many "$KIT")"
hold org-a seven_day
if held "$KIT" org-a >/dev/null; then bad "a newer reading among 16,000 logs did not clear the hold"; else ok "and its reading clears the hold"; fi

# THE TICK: the only thing that asks is the coordinator, so the call site is what is pinned.
echo "--- the tick ---"
T="$KIT/scripts/coordinator-tick.sh"; Q="$KIT/scripts/coordinator-queue.sh"
printf '#!/usr/bin/env bash\n:\n' > "$BIN/noop"; chmod +x "$BIN/noop"
export COORDINATOR_RECONCILE="$BIN/noop" COORDINATOR_SWEEP="$BIN/noop" COORDINATOR_WORKTREE_SWEEP="$BIN/noop"
export COORDINATOR_JUDGE="$BIN/noop" COORDINATOR_NOTIFY_CMD=true COORDINATOR_HOST=here COORDINATOR_SHEET_OWNER=here
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
export SWARM_FREE_MEM_GB=64 SWARM_IDLE=90 SWARM_CORES=10 COORDINATOR_RAMP_FREE_MEM_GB=1
unset COORDINATOR_SHADOW COORDINATOR_CAP SWARM_NOW
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s"\n' "$SPAWNS" > "$BIN/spawn-live"; chmod +x "$BIN/spawn-live"
tickworld() { # the wall an hour ago, its rejection in a step log, three ready tickets
  clean; rm -rf "$STATE/runs"/*; : > "$SPAWNS"; : > "$FIX/claims.txt"; printf '[]\n' > "$FIX/gh/prs-all.json"
  known org-a; printf 'org-a\n' > "$C/usage.account"; hold org-a seven_day
  steplog wall $(( NOWE - 3540 )) rejected seven_day 1
  local t; for t in 701 702 703; do fix_issue "$t" OPEN "status:ready"; bash "$Q" add "$t" >/dev/null; done
}
tick() { SWARM_ACCOUNT=org-a COORDINATOR_PACE=false SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "${1:-$T}" 2>&1; }
tick_cases() { # <tick script>
  local out
  tickworld; probe_reads allowed seven_day 0.56
  out=$(tick "$1")
  if [ "$(grep -c . "$SPAWNS")" -ge 1 ] && [ ! -e "$HOLD" ]; then echo "ok tick-allowed-starts"
  else echo "bad tick-allowed-starts: $(grep -c . "$SPAWNS") started, hold $([ -e "$HOLD" ] && echo kept || echo cleared): $(grep -E 'spawn:|usage:' <<<"$out" | head -2 | tr '\n' '|')"; fi
  [ "$(calls)" = 1 ] && echo "ok tick-allowed-one-call" || echo "bad tick-allowed-one-call: $(calls) calls"
  tickworld; probe_reads rejected seven_day 1
  out=$(tick "$1"); tick "$1" >/dev/null
  if [ "$(grep -c . "$SPAWNS")" = 0 ] && [ -e "$HOLD" ] && grep -q 'spawn: usage limit — holding until' <<<"$out"; then echo "ok tick-rejected-holds"
  else echo "bad tick-rejected-holds: $(grep -c . "$SPAWNS") started"; fi
  [ "$(calls)" = 1 ] && echo "ok tick-rejected-one-call-in-two-ticks" || echo "bad tick-rejected-one-call-in-two-ticks: $(calls) calls"
}
out=$(tick_cases "$T")
printf '%s\n' "$out" | sed 's/^/  /'
want "the tick's 4 cases pass" "4 0" "$(printf '%s\n' "$out" | grep -c '^ok') $(printf '%s\n' "$out" | grep -c '^bad')"

# plant <name> — a copy of the kit with one rule removed; its case must go red.
plant() {
  local P="$FIX/kit-$1"; rm -rf "$P"; mkdir -p "$P"; cp -R "$KIT/swarm" "$KIT/scripts" "$KIT/hooks" "$KIT/driver" "$KIT/tests" "$KIT/.claude-plugin" "$P/" 2>/dev/null
  python3 - "$P" "$1" <<'PY' || return 1
import sys
root, which = sys.argv[1], sys.argv[2]
p = root + "/swarm/swarm-env.sh"
if which == "tick":
    p = root + "/scripts/coordinator-tick.sh"
    old = 'if ! coord_shadow && RECHECK=$(swarm_usage_hold_recheck); then say "$RECHECK"; fi\n'
    new = ''
elif which == "listing":
    old = '''  printf '%s\\0' "$@" | perl -0 -e 'my $n = shift;
    my @f = sort { $b->[0] <=> $a->[0] || $a->[1] cmp $b->[1] }
            map { chomp; my @s = stat $_; (@s && -f _) ? [$s[9], $_] : () } <STDIN>;
    $#f = $n - 1 if @f > $n; print "$_->[1]\\n" for @f' "$n"
'''
    new = '  ls -t "$@" 2>/dev/null | head -"$n"\n'
elif which == "supersede":
    old = 'if (d <= 600 && A[i] >= pa && (!p'
    new = 'if (d <= 600 && (!p'
elif which == "ceiling":
    old = '''    awk -v u="$u" -v c="$SWARM_USAGE_CEILING" 'BEGIN{exit !(u + 0 < c + 0)}' \\
      || { keep='''
    new = '''    true \\
      || { keep='''
s = open(p).read()
if s.count(old) != 1: sys.exit(1)
open(p, "w").write(s.replace(old, new))
if open(p).read().count(old) != 0: sys.exit(1)
PY
  printf '%s' "$P"
}
echo "--- planted: the tick never re-checks ---"
if P=$(plant tick); then
  out=$(tick_cases "$P/scripts/coordinator-tick.sh"); printf '%s\n' "$out" | sed 's/^/  /'
  printf '%s\n' "$out" | grep -q '^bad tick-allowed-starts' && ok "planted: the re-check deleted → tick-allowed-starts red" || bad "planted: the re-check deleted → tick-allowed-starts stayed green"
else bad "plant tick did not land"; fi
check_plant() { # <name> <case that must go red> <what it means>
  local P out
  P=$(plant "$1") || { bad "plant $1 did not land"; return; }
  out=$(cases "$P"); printf '%s\n' "$out" | grep '^bad' | sed 's/^/  /'
  printf '%s\n' "$out" | grep -q "^bad $2" && ok "planted: $3 → $2 red" || bad "planted: $3 → $2 stayed green"
}
echo "--- planted: an older, higher reading outranks the probe ---"
check_plant supersede probe-supersedes-older "the probe's precedence removed"
echo "--- planted: a week over the ceiling clears the hold ---"
check_plant ceiling over-ceiling-held "the ceiling test removed"
echo "--- planted: the listing is ls -t again ---"
if P=$(plant listing); then
  clean; known org-a
  flood
  steplog newest $(( NOWE - 60 )) allowed seven_day 0.56
  got=$(many "$P"); bytes=$(printf '%s\n' "$STATE/driver"/*/steps/*.log | wc -c)
  if [ -z "$got" ]; then ok "planted: ls -t lists none of 16,000 logs → red"
  elif [ "$bytes" -lt "$(getconf ARG_MAX 2>/dev/null || echo 0)" ]; then ok "planted: this machine's command line holds all $bytes bytes of names — not reachable here"
  else bad "planted: ls -t still listed $got"; fi
else bad "plant listing did not land"; fi

suite_end "$FAILED"
