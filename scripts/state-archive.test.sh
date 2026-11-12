#!/usr/bin/env bash
# state-archive.test.sh — the state folders outgrow a command line, and old runs leave them.
# On 2026-11-11 the names of 13,616 logs came to 1.11 MB against a 1.05 MB ARG_MAX, the
# `ls -t <glob>` behind the usage readers was never run, and they read nothing for hours.
# First: with 20,000 logs and 20,000 run records every reader still returns its newest.
# Then the housekeeping pass: a dry run counts and moves nothing; --apply moves a run that
# ended over 14 days ago, whole, into a dated archive, and keeps a run that has not ended,
# every run of its ticket, a run written to since, and every file that is no run's. Then the
# plants: put `ls -t` back, or delete a keep rule or the dry run, and its case goes red.
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
DAY=86400
WEEK=$(( NOWE + 2 * DAY ))
unset SWARM_ACCOUNT SWARM_USAGE_HOLD_FILE SWARM_USAGE_PROBE_MIN STATE_ARCHIVE_DIR STATE_ARCHIVE_DAYS COORDINATOR_STATE_ARCHIVE COORDINATOR_STATE_ARCHIVE_APPLY
export SWARM_ACCOUNT_FILE="$C/account" SWARM_USAGE_CEILING=0.95
PROBES="$FIX/probes.log"
printf '#!/usr/bin/env bash\necho call >> "%s"\n' "$PROBES" > "$BIN/probe"; chmod +x "$BIN/probe"
export SWARM_USAGE_PROBE_CMD="$BIN/probe"
at() { python3 -c 'import os,sys; os.utime(sys.argv[1], (int(sys.argv[2]),) * 2)' "$1" "$2"; }
clean() { rm -rf "$C" "$STATE/logs" "$STATE/runs" "$STATE/archive" "$STATE/driver"; mkdir -p "$C" "$STATE/logs" "$STATE/runs"; : > "$PROBES"
          printf 'org-a\t%s\t%s\n' $(( NOWE - DAY )) $(( NOWE - DAY )) > "$SWARM_ACCOUNT_FILE"; }
env_do() { ( export SWARM_NOW="$NOWE" SWARM_ACCOUNT=org-a; . "$1/scripts/coordinator-env.sh" >/dev/null 2>&1 || exit 9; shift; "$@" ); }

echo "--- 20,000 logs and 20,000 run records: every reader returns its newest ---"
# flood — one ticket's 20,000 runs, 30 days old, under names long enough to pass ARG_MAX on any runner.
flood() {
  python3 - "$STATE" $(( NOWE - 30 * DAY )) <<'PY'
import os, sys
state, old = sys.argv[1], int(sys.argv[2])
pad = "x" * 130
for i in range(20000):
    rid = "claim-77-%s-20261001T000000Z-%d" % (pad, i)
    for f in (os.path.join(state, "logs", rid + ".log"), os.path.join(state, "runs", rid + ".json")):
        open(f, "w").close(); os.utime(f, (old, old))
PY
}
# Stamped a minute ago: a fixed date falls behind the account's start a day after it.
NEWSTAMP=$(date -u -r $(( NOWE - 60 )) +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -d "@$(( NOWE - 60 ))" +%Y%m%dT%H%M%SZ)
NEWRUN="claim-77-$NEWSTAMP-1"
NEWLOG="$STATE/logs/$NEWRUN.log"; NEWREC="$STATE/runs/$NEWRUN.json"
# newest <event json…> — the newest log, a minute old, holding those lines; and its record.
newest() { printf '%s\n' "$@" > "$NEWLOG"; at "$NEWLOG" $(( NOWE - 60 )); printf '{"run_id":"%s"}\n' "$NEWRUN" > "$NEWREC"; at "$NEWREC" $(( NOWE - 60 )); }
ev() { # <status> <utilization>
  jq -nc --arg s "$1" --argjson u "$2" --argjson r "$WEEK" \
    '{type:"rate_limit_event", rate_limit_info:{status:$s, resetsAt:$r, rateLimitType:"seven_day", unifiedWindows:{seven_day:{utilization:$u, resetsAt:$r, status:$s}}}}'
}
readers() { # <kit> — one line per reader: what it read from the newest log or record
  local k="$1"
  newest "$(ev rejected 1)"
  printf 'event-hold\t%s\n' "$(env_do "$k" swarm_usage_event_hold)"
  newest "$(ev allowed_warning 0.97)"
  printf 'near-hold\t%s\n' "$(env_do "$k" swarm_usage_near_hold)"
  printf 'freshest\t%s\n' "$(env_do "$k" swarm_usage_freshest seven_day)"
  : > "$PROBES"; env_do "$k" swarm_usage_probe >/dev/null
  printf 'probe-gate\t%s\n' "$(grep -c . "$PROBES")"
  newest '{"type":"result","is_error":true,"result":"You'"'"'ve hit your weekly limit · resets Nov 20 at 9pm (Europe/London)"}'
  printf 'text-hold\t%s\n' "$(env_do "$k" swarm_usage_text_hold)"
  env_do "$k" coord_record_class 77 build
  printf 'run-record\t%s\n' "$(tail -1 "$C/run-classes.tsv" 2>/dev/null | cut -f1)"
}
clean; flood
want "the fixture holds 20,000 old logs" "20000" "$(find "$STATE/logs" -maxdepth 1 -name 'claim-*.log' | grep -c .)"
out=$(readers "$KIT")
row() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k' | cut -f2-; }
want_in "the rejection in the newest log holds"       '\(seven_day window\)$' "$(row "$out" event-hold)"
want_in "a week at 97% in the newest log holds"       'seven_day window at 97%' "$(row "$out" near-hold)"
want    "the freshest reading is the newest log's"    "0.97	$WEEK" "$(row "$out" freshest)"
want    "a minute-old log is seen: no probe call"     "0" "$(row "$out" probe-gate)"
want    "the CLI's error text in the newest log holds" "9pm" "$(row "$out" text-hold)"
want    "the newest of a ticket's 20,001 records"     "$NEWRUN" "$(row "$out" run-record)"

