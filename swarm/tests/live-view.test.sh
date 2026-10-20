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
  SWARM_RUNS_DIR="$STATE/runs" SWARM_REPO=acme/widgets SWARM_TITLES="$FIX/titles.json" SWARM_GH="${SNAP_GH:-$BIN/gh}" \
  SWARM_PROGRESS_SYNC=1 SWARM_HOST="${SNAP_HOST:-laptop}" SWARM_SERVER_MJS="${SNAP_MJS:-$SERVER_URLPATH}" node --input-type=module -e "
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

echo "--- a step-driver log is plain text, and its last line is the current step ---"
# The step driver writes plain lines, not stream-JSON. Read as JSON only, every
# driver build showed "Starting up" with no steps while it was mid-build.
printf '   build: all 5 task(s) proved red before green\n\n\033[32m   self-check: changed 2 ok\033[0m\n' > "$STATE/logs/claim-501.log"
s=$(snap)
want "two plain steps"      "2" "$(printf '%s' "$s" | jq '[.live[] | select(.ticket=="501")][0].steps | length')"
want "the last line is now" "self-check: changed 2 ok" "$(printf '%s' "$s" | jq -r '[.live[] | select(.ticket=="501")][0].steps[-1].text')"
want "read as said"         "say" "$(printf '%s' "$s" | jq -r '[.live[] | select(.ticket=="501")][0].steps[-1].kind')"
long=$(printf 'x%.0s' $(seq 1 300))
{ for i in $(seq 1 12); do echo "line $i"; done; echo "$long"; } > "$STATE/logs/claim-501.log"
s=$(snap)
want "the last ten only"    "10" "$(printf '%s' "$s" | jq '[.live[] | select(.ticket=="501")][0].steps | length')"
want "in order"             "line 4" "$(printf '%s' "$s" | jq -r '[.live[] | select(.ticket=="501")][0].steps[0].text')"
want "a long line is capped" "220" "$(printf '%s' "$s" | jq '[.live[] | select(.ticket=="501")][0].steps[-1].text | length')"

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
cat > "$STATE/coordinator/queue.json" <<'JSON'
{"scope":"widgets","label":"project:widgets","tickets":[
 {"n":711,"class":"repair","prin":3,"note":""},
 {"n":712,"class":"new","prin":1,"kind":"polish","note":""},
 {"n":713,"class":"new","prin":1,"kind":"feature","note":""},
 {"n":714,"class":"repair","prin":1,"note":""},
 {"n":715,"class":"new","prin":0,"note":""},
 {"n":716,"class":"new","prin":3,"front":true,"note":""},
 {"n":717,"class":"new","prin":3,"top":true,"note":""}]}
JSON
s=$(snap)
want "priority first across classes; a resume leads only its own priority; the PM's top leads all" \
  "717 715 714 713 712 716 711" "$(printf '%s' "$s" | jq -r '[.queue.tickets[].ticket] | join(" ")')"

echo "--- the queue lists and counts only rows somebody can start ---"
cat > "$STATE/coordinator/queue.json" <<'JSON'
{"scope":"widgets","label":"project:widgets","tickets":[
 {"n":720,"class":"new","prin":1,"note":""},
 {"n":721,"class":"new","prin":1,"note":""},
 {"n":722,"class":"new","prin":1,"note":""},
 {"n":723,"class":"new","prin":1,"note":""},
 {"n":724,"class":"repair","prin":1,"note":""},
 {"n":725,"class":"new","prin":1,"note":"REPAIR on PR #9: it clashes"},
 {"n":726,"class":"new","prin":1,"note":""}]}
JSON
mkdir -p "$STATE/coordinator/snapshot"
cat > "$STATE/coordinator/snapshot/issues.json" <<'JSON'
{"720":{"number":720,"state":"OPEN","labels":["status:ready"]},
 "721":{"number":721,"state":"CLOSED","labels":["status:ready"]},
 "722":{"number":722,"state":"OPEN","labels":["status:ready","status:batched"]},
 "723":{"number":723,"state":"OPEN","labels":["status:ready","needs:human-approval"]},
 "724":{"number":724,"state":"OPEN","labels":["status:in-review","needs:human-approval"]},
 "725":{"number":725,"state":"OPEN","labels":["status:in-review","needs:human-approval"]}}
JSON
s=$(snap)
want "closed, batched and held new rows are not listed; a held PR's repair and an unread row are" \
  "724 725 720 726" "$(printf '%s' "$s" | jq -r '[.queue.tickets[].ticket] | join(" ")')"
want "the count is the rows that can start" "4" "$(printf '%s' "$s" | jq '.queue.tickets | length')"
want "a new row with a REPAIR brief is shown as a repair" "repair" "$(printf '%s' "$s" | jq -r '.queue.tickets[] | select(.ticket=="725") | .class')"
rm -f "$STATE/coordinator/snapshot/issues.json"
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

