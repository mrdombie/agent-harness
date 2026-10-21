#!/usr/bin/env bash
# spawn-wall.test.sh — nothing starts a model run into the plan's usage limit.
# spawn-claim.sh is the one door every spawner goes through (the tick, the merge
# lane, repair-watch, queue drain, a person's shell), so it refuses under the
# hold before anything else runs. The judge waits out the hold
# too, and a judge the wall stopped mid-run leaves its event to be judged again.
#
# Measured 2026-10-15/16: eleven claim runs started into a hold that was already
# on record, each dead at its first call, and 33 judges died on the wall with
# their red-PR event marked judged — so those PRs were never queued for repair.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
FAILED=0
KIT="${SPAWN_WALL_KIT:-$HERE/../..}"
SOON=$(( $(date +%s) + 7200 ))

# A claude that records being started; the spawner must never reach it under a hold.
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" | cut -c1-80 >> "$FIX/claude.log"
SH
chmod +x "$BIN/claude"
: > "$FIX/claude.log"
# A named ticket's builder is the step driver: a stand-in that records being started the same way.
cat > "$BIN/build-ticket" <<'SH'
#!/usr/bin/env bash
printf 'driver %s\n' "$*" | cut -c1-80 >> "$FIX/claude.log"
SH
chmod +x "$BIN/build-ticket"
export SPAWN_CLAIM_DRIVER="$BIN/build-ticket"

# An integration branch to start in, so with no hold the spawner really does reach claude.
G() { git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false "$@"; }
G -C "$REPO" checkout -q -b develop && G -C "$REPO" add -A && G -C "$REPO" commit -qm base
G init -q --bare "$FIX/upstream.git" && G -C "$REPO" remote add origin "$FIX/upstream.git" && G -C "$REPO" push -q origin develop
mkdir -p "$FIX/tmp"; export TMPDIR="$FIX/tmp"
spawn() { bash "$KIT/scripts/spawn-claim.sh" "$@" 2>&1; }
started() { for _ in $(seq 1 50); do [ -s "$FIX/claude.log" ] && break; sleep 0.1; done; cat "$FIX/claude.log"; }

echo "--- spawn-claim.sh refuses under the hold ---"
printf '%s\tYou have hit your session limit\n' "$SOON" > "$STATE/usage-hold"
out=$(spawn 4242); rc=$?
want "it exits 75 (temporary failure)" "75" "$rc"
want_in "it says the limit holds, and until when" "usage limit holds until .*recorded by a window" "$out"
want "it never starts claude" "" "$(cat "$FIX/claude.log")"
want "it writes no run record" "0" "$(ls "$STATE/runs" | grep -c 'claim-4242')"

