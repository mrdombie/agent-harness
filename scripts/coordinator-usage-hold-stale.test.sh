#!/usr/bin/env bash
# coordinator-usage-hold-stale.test.sh — the usage hold file binds only the account it was hit
# under, and only until a newer reading clears it. On 2026-11-02 the Mac, and on 2026-11-03
# Yomato, sat held for days on the old account's wall after the owner switched logins, until
# the file was moved aside by hand. Now a hold naming another account, or one a reading taken
# after it puts under the ceiling, is moved aside to logs/ and spawning proceeds; with nothing
# to read it stands. Then the plants: remove either clearing rule and its case goes red.
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
UNTIL=$(( NOWE + 3 * 86400 ))       # the old account's weekly wall, three days out
WEEK=$(( NOWE + 4 * 86400 ))
FIVE=$(( NOWE + 14000 ))
unset SWARM_USAGE_STEP_HOLD COORDINATOR_PACE_BURN SWARM_ACCOUNT SWARM_USAGE_HOLD_FILE
export SWARM_USAGE_PROBE_CMD=false   # nothing here may reach the model
export SWARM_ACCOUNT_FILE="$C/account" SWARM_USAGE_CEILING=0.95
HOLD="$STATE/usage-hold"

clean() { rm -rf "$C" "$STATE/logs"/* "$STATE/driver" "$HOLD"; mkdir -p "$C"; }
at() { python3 -c 'import os,sys; os.utime(sys.argv[1], (int(sys.argv[2]),) * 2)' "$1" "$2"; }
# known <account> — this host has been on <account> for a day.
known() { printf '%s\t%s\t%s\n' "$1" $(( NOWE - 86400 )) $(( NOWE - 86400 )) > "$SWARM_ACCOUNT_FILE"; }
# hold <account|""> [window] — the wall, written an hour ago.
hold() { printf '%s\tYou have hit your weekly limit (#17697 review)\t%s\t%s\n' "$UNTIL" "$1" "${2:-}" > "$HOLD"; at "$HOLD" $(( NOWE - 3600 )); }
# oldhold — a hold an older harness wrote: no account, no window.
oldhold() { printf '%s\tthe plan'"'"'s usage limit (rate-limit event) (#17697 review)\n' "$UNTIL" > "$HOLD"; at "$HOLD" $(( NOWE - 3600 )); }
# reading <5h use> <7d use> <observed epoch> — a builder step log's rate_limit_event.
reading() {
  mkdir -p "$STATE/driver/1/steps"; local f="$STATE/driver/1/steps/review.log"
  jq -nc --argjson f "$FIVE" --argjson w "$WEEK" --argjson a "$1" --argjson b "$2" \
    '{type:"rate_limit_event", rate_limit_info:{status:"allowed",
      unifiedWindows:{five_hour:{utilization:$a, resetsAt:$f, status:"allowed"}, seven_day:{utilization:$b, resetsAt:$w, status:"allowed"}}}}' > "$f"
  at "$f" "$3"
}
held() { ( export SWARM_NOW="$NOWE" SWARM_ACCOUNT="$2"; . "$1/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9; swarm_usage_hold 2>"$FIX/held.err" ); }
moved() { ls "$STATE/logs" 2>/dev/null | grep -c '^usage-hold\.stale-' ; }

cases() { # <kit>
  local k="$1" got
  # other-account: the wall was hit under org-old; this machine is now on org-new.
  clean; known org-new; hold org-old
  if got=$(held "$k" org-new); then echo "bad other-account-cleared: held $got"
  elif [ -e "$HOLD" ] || [ "$(moved)" != 1 ]; then echo "bad other-account-cleared: not moved aside"
  else echo "ok other-account-cleared"; fi
  ls "$STATE/logs" | grep -q '^usage-hold\.stale-org-old-' && echo "ok moved-aside-names-account" || echo "bad moved-aside-names-account: $(ls "$STATE/logs")"
  grep -q 'written under account org-old and this machine is now on org-new' "$FIX/held.err" \
    && echo "ok says-why" || echo "bad says-why: $(cat "$FIX/held.err")"
  # same-account: the wall is this account's, and nothing newer has been read.
  clean; known org-old; hold org-old
  got=$(held "$k" org-old) && [ -e "$HOLD" ] && echo "ok same-account-held" || echo "bad same-account-held: ${got:-nothing held}"
  # newer-under: no account recorded (the hold Yomato carries), but a reading taken after it
  # has both windows well under the ceiling.
  clean; known org-new; oldhold; reading 0.10 0.20 $(( NOWE - 60 ))
  if got=$(held "$k" org-new); then echo "bad newer-reading-under-cleared: held $got"
  elif [ -e "$HOLD" ]; then echo "bad newer-reading-under-cleared: not moved aside"
  else echo "ok newer-reading-under-cleared"; fi
  ls "$STATE/logs" | grep -q '^usage-hold\.stale-unknown-' && echo "ok moved-aside-unknown-account" || echo "bad moved-aside-unknown-account: $(ls "$STATE/logs")"
  # newer-over: a reading after it still has the week over the ceiling.
  clean; known org-old; oldhold; reading 0.10 0.97 $(( NOWE - 60 ))
  got=$(held "$k" org-old) && [ -e "$HOLD" ] && echo "ok newer-reading-over-held" || echo "bad newer-reading-over-held: ${got:-nothing held}"
  # older-under: the only reading was taken before the hold was written.
  clean; known org-old; oldhold; reading 0.10 0.20 $(( NOWE - 7200 ))
  got=$(held "$k" org-old) && [ -e "$HOLD" ] && echo "ok older-reading-held" || echo "bad older-reading-held: ${got:-nothing held}"
  # named-window: a hold on seven_day clears on a newer seven_day reading alone.
  clean; known org-old; hold org-old seven_day; reading 0.99 0.20 $(( NOWE - 60 ))
  if held "$k" org-old >/dev/null; then echo "bad named-window-cleared: held"; else echo "ok named-window-cleared"; fi
  # nothing-read: no account recorded and no reading at all.
  clean; oldhold
  got=$(held "$k" "") && [ -e "$HOLD" ] && echo "ok nothing-read-held" || echo "bad nothing-read-held: ${got:-nothing held}"
  # the login unknown now: an account-stamped hold stands.
  clean; hold org-old
  got=$(held "$k" "") && [ -e "$HOLD" ] && echo "ok account-unknown-held" || echo "bad account-unknown-held: ${got:-nothing held}"
}
N_CASES=11

echo "--- the fixed kit ---"
out=$(cases "$KIT")
printf '%s\n' "$out" | sed 's/^/  /'
n=$(printf '%s\n' "$out" | grep -c '^bad')
[ "$n" = 0 ] && ok "every case passes" || bad "$n case(s) failed"
want "all $N_CASES cases ran" "$N_CASES" "$(printf '%s\n' "$out" | grep -c '^ok')"

echo "--- the writer stamps the account and the window ---"
clean
( export SWARM_NOW="$NOWE" SWARM_ACCOUNT=org-a; . "$KIT/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9
  swarm_usage_hold_write "$UNTIL" "weekly wall" seven_day )
want "account and window recorded" "org-a	seven_day" "$(cut -f3,4 "$HOLD")"
( export SWARM_NOW="$NOWE" SWARM_ACCOUNT=org-b; . "$KIT/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9
  swarm_usage_hold_write $(( NOWE + 3600 )) "session wall" five_hour )
want "another account's later wall is replaced" "$(( NOWE + 3600 ))	org-b" "$(cut -f1,3 "$HOLD")"
( export SWARM_NOW="$NOWE" SWARM_ACCOUNT=org-b; . "$KIT/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9
  swarm_usage_hold_write $(( NOWE + 1800 )) "nearer wall" five_hour )
want "on the same account the later wall is kept" "$(( NOWE + 3600 ))" "$(cut -f1 "$HOLD")"

echo "--- spawn-claim's pre-check ---"
# Stand-ins that record being started: the door must never reach them under a binding hold.
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" | cut -c1-80 >> "$FIX/claude.log"
SH
cat > "$BIN/build-ticket" <<'SH'
#!/usr/bin/env bash
printf 'driver %s\n' "$*" | cut -c1-80 >> "$FIX/claude.log"
SH
chmod +x "$BIN/claude" "$BIN/build-ticket"; : > "$FIX/claude.log"
G() { git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false "$@"; }
G -C "$REPO" checkout -q -b develop && G -C "$REPO" add -A && G -C "$REPO" commit -qm base
G init -q --bare "$FIX/upstream.git" && G -C "$REPO" remote add origin "$FIX/upstream.git" && G -C "$REPO" push -q origin develop
mkdir -p "$FIX/tmp"
door() { SWARM_ACCOUNT="$1" SPAWN_CLAIM_DRIVER="$BIN/build-ticket" TMPDIR="$FIX/tmp" bash "$KIT/scripts/spawn-claim.sh" "$2" 2>&1; }
started() { for _ in $(seq 1 50); do [ -s "$FIX/claude.log" ] && break; sleep 0.1; done; cat "$FIX/claude.log"; }
clean; known org-old; hold org-old
out=$(door org-old 4242); rc=$?
want "same account: spawn-claim refuses (75)" "75" "$rc"
want "and starts nothing" "" "$(cat "$FIX/claude.log")"
clean; known org-new; hold org-old
out=$(door org-new 4243); rc=$?
want_not_in "another account: no usage refusal" "usage limit holds" "$out"
want "another account: it spawns" "0" "$rc"
want_in "and its builder starts" "^driver 4243" "$(started)"
[ ! -e "$HOLD" ] && ok "and the hold was moved aside" || bad "the hold is still in place"
for _ in $(seq 1 50); do ls "$STATE"/runs/claim-4243-*.ended >/dev/null 2>&1 && break; sleep 0.1; done
rm -f "$STATE"/runs/claim-424* "$STATE"/logs/claim-424*

# THE TICK: the hold from the old account stops nothing on the new one.
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
tickworld() {
  clean; rm -rf "$STATE/runs"/*; : > "$SPAWNS"; : > "$FIX/claims.txt"; printf '[]\n' > "$FIX/gh/prs-all.json"
  local t; for t in 701 702 703; do fix_issue "$t" OPEN "status:ready"; bash "$Q" add "$t" >/dev/null; done
}
tick() { SWARM_ACCOUNT="$1" COORDINATOR_PACE=false SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1; }
tickworld; known org-old; printf 'org-old\n' > "$C/usage.account"; hold org-old
out=$(tick org-old)
want "same account: nothing starts" "0" "$(grep -c . "$SPAWNS")"
want_in "same account: the tick names the usage hold" 'spawn: usage limit — holding until' "$out"
tickworld; known org-new; printf 'org-new\n' > "$C/usage.account"; hold org-old
out=$(tick org-new)
[ "$(grep -c . "$SPAWNS")" -ge 1 ] && ok "another account's hold: the tick starts builders" \
  || bad "another account's hold: the tick started nothing: $(grep 'spawn:' <<<"$out" | head -2)"
want_not_in "and holds on no usage limit" 'spawn: usage limit — holding until' "$out"
want_in "and says the hold no longer applies" 'usage: the usage hold until .* no longer applies' "$out"

# plant <name> — a copy of the kit with one clearing rule removed; its case must go red.
plant() {
  local P="$FIX/kit-$1"; rm -rf "$P"; mkdir -p "$P"; cp -R "$KIT/swarm" "$KIT/scripts" "$KIT/hooks" "$KIT/driver" "$KIT/tests" "$KIT/.claude-plugin" "$P/" 2>/dev/null
  python3 - "$P" "$1" <<'PY' || return 1
import sys
root, which = sys.argv[1], sys.argv[2]
p = root + "/swarm/swarm-env.sh"; s = open(p).read()
if which == "account":
    old = '    if [ -n "$cur" ] && [ "$cur" != "$acct" ]; then\n'
    new = '    if false; then\n'
elif which == "reading":
    old = "    awk -v u=\"$u\" -v c=\"$SWARM_USAGE_CEILING\" 'BEGIN{exit !(u + 0 < c + 0)}' || return 1\n"
    new = "    return 1\n"
elif which == "ceiling":
    old = "    awk -v u=\"$u\" -v c=\"$SWARM_USAGE_CEILING\" 'BEGIN{exit !(u + 0 < c + 0)}' || return 1\n"
    new = ''
elif which == "newer":
    old = '    [ "${o:-0}" -gt "$at" ] 2>/dev/null || return 1\n'
    new = ''
if s.count(old) != 1: sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  printf '%s' "$P"
}
check_plant() { # <name> <case that must go red> <what it means>
  local P out
  P=$(plant "$1") || { bad "plant $1 did not land"; return; }
  out=$(cases "$P"); printf '%s\n' "$out" | sed 's/^/  /'
  printf '%s\n' "$out" | grep -q "^bad $2" && ok "planted: $3 → $2 red" || bad "planted: $3 → $2 stayed green"
}
echo "--- planted: another account's hold is never cleared ---"
check_plant account other-account-cleared "the account rule removed"
echo "--- planted: a newer reading never clears a hold ---"
check_plant reading newer-reading-under-cleared "the reading rule removed"
echo "--- planted: a reading taken before the hold clears it ---"
check_plant newer older-reading-held "the newer-than-the-hold test removed"

echo "--- planted: a newer reading over the ceiling clears a hold ---"
check_plant ceiling newer-reading-over-held "the ceiling test removed"

suite_end "$FAILED"
