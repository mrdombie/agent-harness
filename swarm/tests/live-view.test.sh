#!/usr/bin/env bash
# live-view.test.sh — the live view is the swarm's only answer to "how many
# agents are running", so the thing to pin is what it counts as running.
#
# The bug this suite exists for: a record whose agent died before it could write
# its .ended marker looked like a running agent forever, and a launcher reported
# eight running with three alive. The marker alone is not the test; the process
# has to still be there.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture
# A pid that is certainly alive (this shell) and one that is certainly not.
# Taken BEFORE the cleanup trap is armed, deliberately: in bash 3.2 a background
# job inherits the EXIT trap, so `sleep 30 &` under the trap deletes the fixture
# out from under the suite the moment it is killed — every later case then reads
# an empty directory and the suite reports a machine with no agents as correct.
sleep 30 & DEAD=$!; kill "$DEAD" 2>/dev/null; wait "$DEAD" 2>/dev/null
trap 'rm -rf "$FIX"' EXIT
SERVER="$HERE/../live-view/server.mjs"
SERVER_URLPATH="$SERVER"; command -v cygpath >/dev/null 2>&1 && SERVER_URLPATH=$(cygpath -m "$SERVER")
command -v node >/dev/null 2>&1 || { echo "SKIP live-view: node is not on PATH"; exit 0; }

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
run() { # <ticket> <pid> [ended-exit-code]
  local t=$1 pid=$2 winpid=null log
  log="$STATE/logs/claim-$t.log"
  # As the spawner records it on Git Bash: the native pid beside the MSYS one.
  [ -r "/proc/$pid/winpid" ] && winpid=$(cat "/proc/$pid/winpid")
  command -v cygpath >/dev/null 2>&1 && log=$(cygpath -m "$log")
  printf '{"run_id":"claim-%s-a","ticket":"%s","child_pid":%s,"child_winpid":%s,"started_at":"%s","budget_usd":150,"log":"%s"}\n' \
    "$t" "$t" "$pid" "$winpid" "$NOW_ISO" "$log" > "$STATE/runs/claim-$t-a.json"
  [ -n "${3:-}" ] && printf '{"exit_code":%s,"ended_at":"%s"}\n' "$3" "$NOW_ISO" > "$STATE/runs/claim-$t-a.ended"
  : > "$STATE/logs/claim-$t.log"
}
snap() {
  SWARM_RUNS_DIR="$STATE/runs" SWARM_REPO=acme/widgets SWARM_TITLES="$FIX/titles.json" SWARM_GH="$BIN/gh" \
  SWARM_PROGRESS_SYNC=1 SWARM_SERVER_MJS="$SERVER_URLPATH" node --input-type=module -e "
    import { pathToFileURL } from 'node:url'
    const { snapshot } = await import(pathToFileURL(process.env.SWARM_SERVER_MJS).href)
    console.log(JSON.stringify(snapshot()))"
}

echo "--- a running agent is live ---"
run 501 "$$"
s=$(snap)
want "one live"            "1" "$(printf '%s' "$s" | jq '.live | length')"
want "and nothing finished" "0" "$(printf '%s' "$s" | jq '.done | length')"
want "it carries its ticket" "501" "$(printf '%s' "$s" | jq -r '.live[0].ticket')"

echo "--- a dead agent with NO marker is not live, and is not finished either ---"
run 502 "$DEAD"
s=$(snap)
want "still one live"      "1" "$(printf '%s' "$s" | jq '.live | length')"
want "502 is not among them" "0" "$(printf '%s' "$s" | jq '[.live[] | select(.ticket=="502")] | length')"

echo "--- a marker makes it finished, with its exit code ---"
run 503 "$DEAD" 1
s=$(snap)
want "one finished"        "1" "$(printf '%s' "$s" | jq '.done | length')"
want "carrying the code"   "1" "$(printf '%s' "$s" | jq '.done[0].exit')"
want "and read as stopped" "stopped" "$(printf '%s' "$s" | jq -r '.done[0].outcome')"

echo "--- a marker on a LIVE pid still means finished ---"
# The marker wins over the process: an agent that wrote its marker and has not
# yet exited is done, not running.
run 504 "$$" 0
s=$(snap)
want "not live"            "0" "$(printf '%s' "$s" | jq '[.live[] | select(.ticket=="504")] | length')"
want "finished cleanly"    "success" "$(printf '%s' "$s" | jq -r '.done[] | select(.ticket=="504") | .outcome')"

echo "--- the snapshot is stamped, and names the repo ---"
s=$(snap)
want_in "it has an instant" '^"20[0-9]{2}-[0-9]{2}-[0-9]{2}T' "$(printf '%s' "$s" | jq '.at')"
want "and the repo"        "acme/widgets" "$(printf '%s' "$s" | jq -r '.repo')"