# plant <name> — a copy of the kit with one rule removed; its case must go red.
plant() {
  local P="$FIX/kit-$1"; rm -rf "$P"; mkdir -p "$P"; cp -R "$KIT/swarm" "$KIT/scripts" "$KIT/hooks" "$KIT/driver" "$KIT/tests" "$KIT/.claude-plugin" "$P/" 2>/dev/null
  python3 - "$P" "$1" <<'PY' || return 1
import sys
root, which = sys.argv[1], sys.argv[2]
p = root + "/scripts/state-archive.sh"
if which == "listing":
    p = root + "/swarm/swarm-env.sh"
    old = '''  printf '%s\\0' "$@" | perl -0 -e 'my $n = shift;
    my @f = sort { $b->[0] <=> $a->[0] || $a->[1] cmp $b->[1] }
            map { chomp; my @s = stat $_; (@s && -f _) ? [$s[9], $_] : () } <STDIN>;
    $#f = $n - 1 if @f > $n; print "$_->[1]\\n" for @f' "$n"
'''
    new = '  ls -t "$@" 2>/dev/null | head -"$n"\n'
elif which == "live":
    old = '  if ($open_ticket{ ticket_of($id) }) { $n{live}++; next }\n'; new = ''
elif which == "age":
    s = open(p).read(); old2 = '  if ($s[9] > $cutoff) { $n{young}++; next }\n'
    if s.count(old2) != 1: sys.exit(1)
    open(p, "w").write(s.replace(old2, ''))
    old = '  if ($r->{newest} > $cutoff) { $n{young}++; next }\n'; new = ''
elif which == "dry":
    old = 'if (!$apply) { print'; new = 'if (0) { print'
elif which == "wired":
    p = root + "/scripts/coordinator-housekeeping.sh"
    old = '  sa_out=$(bash "$STATE_ARCHIVE" $sa_args 2>&1); sa_rc=$?\n'; new = '  sa_out=skipped; sa_rc=0\n'
s = open(p).read()
if s.count(old) != 1: sys.exit(1)
open(p, "w").write(s.replace(old, new))
if open(p).read().count(old) != 0: sys.exit(1)
PY
  printf '%s' "$P"
}
echo "--- planted: the listing is ls -t again ---"
if P=$(plant listing); then
  out=$(readers "$P"); bytes=$(printf '%s\n' "$STATE/logs"/claim-*.log | wc -c)
  if [ "$bytes" -lt "$(getconf ARG_MAX 2>/dev/null || echo 0)" ]; then ok "planted: this machine's command line holds all $bytes bytes of names — not reachable here"
  else
    want "planted: ls -t → the rejection is not seen" "" "$(row "$out" event-hold)"
    want "planted: ls -t → no freshest reading"       "" "$(row "$out" freshest)"
    want "planted: ls -t → the probe is called blind" "1" "$(row "$out" probe-gate)"
  fi
else bad "plant listing did not land"; fi