echo "--- through swarm_spawn, the path every swarm script takes ---"
out=$(SWARM_SPAWN="$KIT/scripts/spawn-claim.sh" bash -c '. "$1/swarm/swarm-env.sh" >/dev/null; swarm_spawn 4243' _ "$KIT" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "swarm_spawn reports the refusal ($rc)" || bad "swarm_spawn spawned under the hold"
want "and claude was never started" "" "$(cat "$FIX/claude.log")"

echo "--- a window at the ceiling holds the door too ---"
rm -f "$STATE/usage-hold"
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":%s,"rateLimitType":"seven_day","unifiedWindows":{"five_hour":{"utilization":0.4,"resetsAt":%s},"seven_day":{"utilization":0.99,"resetsAt":%s}}}}\n' \
  "$SOON" "$SOON" "$SOON" > "$STATE/logs/claim-12559-20261016T010445Z-1.log"
out=$(spawn 4244); rc=$?
want "at 99% of the week it refuses" "75" "$rc"
want_in "and names the reading" "seven_day window at 99%" "$out"
rm -f "$STATE/logs/claim-12559-20261016T010445Z-1.log"

echo "--- no hold: the door is open ---"
out=$(spawn 4245); rc=$?
want_not_in "no hold, no refusal" "usage limit holds" "$out"
want "it spawns" "0" "$rc"
want_in "and its builder starts" "^driver 4245" "$(started)"
for _ in $(seq 1 50); do [ -f "$STATE/runs/"claim-4245-*.ended ] 2>/dev/null && break; sleep 0.1; done
: > "$FIX/claude.log"; rm -f "$STATE"/runs/claim-4245-* "$STATE"/logs/claim-4245-*
printf '%s\tYou have hit your session limit\n' "$SOON" > "$STATE/usage-hold"
out=$(spawn --fg 4246)
want_not_in "a person's own --fg window is theirs to open" "usage limit holds" "$out"
rm -f "$STATE/usage-hold"

echo "--- under the disk guard's floor the door is shut too ---"
# Owner call 2026-10-20: a build fills ~1.5 GB, and on a full disk nothing can even start a shell.
: > "$FIX/claude.log"
out=$(HARNESS_DISK_GUARD=on COORDINATOR_FREE_GB=12 spawn 4247); rc=$?
want "12 GB free: it exits 76" "76" "$rc"
want_in "and says the disk is low, and what a build needs" "spawn-claim: disk low: 12 GB free, under the 30 GB a build needs — not spawning" "$out"
want "it never starts a builder" "" "$(cat "$FIX/claude.log")"
want "it writes no run record" "0" "$(ls "$STATE/runs" | grep -c 'claim-4247')"
out=$(SWARM_SPAWN="$KIT/scripts/spawn-claim.sh" HARNESS_DISK_GUARD=on COORDINATOR_FREE_GB=12 bash -c '. "$1/swarm/swarm-env.sh" >/dev/null; swarm_spawn 4248' _ "$KIT" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "through swarm_spawn the refusal is reported ($rc)" || bad "swarm_spawn spawned on a low disk"
want "and nothing started" "" "$(cat "$FIX/claude.log")"
out=$(HARNESS_DISK_GUARD=on COORDINATOR_FREE_GB=30 spawn 4249); rc=$?
want "30 GB free, at the floor: it spawns" "0" "$rc"
want_in "and its builder starts" "^driver 4249" "$(started)"
for _ in $(seq 1 50); do [ -f "$STATE/runs/"claim-4249-*.ended ] 2>/dev/null && break; sleep 0.1; done
: > "$FIX/claude.log"; rm -f "$STATE"/runs/claim-4249-* "$STATE"/logs/claim-4249-*

echo "--- the judge waits out the hold ---"
C="$STATE/coordinator"; mkdir -p "$C"
export COORDINATOR_SHADOW=0 COORDINATOR_CLAUDE="$BIN/claude"
printf '{"id":"red-pr:41:sha41","kind":"red-pr","judge":true,"ticket":"601","pr":"41","detail":"checks settled red"}\n' > "$C/events.did.jsonl"
printf '%s\tYou have hit your weekly limit\n' "$SOON" > "$STATE/usage-hold"
out=$(bash "$KIT/scripts/coordinator-judge.sh" 2>&1)
want_in "it says the event waits" "usage limit holds until .* red-pr:41:sha41 waits" "$out"
want "the event is not marked judged" "0" "$(grep -c 'red-pr:41' "$C/judged.did.ids" 2>/dev/null || true)"
rm -f "$STATE/usage-hold"

echo "--- a judge the wall stopped gives its event back ---"
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
printf 'claude judge\n' >> "$FIX/claude.log"
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"seven_day"}}\n' "$(( $(date +%s) + 7200 ))"
printf '{"type":"result","is_error":true,"result":"You have hit your weekly limit"}\n'
exit 1
SH
chmod +x "$BIN/claude"
bash "$KIT/scripts/coordinator-judge.sh" >/dev/null 2>&1
for _ in $(seq 1 50); do ls "$C"/judges/*.ended >/dev/null 2>&1 && break; sleep 0.1; done
want "the judge ran" "claude judge" "$(cat "$FIX/claude.log" | tail -1)"
want "its event is open again for the next tick" "0" "$(grep -c 'red-pr:41' "$C/judged.did.ids")"
# A judge that decided something keeps its event judged.
rm -rf "$C/judges"; : > "$C/judged.did.ids"
printf '#!/usr/bin/env bash\nprintf '"'"'{"type":"result","is_error":false,"result":"queued 601 as repair"}\\n'"'"'\n' > "$BIN/claude"
bash "$KIT/scripts/coordinator-judge.sh" >/dev/null 2>&1
for _ in $(seq 1 50); do ls "$C"/judges/*.ended >/dev/null 2>&1 && break; sleep 0.1; done
want "a judge that finished keeps its event judged" "1" "$(grep -c 'red-pr:41' "$C/judged.did.ids")"

suite_end "$FAILED"