echo "--- a ticket with no project label still renders, and the page survives it ---"
# A ticket with a colon in its title and no project: label handed an empty name
# to plainName, which read ''[0] and threw. The throw escaped the request
# handler and killed the server, so one unlabelled ticket took the live view
# down for every viewer.
run 901 "$$"
printf '{"901":{"title":"Pre-push: drop the typecheck legs","project":""}}' > "$FIX/titles.json"
s=$(snap 2>&1)
want "the snapshot is still JSON"   "1" "$(printf '%s' "$s" | jq '[.live[] | select(.ticket=="901")] | length' 2>/dev/null || echo threw)"
want "its card is named by the clause before the colon" "Pre-push" "$(printf '%s' "$s" | jq -r '.live[] | select(.ticket=="901") | .short' 2>/dev/null)"
rm -f "$FIX/titles.json"

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


echo "--- a finished row says where its ticket stands NOW, not how the run ended ---"
# Measured 2026-10-19: of 20 rows reading "stopped", 10 were back in the queue, 1
# closed, 1 in review and several waiting on a question. The owner read 20 failures.
rm -f "$STATE"/runs/claim-* "$STATE"/logs/claim-*
LV="$HERE/../live-view"
ended_run() { # <ticket> <exit> [run-suffix] [ended_at] — a finished run with an empty log
  local t=$1 sfx=${3:-a} at=${4:-$NOW_ISO} log="$STATE/logs/claim-$1-${3:-a}.log"
  command -v cygpath >/dev/null 2>&1 && log=$(cygpath -m "$log")
  printf '{"run_id":"claim-%s-%s","ticket":"%s","child_pid":%s,"started_at":"%s","log":"%s"}\n' \
    "$t" "$sfx" "$t" "$DEAD" "$at" "$log" > "$STATE/runs/claim-$t-$sfx.json"
  printf '{"exit_code":%s,"ended_at":"%s"}\n' "$2" "$at" > "$STATE/runs/claim-$t-$sfx.ended"
  : > "$STATE/logs/claim-$t-$sfx.log"
}
park_line() { printf '⏸ #%s parked (%s): %s\n' "$1" "$2" "$3" >> "$STATE/logs/claim-$1-a.log"; }
ended_run 1001 0
printf '%s\n' '{"type":"result","subtype":"success","result":"Merged: https://github.com/acme/widgets/pull/2001"}' > "$STATE/logs/claim-1001-a.log"
for t in 1002 1003 1004 1005 1006 1007 1008 1009 1010 1011 1012 1013 1015 1017; do ended_run "$t" 20; done
ended_run 1016 143
park_line 1009 pm "build asked a question rather than guessing — which repo does this belong in?"
park_line 1012 driver "start refused: blocked by #77"
park_line 1013 driver "build refused (exit 24) — build left no reason on the record"
park_line 1015 driver "review answered in a shape the driver cannot read"
printf '{"exit_code":143,"ended_at":"%s","note":"stopped on the owner pause"}\n' "$NOW_ISO" > "$STATE/runs/claim-1016-a.ended"
# Two runs of one ticket: the older parked, the newer is the one that counts.
ended_run 1014 20 old "2026-01-01T00:00:00Z"
printf '{"exit_code":20,"ended_at":"%s"}\n' "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" > "$STATE/runs/claim-1014-old.ended"
ended_run 1014 0 new
# 1008 is running again under a new run.
printf '{"run_id":"claim-1008-b","ticket":"1008","child_pid":%s,"started_at":"%s","log":"%s"}\n' \
  "$$" "$NOW_ISO" "$STATE/logs/claim-1008-b.log" > "$STATE/runs/claim-1008-b.json"
: > "$STATE/logs/claim-1008-b.log"
mkdir -p "$STATE/coordinator/snapshot" "$STATE/swarm"
cat > "$STATE/coordinator/snapshot/issues.json" <<'JSON'
{"1002":{"number":1002,"state":"CLOSED","labels":["status:done","P1"]},
 "1003":{"number":1003,"state":"CLOSED","stateReason":"NOT_PLANNED","labels":["status:ready"]},
 "1017":{"number":1017,"state":"CLOSED","stateReason":"COMPLETED","labels":["status:in-review"]},
 "1004":{"number":1004,"state":"OPEN","labels":["status:in-review"]},
 "1005":{"number":1005,"state":"OPEN","labels":["status:ready"]},
 "1007":{"number":1007,"state":"OPEN","labels":["status:ready","P2"]},
 "1009":{"number":1009,"state":"OPEN","labels":["status:parked"]},
 "1010":{"number":1010,"state":"OPEN","labels":["status:pm-decision"]},
 "1011":{"number":1011,"state":"OPEN","labels":["needs:owner-decision"]},
 "1012":{"number":1012,"state":"OPEN","labels":["status:blocked"]},
 "1013":{"number":1013,"state":"OPEN","labels":["status:parked"]},
 "1015":{"number":1015,"state":"OPEN","labels":["status:ready","status:parked"]}}