echo "--- the housekeeping pass ---"
# run <id> <age days> <suffix…> — a run's record files and log, all that old. `log` is its log.
run() {
  local id="$1" t=$(( NOWE - $2 * DAY )) s f; shift 2
  for s in "$@"; do
    if [ "$s" = log ]; then f="$STATE/logs/$id.log"; else f="$STATE/runs/$id.$s"; fi
    printf '%s of %s\n' "$s" "$id" > "$f"; at "$f" "$t"
  done
}
world() {
  clean
  run claim-101-20261001T000000Z-11 20 json child child.started started ended worktrees brief log   # ended 20 days ago
  run claim-102-20261108T000000Z-12 3 json ended log                                                 # ended 3 days ago
  run claim-103-20261001T000000Z-13 20 json started log                                              # never ended
  run claim-103-20260920T000000Z-14 40 json ended log                                                # the same ticket, ended
  run claim-104-20261001T000000Z-15 20 json ended; run claim-104-20261001T000000Z-15 1 log           # its log written yesterday
  run claim-usage-probe-20261001T000000Z-0 20 log                                                    # a log with no record
  printf 'daemon\n' > "$STATE/logs/coordinator.out.log"; at "$STATE/logs/coordinator.out.log" $(( NOWE - 20 * DAY ))
  printf 'brief\n' > "$STATE/runs/pm-9-repair.brief"; at "$STATE/runs/pm-9-repair.brief" $(( NOWE - 20 * DAY ))
  mkdir -p "$STATE/logs/old-folder"; at "$STATE/logs/old-folder" $(( NOWE - 20 * DAY ))
}
archive() { ( export SWARM_NOW="$NOWE"; shift; bash "$K/scripts/state-archive.sh" "$@" 2>&1 ); }
TODAY=$(date -u +%Y-%m-%d); A="$STATE/archive/$TODAY"
left() { ls "$STATE/logs" "$STATE/runs" | grep -c "^$1\\."; }
cases() { # <kit>
  local K="$1" out before
  world; before=$(ls -R "$STATE/logs" "$STATE/runs")
  out=$(archive "$K")
  [ "$(ls -R "$STATE/logs" "$STATE/runs")" = "$before" ] && [ ! -e "$STATE/archive" ] && echo "ok dry-run-moves-nothing" || echo "bad dry-run-moves-nothing: $out"
  grep -q 'dry run): would archive 2 logs and 7 run-record files of 2 runs that ended over 14 days ago' <<<"$out" \
    && echo "ok dry-run-counts" || echo "bad dry-run-counts: $out"
  out=$(archive "$K" --apply)
  if [ "$(left claim-101-20261001T000000Z-11)" = 0 ] && [ "$(ls "$A/runs" 2>/dev/null | grep -c '^claim-101-')" = 7 ] \
     && [ "$(cat "$A/logs/claim-101-20261001T000000Z-11.log" 2>/dev/null)" = "log of claim-101-20261001T000000Z-11" ]; then echo "ok old-run-archived-whole"
  else echo "bad old-run-archived-whole: $out"; fi
  [ -f "$A/logs/claim-usage-probe-20261001T000000Z-0.log" ] && echo "ok old-orphan-log-archived" || echo "bad old-orphan-log-archived: $out"
  [ "$(left claim-102-20261108T000000Z-12)" = 3 ] && echo "ok young-run-kept" || echo "bad young-run-kept"
  [ "$(left claim-103-20261001T000000Z-13)" = 3 ] && echo "ok unended-run-kept" || echo "bad unended-run-kept"
  [ "$(left claim-103-20260920T000000Z-14)" = 3 ] && echo "ok live-ticket-older-run-kept" || echo "bad live-ticket-older-run-kept"
  [ "$(left claim-104-20261001T000000Z-15)" = 3 ] && echo "ok run-written-since-kept" || echo "bad run-written-since-kept"
  [ -f "$STATE/logs/coordinator.out.log" ] && [ -f "$STATE/runs/pm-9-repair.brief" ] && [ -d "$STATE/logs/old-folder" ] \
    && echo "ok not-a-run-untouched" || echo "bad not-a-run-untouched"
  grep -q '^state-archive: archived 9 of 9 files' <<<"$out" && echo "ok apply-says-what-moved" || echo "bad apply-says-what-moved: $out"
  out=$(archive "$K" --apply)
  grep -q 'archived 0 of 0 files' <<<"$out" && echo "ok second-pass-moves-nothing" || echo "bad second-pass-moves-nothing: $out"
  # a name already in the archive is never overwritten
  world; mkdir -p "$A/logs"; printf 'earlier\n' > "$A/logs/claim-usage-probe-20261001T000000Z-0.log"
  out=$(archive "$K" --apply)
  [ "$(cat "$A/logs/claim-usage-probe-20261001T000000Z-0.log")" = earlier ] && [ -f "$STATE/logs/claim-usage-probe-20261001T000000Z-0.log" ] \
    && grep -q '1 already in the archive, left in place' <<<"$out" && echo "ok clash-left-in-place" || echo "bad clash-left-in-place: $out"
}
N_CASES=12
out=$(cases "$KIT")
printf '%s\n' "$out" | sed 's/^/  /'
want "all $N_CASES cases pass" "$N_CASES 0" "$(printf '%s\n' "$out" | grep -c '^ok') $(printf '%s\n' "$out" | grep -c '^bad')"