echo "--- steps come out of the agent's own log ---"
cat > "$STATE/logs/claim-501.log" <<'LOG'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"description":"Run the gates"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"The queue order holds."}]}}
LOG
s=$(snap)
want "two steps"           "2" "$(printf '%s' "$s" | jq '[.live[] | select(.ticket=="501")][0].steps | length')"
want "the command is named" "Run the gates" "$(printf '%s' "$s" | jq -r '[.live[] | select(.ticket=="501")][0].steps[0].text')"
want "and what it said"    "say" "$(printf '%s' "$s" | jq -r '[.live[] | select(.ticket=="501")][0].steps[1].kind')"

echo "--- an unreadable record is skipped, not fatal ---"
printf 'not json\n' > "$STATE/runs/claim-599-a.json"
s=$(snap)
want "the rest still answer" "1" "$(printf '%s' "$s" | jq '.live | length')"

echo "--- the coordinator's queue is shown in the order it runs, notes and all ---"
mkdir -p "$STATE/coordinator"
cat > "$STATE/coordinator/queue.json" <<'JSON'
{"scope":"widgets","label":"project:widgets","seeded_at":"2026-10-16T09:00:00Z","tickets":[
 {"n":701,"class":"new","note":""},
 {"n":702,"class":"repair","note":"resume the worktree","pinned":true},
 {"n":703,"class":"approved-merge","note":""},
 {"n":704,"class":"new","note":"","scope":"project:gadgets"}]}
JSON
s=$(snap)
want "four queued"              "4" "$(printf '%s' "$s" | jq '.queue.tickets | length')"
want "repair first, then merge, then new in place" "702 703 701 704" "$(printf '%s' "$s" | jq -r '[.queue.tickets[].ticket] | join(" ")')"
want "the pinned note travels"  "resume the worktree" "$(printf '%s' "$s" | jq -r '.queue.tickets[0].note')"
want "an entry without a scope takes the queue's" "project:widgets" "$(printf '%s' "$s" | jq -r '.queue.tickets[2].scope')"
want "an entry's own scope wins" "project:gadgets" "$(printf '%s' "$s" | jq -r '.queue.tickets[3].scope')"
want "it carries a title"       "Ticket 701" "$(printf '%s' "$s" | jq -r '.queue.tickets[2].title')"
rm -f "$STATE/coordinator/queue.json"
s=$(snap)
want "no queue file: an empty queue, not an error" "0" "$(printf '%s' "$s" | jq '.queue.tickets | length')"

echo "--- the coordinator's ceiling and its healing / new split are served ---"
want "no capacity file: null, not an error" "null" "$(printf '%s' "$s" | jq '.capacity')"
printf '{"live":7,"ceiling":8,"room":true,"reading":"cpu idle 31%%, 9 GB free","cap":null,"healing":{"slots":2,"live":1},"new":{"slots":6,"live":6},"redsWaiting":2}\n' \
  > "$STATE/coordinator/capacity.json"
s=$(snap)
want "the ceiling and the reading" "8 cpu idle 31%, 9 GB free" "$(printf '%s' "$s" | jq -r '"\(.capacity.ceiling) \(.capacity.reading)"')"
want "the split"                   "6 1 2" "$(printf '%s' "$s" | jq -r '"\(.capacity.new.live) \(.capacity.healing.live) \(.capacity.redsWaiting)"')"
rm -f "$STATE/coordinator/capacity.json"

echo "--- a hold on spawns is shown, with why and until when ---"
s=$(snap)
want "nothing held"             "false" "$(printf '%s' "$s" | jq '.hold.held')"
printf 'testing the banner (held 2026-10-16T09:00Z by tester)\n' > "$STATE/swarm/HOLD"
s=$(snap)
want "the owner's pause"        "paused" "$(printf '%s' "$s" | jq -r '.hold.kind')"
want_in "with its reason"       'testing the banner' "$(printf '%s' "$s" | jq -r '.hold.reason')"
rm -f "$STATE/swarm/HOLD"
printf '%s\thit your usage limit\n' "$(( $(date +%s) + 3600 ))" > "$STATE/usage-hold"
s=$(snap)
want "the usage limit"          "usage" "$(printf '%s' "$s" | jq -r '.hold.kind')"
want_in "until an instant"      '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T' "$(printf '%s' "$s" | jq -r '.hold.until')"
printf '%s\thit your usage limit\n' "$(( $(date +%s) - 60 ))" > "$STATE/usage-hold"
s=$(snap)
want "a reset already passed holds nothing" "false" "$(printf '%s' "$s" | jq '.hold.held')"
rm -f "$STATE/usage-hold"
: > "$STATE/logs/claim-zzz.log"
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"seven_day"}}\n' \
  "$(( $(date +%s) + 7200 ))" > "$STATE/logs/claim-zzz.log"
s=$(snap)
want_in "a limit read from the newest log names its window" "weekly usage limit" "$(printf '%s' "$s" | jq -r '.hold.reason')"
rm -f "$STATE/logs/claim-zzz.log"