JSON
cat > "$STATE/swarm/prs.json" <<'JSON'
[{"number":2004,"headRefName":"tkt-1004/the-fix","closingIssuesReferences":[]},
 {"number":2005,"headRefName":"someone/else","closingIssuesReferences":[{"number":1005}]}]
JSON
printf '{"scope":"widgets","tickets":[{"n":1006,"class":"new","note":""}]}\n' > "$STATE/coordinator/queue.json"
nows() { BRANCH_PREFIX=tkt- snap | jq -r '.done[] | "\(.ticket)=\(.now.text)"' | sort; }
now_of() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }
n=$(nows)
want "exit 0 with a PR no longer open: shipped"  "Shipped"             "$(now_of "$n" 1001)"
want "closed done: shipped"                      "Shipped"             "$(now_of "$n" 1002)"
want "closed not planned: closed"                "Closed"              "$(now_of "$n" 1003)"
want "closed completed, labels left behind: shipped" "Shipped"         "$(now_of "$n" 1017)"
want "an open PR by its branch: in review"       "In review — PR #2004" "$(now_of "$n" 1004)"
want "an open PR by its closing reference"       "In review — PR #2005" "$(now_of "$n" 1005)"
want "on the coordinator's queue"                "Back in the queue"   "$(now_of "$n" 1006)"
want "status:ready: back in the queue"           "Back in the queue"   "$(now_of "$n" 1007)"
want "a live run for the ticket: running again"  "Running again"       "$(now_of "$n" 1008)"
want "parked on a PM question"                   "Waiting on PM"       "$(now_of "$n" 1009)"
want "status:pm-decision"                        "Waiting on PM"       "$(now_of "$n" 1010)"
want "the owner's decision label"                "Waiting on the owner" "$(now_of "$n" 1011)"
want "blocked, by the ticket its park names"     "Blocked by #77"      "$(now_of "$n" 1012)"
want "a driver park: stopped, with its one-line reason" "Stopped — build refused (exit 24)" "$(now_of "$n" 1013)"
want "ready AND parked is not queued"            "Stopped — review answered in a shape the driver cannot read" "$(now_of "$n" 1015)"
want "a stop with no park line names the marker's note" "Stopped — stopped on the owner pause" "$(now_of "$n" 1016)"
s=$(BRANCH_PREFIX=tkt- snap)
want "one row per ticket"                        "1" "$(printf '%s' "$s" | jq '[.done[] | select(.ticket=="1014")] | length')"
want "and it is the newest run"                  "0" "$(printf '%s' "$s" | jq '.done[] | select(.ticket=="1014") | .exit')"
want "the owner is named when the project names them" "Waiting on Dom" \
  "$(SWARM_OWNER_NAME=Dom BRANCH_PREFIX=tkt- snap | jq -r '.done[] | select(.ticket=="1011") | .now.text')"
want "only a true stop is red" "stopped" "$(printf '%s' "$s" | jq -r '[.done[] | select(.now.tone=="bad") | .now.state] | unique | join(" ")')"
want "the header counts by state" \
  "Finished: 3 shipped · 1 closed · 2 in review · 2 back in queue · 1 running again · 2 waiting on PM · 1 waiting on the owner · 1 blocked · 1 finished · 3 stopped" \
  "$(printf '%s' "$s" | jq -r '.doneSummary')"

echo "--- the page shows that state, not the run's exit ---"
# The page's own row renderer, run in node against a row from the snapshot.
page_row() { # <live-view dir> <ticket>
  printf '%s' "$s" | jq -c --arg t "$2" '.done[] | select(.ticket==$t)' > "$FIX/row.json"
  PAGE="$1/index.html" ROW="$FIX/row.json" node -e '
    const fs = require("fs"), vm = require("vm")
    const html = fs.readFileSync(process.env.PAGE, "utf8")
    const js = html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</script>"))
    const el = () => ({ textContent: "", innerHTML: "", hidden: false })
    const ctx = { document: { getElementById: el }, fetch: () => new Promise(() => {}), setInterval: () => 0, console }
    vm.createContext(ctx); vm.runInContext(js + "\n;globalThis.__row = doneRow", ctx)
    console.log(ctx.__row(JSON.parse(fs.readFileSync(process.env.ROW, "utf8"))))' 2>&1
}
r=$(page_row "$LV" 1006)
want_in "a queued ticket reads as back in the queue" 'pill neutral">Back in the queue' "$r"
want "and nothing on it says stopped" "0" "$(printf '%s' "$r" | grep -c 'Stopped')"
r=$(page_row "$LV" 1013)
want_in "a true stop is red, with its reason" 'pill bad">Stopped</span><div class="note">build refused \(exit 24\)' "$r"

