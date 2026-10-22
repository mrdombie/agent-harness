#!/usr/bin/env bash
# coordinator-pace.test.sh — the two things that kept the coordinator slow:
# a run that ended waiting on a human was picked again the next tick, and the
# slow housekeeping sat between one tick's starts and the next.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
T="$HERE/coordinator-tick.sh"
HK="$HERE/coordinator-housekeeping.sh"
Q="$HERE/coordinator-queue.sh"
C="$STATE/coordinator"

for s in reconcile sweep wtsweep; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$FIX/house.log"\n' "$s" > "$BIN/$s"; chmod +x "$BIN/$s"
done
printf '#!/usr/bin/env bash\n:\n' > "$BIN/judge"; chmod +x "$BIN/judge"
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep" COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep"
export COORDINATOR_JUDGE="$BIN/judge" COORDINATOR_NOTIFY_CMD=true
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
unset COORDINATOR_SHADOW COORDINATOR_CAP COORDINATOR_HEALING_SHARE
export SWARM_FREE_MEM_GB=16 SWARM_IDLE=90 SWARM_CORES=10 TEST_PID=$$
cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${CLAIM_CLASS:-}" >> "$SPAWNS"
SH
chmod +x "$BIN/spawn-live"

fresh() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/HOLD"
  : > "$SPAWNS"; : > "$FIX/house.log"; : > "$FIX/claims.txt"
  printf '[]\n' > "$FIX/gh/prs-all.json"
}
issue() { # <n> <labels,…> [comments JSON array]
  jq -n --arg l "$2" --argjson c "${3:-[]}" \
    '{state:"OPEN", title:"t", labels:($l|split(",")|map(select(length>0)|{name:.})), comments:$c}' > "$FIX/gh/issue-$1.json"
}
ended() { # <ticket> <run> <final result text> — a run of <ticket> that ended 10 minutes ago, exit 0
  printf '{"run_id":"%s","ticket":"%s","log":"%s"}\n' "$2" "$1" "$STATE/logs/$2.log" > "$STATE/runs/$2.json"
  jq -nc --arg r "$3" '{type:"result",result:$r}' > "$STATE/logs/$2.log"
  jq -nc --arg r "$2" --arg at "$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-10 min' +%Y-%m-%dT%H:%M:%SZ)" \
    '{run_id:$r, exit_code:0, ended_at:$at}' > "$STATE/runs/$2.ended"
}
pr() { # <ticket> <sha> [labels,…] [branch] [merge state] — its open PR, checks green
  jq -n --arg t "$1" --arg s "$2" --arg l "${3:-}" --arg b "${4:-tkt-$1-x}" --arg m "${5:-CLEAN}" \
    '[{number:($t|tonumber + 1000), headRefName:$b, headRefOid:$s, isDraft:false,
       labels:($l|split(",")|map(select(length>0)|{name:.})), mergeStateStatus:$m,
       statusCheckRollup:[{status:"COMPLETED", conclusion:"SUCCESS"}]}]' > "$FIX/gh/prs-all.json"
}
queue() { local t; for t in "$@"; do bash "$Q" add "$t" >/dev/null; done; }
queue_repair() { local t; for t in "$@"; do bash "$Q" add "$t" --class repair >/dev/null; done; }
live() { SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1; }
spawned() { cut -f1 "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }
STATUS() { printf '## Status\n\n| | |\n|---|---|\n| **Running** | Nothing |\n| Waiting for | %s |\n| Next check | None |\n' "$1"; }

echo "--- a run that ended waiting on a human is not picked again ---"
fresh; issue 601 "status:ready"; ended 601 claim-601-a "$(STATUS 'Your sign-off on the PR, then CI')"
out=$(live)
want_in "the end is read as a wait"        'wait: #601 ended waiting on a human \(waiting for: Your sign-off on the PR, then CI\)' "$out"
queue 601; out=$(live)
want "queued again, it is not spawned"     "" "$(spawned)"
want_in "and the tick log says why"        'skip #601 \(new\): waiting on a human since run claim-601-a ended .*nothing has changed' "$(cat "$C/tick.log")"
out=$(live)
want "nor on the tick after"               "" "$(spawned)"

echo "--- the guard flags nothing correct ---"
fresh; issue 602 "status:ready"; ended 602 claim-602-a "$(STATUS 'CI on the PR, then auto-merge')"
live >/dev/null; queue 602; live >/dev/null
want "waiting on CI alone: picked again"   "602" "$(spawned)"
fresh; issue 612 "status:ready"; ended 612 claim-612-a "$(STATUS 'CI to pass; auto-merge then merges it with no sign-off from you')"
live >/dev/null; queue 612; live >/dev/null
want "\"no sign-off from you\" is no wait"   "612" "$(spawned)"
fresh; issue 613 "status:ready"; ended 613 claim-613-a "$(STATUS "The design doc's approval-line fix (#12344) to merge to develop")"
live >/dev/null; queue 613; live >/dev/null
want "a row naming no person is no wait"   "613" "$(spawned)"
fresh; issue 603 "status:ready"; ended 603 claim-603-a "There's nothing for you to decide. Merging develop into the PR is routine follow-up."
live >/dev/null; queue 603; live >/dev/null
want "\"nothing for you to decide\" is no wait" "603" "$(spawned)"
fresh; issue 604 "status:ready"; ended 604 claim-604-a "Waiting on you is a slot nobody can use, so the brief was trimmed. Handed off."
live >/dev/null; queue 604; live >/dev/null
want "a phrase quoted in passing is no wait" "604" "$(spawned)"
fresh; issue 605 "status:ready"; ended 605 claim-605-a "$(STATUS 'Your pick above')"
live >/dev/null
ended 605 claim-605-b "Handed off at abc123"; live >/dev/null; queue 605; live >/dev/null
want "a later run that ended clean replaces the wait" "605" "$(spawned)"

echo "--- with no status table, a run that says it could not ask is a wait ---"
fresh; issue 606 "status:ready"; ended 606 claim-606-a "The question tool doesn't exist in this run, so the choice is written on the ticket."
live >/dev/null; queue 606; live >/dev/null
want "\"the question tool doesn't exist\": held" "" "$(spawned)"

echo "--- the wait is over when a human moves ---"
fresh; issue 607 "status:ready,needs:design"; ended 607 claim-607-a "$(STATUS 'You to approve the target picture')"
live >/dev/null; queue 607; live >/dev/null
want "held while nothing moves"            "" "$(spawned)"
issue 607 "status:ready"; out=$(live)
want "a label removed: picked again"       "607" "$(spawned)"
want_in "and the log says what moved"      'wait over: #607 — changed since run claim-607-a ended' "$(cat "$C/tick.log")"

fresh; issue 608 "status:ready"; ended 608 claim-608-a "$(STATUS 'Your answer on the two flagged lines')"
live >/dev/null; queue 608
issue 608 "status:ready" '[{"createdAt":"2000-01-01T00:00:00Z","body":"an old comment"}]'; live >/dev/null
want "a comment from before the end moves nothing" "" "$(spawned)"
issue 608 "status:ready" "[{\"createdAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"body\":\"**Claim released.** The agent holding this is gone\"}]"; live >/dev/null
want "the kit's own release comment moves nothing" "" "$(spawned)"
issue 608 "status:ready" "[{\"createdAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"body\":\"Go with option A\"}]"; live >/dev/null
want "a new comment: picked again"         "608" "$(spawned)"

fresh; issue 609 "status:claimed"; ended 609 claim-609-a "$(STATUS 'Your sign-off on the screens')"
live >/dev/null; queue 609
issue 609 "status:ready"; live >/dev/null
want "reconcile flipping claimed to ready moves nothing" "" "$(spawned)"

fresh; issue 610 "status:in-review"; pr 610 sha-a "needs:human-approval"
ended 610 claim-610-a "$(STATUS 'Your screen sign-off on the PR')"
live >/dev/null; queue_repair 610
pr 610 sha-a ""; issue 610 "status:in-review"; live >/dev/null
want "the hold taken off the PR: the repair is picked" "610" "$(spawned)"
fresh; issue 611 "status:in-review"; pr 611 sha-a
ended 611 claim-611-a "$(STATUS 'Your sign-off, then CI')"
live >/dev/null; queue_repair 611; live >/dev/null
want "same head, same labels: held"        "" "$(spawned)"
pr 611 sha-b; live >/dev/null
want "a new commit on the PR: picked"      "611" "$(spawned)"
# A branch named for the ticket alone, without the prefix, is still its PR.
fresh; issue 614 "status:in-review"; pr 614 sha-a "" "614/ask-files"
ended 614 claim-614-a "$(STATUS 'Your sign-off on the PR')"
live >/dev/null; queue_repair 614; live >/dev/null
want "held while its unprefixed PR has not moved" "" "$(spawned)"
pr 614 sha-a "" "614/ask-files" DIRTY; live >/dev/null
want "that PR clashing frees it for the repair" "614" "$(spawned)"

echo "--- housekeeping is off the start path ---"
cat > "$BIN/slowhouse" <<'SH'
#!/usr/bin/env bash
sleep 3; echo done > "$FIX/slowhouse.done"
SH
chmod +x "$BIN/slowhouse"
fresh; rm -f "$FIX/slowhouse.done"; issue 620 "status:ready"; queue 620
out=$(COORDINATOR_HOUSEKEEPING=background COORDINATOR_HOUSEKEEPING_CMD="$BIN/slowhouse" live)
# Whether the housekeeping had ended when the tick returned, not a wall-clock bound a loaded runner misses.
ended=$([ -f "$FIX/slowhouse.done" ] && echo yes || echo no)
want "the tick starts its builder"         "620" "$(spawned)"
want "and returns before the housekeeping ends" "no" "$ended"
want_in "it says the housekeeping went to the background" 'housekeeping: started in the background' "$out"
for _ in $(seq 1 60); do [ -f "$FIX/slowhouse.done" ] && break; sleep 0.1; done
want "which still runs to the end"         "done" "$(cat "$FIX/slowhouse.done" 2>/dev/null)"
out=$(COORDINATOR_HOUSEKEEPING_EVERY_MIN=5 COORDINATOR_HOUSEKEEPING=background COORDINATOR_HOUSEKEEPING_CMD="$BIN/slowhouse" live)
want_in "inside its interval it is not started again" 'housekeeping: ran under 5 min ago — not this tick' "$out"

fresh; mkdir -p "$C"; sleep 30 & holder=$!
mkdir "$C/housekeeping.lock"; echo "$holder" > "$C/housekeeping.lock/pid"
LC_ALL=C TZ=UTC ps -o lstart= -p "$holder" | tr -s ' ' | sed 's/^ *//;s/ *$//' > "$C/housekeeping.lock/started"
case_refused_stamp() { # the tick stamped this start; the lock refuses it
  touch "$C/housekeeping.stamp"; out=$(COORDINATOR_SHADOW=0 bash "${HK_SUT:-$HK}" 2>&1)
  R="stamp=$([ -f "$C/housekeeping.stamp" ] && echo kept || echo gone)"
}
case_refused_stamp
want_in "one still running: a second does not start" 'housekeeping: another housekeeping \(pid [0-9]+\) is running — not started again' "$out"
want "and touches nothing"                 "" "$(cat "$FIX/house.log")"
want "a refused start leaves no interval stamp: the next tick starts one" "stamp=gone" "$R"
KHK="$FIX/kit-hk"; rm -rf "$KHK"; mkdir -p "$KHK"; cp -R "$HERE/../scripts" "$HERE/../swarm" "$HERE/../driver" "$KHK/"
PLANT_LINE='rm -f "$COORD_DIR/housekeeping.stamp"; '
python3 -I -c 'import sys; p, a = sys.argv[1:3]; s = open(p).read(); n = s.count(a); open(p, "w").write(s.replace(a, "", 1)); sys.exit(0 if n == 1 else 1)' \
  "$KHK/scripts/coordinator-housekeeping.sh" "$PLANT_LINE" || bad "plant did not land: the stamp reset"
HK_SUT="$KHK/scripts/coordinator-housekeeping.sh" case_refused_stamp
want "planted (the stamp reset): the case now fails" "stamp=kept" "$R"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
out=$(COORDINATOR_SHADOW=0 bash "$HK" 2>&1)
want_in "with the holder gone, it runs"    '^reconcile --quiet' "$(cat "$FIX/house.log")"
want "and frees its lock"                  "" "$(ls -d "$C/housekeeping.lock" 2>/dev/null)"

suite_end "$FAILED"