echo "--- a service death is the CLI's error result, never a report quoting one ---"
run 801 "$DEAD" 1
printf '%s\n' '{"type":"result","subtype":"success","is_error":true,"result":"API Error: Connection refused"}' > "$STATE/logs/claim-801.log"
run 802 "$DEAD" 0
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"Done. CI said: API Error 529 overloaded"}' > "$STATE/logs/claim-802.log"
s=$(snap)
want "the CLI's own error result is a service death" "true" "$(printf '%s' "$s" | jq '.done[] | select(.ticket=="801") | .infra')"
want "a report quoting one is not"                   "false" "$(printf '%s' "$s" | jq '.done[] | select(.ticket=="802") | .infra')"

echo "--- a slow progress refresh never freezes the page ---"
# Measured 2026-10-16: the refresh ran ~45 s of synchronous git and forge calls on
# the server's own loop every minute, and requests waited 7-30 s or timed out.
cat > "$BIN/slow-claim-lock" <<'SH'
#!/usr/bin/env bash
sleep 3; printf '{"branch":"tkt-501/x"}\n'
SH
chmod +x "$BIN/slow-claim-lock"
LV="$HERE/../live-view"
# The fixture's curl answers from a file; this case needs the real one.
REAL_CURL=$(PATH=$(getconf PATH) command -v curl)
served() { # <live-view dir> — ms for two answers, the first of which starts a refresh
  local pf="$FIX/port-$RANDOM" pid i port t0 t1
  SWARM_RUNS_DIR="$STATE/runs" SWARM_REPO=acme/widgets SWARM_TITLES="$FIX/titles.json" SWARM_GH="$BIN/gh" \
  SWARM_CLAIM_LOCK="$BIN/slow-claim-lock" SWARM_PROGRESS_CACHE="$FIX/progress-$RANDOM.json" \
  SWARM_SERVER_MJS="$1/server.mjs" PORT_FILE="$pf" node --input-type=module -e "
    import { pathToFileURL } from 'node:url'
    import fs from 'node:fs'
    const { serve } = await import(pathToFileURL(process.env.SWARM_SERVER_MJS).href)
    const srv = serve(0)
    srv.on('listening', () => fs.writeFileSync(process.env.PORT_FILE, String(srv.address().port)))
    setTimeout(() => process.exit(0), 15000)" 2>/dev/null &
  pid=$!
  for i in $(seq 1 50); do [ -s "$pf" ] && break; sleep 0.1; done
  port=$(cat "$pf" 2>/dev/null)
  t0=$(node -e 'console.log(Date.now())')
  "$REAL_CURL" -s -m 8 -o /dev/null "http://127.0.0.1:$port/api/agents"
  "$REAL_CURL" -s -m 8 -o /dev/null "http://127.0.0.1:$port/api/agents"
  t1=$(node -e 'console.log(Date.now())')
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  echo $(( t1 - t0 ))
}
ms=$(served "$LV")
case "$ms" in ''|*[!0-9]*) bad "the page did not answer during a refresh ($ms)" ;;
  *) [ "$ms" -lt 1500 ] && ok "two answers in ${ms} ms while a 3 s refresh ran" || bad "two answers took ${ms} ms while a 3 s refresh ran" ;; esac
g=$(SWARM_CLAIM_LOCK="$BIN/slow-claim-lock" SWARM_GH="$BIN/gh" SWARM_GIT=false \
    node "$LV/progress.mjs" --gather '{"tickets":["501"],"ids":[],"repo":"acme/widgets"}' 2>/dev/null)
want "the refresh process prints what it read" "tkt-501/x" "$(printf '%s' "$g" | jq -r '.tickets["501"].branch' 2>/dev/null)"
# Plant: the refresh back on the server's own loop. The page must then wait for it.
P="$FIX/lv-plant"; mkdir -p "$P"; cp "$LV"/*.mjs "$LV"/index.html "$P/"
python3 - "$P/server.mjs" <<'PY' || bad "plant did not land"
import sys
p = sys.argv[1]; s = open(p).read()
a = "  gathering = true\n  execFile(process.execPath, [PROGRESS_JS, '--gather', JSON.stringify(args)],"
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, "  setTimeout(() => { try { keep(gatherProgress(args)) } catch {} }, 0); if (0) execFile(process.execPath, [PROGRESS_JS, '--gather', JSON.stringify(args)],"))
PY
grep -q "if (0) execFile" "$P/server.mjs" || bad "plant: the child process is still in the copy"
ms=$(served "$P")
case "$ms" in *[!0-9]*|'') ms=99999 ;; esac
[ "$ms" -ge 1500 ] && ok "planted: refresh in-process → two answers took ${ms} ms → red" \
  || bad "planted: refresh in-process and two answers still took ${ms} ms → the test cannot see it"

exit $FAILED