world; : > "$FIX/afile"
out=$(SWARM_LOGS="$FIX/afile/logs" SWARM_NOW="$NOWE" bash "$KIT/scripts/state-archive.sh" --apply 2>&1); rc=$?
want "a folder that cannot be read is exit 1" "1" "$rc"
want_in "and says which" "cannot read $FIX/afile/logs" "$out"
want "and nothing moved" "0" "$(ls "$STATE/archive" 2>/dev/null | grep -c .)"
want "ages by the file's own mtime, never find -newermt" "0" "$(grep -vE '^\s*#' "$KIT/scripts/state-archive.sh" | grep -c 'newermt')"

check_plant() { # <name> <case that must go red> <what it means>
  local P out
  P=$(plant "$1") || { bad "plant $1 did not land"; return; }
  out=$(cases "$P"); printf '%s\n' "$out" | grep '^bad' | cut -c1-160 | sed 's/^/  /'
  printf '%s\n' "$out" | grep -q "^bad $2" && ok "planted: $3 → $2 red" || bad "planted: $3 → $2 stayed green"
}
echo "--- planted: each keep rule, and the dry run ---"
check_plant live live-ticket-older-run-kept "the live-ticket rule removed"
check_plant live unended-run-kept "the live-ticket rule removed"
check_plant age young-run-kept "the age rule removed"
check_plant dry dry-run-moves-nothing "the dry run moves"

echo "--- the coordinator's housekeeping runs it: counting by default, once a day ---"
printf '#!/usr/bin/env bash\n:\n' > "$BIN/noop"; chmod +x "$BIN/noop"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/critic"; chmod +x "$BIN/critic"
export COORDINATOR_RECONCILE="$BIN/noop" COORDINATOR_SWEEP="$BIN/noop" COORDINATOR_LANE="$BIN/noop" COORDINATOR_WORKTREE_SWEEP="$BIN/noop"
export COORDINATOR_KEEP_FRESH="$BIN/noop" COORDINATOR_POLISH_LIST="$BIN/noop" COORDINATOR_CLOSE_MERGED="$BIN/noop"
export COORDINATOR_CRITIC_JUDGE="$BIN/critic" COORDINATOR_CACHE="$BIN/noop" COORDINATOR_NOTIFY_CMD=true COORDINATOR_FREE_GB=500
export COORDINATOR_FOLLOW_UP=off COORDINATOR_UNBLOCK=off COORDINATOR_FEATURE_CLOSE=off COORDINATOR_RELEASE_BATCH=off
export COORDINATOR_MACHINE_PARKS=off COORDINATOR_DEVELOP_HOOKS=off COORDINATOR_PRUNE_BUNDLES=off COORDINATOR_FINDING_CLASS=off
unset SWARM_NOW
house() { COORDINATOR_SHADOW=0 SWARM_ACCOUNT=org-a bash "${1:-$KIT}/scripts/coordinator-housekeeping.sh" 2>&1; }
world
out=$(house)
want_in "housekeeping says the count" 'state-archive \(dry run\): would archive 2 logs and 7 run-record files' "$out"
want "and moved nothing" "8" "$(left claim-101-20261001T000000Z-11)"
out=$(house)
want_not_in "a second pass the same day does not run it" 'state-archive' "$out"
rm -f "$C/state-archive.stamp"
out=$(COORDINATOR_STATE_ARCHIVE_APPLY=true house)
want_in "switched on, it moves" 'state-archive: archived 9 of 9 files' "$out"
want "the old run left the live folders" "0" "$(left claim-101-20261001T000000Z-11)"
if P=$(plant wired); then
  world; out=$(house "$P")
  want_not_in "planted: the call removed → no count" 'would archive' "$out"
else bad "plant wired did not land"; fi

suite_end "$FAILED"