echo "--- planted: each rule removed is seen ---"
P2="$FIX/lv-plant-now"; mkdir -p "$P2"
plant() { # <file> <exact text> [what it becomes; default nothing]
  cp "$LV"/*.mjs "$LV/index.html" "$P2/"
  python3 - "$P2/$1" "$2" "${3:-}" <<'PY' || bad "plant did not land: $2"
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]; s = open(p).read()
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
}
P2_URL="$P2/server.mjs"; command -v cygpath >/dev/null 2>&1 && P2_URL=$(cygpath -m "$P2_URL")
psnap() { SNAP_MJS="$P2_URL" SWARM_HOLD_SCRIPT="$HERE/../hold-status.sh" BRANCH_PREFIX=tkt- snap; }
plant server.mjs "  if (ctx.queued.has(t) || (has(LBL('LBL_READY', 'status:ready')) && !parked)) return at('queue', 'Back in the queue')"
got=$(psnap | jq -r '.done[] | select(.ticket=="1006") | .now.text')
[ -n "$got" ] && [ "$got" != "Back in the queue" ] \
  && ok "planted: no queue rule → a queued ticket reads '$got' → red" || bad "planted: the queue rule deleted and the test cannot see it ($got)"
plant server.mjs "  for (const d of done) { const o = newest.get(d.ticket); if (!o || d.endedAt > o.endedAt) newest.set(d.ticket, d) }" \
  "  for (const d of done) newest.set(d.ticket + ':' + d.endedAt, d)"
got=$(psnap | jq '[.done[] | select(.ticket=="1014")] | length' 2>/dev/null)
[ "$got" != "1" ] && ok "planted: no de-duplication → $got rows for 1014 → red" || bad "planted: de-duplication deleted and the test cannot see it"
plant server.mjs '  if (openPr) return at('"'"'review'"'"', `In review — PR #${openPr}`, { pr: openPr })'
got=$(psnap | jq -r '.done[] | select(.ticket=="1004") | .now.text')
[ -n "$got" ] && [ "$got" != "In review — PR #2004" ] \
  && ok "planted: no review rule → 1004 reads '$got' → red" || bad "planted: the review rule deleted and the test cannot see it ($got)"
plant index.html '      <td>${nowPill(d)}</td>'
[ "$(page_row "$P2" 1006 | grep -c 'Back in the queue')" = 0 ] \
  && ok "planted: the page drops the state → no 'Back in the queue' → red" || bad "planted: the page drops the state and the test cannot see it"
rm -f "$STATE/coordinator/queue.json" "$STATE/coordinator/snapshot/issues.json" "$STATE/swarm/prs.json"

echo "--- the headline counts every open ticket before launch, and the chips add up to it ---"
# Measured 2026-10-20: the page said "Queued · 354" (the startable queue) with
# 1,338 tickets open and 79 set after launch, so it showed a third of the work.
rm -f "$STATE"/runs/claim-* "$STATE"/logs/claim-*
SINCE=$(node -e 'const d=new Date();d.setHours(0,0,0,0);console.log(d.toISOString().replace(/\.\d{3}Z$/,"Z"))')
BOARD="$STATE/swarm/board.json"
board_fixture() { # <since> — sixteen before launch, two after, one of each kind of wait
  # 1116-1118 carry the claimed label with no run anywhere (1118 also a claim on
  # this host, laptop): stale, so they sort by their other labels, not as building.
  cat > "$BOARD" <<JSON
{"at":"$NOW_ISO","since":"$1","doneToday":5,"newToday":2,"mergedToday":4,
 "claims":[{"issue":"1114","host":"dom@studio-mac"},{"issue":"1113","host":"dom@laptop"},{"issue":"1118","host":"dom@laptop"}],
 "open":[
  {"number":1101,"title":"Ready one","labels":["status:ready"]},
  {"number":1102,"title":"Later ready","labels":["status:ready","after-launch"]},
  {"number":1103,"title":"Later bare","labels":["after-launch"]},
  {"number":1104,"title":"In review","labels":["status:in-review"]},
  {"number":1105,"title":"Held and green","labels":["status:in-review"]},
  {"number":1106,"title":"Held but red","labels":["status:in-review"]},
  {"number":1107,"title":"Owner decides","labels":["needs:owner-decision"]},
  {"number":1108,"title":"PM decides","labels":["status:pm-decision"]},
  {"number":1109,"title":"Drafting","labels":["status:drafting"]},
  {"number":1110,"title":"Parked","labels":["status:parked","status:ready"]},
  {"number":1111,"title":"Batched","labels":["status:batched"]},
  {"number":1112,"title":"No status","labels":["P3"]},
  {"number":1113,"title":"Running here","labels":["status:ready"]},
  {"number":1114,"title":"Claimed elsewhere","labels":["status:ready"]},
  {"number":1115,"title":"Held and blocked","labels":["needs:human-approval","status:blocked"]},
  {"number":1116,"title":"Stale claim, ready","labels":["status:claimed","status:ready"]},
  {"number":1117,"title":"Stale claim, bare","labels":["status:claimed"]},
  {"number":1118,"title":"Stale claim here","labels":["status:claimed","status:in-review"]}]}
JSON
}
board_fixture "$SINCE"
cat > "$STATE/swarm/prs.json" <<'JSON'
[{"number":2104,"headRefName":"tkt-1104/a","closingIssuesReferences":[],"labels":[],"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]},
 {"number":2105,"headRefName":"tkt-1105/a","closingIssuesReferences":[],"labels":[{"name":"needs:human-approval"}],"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]},
 {"number":2106,"headRefName":"tkt-1106/a","closingIssuesReferences":[],"labels":[{"name":"needs:human-approval"}],"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"FAILURE"}]}]
JSON
printf '{"run_id":"claim-1113-a","ticket":"1113","child_pid":%s,"started_at":"%s","operator":"dom@laptop","log":"%s"}\n' \
  "$$" "$NOW_ISO" "$STATE/logs/claim-1113-a.log" > "$STATE/runs/claim-1113-a.json"
printf 'build: writing the tests\n' > "$STATE/logs/claim-1113-a.log"
s=$(BRANCH_PREFIX=tkt- snap)
want "before launch leaves the after-launch tickets out" "16" "$(printf '%s' "$s" | jq '.board.beforeLaunch')"
want "after launch is counted apart"                     "2"  "$(printf '%s' "$s" | jq '.board.afterLaunch')"
want "the chips add up to what is left"                  "16" "$(printf '%s' "$s" | jq '[.board.buckets[].n] | add')"
# Measured 2026-10-20: the chip said Building 10 beside "Building now · 5" — it
# counted the status:claimed label, which outlives the run that set it.
want "the building chip is live runs plus other hosts' claims, never a stale label" \
  "2" "$(printf '%s' "$s" | jq '[.board.buckets[] | select(.key=="building") | .n] | add')"
want "a stale claim sorts by its other labels" \
  "ready=2 building=2 review=3 pm=1 owner=3 stuck=2 batched=1 other=2" \
  "$(printf '%s' "$s" | jq -r '[.board.buckets[] | "\(.key)=\(.n)"] | join(" ")')"
want "needs you: the decision, the green held PR, the held ticket — never the red one" "1105 1107 1115" \
  "$(printf '%s' "$s" | jq -r '[.board.needsYou[].ticket] | join(" ")')"
want "a held PR links to the PR"                          "2105 A sign-off" "$(printf '%s' "$s" | jq -r '.board.needsYou[0] | "\(.pr) \(.why)"')"
want "today: merged, done, new and the delta"             "4 5 2 3" "$(printf '%s' "$s" | jq -r '.board.today | "\(.merged) \(.done) \(.made) \(.delta)"')"
want "who is building where"                              "laptop:1 studio-mac:1" "$(printf '%s' "$s" | jq -r '[.hosts[] | "\(.host):\(.n)"] | sort | join(" ")')"
want "the after-launch label is the project's to name"    "17 1" \
  "$(SWARM_AFTER_LAUNCH_LABEL=status:batched BRANCH_PREFIX=tkt- snap | jq -r '"\(.board.beforeLaunch) \(.board.afterLaunch)"')"
board_fixture "2001-01-01T00:00:00Z"
want "yesterday's today counts say nothing"               "null" "$(BRANCH_PREFIX=tkt- snap | jq '.board.today')"
board_fixture "$SINCE"

echo "--- the five-hour usage is the coordinator's newest reading still open ---"
want "no readings: null"                                  "null" "$(printf '%s' "$s" | jq '.usage')"
E=$(date +%s)
printf '%s\t0.20\t%s\t3\n%s\t0.42\t%s\t3\n' $((E - 9000)) $((E - 60)) $((E - 120)) $((E + 3600)) > "$STATE/coordinator/pace.tsv"
want "the newest open window, as a percentage"            "42" "$(BRANCH_PREFIX=tkt- snap | jq '.usage.pct')"
rm -f "$STATE/coordinator/pace.tsv"

echo "--- the count is one batched read, kept five minutes, and a short read is not a count ---"
cat > "$FIX/board-gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/board-gh.log"
case "$*" in *"issues(states:OPEN"*) cat "$FIX/board-pages.json" ;; *) cat "$FIX/trend-answer.json" 2>/dev/null ;; esac
SH
chmod +x "$FIX/board-gh"
pages() { # <hasNextPage on the last page>
  cat > "$FIX/board-pages.json" <<JSON
[{"data":{"done":{"issueCount":7},"made":{"issueCount":1},"merged":{"issueCount":6},"repository":{"issues":{"totalCount":3,
   "pageInfo":{"hasNextPage":true,"endCursor":"a"},"nodes":[{"number":1,"title":"fix(x): one","labels":{"nodes":[{"name":"status:ready"}]}},
   {"number":2,"title":"two","labels":{"nodes":[{"name":"after-launch"}]}}]}}}},
 {"data":{"done":{"issueCount":7},"made":{"issueCount":1},"merged":{"issueCount":6},"repository":{"issues":{"totalCount":3,
   "pageInfo":{"hasNextPage":$1,"endCursor":"b"},"nodes":[{"number":3,"title":"three","labels":{"nodes":[]}}]}}}}]
JSON
}
gsnap() { SNAP_GH="$FIX/board-gh" BRANCH_PREFIX=tkt- snap; }
: > "$FIX/board-gh.log"
want "a fresh count is not read again"                    "0" "$(gsnap >/dev/null; grep -c 'api graphql --paginate' "$FIX/board-gh.log")"
rm -f "$BOARD"; pages true
s=$(gsnap)
want "a read that stopped part-way is not kept"           "null" "$(printf '%s' "$s" | jq '.board')"
rm -f "$BOARD"; pages false; : > "$FIX/board-gh.log"
s=$(gsnap)
want "one read of every open ticket"                      "1" "$(grep -c 'api graphql --paginate' "$FIX/board-gh.log")"
want "counted from both pages"                            "2 1" "$(printf '%s' "$s" | jq -r '"\(.board.beforeLaunch) \(.board.afterLaunch)"')"
want "with today's counts"                                "6 7 1" "$(printf '%s' "$s" | jq -r '.board.today | "\(.merged) \(.done) \(.made)"')"
want "and kept for the next ask"                          "One" "$(jq -r '.open[0].title' "$BOARD")"
board_fixture "$SINCE"

echo "--- the page leads with the headline, one row per builder, and the rest folded ---"
s=$(BRANCH_PREFIX=tkt- snap)
page_render() { # <live-view dir> — every element the page wrote, as id=html lines
  printf '%s' "$s" > "$FIX/snap.json"
  PAGE="$1/index.html" SNAP="$FIX/snap.json" node -e '
    const fs = require("fs"), vm = require("vm")
    const html = fs.readFileSync(process.env.PAGE, "utf8")
    const js = html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</script>"))
    const els = {}
    const el = (id) => (els[id] ||= { textContent: "", innerHTML: "", hidden: false })
    const ctx = { document: { getElementById: el }, fetch: () => new Promise(() => {}), setInterval: () => 0, console }
    vm.createContext(ctx); vm.runInContext(js + "\n;globalThis.__render = render", ctx)
    ctx.__render(JSON.parse(fs.readFileSync(process.env.SNAP, "utf8")))
    for (const [k, v] of Object.entries(els)) console.log(k + "=" + (v.innerHTML || v.textContent).replace(/\s+/g, " "))' 2>&1
}
r=$(page_render "$LV")
want_in "the block is the release's progress"             '^headline=<div class="ptitle">Release progress</div>' "$r"
want_not_in "it no longer leads with what is left"        'Before launch:' "$r"
want_in "the building chip counts the live run and the other host's claim" 'data-k="building"><b>2</b> Building' "$r"
want_in "with a chip per place"                           'data-k="owner"><b>3</b> Waiting on the owner' "$r"
want_in "and after launch muted beside it"                'chip muted" data-k="after"><b>2</b> After launch' "$r"
want_in "today, with the list shrinking"                  '^today=.*<b>4</b> merged.*List shrinking by 3' "$r"
want_in "a builder is one row with its step and time"     '^building=.*class="row build".*Running here.*[0-9]+ min running.*build: writing the tests' "$r"
want_in "needs you lists the owner's items"               '^needs=.*Held and green.*A sign-off' "$r"
want_in "the machine line names the hosts, not a stale claim here" '^machine=.*Building on: laptop \(1\), studio-mac \(1\)' "$r"
want_not_in "the finished rows start folded"              '<details class="fold" id="donefold" open' "$(cat "$LV/index.html")"
board_fixture "$SINCE"
jq '.open |= map(select((.labels | index("needs:owner-decision") or index("needs:human-approval")) | not))' "$BOARD" > "$BOARD.t" && mv "$BOARD.t" "$BOARD"
rm -f "$STATE/swarm/prs.json"
s=$(BRANCH_PREFIX=tkt- snap)
want_in "nothing waiting on the owner says so"            '^needs=<div class="allclear">Nothing needs you' "$(page_render "$LV")"

echo "--- planted: each rule removed is seen ---"
board_fixture "$SINCE"
cat > "$STATE/swarm/prs.json" <<'JSON'
[{"number":2105,"headRefName":"tkt-1105/a","closingIssuesReferences":[],"labels":[{"name":"needs:human-approval"}],"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]},
 {"number":2106,"headRefName":"tkt-1106/a","closingIssuesReferences":[],"labels":[{"name":"needs:human-approval"}],"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"FAILURE"}]}]
JSON
plant server.mjs "    if (labels.includes(AFTER_LAUNCH)) { after++; continue }"
got=$(psnap | jq '.board.beforeLaunch')
[ "$got" != "16" ] && ok "planted: no after-launch rule → before launch reads $got → red" || bad "planted: the after-launch rule deleted and the test cannot see it"
plant server.mjs "  if (ownerWait && !(pr && pr.red)) return 'owner'"
got=$(psnap | jq -r '[.board.needsYou[].ticket] | join(" ")')
[ "$got" != "1105 1107 1115" ] && ok "planted: no owner rule → needs you reads '$got' → red" || bad "planted: the owner rule deleted and the test cannot see it"
plant server.mjs "  if (!last || !last.pageInfo || last.pageInfo.hasNextPage !== false) return null"
rm -f "$BOARD"; pages true
got=$(SNAP_GH="$FIX/board-gh" psnap | jq '.board.beforeLaunch')
[ "$got" != "null" ] && ok "planted: no short-read guard → a part read counts $got → red" || bad "planted: the short-read guard deleted and the test cannot see it"
board_fixture "$SINCE"
s=$(BRANCH_PREFIX=tkt- snap)
plant index.html "  document.getElementById('headline').innerHTML = headline(s.board, s.launch)"
[ "$(page_render "$P2" | grep -c 'Release progress')" = 0 ] \
  && ok "planted: the page drops the headline → no 'Release progress' → red" || bad "planted: the page drops the headline and the test cannot see it"
plant server.mjs "  if (building) return 'building'"
got=$(psnap | jq '[.board.buckets[] | select(.key=="building") | .n] | add')
[ "$got" != "2" ] && ok "planted: no live-run rule → building reads $got → red" || bad "planted: the live-run rule deleted and the test cannot see it"
plant server.mjs "  const claimed = new Set((board.claims || []).filter((c) => !here.has(hostName(c.host))).map((c) => c.issue))" \
  "  const claimed = new Set()"
got=$(psnap | jq '[.board.buckets[] | select(.key=="building") | .n] | add')
[ "$got" != "2" ] && ok "planted: other hosts' claims dropped → building reads $got → red" || bad "planted: other hosts' claims dropped and the test cannot see it"
plant server.mjs "  const claimed = new Set((board.claims || []).filter((c) => !here.has(hostName(c.host))).map((c) => c.issue))" \
  "  const claimed = new Set((board.claims || []).map((c) => c.issue))"
got=$(psnap | jq '[.board.buckets[] | select(.key=="building") | .n] | add')
[ "$got" != "2" ] && ok "planted: a stale claim here counted → building reads $got → red" || bad "planted: a stale claim here counted and the test cannot see it"

echo "--- progress to launch: done since the start, the pace, and where it lands ---"
TREND="$STATE/swarm/trend.json"
trend_fixture() { # <added per whole day> <done per whole day> — today: 1 added, 2 done
  SERVER_MJS="$SERVER_URLPATH" A=$1 D=$2 node --input-type=module -e '
    import { pathToFileURL } from "node:url"
    const { trendDays } = await import(pathToFileURL(process.env.SERVER_MJS).href)
    const ds = trendDays(), last = ds.length - 1
    console.log(JSON.stringify({ at: new Date().toISOString(), base: "2026-10-13", doneSinceBase: 37,
      days: ds.map((d, i) => ({ day: d.day, added: i === last ? 1 : +process.env.A, done: i === last ? 2 : +process.env.D, merged: i + 1 })) }))' > "$TREND"
}
board_fixture "$SINCE"
trend_fixture 2 5
s=$(BRANCH_PREFIX=tkt- snap)
want "done and still open make the whole"               "37 16 53" "$(printf '%s' "$s" | jq -r '.launch | "\(.done) \(.open) \(.total)"')"
want "the bar is done of the whole"                     "69.8" "$(printf '%s' "$s" | jq '.launch.pct')"
want "the open side leaves after launch out"            "16" "$(printf '%s' "$s" | jq '.launch.open')"
want "burn is done less added over the whole days"      "3 true" "$(printf '%s' "$s" | jq -r '.launch | "\(.burn) \(.converging)"')"
ETA=$(node -e 'const d=new Date();d.setDate(d.getDate()+6);console.log(`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`)')
want "at this pace: sixteen left at three a day is six days" "$ETA" "$(printf '%s' "$s" | jq -r '.launch.eta')"
want "today is today's own counts"                      "1 2" "$(printf '%s' "$s" | jq -r '.launch.today | "\(.added) \(.done)"')"
r=$(page_render "$LV")
want_in "the big number is the release: done plus left" '^headline=<div class="ptitle">Release progress</div><div class="big">Release: 53 <small>tickets</small></div>' "$r"
want_in "then the bar: done, left, share"               'width:69.8%.*<b>37</b> done · <b>16</b> left · <b>69.8%</b>.*Added and done, per day.*Pull requests merged' "$r"
want "the chips add up to the bar's left"               "$(printf '%s' "$s" | jq '.launch.open')" "$(printf '%s' "$s" | jq '[.board.buckets[].n] | add')"
# Dom, 2026-10-20: "it's 1669; this is a screen for the release" — the numbers he read.
s=$(printf '%s' "$s" | jq '.launch |= (.done = 410 | .open = 1259 | .total = 1669 | .pct = 24.6)')
r=$(page_render "$LV")
want_in "the release in his numbers"                     'Release: 1,669 <small>tickets</small>.*<b>410</b> done · <b>1,259</b> left · <b>24.6%</b>' "$r"
want_in "the page is titled for the release"             '<title>Release, live</title>.*<h1>Release, live</h1>' "$(tr -d '\n' < "$LV/index.html")"
want_in "a converging pace is a date"                   'pace ok">Shrinking 3/day</span><span>At this pace: <b>' "$r"
want_in "eight days of added and done, today last"      '(class="day[^"]*".*){8}' "$r"
want_in "and today's line reads from the same counts"   '^today=.*<b>2</b> done.*<b>1</b> new.*List shrinking by 1' "$r"
want_in "merged per day as a line"                      '<polyline points=.*28 in the last seven days · 8 today' "$r"
trend_fixture 6 2
s=$(BRANCH_PREFIX=tkt- snap)
want "a growing list: no date"                          "-4 false null" "$(printf '%s' "$s" | jq -r '.launch | "\(.burn) \(.converging) \(.eta)"')"
r=$(page_render "$LV")
want_in "it says not converging, in red"                'pace bad">Not converging: \+4/day' "$r"
want_not_in "and never shows a date"                    'At this pace' "$r"

echo "--- the pace is one call of counts, kept fifteen minutes, after launch left out ---"
rm -f "$TREND"; : > "$FIX/board-gh.log"
SERVER_MJS="$SERVER_URLPATH" node --input-type=module -e '
  import { pathToFileURL } from "node:url"
  const { trendDays } = await import(pathToFileURL(process.env.SERVER_MJS).href)
  const data = { base: { issueCount: 9 } }
  trendDays().forEach((d, i) => { data["a" + i] = { issueCount: 1 }; data["d" + i] = { issueCount: 3 }; data["m" + i] = { issueCount: 2 } })
  console.log(JSON.stringify({ data }))' > "$FIX/trend-answer.json"
s=$(gsnap)
want "one call"                                          "1" "$(grep -c 'base: search' "$FIX/board-gh.log")"
want_in "done and added both leave after launch out"     'reason:completed closed:[^ ]+ -label:\\"after-launch\\".*created:[^ ]+ -label:\\"after-launch\\"|created:[^ ]+ -label:\\"after-launch\\".*reason:completed closed:[^ ]+ -label:\\"after-launch\\"' "$(grep 'base: search' "$FIX/board-gh.log")"
want "kept, and read back"                               "9 2" "$(jq -r '"\(.doneSinceBase) \(.days[0].done - .days[0].added)"' "$TREND")"
: > "$FIX/board-gh.log"; gsnap >/dev/null
want "a fresh pace is not read again"                    "0" "$(grep -c 'base: search' "$FIX/board-gh.log")"

echo "--- planted: the pace rules removed are seen ---"
trend_fixture 6 2
plant server.mjs "  const converging = burn != null && burn > 0" "  const converging = burn != null"
got=$(psnap | jq -r '.launch.eta')
[ "$got" != "null" ] && ok "planted: no converging rule → a growing list gets a date ($got) → red" || bad "planted: the converging rule deleted and the test cannot see it"
plant server.mjs '  const not = `-label:"${label}"`' '  const not = ``'
rm -f "$TREND"; : > "$FIX/board-gh.log"; SNAP_GH="$FIX/board-gh" psnap >/dev/null
[ "$(grep 'base: search' "$FIX/board-gh.log" | grep -c 'after-launch')" = 0 ] \
  && ok "planted: after launch left in the pace → the query no longer names it → red" || bad "planted: after launch left in and the test cannot see it"
rm -f "$BOARD" "$TREND" "$STATE/swarm/prs.json" "$STATE"/runs/claim-1113-a.json

exit $FAILED
