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
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture
# A pid that is certainly alive (this shell) and one that is certainly not.
# Taken BEFORE the cleanup trap is armed, deliberately: in bash 3.2 a background
# job inherits the EXIT trap, so `sleep 30 &` under the trap deletes the fixture
# out from under the suite the moment it is killed — every later case then reads
# an empty directory and the suite reports a machine with no agents as correct.
sleep 30 & DEAD=$!; kill "$DEAD" 2>/dev/null; wait "$DEAD" 2>/dev/null
on_exit_keep_status 'rm -rf "$FIX"'
SERVER="$HERE/../live-view/server.mjs"
SERVER_URLPATH="$SERVER"; command -v cygpath >/dev/null 2>&1 && SERVER_URLPATH=$(cygpath -m "$SERVER")
command -v node >/dev/null 2>&1 || { suite_skip "SKIP live-view: node is not on PATH"; }

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
want "and its run read as stopped" "stopped" "$(printf '%s' "$s" | jq -r '.done[0].lastRun')"

echo "--- a marker on a LIVE pid still means finished ---"
# The marker wins over the process: an agent that wrote its marker and has not
# yet exited is done, not running.
run 504 "$$" 0
s=$(snap)
want "not live"            "0" "$(printf '%s' "$s" | jq '[.live[] | select(.ticket=="504")] | length')"
want "its run ended, which is all a clean exit says" "ended" "$(printf '%s' "$s" | jq -r '.done[] | select(.ticket=="504") | .lastRun')"

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
echo "--- process fixes are listed first and counted ---"
cat > "$STATE/coordinator/queue.json" <<'JSON'
{"scope":"widgets","label":"project:widgets","tickets":[
 {"n":731,"class":"new","prin":0,"top":true,"note":""},
 {"n":732,"class":"repair","prin":1,"note":""},
 {"n":733,"class":"new","prin":3,"note":""},
 {"n":734,"class":"new","prin":3,"process":true,"note":""}]}
JSON
cat > "$STATE/coordinator/snapshot/issues.json" <<'JSON'
{"733":{"number":733,"state":"OPEN","labels":["status:ready","P3","process"]}}
JSON
s=$(snap)
want "process fixes first, from the labels or the queue's own flag, ahead of the PM's top" \
  "733 734 731 732" "$(printf '%s' "$s" | jq -r '[.queue.tickets[].ticket] | join(" ")')"
want "and the page's count of them" "2" "$(printf '%s' "$s" | jq '.queue.processFirst')"
want_in "the page draws the line"  'Process fixes first: \$\{np\}' "$(cat "$HERE/../live-view/index.html")"
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
want "a plain pause lets nothing through" "null" "$(printf '%s' "$s" | jq -r '.hold.allows')"
printf 'quiet night, for process fixes (held 2026-10-16T09:00Z by tester)\n' > "$STATE/swarm/HOLD"
s=$(SWARM_HOLD_MS=0 snap)
want "a pause for process fixes says it lets them through" "process" "$(printf '%s' "$s" | jq -r '.hold.allows')"
printf 'testing the banner (held 2026-10-16T09:00Z by tester)\n' > "$STATE/swarm/HOLD"
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
a = "  gathering = true\n  runChild('progress', process.execPath, [PROGRESS_JS, '--gather', JSON.stringify(args)],"
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, "  setTimeout(() => { try { keep(gatherProgress(args)) } catch {} }, 0); if (0) runChild('progress', process.execPath, [PROGRESS_JS, '--gather', JSON.stringify(args)],"))
PY
grep -q "if (0) runChild" "$P/server.mjs" || bad "plant: the child process is still in the copy"
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
want "exit 0, a PR reported, nothing read about it: no claim it merged" "Handed off PR #2001 — its state is not read yet" "$(now_of "$n" 1001)"
want "closed done"                               "Ticket closed as done" "$(now_of "$n" 1002)"
want "closed not planned: closed"                "Ticket closed"       "$(now_of "$n" 1003)"
want "closed completed, labels left behind: done" "Ticket closed as done" "$(now_of "$n" 1017)"
want "an open PR by its branch: its checks"      "Waiting for checks (none started yet)" "$(now_of "$n" 1004)"
want "an open PR by its closing reference"       "Waiting for checks (none started yet)" "$(now_of "$n" 1005)"
want "on the coordinator's queue"                "Back in the queue"   "$(now_of "$n" 1006)"
want "status:ready: back in the queue"           "Back in the queue"   "$(now_of "$n" 1007)"
want "a live run for the ticket: running again"  "Running again"       "$(now_of "$n" 1008)"
want "parked on a PM question"                   "Stopped: build asked a question — next: PM" "$(now_of "$n" 1009)"
want "status:pm-decision"                        "Stopped: waiting on a PM decision — next: PM" "$(now_of "$n" 1010)"
want "the owner's decision label"                "Stopped: waiting on the owner — next: the owner" "$(now_of "$n" 1011)"
want "blocked, by the ticket its park names"     "Stopped: blocked by #77 — next: #77 finishing" "$(now_of "$n" 1012)"
want "a driver park: stopped, with its one-line reason" "Stopped: build refused — next: machine fault" "$(now_of "$n" 1013)"
want "ready AND parked is not queued"            "Stopped: review answered in a shape the driver cannot read — next: machine fault" "$(now_of "$n" 1015)"
want "a stop with no park line names the marker's note" "Stopped: stopped on the owner pause — next: the queue" "$(now_of "$n" 1016)"
s=$(BRANCH_PREFIX=tkt- snap)
want "one row per ticket"                        "1" "$(printf '%s' "$s" | jq '[.done[] | select(.ticket=="1014")] | length')"
want "and it is the newest run"                  "0" "$(printf '%s' "$s" | jq '.done[] | select(.ticket=="1014") | .exit')"
want "the owner is named when the project names them" "Stopped: waiting on Dom — next: Dom" \
  "$(SWARM_OWNER_NAME=Dom BRANCH_PREFIX=tkt- snap | jq -r '.done[] | select(.ticket=="1011") | .now.text')"
want "only a true stop is red" "stopped" "$(printf '%s' "$s" | jq -r '[.done[] | select(.now.tone=="bad") | .now.state] | unique | join(" ")')"
want "the header counts by state" \
  "Finished: 2 waiting for checks · 1 running again · 2 back in queue · 2 waiting on PM · 1 waiting on the owner · 4 stopped · 2 closed as done · 1 closed · 1 not read yet · 1 no pull request" \
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
want_in "a true stop is red, with its reason and who moves it" 'pill bad">Stopped: build refused — next: machine fault</span><div class="note">build left no reason on the record' "$r"

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
plant server.mjs "  if (ctx.queued.has(t) || (ready && !parked)) return at('queue', 'Back in the queue')"
got=$(psnap | jq -r '.done[] | select(.ticket=="1006") | .now.text')
[ -n "$got" ] && [ "$got" != "Back in the queue" ] \
  && ok "planted: no queue rule → a queued ticket reads '$got' → red" || bad "planted: the queue rule deleted and the test cannot see it ($got)"
plant server.mjs "  for (const d of done) { const o = newest.get(d.ticket); if (!o || d.endedAt > o.endedAt) newest.set(d.ticket, d) }" \
  "  for (const d of done) newest.set(d.ticket + ':' + d.endedAt, d)"
got=$(psnap | jq '[.done[] | select(.ticket=="1014")] | length' 2>/dev/null)
[ "$got" != "1" ] && ok "planted: no de-duplication → $got rows for 1014 → red" || bad "planted: de-duplication deleted and the test cannot see it"
plant server.mjs "  if (open) return at(open.status ? open.status.state : 'checks'," "  if (false) return at(open.status ? open.status.state : 'checks',"
got=$(psnap | jq -r '.done[] | select(.ticket=="1004") | .now.text')
[ -n "$got" ] && [ "$got" != "Waiting for checks (none started yet)" ] \
  && ok "planted: no review rule → 1004 reads '$got' → red" || bad "planted: the review rule deleted and the test cannot see it ($got)"
plant index.html '      <td>${nowPill(d)}</td>'
[ "$(page_row "$P2" 1006 | grep -c 'Back in the queue')" = 0 ] \
  && ok "planted: the page drops the state → no 'Back in the queue' → red" || bad "planted: the page drops the state and the test cannot see it"
rm -f "$STATE/coordinator/queue.json" "$STATE/coordinator/snapshot/issues.json" "$STATE/swarm/prs.json"

echo "--- the release is the urgent and high-priority work, and the chips add up to what is left ---"
# Measured 2026-10-20: the page said "Release: 1,669 tickets" — every open ticket
# not labelled after-launch. Dom: "1k tickets which isn't right". The release was
# decided on 2026-10-18 (the launch-runway study): P0 and P1 only, less the
# after-launch label and the Post-launch, Mobile (fast-follow) and Echo phase 2
# milestones, less parked work and the containers; it came to 285.
rm -f "$STATE"/runs/claim-* "$STATE"/logs/claim-*
SINCE=$(node -e 'const d=new Date();d.setHours(0,0,0,0);console.log(d.toISOString().replace(/\.\d{3}Z$/,"Z"))')
BOARD="$STATE/swarm/board.json"
# Our own tooling, as the coordinator would be told it.
export SWARM_TOOLING_LABELS="repo:agent-harness code-health" SWARM_TOOLING_SCOPES="gates ci"
scope_json() { # [rows] — the scope a kept file must carry, in this environment, as JSON
  SERVER_MJS="$SERVER_URLPATH" KIND="${1:-}" node --input-type=module -e '
    import { pathToFileURL } from "node:url"
    const m = await import(pathToFileURL(process.env.SERVER_MJS).href)
    console.log(JSON.stringify(process.env.KIND === "rows" ? m.rowsKey() : m.scopeClause()))'
}
board_fixture() { # <since> [scope] — sixteen in the release, eleven outside it, one of each kind of wait
  # 1116-1118 carry the claimed label with no run anywhere (1118 also a claim on
  # this host, laptop): stale, so they sort by their other labels, not as building.
  local sc; sc=${2:-$(scope_json)}
  cat > "$BOARD" <<JSON
{"at":"$NOW_ISO","since":"$1","scope":$sc,"doneToday":6,"newToday":3,"mergedToday":4,
 "claims":[{"issue":"1114","host":"dom@studio-mac"},{"issue":"1113","host":"dom@laptop"},{"issue":"1118","host":"dom@laptop"}],
 "open":[
  {"number":1101,"title":"Ready one","labels":["status:ready","P1","repo:agent-harness"]},
  {"number":1102,"title":"Later ready","labels":["status:ready","after-launch","P1"]},
  {"number":1103,"title":"Later bare","labels":["after-launch","P1","status:needs-human"]},
  {"number":1104,"title":"In review","raw":"fix(gates): in review","labels":["status:in-review","P1"]},
  {"number":1105,"title":"Held and green","labels":["status:in-review","P1"]},
  {"number":1106,"title":"Held but red","labels":["status:in-review","P1"]},
  {"number":1107,"title":"Owner decides","labels":["needs:owner-decision","P0"]},
  {"number":1108,"title":"PM decides","raw":"feat(desk): PM decides","labels":["status:pm-decision","P1"]},
  {"number":1109,"title":"Drafting","labels":["status:drafting","P1"]},
  {"number":1110,"title":"Parked","labels":["status:parked","status:ready","P1"]},
  {"number":1111,"title":"Batched","labels":["status:batched","P1"]},
  {"number":1112,"title":"No status","labels":["P0"]},
  {"number":1113,"title":"Running here","labels":["status:ready","P1"]},
  {"number":1114,"title":"Claimed elsewhere","labels":["status:ready","P1"]},
  {"number":1115,"title":"Held and blocked","labels":["needs:human-approval","status:blocked","P1"]},
  {"number":1116,"title":"Stale claim, ready","labels":["status:claimed","status:ready","P1"]},
  {"number":1117,"title":"Stale claim, bare","labels":["status:claimed","P1"]},
  {"number":1118,"title":"Stale claim here","labels":["status:claimed","status:in-review","P1"]},
  {"number":1119,"title":"Three fixes","raw":"Batch: three fixes","labels":["status:ready","P1"]},
  {"number":1120,"title":"The platform","raw":"PROGRAMME(platform): the platform","labels":["P1","needs:data-model"]},
  {"number":1121,"title":"Watch","raw":"Watch","labels":["epic","status:in-review","P1"]},
  {"number":1122,"title":"Lower one","labels":["P2","status:ready"]},
  {"number":1123,"title":"Lower bare","labels":[]},
  {"number":1124,"title":"Later by milestone","labels":["P1","status:ready"],"milestone":"Post-launch"},
  {"number":1125,"title":"Mobile later","labels":["P0"],"milestone":"Mobile (fast-follow)"},
  {"number":1126,"title":"Parked urgent","labels":["P0","status:parked"]},
  {"number":1127,"title":"For the launch","labels":["P1"],"milestone":"v1.0 Launch"}]}
JSON
}
# The rows the scoped search counts that are not the release, read beside the trend
# and taken off it: wrappers (batch 901 made and done today, epic 902 on the first
# whole day) and a post-launch milestone (905, made and done today). The search never
# counted 903 (after launch), 904 (not planned), 906 (P2) or 907 (no priority), so
# none of them may come off.
WRAPPERS="$STATE/swarm/wrappers.json"
wrappers_fixture() { # [none]
  local sc; sc=$(scope_json rows)
  [ "${1:-}" = none ] && { printf '{"at":"%s","scope":%s,"issues":[]}\n' "$NOW_ISO" "$sc" > "$WRAPPERS"; return; }
  SERVER_MJS="$SERVER_URLPATH" NOW="$NOW_ISO" TODAY="$SINCE" node --input-type=module -e '
    import { pathToFileURL } from "node:url"
    const { trendDays, rowsKey } = await import(pathToFileURL(process.env.SERVER_MJS).href)
    const d0 = trendDays()[0].from, N = process.env.NOW, T = process.env.TODAY
    const row = (number, title, labels, createdAt, closedAt, stateReason = "COMPLETED", milestone = null) =>
      ({ number, title, labels, milestone, state: "CLOSED", stateReason, createdAt, closedAt })
    console.log(JSON.stringify({ at: N, scope: rowsKey(), issues: [
      row(901, "Batch: two fixes", ["P1"], T, N),
      row(902, "EPIC(time): the clock", ["P0"], d0, d0),
      row(903, "Batch: later", ["after-launch", "P1"], T, N),
      row(904, "A container", ["programme", "P1"], "2001-01-01T00:00:00Z", N, "NOT_PLANNED"),
      row(905, "Later work", ["P1"], T, N, "COMPLETED", "Post-launch"),
      row(906, "Lower later", ["P2"], T, N, "COMPLETED", "Post-launch"),
      row(907, "Batch: no priority", [], T, N)] }))' > "$WRAPPERS"
}
board_fixture "$SINCE"
wrappers_fixture
cat > "$STATE/swarm/prs.json" <<'JSON'
[{"number":2104,"title":"fix(gates): in review","headRefName":"tkt-1104/a","closingIssuesReferences":[],"labels":[],"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]},
 {"number":2105,"title":"feat(x): held and green","headRefName":"tkt-1105/a","closingIssuesReferences":[],"labels":[{"name":"needs:human-approval"}],"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]},
 {"number":2106,"title":"fix(y): held but red","headRefName":"tkt-1106/a","closingIssuesReferences":[],"labels":[{"name":"needs:human-approval"}],"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"FAILURE"}]},
 {"number":2107,"title":"chore: pick the plan","headRefName":"misc-a","closingIssuesReferences":[],"labels":[{"name":"needs:owner-decision"}],"mergeable":"MERGEABLE","statusCheckRollup":[]},
 {"number":2108,"title":"Your eyes on this","headRefName":"misc-b","closingIssuesReferences":[],"labels":[{"name":"status:needs-human"}],"mergeable":"MERGEABLE","statusCheckRollup":[]},
 {"number":2109,"title":"feat(db): a new table","headRefName":"misc-c","closingIssuesReferences":[],"labels":[{"name":"needs:data-model"}],"mergeable":"CONFLICTING","statusCheckRollup":[]}]
JSON
printf '{"run_id":"claim-1113-a","ticket":"1113","child_pid":%s,"started_at":"%s","operator":"dom@laptop","log":"%s"}\n' \
  "$$" "$NOW_ISO" "$STATE/logs/claim-1113-a.log" > "$STATE/runs/claim-1113-a.json"
printf 'build: writing the tests\n' > "$STATE/logs/claim-1113-a.log"
s=$(BRANCH_PREFIX=tkt- snap)
want "the release is P0 and P1 work, less post-launch, parked and the wrappers" "16" "$(printf '%s' "$s" | jq '.board.releaseLeft')"
want "outside it: lower priority, post-launch by label or milestone, wrappers, parked" \
  '{"lower":2,"post":4,"batch":1,"epic":2,"parked":2}' "$(printf '%s' "$s" | jq -c '.board.outside')"
want "the lower priorities it saw, named"                  '["P2","none"]' "$(printf '%s' "$s" | jq -c '.board.lowerPriorities')"
want "a milestone that is not post-launch stays in"        "1" "$(printf '%s' "$s" | jq '[.board.buckets[] | select(.key=="other") | .n] | add | if . == 3 then 1 else 0 end')"
want "left splits into product and our tooling, and they sum" "14 2 16" \
  "$(printf '%s' "$s" | jq -r '.board | "\(.product) \(.tooling) \(.product + .tooling)"')"
want "the wrapper rules are the project's to name"        "19 null" \
  "$(SWARM_WRAPPER_TITLE_PREFIXES= SWARM_WRAPPER_LABELS= BRANCH_PREFIX=tkt- snap | jq -c '"\(.board.releaseLeft) \(.board.outside.batch | if . == 0 then null else . end)"' | tr -d '"')"
want "a prefix of its own names the batch wrappers"       '{"batch":1,"epic":0}' \
  "$(SWARM_WRAPPER_TITLE_PREFIXES=programme SWARM_WRAPPER_LABELS= BRANCH_PREFIX=tkt- snap | jq -c '.board.outside | {batch, epic}')"
want "the priorities are the project's to name"           "2 20" \
  "$(board_fixture "$SINCE" "$(SWARM_RELEASE_PRIORITIES=P0 scope_json)"; SWARM_RELEASE_PRIORITIES=P0 BRANCH_PREFIX=tkt- snap | jq -r '"\(.board.releaseLeft) \(.board.outside.lower)"')"
want "so are the post-launch milestones"                  "17 3" \
  "$(board_fixture "$SINCE" "$(SWARM_POST_LAUNCH_MILESTONES='["Post-launch"]' scope_json)"; SWARM_POST_LAUNCH_MILESTONES='["Post-launch"]' BRANCH_PREFIX=tkt- snap | jq -r '"\(.board.releaseLeft) \(.board.outside.post)"')"
board_fixture "$SINCE"
echo "--- a wrapper is told by its own title's first word, or a label ---"
w=$(SERVER_MJS="$SERVER_URLPATH" node --input-type=module -e '
  import { pathToFileURL } from "node:url"
  const { wrapperOf } = await import(pathToFileURL(process.env.SERVER_MJS).href)
  console.log([["Batch: x", []], ["batch — x", []], ["Batching jobs runs twice", []], ["A batch of fixes", []],
    ["EPIC(access): x", []], ["Epic: x", []], ["PROGRAMME: x", []], ["Programmes page", []], ["Plain", ["epic"]],
    ["Plain", ["programme"]], ["Plain", ["status:batched"]]].map(([t, l]) => wrapperOf(t, l) || "-").join(" "))')
want "batch, epic and programme by title and label; a word that only starts the same is work" \
  "batch batch - - epic epic epic - epic epic -" "$w"
want "the chips add up to what is left"                  "16" "$(printf '%s' "$s" | jq '[.board.buckets[].n] | add')"
# Measured 2026-10-20: the chip said Building 10 beside "Building now · 5" — it
# counted the status:claimed label, which outlives the run that set it.
want "the building chip is live runs plus other hosts' claims, never a stale label" \
  "2" "$(printf '%s' "$s" | jq '[.board.buckets[] | select(.key=="building") | .n] | add')"
want "a stale claim sorts by its other labels" \
  "ready=2 building=2 review=3 pm=1 owner=3 stuck=1 batched=1 other=3" \
  "$(printf '%s' "$s" | jq -r '[.board.buckets[] | "\(.key)=\(.n)"] | join(" ")')"
want "today: merged, done, new and the delta, the off rows taken off" "4 4 1 3" "$(printf '%s' "$s" | jq -r '.board.today | "\(.merged) \(.done) \(.made) \(.delta)"')"
want "who is building where"                              "laptop:1 studio-mac:1" "$(printf '%s' "$s" | jq -r '[.hosts[] | "\(.host):\(.n)"] | sort | join(" ")')"
want "the after-launch label is the project's to name"    "17 3" \
  "$(board_fixture "$SINCE" "$(SWARM_AFTER_LAUNCH_LABEL=status:batched scope_json)"; SWARM_AFTER_LAUNCH_LABEL=status:batched BRANCH_PREFIX=tkt- snap | jq -r '"\(.board.releaseLeft) \(.board.outside.post)"')"
board_fixture "$SINCE" '"label:P0 -label:\"after-launch\""'
want "a board read under another scope is no count"       "null" "$(BRANCH_PREFIX=tkt- snap | jq '.board')"
board_fixture "2001-01-01T00:00:00Z"
want "yesterday's today counts say nothing"               "null" "$(BRANCH_PREFIX=tkt- snap | jq '.board.today')"
board_fixture "$SINCE"

echo "--- needs you is everything labelled for the owner: issues and pull requests ---"
# Dom, 2026-10-20: "Needs you is wrong too" — it listed only release tickets in the
# owner's bucket and dropped a held PR that was red. He wants "everything labelled for you".
want "every open issue and PR with an owner label, whatever else it is" \
  "issue:1103 issue:1107 issue:1115 issue:1120 pr:2105 pr:2106 pr:2107 pr:2108 pr:2109" \
  "$(printf '%s' "$s" | jq -r '[.board.needsYou[] | "\(.kind):\(.number)"] | join(" ")')"
want "each says what it waits on, in words" \
  "1103=Your input 1107=A decision 1115=A sign-off 1120=A data model to approve 2105=A sign-off 2107=A decision 2108=Your input 2109=A data model to approve" \
  "$(printf '%s' "$s" | jq -r '[.board.needsYou[] | select(.number != "2106") | "\(.number)=\(.why)"] | join(" ")')"
want "a PR is named by its plain title"                   "Pick the plan" "$(printf '%s' "$s" | jq -r '.board.needsYou[] | select(.number=="2107") | .title')"
want "the owner labels are the project's to name"         "pr:2107" \
  "$(SWARM_OWNER_LABELS="needs:owner-decision" BRANCH_PREFIX=tkt- snap | jq -r '[.board.needsYou[] | select(.kind=="pr") | "\(.kind):\(.number)"] | join(" ")')"

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
   "pageInfo":{"hasNextPage":true,"endCursor":"a"},"nodes":[{"number":1,"title":"fix(x): one","milestone":null,"labels":{"nodes":[{"name":"status:ready"},{"name":"P1"}]}},
   {"number":2,"title":"two","labels":{"nodes":[{"name":"after-launch"},{"name":"P1"}]}}]}}}},
 {"data":{"done":{"issueCount":7},"made":{"issueCount":1},"merged":{"issueCount":6},"repository":{"issues":{"totalCount":3,
   "pageInfo":{"hasNextPage":$1,"endCursor":"b"},"nodes":[{"number":3,"title":"three","milestone":{"title":"Post-launch"},"labels":{"nodes":[{"name":"P0"}]}}]}}}}]
JSON
}
gsnap() { SNAP_GH="$FIX/board-gh" BRANCH_PREFIX=tkt- snap; }
: > "$FIX/board-gh.log"
want "a fresh count is not read again"                    "0" "$(gsnap >/dev/null; grep -c 'api graphql --paginate' "$FIX/board-gh.log")"
rm -f "$BOARD"; pages true
s=$(gsnap)
want "a read that stopped part-way is not kept"           "null" "$(printf '%s' "$s" | jq '.board')"
rm -f "$BOARD"; pages false; : > "$FIX/board-gh.log"; wrappers_fixture none
s=$(gsnap)
want "one read of every open ticket"                      "1" "$(grep -c 'api graphql --paginate' "$FIX/board-gh.log")"
want_in "it reads each ticket's milestone"                'nodes\{number title createdAt milestone\{title\}' "$(tr '\n' ' ' < "$FIX/board-gh.log")"
want_in "and today's counts are of the release's scope"   'done=repo:acme/widgets is:issue is:closed reason:completed closed:>=[^ ]+ label:P0,P1 -label:"after-launch" -label:"status:parked"' "$(grep 'api graphql --paginate' "$FIX/board-gh.log")"
want "counted from both pages, the milestone read"        "1 2" "$(printf '%s' "$s" | jq -r '"\(.board.releaseLeft) \(.board.outside.post)"')"
want "with today's counts"                                "6 7 1" "$(printf '%s' "$s" | jq -r '.board.today | "\(.merged) \(.done) \(.made)"')"
want "and kept for the next ask"                          "One" "$(jq -r '.open[0].title' "$BOARD")"
want "with the forge's own title beside the plain one"    "fix(x): one" "$(jq -r '.open[0].raw' "$BOARD")"
want "and the milestone by title"                         "Post-launch" "$(jq -r '.open[2].milestone' "$BOARD")"
board_fixture "$SINCE"; wrappers_fixture

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
want_not_in "after launch is no chip: it is outside the release" 'data-k="after"' "$r"
want_in "what is outside the release, muted, with why"   'class="sub outside">Outside the release: 2 lower-priority \(P2/no priority\) · 4 post-launch · 3 wrappers · 2 parked</div>' "$r"
want_in "today, with the list shrinking"                  '^today=.*<b>4</b> merged.*List shrinking by 3' "$r"
want_in "a builder is one row with its step and time"     '^building=.*class="row build".*Running here.*[0-9]+ min running.*build: writing the tests' "$r"
want_in "needs you counts every row in its heading"       '^needshead=Needs you · 9$' "$r"
want_in "a PR row says what it waits on and links the PR" '^needs=.*Pick the plan.*A decision · pull request <a href="https://github.com/acme/widgets/pull/2107"' "$r"
want_in "an issue row links the issue"                    '^needs=.*Later bare.*Your input · <a href="https://github.com/acme/widgets/issues/1103"' "$r"
want_in "the machine line names the hosts, not a stale claim here" '^machine=.*Building on: laptop \(1\), studio-mac \(1\)' "$r"
want_not_in "the finished rows start folded"              '<details class="fold" id="donefold" open' "$(cat "$LV/index.html")"
# Dom, 2026-10-28: building first, then the queue of what starts next.
s0="$s"
s=$(printf '%s' "$s0" | jq '.queue = {tickets: [
  {ticket:"9001",class:"new",note:"",process:true,title:"Switch the pacer off"},
  {ticket:"9002",class:"repair",note:"",process:false,title:"Mend the campaign card"},
  {ticket:"9003",class:"new",note:"",process:false,title:"Voices learning tab"}]}
  | .live = (.live | map(.ticket = "9002"))')
r=$(page_render "$LV")
want_in "the queue heading counts what waits, not what builds" '^nexthead=Coming up next · 2$' "$r"
want_in "the queue keeps the coordinator's order"   '^next=.*>1</span>.*Switch the pacer off.*Process fix.*>2</span>.*Voices learning tab' "$r"
want_not_in "a ticket building now is not also next" '^next=.*Mend the campaign card' "$r"
page_one=$(tr -d '\n' < "$LV/index.html")
case "$page_one" in *'id="buildinghead"'*'id="nexthead"'*'id="headline"'*) ok "building comes first, the queue under it, then the rest" ;; *) bad "the page does not open on building then the queue" ;; esac
P3="$FIX/lv-next"; mkdir -p "$P3"; cp "$LV"/*.mjs "$LV"/index.html "$P3/"
sed -i.bak "s/  document.getElementById('next').innerHTML = nx.html/  document.getElementById('next').innerHTML = ''/" "$P3/index.html"
grep -q "getElementById('next').innerHTML = ''" "$P3/index.html" || bad "the queue plant did not land"
[ "$(page_render "$P3" | grep -c '^next=.*Voices learning tab')" = 0 ] \
  && ok "planted: the queue left undrawn → red" || bad "planted: the queue left undrawn and the test cannot see it"
s="$s0"
jq '.open |= map(.labels -= ["needs:owner-decision", "needs:human-approval", "status:needs-human", "needs:data-model"])' "$BOARD" > "$BOARD.t" && mv "$BOARD.t" "$BOARD"
rm -f "$STATE/swarm/prs.json"
s=$(BRANCH_PREFIX=tkt- snap)
want_in "nothing labelled for the owner says so"          '^needs=<div class="allclear">Nothing needs you' "$(page_render "$LV")"

echo "--- the machine line shows free disk, red under the guard's floor ---"
# Owner call 2026-10-20: under 30 GB nothing new starts, and the page says so where the machine is.
s=$(SWARM_FREE_DISK_GB=12 SWARM_DISK_HOLD_FILE="$FIX/disk-hold" BRANCH_PREFIX=tkt- snap)
want "the snapshot carries the disk, low"                 "12 30 50 true" "$(printf '%s' "$s" | jq -r '.disk | "\(.freeGb) \(.stopBelowGb) \(.resumeAtGb) \(.low)"')"
want_in "under the floor the line is red, and says nothing new starts" '^machine=.*<span class="disklow">12 GB disk free — under 30 GB, nothing new starts</span>' "$(page_render "$LV")"
: > "$FIX/disk-hold"
s=$(SWARM_FREE_DISK_GB=40 SWARM_DISK_HOLD_FILE="$FIX/disk-hold" BRANCH_PREFIX=tkt- snap)
want_in "over the floor but still held: amber, with the resume mark" '^machine=.*<span class="diskheld">40 GB disk free — starts resume at 50 GB</span>' "$(page_render "$LV")"
rm -f "$FIX/disk-hold"
s=$(SWARM_FREE_DISK_GB=80 SWARM_DISK_HOLD_FILE="$FIX/disk-hold" BRANCH_PREFIX=tkt- snap)
r=$(page_render "$LV")
want_in "plenty free: the plain figure"                   '^machine=.* · 80 GB disk free · ' "$r"
want_not_in "and never red"                               'disklow|diskheld' "$r"
s=$(SWARM_DISK_HOLD_FILE="$FIX/disk-hold" BRANCH_PREFIX=tkt- snap)
want_in "unplanted, the real volume is read"              '^[0-9]+$' "$(printf '%s' "$s" | jq -r '.disk.freeGb')"
echo "--- WSL: the machine line shows the lower of Linux and the Windows drive, and which ---"
s=$(SWARM_FREE_DISK_GB=831 SWARM_DISK_HOST_PATH=/mnt/c SWARM_HOST_FREE_DISK_GB=37 SWARM_DISK_HOLD_FILE="$FIX/disk-hold" BRANCH_PREFIX=tkt- snap)
want "the snapshot takes the host's 37, not Linux's 831"  "37" "$(printf '%s' "$s" | jq -r '.disk.freeGb')"
want_in "and the line says where"                         '^machine=.* · 37 GB disk free on the Windows host \(Linux shows 831\) · ' "$(page_render "$LV")"
s=$(SWARM_FREE_DISK_GB=831 SWARM_DISK_HOST_PATH=/mnt/c SWARM_HOST_FREE_DISK_GB=12 SWARM_DISK_HOLD_FILE="$FIX/disk-hold" BRANCH_PREFIX=tkt- snap)
want_in "12 on the host: red, though Linux shows 831"     '<span class="disklow">12 GB disk free on the Windows host \(Linux shows 831\) — under 30 GB' "$(page_render "$LV")"
s=$(SWARM_FREE_DISK_GB=80 SWARM_DISK_HOST_PATH= SWARM_HOST_FREE_DISK_GB=12 SWARM_DISK_HOLD_FILE="$FIX/disk-hold" BRANCH_PREFIX=tkt- snap)
want "no host drive named: Linux's figure, no where"      "80 null" "$(printf '%s' "$s" | jq -r '.disk | "\(.freeGb) \(.where)"')"
grep -q '^\.disklow{color:var(--bad)' "$LV/index.html" && ok "the low figure is drawn in the page's red" || bad "the low figure has no red rule"

echo "--- product and tooling are told the way the coordinator tells them ---"
# One rule, two readers: the page's split must say what coord_tooling says.
CASES='[[["repo:agent-harness"],"x"],[[],"fix(gates): x"],[[],"Fix(CI)!: x"],[[],"feat(desk): x"],[[],"gates: x"],
 [["area:OPS-CONSOLE"],""],[["area:ops"],"y"],[[],"feat(dev): x"],[[],"feat(gates)x"],[["code-health","P1"],"feat(desk): y"]]'
JQ_SAYS=$(env -u SWARM_TOOLING_LABELS -u SWARM_TOOLING_SCOPES bash -c '. "$1/scripts/coordinator-env.sh" >/dev/null 2>&1 || exit 1
  coord_jq -r "$COORD_TICKET_JQ"'"'"'[.[] | if coord_tooling(.[0]; .[1]) then "1" else "0" end] | join(" ")'"'"' <<<"$2"
  printf "%s\t%s\n" "$COORD_TOOLING_LABELS" "$COORD_TOOLING_SCOPES" > "$3"' _ "$HERE/../.." "$CASES" "$FIX/coord-lists")
JS_SAYS=$(SWARM_TOOLING_LABELS="$(cut -f1 "$FIX/coord-lists")" SWARM_TOOLING_SCOPES="$(cut -f2 "$FIX/coord-lists")" \
  SERVER_MJS="$SERVER_URLPATH" CASES="$CASES" node --input-type=module -e '
  import { pathToFileURL } from "node:url"
  const { toolingOf } = await import(pathToFileURL(process.env.SERVER_MJS).href)
  console.log(JSON.parse(process.env.CASES).map(([l, t]) => (toolingOf(l, t) ? "1" : "0")).join(" "))')
want "the coordinator's rule, on its own lists"           "1 1 1 0 0 1 0 1 0 1" "$JQ_SAYS"
want "the page's rule says the same of every case"        "$JQ_SAYS" "$JS_SAYS"
echo "--- live-view.sh hands the page the project's rules, the tooling lists from the coordinator ---"
CFG2="$FIX/cfg-later.json"
jq '.swarm = {postLaunchMilestones: ["Later list", "Some day"], releasePriorities: ["P0"]}' "$HARNESS_CFG_PATH" > "$CFG2"
rules() { # <kit root> — the rules a --print snapshot was counted under
  env -u SWARM_TOOLING_LABELS -u SWARM_TOOLING_SCOPES HARNESS_CFG_PATH="$CFG2" COORDINATOR_TOOLING_LABELS="lab-a lab-b" COORDINATOR_TOOLING_SCOPES="sc" \
    bash "$1/swarm/live-view.sh" --print 2>/dev/null | jq -c '.rules | [.priorities, .postLaunchMilestones, .toolingLabels, .toolingScopes, .ownerLabels]'
}
want "priorities, milestones, tooling and owner labels"   '[["P0"],["Later list","Some day"],["lab-a","lab-b"],["sc"],["needs:owner-decision","status:needs-human","needs:data-model","needs:human-approval"]]' \
  "$(rules "$HERE/../..")"
KIT2="$FIX/kit-plant"; mkdir -p "$KIT2"; cp -R "$HERE/../../swarm" "$HERE/../../scripts" "$KIT2/"
python3 - "$KIT2/swarm/live-view.sh" <<'PY' || bad "plant did not land: live-view.sh tooling lists"
import sys
p = sys.argv[1]; s = open(p).read(); a = 'SWARM_TOOLING_LABELS="${SWARM_TOOLING_LABELS:-$COORD_TOOLING_LABELS}"'
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, 'SWARM_TOOLING_LABELS="${SWARM_TOOLING_LABELS:-}"'))
PY
got=$(rules "$KIT2" | jq -c '.[2]')
[ "$got" != '["lab-a","lab-b"]' ] && ok "planted: the coordinator's tooling labels not handed on → the page reads $got → red" \
  || bad "planted: the tooling labels not handed on and the test cannot see it"

echo "--- planted: each rule removed is seen ---"
board_fixture "$SINCE"
cat > "$STATE/swarm/prs.json" <<'JSON'
[{"number":2105,"title":"feat(x): held and green","headRefName":"tkt-1105/a","closingIssuesReferences":[],"labels":[{"name":"needs:human-approval"}],"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}]},
 {"number":2106,"title":"fix(y): held but red","headRefName":"tkt-1106/a","closingIssuesReferences":[],"labels":[{"name":"needs:human-approval"}],"mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"FAILURE"}]},
 {"number":2109,"title":"feat(db): a new table","headRefName":"misc-c","closingIssuesReferences":[],"labels":[{"name":"needs:data-model"}],"mergeable":"MERGEABLE","statusCheckRollup":[]}]
JSON
left() { psnap | jq '.board.releaseLeft'; }
plant server.mjs "export const postLaunch = (labels, milestone) => (labels || []).includes(AFTER_LAUNCH) || POST_LAUNCH_MILESTONES.includes(msTitle(milestone))" \
  "export const postLaunch = (labels, milestone) => (labels || []).includes(AFTER_LAUNCH)"
got=$(left); [ "$got" != "16" ] && ok "planted: no post-launch milestones → the release reads $got → red" || bad "planted: the milestone rule deleted and the test cannot see it"
plant server.mjs "export const postLaunch = (labels, milestone) => (labels || []).includes(AFTER_LAUNCH) || POST_LAUNCH_MILESTONES.includes(msTitle(milestone))" \
  "export const postLaunch = (labels, milestone) => POST_LAUNCH_MILESTONES.includes(msTitle(milestone))"
got=$(left); [ "$got" != "16" ] && ok "planted: no after-launch label → the release reads $got → red" || bad "planted: the after-launch rule deleted and the test cannot see it"
plant server.mjs "  if (!releasePriority(labels)) return 'lower'"
got=$(left); [ "$got" != "16" ] && ok "planted: no priority rule → the release reads $got → red" || bad "planted: the priority rule deleted and the test cannot see it"
plant server.mjs "  if (labels.includes(PARKED)) return 'parked'"
got=$(left); [ "$got" != "16" ] && ok "planted: parked counted → the release reads $got → red" || bad "planted: the parked rule deleted and the test cannot see it"
plant server.mjs "  if (w) return w"
got=$(left); [ "$got" != "16" ] && ok "planted: wrappers counted as work → the release reads $got → red" || bad "planted: the wrapper rule deleted and the test cannot see it"
plant server.mjs "    const r = releaseOf(i.raw ?? i.title, labels, i.milestone)" "    const r = releaseOf(i.title, labels, i.milestone)"
got=$(left); [ "$got" != "16" ] && ok "planted: the plain title read → the release reads $got → red" || bad "planted: the plain title read and the test cannot see it"
plant server.mjs "    if (toolingOf(labels, i.raw ?? i.title)) tooling++"
got=$(psnap | jq -r '.board | "\(.product) \(.tooling)"'); [ "$got" != "14 2" ] && ok "planted: no tooling count → the split reads $got → red" || bad "planted: the tooling count deleted and the test cannot see it"
plant server.mjs "  return TOOLING_SCOPES.includes(m ? m[1].toLowerCase() : '')" "  return false"
got=$(psnap | jq -r '.board.tooling'); [ "$got" != "2" ] && ok "planted: no title scope → tooling reads $got → red" || bad "planted: the title-scope rule deleted and the test cannot see it"
plant server.mjs "  if (!board || !Array.isArray(board.open) || board.scope !== scopeClause()) return null" "  if (!board || !Array.isArray(board.open)) return null"
board_fixture "$SINCE" '"label:P0 -label:\"after-launch\""'
got=$(psnap | jq -c '.board.releaseLeft'); board_fixture "$SINCE"
[ "$got" != "null" ] && ok "planted: no scope check → an old board counts $got → red" || bad "planted: the board's scope check deleted and the test cannot see it"
needs() { psnap | jq -r '[.board.needsYou[] | "\(.kind):\(.number)"] | join(" ")'; }
want "needs you, before the plants"                       "issue:1103 issue:1107 issue:1115 issue:1120 pr:2105 pr:2106 pr:2109" "$(needs)"
plant server.mjs "  for (const p of Array.isArray(prs) ? prs : []) if (p && p.number != null) add('pr', p.number, plainTitle(p.title), labelNames(p.labels))"
got=$(needs); [ "$got" != "issue:1103 issue:1107 issue:1115 issue:1120 pr:2105 pr:2106 pr:2109" ] && ok "planted: no PRs → needs you reads '$got' → red" || bad "planted: the PR rows deleted and the test cannot see it"
plant server.mjs "  LBL('LBL_NEEDS_HUMAN', 'status:needs-human'), 'needs:data-model', LBL('HOLD_LABEL', 'needs:human-approval')])" \
  "  LBL('LBL_NEEDS_HUMAN', 'status:needs-human'), LBL('HOLD_LABEL', 'needs:human-approval')])"
got=$(needs); [ "$got" != "issue:1103 issue:1107 issue:1115 issue:1120 pr:2105 pr:2106 pr:2109" ] && ok "planted: no data-model label → needs you reads '$got' → red" || bad "planted: the data-model label deleted and the test cannot see it"
plant server.mjs "  if (ownerWait && !(pr && pr.red)) return 'owner'"
got=$(psnap | jq '[.board.buckets[] | select(.key=="owner") | .n] | add')
[ "$got" != "3" ] && ok "planted: no owner rule → the owner chip reads $got → red" || bad "planted: the owner rule deleted and the test cannot see it"
plant server.mjs "  if (!last || !last.pageInfo || last.pageInfo.hasNextPage !== false) return null"
rm -f "$BOARD"; pages true
got=$(SNAP_GH="$FIX/board-gh" psnap | jq '.board.releaseLeft')
[ "$got" != "null" ] && ok "planted: no short-read guard → a part read counts $got → red" || bad "planted: the short-read guard deleted and the test cannot see it"
board_fixture "$SINCE"
s=$(BRANCH_PREFIX=tkt- snap)
plant index.html "  document.getElementById('headline').innerHTML = headline(s.board, s.launch)"
[ "$(page_render "$P2" | grep -c 'Release progress')" = 0 ] \
  && ok "planted: the page drops the headline → no 'Release progress' → red" || bad "planted: the page drops the headline and the test cannot see it"
plant index.html "    <div class=\"sub\">\${esc(n.why)} · \${n.kind === 'pr' ? \`pull request \${ticketLink(n.number, 'pull')}\` : ticketLink(n.number)}</div></div></div>\`" \
  "    <div class=\"sub\">\${esc(n.why)} · \${ticketLink(n.number)}</div></div></div>\`"
[ "$(page_render "$P2" | grep -c 'pull/2109')" = 0 ] \
  && ok "planted: a PR row links as an issue → no pull link → red" || bad "planted: the PR link dropped and the test cannot see it"
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
    const { trendDays, scopeClause } = await import(pathToFileURL(process.env.SERVER_MJS).href)
    const ds = trendDays(), last = ds.length - 1
    // The raw search counts: what the page shows plus the off rows 901 and 905 (today) and 902 (day 0).
    const w = (i) => (i === 0 ? 1 : i === last ? 2 : 0)
    console.log(JSON.stringify({ at: new Date().toISOString(), base: "2026-10-13", scope: scopeClause(), doneSinceBase: 40,
      days: ds.map((d, i) => ({ day: d.day, added: (i === last ? 1 : +process.env.A) + w(i), done: (i === last ? 2 : +process.env.D) + w(i), merged: i + 1 })) }))' > "$TREND"
}
board_fixture "$SINCE"
trend_fixture 2 5
s=$(BRANCH_PREFIX=tkt- snap)
want "done and still open make the whole"               "37 16 53" "$(printf '%s' "$s" | jq -r '.launch | "\(.done) \(.open) \(.total)"')"
want "the bar is done of the whole"                     "69.8" "$(printf '%s' "$s" | jq '.launch.pct')"
want "the open side is the release's own left"          "16" "$(printf '%s' "$s" | jq '.launch.open')"
want "and it splits into product and tooling that sum"  "14 2 16" "$(printf '%s' "$s" | jq -r '.launch | "\(.product) \(.tooling) \(.product + .tooling)"')"
want "burn is done less added over the whole days"      "3 true" "$(printf '%s' "$s" | jq -r '.launch | "\(.burn) \(.converging)"')"
ETA=$(node -e 'const d=new Date();d.setDate(d.getDate()+6);console.log(`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`)')
want "at this pace: sixteen left at three a day is six days" "$ETA" "$(printf '%s' "$s" | jq -r '.launch.eta')"
want "today is today's own counts"                      "1 2" "$(printf '%s' "$s" | jq -r '.launch.today | "\(.added) \(.done)"')"
want "a whole day's wrapper comes off its added and done" "2 5" "$(printf '%s' "$s" | jq -r '.launch.days[0] | "\(.added) \(.done)"')"
want "no wrappers read is no release"                     "null" "$(rm -f "$WRAPPERS"; SWARM_REPO= BRANCH_PREFIX=tkt- SNAP_GH=false snap | jq '.launch')"
wrappers_fixture
want "a pace read under another scope is no release"    "null" \
  "$(jq '.scope = "label:P0"' "$TREND" > "$TREND.t" && mv "$TREND.t" "$TREND"; SWARM_REPO= BRANCH_PREFIX=tkt- SNAP_GH=false snap | jq '.launch')"
trend_fixture 2 5
r=$(page_render "$LV")
want_in "the big number is the release: done plus left" '^headline=<div class="ptitle">Release progress</div><div class="big">Release: 53 <small>tickets</small></div>' "$r"
want_in "then the bar: done, left, share"               'width:69.8%.*<b>37</b> done · <b>16</b> left · <b>69.8%</b>.*Added and done, per day.*Pull requests merged' "$r"
want_in "under it, left split into product and our tooling" '<b>69.8%</b>.*Left: Product <b>14</b> · Our tooling <b>2</b>.*Outside the release:' "$r"
want "the chips add up to the bar's left"               "$(printf '%s' "$s" | jq '.launch.open')" "$(printf '%s' "$s" | jq '[.board.buckets[].n] | add')"
# Dom, 2026-10-20: "it's 1669; this is a screen for the release" — big numbers still read.
s=$(printf '%s' "$s" | jq '.launch |= (.done = 410 | .open = 1259 | .total = 1669 | .pct = 24.6 | .product = 1100 | .tooling = 159)')
r=$(page_render "$LV")
want_in "the release in big numbers"                    'Release: 1,669 <small>tickets</small>.*<b>410</b> done · <b>1,259</b> left · <b>24.6%</b>.*Product <b>1,100</b> · Our tooling <b>159</b>' "$r"
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

echo "--- the pace is one call of counts, kept fifteen minutes, of the release's own scope ---"
rm -f "$TREND"; : > "$FIX/board-gh.log"
SERVER_MJS="$SERVER_URLPATH" node --input-type=module -e '
  import { pathToFileURL } from "node:url"
  const { trendDays } = await import(pathToFileURL(process.env.SERVER_MJS).href)
  const data = { base: { issueCount: 9 } }
  trendDays().forEach((d, i) => { data["a" + i] = { issueCount: 1 }; data["d" + i] = { issueCount: 3 }; data["m" + i] = { issueCount: 2 } })
  console.log(JSON.stringify({ data }))' > "$FIX/trend-answer.json"
s=$(gsnap)
want "one call"                                          "1" "$(grep -c 'base: search' "$FIX/board-gh.log")"
want_in "done and added both count only the release's scope" \
  'reason:completed closed:[^ ]+ label:P0,P1 -label:\\"after-launch\\" -label:\\"status:parked\\".*created:[^ ]+ label:P0,P1 -label:\\"after-launch\\" -label:\\"status:parked\\"' "$(grep 'base: search' "$FIX/board-gh.log")"
# Measured 2026-10-20: the forge's search honours only the first -milestone: of a
# query, so the milestones must never be left to it.
want_not_in "and never ask the search to leave milestones out" '-milestone:' "$(grep 'base: search' "$FIX/board-gh.log")"
want "kept, and read back"                               "9 2" "$(jq -r '"\(.doneSinceBase) \(.days[0].done - .days[0].added)"' "$TREND")"
: > "$FIX/board-gh.log"; gsnap >/dev/null
want "a fresh pace is not read again"                    "0" "$(grep -c 'base: search' "$FIX/board-gh.log")"

echo "--- planted: the pace rules removed are seen ---"
trend_fixture 6 2
plant server.mjs "  const converging = burn != null && burn > 0" "  const converging = burn != null"
got=$(psnap | jq -r '.launch.eta')
[ "$got" != "null" ] && ok "planted: no converging rule → a growing list gets a date ($got) → red" || bad "planted: the converging rule deleted and the test cannot see it"
plant server.mjs "export function trendArgs(repo, now = Date.now(), base = PROGRESS_SINCE, scope = scopeClause()) {" \
  "export function trendArgs(repo, now = Date.now(), base = PROGRESS_SINCE, scope = '') {"
rm -f "$TREND"; : > "$FIX/board-gh.log"; SNAP_GH="$FIX/board-gh" psnap >/dev/null
[ "$(grep 'base: search' "$FIX/board-gh.log" | grep -c 'label:P0,P1')" = 0 ] \
  && ok "planted: the scope left out of the pace → the query no longer names it → red" || bad "planted: the pace's scope left out and the test cannot see it"
plant server.mjs "  if (trend.scope !== scopeClause() || wrappers.scope !== rowsKey()) return null"
trend_fixture 2 5; jq '.scope = "label:P0"' "$TREND" > "$TREND.t" && mv "$TREND.t" "$TREND"
got=$(SWARM_REPO= SNAP_GH=false psnap | jq -c '.launch.total'); trend_fixture 2 5
[ "$got" != "null" ] && ok "planted: no scope check → an old pace counts $got → red" || bad "planted: the pace's scope check deleted and the test cannot see it"

echo "--- the off rows are one search per prefix, per label and per milestone, kept with the pace ---"
cat > "$FIX/board-gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/board-gh.log"
case "$*" in *"wrappers: search"*) cat "$FIX/wrapper-pages.json" ;; *"issues(states:OPEN"*) cat "$FIX/board-pages.json" ;; *) cat "$FIX/trend-answer.json" 2>/dev/null ;; esac
SH
chmod +x "$FIX/board-gh"
wpages() { # <hasNextPage on the last page> [issueCount]
  cat > "$FIX/wrapper-pages.json" <<JSON
[{"data":{"wrappers":{"issueCount":${2:-3},"pageInfo":{"hasNextPage":true,"endCursor":"a"},"nodes":[
   {"number":71,"title":"Batch: two fixes","state":"CLOSED","stateReason":"COMPLETED","createdAt":"$SINCE","closedAt":"$NOW_ISO","labels":{"nodes":[]}},
   {"number":72,"title":"A batch of fixes","state":"OPEN","createdAt":"$SINCE","labels":{"nodes":[]}}]}}},
 {"data":{"wrappers":{"issueCount":${2:-3},"pageInfo":{"hasNextPage":$1,"endCursor":"b"},"nodes":[
   {"number":73,"title":"Watch","state":"OPEN","createdAt":"$SINCE","labels":{"nodes":[{"name":"epic"}]}},
   {"number":74,"title":"Later work","state":"OPEN","createdAt":"$SINCE","milestone":{"title":"Mobile (fast-follow)"},"labels":{"nodes":[{"name":"P1"}]}},
   {"number":75,"title":"Plain work","state":"OPEN","createdAt":"$SINCE","milestone":{"title":"v1.0 Launch"},"labels":{"nodes":[{"name":"P1"}]}}]}}}]
JSON
}
rm -f "$WRAPPERS"; wpages false; : > "$FIX/board-gh.log"
s=$(gsnap)
want "one search for each prefix, each label and each milestone" "8" "$(grep -c 'wrappers: search' "$FIX/board-gh.log")"
want_in "each a whole-word title, a label, or a milestone in the release's scope" \
  'is:issue in:title "Batch".*is:issue in:title "PROGRAMME".*is:issue in:title "EPIC".*is:issue label:"epic".*is:issue label:"programme".*is:issue milestone:"Post-launch" label:P0,P1 -label:"after-launch".*milestone:"Mobile \(fast-follow\)".*milestone:"Echo phase 2 — Bodyguard \+ Sedric parity"' \
  "$(tr '\n' ' ' < "$FIX/board-gh.log")"
want "kept: only the wrappers and the post-launch rows"  "71 73 74" "$(jq -r '[.issues[].number] | join(" ")' "$WRAPPERS")"
: > "$FIX/board-gh.log"; gsnap >/dev/null
want "a fresh read is not read again"                    "0" "$(grep -c 'wrappers: search' "$FIX/board-gh.log")"
rm -f "$WRAPPERS"; wpages true; gsnap >/dev/null
want "a read that stopped part-way is not kept"          "no" "$([ -f "$WRAPPERS" ] && echo yes || echo no)"
rm -f "$WRAPPERS"; wpages false 1001; gsnap >/dev/null
want "a search past the forge's cap is not kept"         "no" "$([ -f "$WRAPPERS" ] && echo yes || echo no)"

echo "--- planted: the off-row rules removed are seen ---"
board_fixture "$SINCE"; wrappers_fixture; trend_fixture 2 5
plant server.mjs "  const done = Math.max(0, trend.doneSinceBase - wrappersIn(wrappers, 'done', Date.parse(baseStart(trend.base)), Infinity))" \
  "  const done = trend.doneSinceBase"
got=$(psnap | jq '.launch.done')
[ "$got" != "37" ] && ok "planted: closed off rows counted as done → done reads $got → red" || bad "planted: closed off rows counted as done and the test cannot see it"
plant server.mjs "    return { ...d, added: Math.max(0, d.added - wrappersIn(wrappers, 'added', from, to))," "    return { ...d, added: d.added,"
got=$(psnap | jq -r '.launch.days[0].added')
[ "$got" != "2" ] && ok "planted: new wrappers counted as added → day 0 reads $got → red" || bad "planted: new wrappers counted as added and the test cannot see it"
plant server.mjs "  return w.issues.filter((i) => searchScope(i.labels) && (wrapperOf(i.title, i.labels) || postLaunchMilestone(i.milestone))" \
  "  return w.issues.filter((i) => searchScope(i.labels) && (wrapperOf(i.title, i.labels))"
got=$(psnap | jq -r '.launch.today.done')
[ "$got" != "2" ] && ok "planted: post-launch rows left on the counts → today done reads $got → red" || bad "planted: post-launch rows left on and the test cannot see it"
plant server.mjs "  return w.issues.filter((i) => searchScope(i.labels) && (wrapperOf(i.title, i.labels) || postLaunchMilestone(i.milestone))" \
  "  return w.issues.filter((i) => (wrapperOf(i.title, i.labels) || postLaunchMilestone(i.milestone))"
got=$(psnap | jq -r '.launch.today.done')
[ "$got" != "2" ] && ok "planted: rows the search never counted taken off → today done reads $got → red" || bad "planted: unsearched rows taken off and the test cannot see it"
plant server.mjs "      : i.state === 'CLOSED' && i.stateReason === 'COMPLETED' && inside(i.closedAt))).length" "      : inside(i.closedAt))).length"
got=$(psnap | jq -r '.launch.today.done')
[ "$got" != "2" ] && ok "planted: a not-planned wrapper taken off done → today done reads $got → red" || bad "planted: not-planned wrappers taken off and the test cannot see it"
plant server.mjs "  if (!board || !trend || !Array.isArray(trend.days) || !wrappers || !Array.isArray(wrappers.issues)) return null" \
  "  if (!board || !trend || !Array.isArray(trend.days)) return null"
# The scope check reads the wrappers too; with the guard gone it must not be the one that refuses.
python3 - "$P2/server.mjs" <<'PY2' || bad "plant did not land: the wrappers' scope check"
import sys
p = sys.argv[1]; s = open(p).read(); a = "trend.scope !== scopeClause() || wrappers.scope !== rowsKey()"
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, "trend.scope !== scopeClause() || (wrappers && wrappers.scope !== rowsKey())"))
PY2
cp "$WRAPPERS" "$FIX/wrappers.keep"; rm -f "$WRAPPERS"
got=$(SWARM_REPO= SNAP_GH=false psnap | jq -c '.launch.total')
cp "$FIX/wrappers.keep" "$WRAPPERS"
[ "$got" != "null" ] && ok "planted: no wrappers read still counts → the release reads $got → red" || bad "planted: the no-wrappers guard deleted and the test cannot see it"
plant server.mjs "      if (!s || !Array.isArray(s.nodes) || !Number.isInteger(s.issueCount) || s.issueCount > SEARCH_CAP) return null" \
  "      if (!s || !Array.isArray(s.nodes)) return null"
rm -f "$WRAPPERS"; wpages false 1001; SNAP_GH="$FIX/board-gh" psnap >/dev/null
[ -f "$WRAPPERS" ] && ok "planted: no search-cap guard → a capped read is kept → red" || bad "planted: the search-cap guard deleted and the test cannot see it"
plant server.mjs "          ...milestones.map((m) => \`milestone:\${quoted(m)} \${scopeClause()}\`)]" "          ]"
rm -f "$WRAPPERS"; wpages false; : > "$FIX/board-gh.log"; SNAP_GH="$FIX/board-gh" psnap >/dev/null
[ "$(grep -c 'wrappers: search' "$FIX/board-gh.log")" != 8 ] && ok "planted: no milestone searches → the post-launch rows are never read → red" || bad "planted: the milestone searches deleted and the test cannot see it"
wrappers_fixture
s=$(BRANCH_PREFIX=tkt- snap)
plant index.html '    <div class="pline"><span><b>${num(l.done)}</b> done · <b>${num(l.open)}</b> left · <b>${esc(l.pct)}%</b></span><span class="sub">counted since ${esc(dateName(l.base))}</span></div>${splitLine(l)}</div>${outsideLine(b)}`' \
  '    <div class="pline"><span><b>${num(l.done)}</b> done · <b>${num(l.open)}</b> left · <b>${esc(l.pct)}%</b></span><span class="sub">counted since ${esc(dateName(l.base))}</span></div>${splitLine(l)}</div>`'
[ "$(page_render "$P2" | grep -c 'Outside the release:')" = 0 ] \
  && ok "planted: the page drops the outside line → none shown → red" || bad "planted: the outside line dropped and the test cannot see it"
plant server.mjs "  return { base: trend.base, done, open, product: board.product, tooling: board.tooling, total, pct: total ? Math.round((done * 1000) / total) / 10 : 0," \
  "  return { base: trend.base, done, open, total, pct: total ? Math.round((done * 1000) / total) / 10 : 0,"
s=$(psnap)
[ "$(page_render "$P2" | grep -c 'Our tooling')" = 0 ] \
  && ok "planted: the split not served → the page shows none → red" || bad "planted: the split not served and the test cannot see it"
rm -f "$BOARD" "$TREND" "$WRAPPERS" "$STATE/swarm/prs.json" "$STATE"/runs/claim-1113-a.json

echo "--- a repair run shows its own step, not the earlier build's last one ---"
# Measured 2026-10-20 18:40Z: a repair of a green PR read "step 7 of 7 · Merged"
# while it was in self-check — the bar was read from the build and the PR.
rm -f "$STATE"/runs/claim-* "$STATE"/logs/claim-*
run 1301 "$$"
pcache() { # <driver record> — what the progress refresh last read for 1301
  printf '{"tickets":{"1301":{"claim":true,"branch":"tkt-1301/a","commits":3,"pushed":true,"trailers":["UI-Gate: SHIP"],"stampsReviews":true,"prRead":true,"pr":{"number":2301,"state":"OPEN","fail":0,"pending":0},"driver":%s}},"plans":{}}\n' "$1" > "$STATE/swarm/progress.json"
}
rsnap() { SWARM_PROGRESS_MS=999999999999999 BRANCH_PREFIX=tkt- snap; }
pcache '{"mode":"build","done":["start","plan","build","self-check","review","ship"]}'
want "a finished build waiting to merge is at its last step" "7 Merged" \
  "$(rsnap | jq -r '.live[] | select(.ticket=="1301") | .progress | "\(.step) \(.steps[.step - 1].name)"')"
pcache '{"mode":"repair","done":["start","plan","build","reenter","repair","fix"]}'
s=$(rsnap)
want "a repair after that build, in self-check, is at its check" "4 of 7 Check true" \
  "$(printf '%s' "$s" | jq -r '.live[] | select(.ticket=="1301") | .progress | "\(.step) of \(.of) \(.steps[.step - 1].name) \(.repair)"')"
want_in "and the page says so"                            '^building=.*Repair · 4 of 7 · <b>Checking</b>' "$(page_render "$LV")"
pcache '{"done":["start","plan","build","reenter"]}'
want "a reenter with no mode on record is a repair too"    "2 Repair" \
  "$(rsnap | jq -r '.live[] | select(.ticket=="1301") | .progress | "\(.step) \(.steps[.step - 1].name)"')"
pcache '{"mode":"repair","done":["start","plan","build","reenter","repair","fix"]}'
plant progress.mjs "  if (!(driver && (driver.mode === 'repair' || done.includes('reenter')))) return p" "  return p"
got=$(SWARM_PROGRESS_MS=999999999999999 psnap | jq -r '.live[] | select(.ticket=="1301") | .progress.step')
[ "$got" != "4" ] && ok "planted: the repair read from the build → step $got → red" || bad "planted: the repair's own step dropped and the test cannot see it"
rm -f "$STATE/swarm/progress.json" "$STATE"/runs/claim-1301-a.json

echo "--- another machine's builds show beside this one's, each with its machine ---"
# Measured 2026-10-20: the page listed 4 builds, all on this Mac, while the claim
# list held 8 — 4 on the Windows VM. A view of shared work read only local runs.
rm -f "$STATE"/runs/claim-* "$STATE"/logs/claim-* "$STATE/swarm/claims.json" "$STATE/swarm/board.json"
run 1401 "$$"
AGO=$(node -e 'console.log(new Date(Date.now() - 20 * 60000).toISOString().replace(/\.\d{3}Z$/, "Z"))')
cat > "$BIN/claims-lock" <<SH
#!/usr/bin/env bash
cat <<'JSON'
[{"issue":1401,"host":"laptop","agent":"dom@laptop","step":"build","claimed_at":"$AGO"},
 {"issue":1402,"host":"studio-mac","agent":"dom@studio-mac","step":"fix","claimed_at":"$AGO"},
 {"issue":1403,"host":"laptop","agent":"dom@laptop","step":"build"},
 {"issue":1404,"host":"studio-mac","agent":"dom@studio-mac"}]
JSON
SH
chmod +x "$BIN/claims-lock"
printf '{"1401":{"title":"Local build","project":""},"1402":{"title":"Remote fix","project":""},"1404":{"title":"Remote bare","project":""}}' > "$FIX/titles.json"
csnap() { SWARM_CLAIM_LOCK="$BIN/claims-lock" BRANCH_PREFIX=tkt- snap; }
s=$(csnap)
want "this machine's count is still its own runs"          "1" "$(printf '%s' "$s" | jq '.live | length')"
want "the other machine's claims are rows, a local one once, a stale one never" "1402 1404" \
  "$(printf '%s' "$s" | jq -r '[.elsewhere[].ticket] | join(" ")')"
want "each with its machine, title and claim step"         "studio-mac Remote fix fix" \
  "$(printf '%s' "$s" | jq -r '.elsewhere[] | select(.ticket=="1402") | "\(.host) \(.title) \(.claimStep)"')"
want "progress and activity absent, not invented"          "null null null 20" \
  "$(printf '%s' "$s" | jq -r '.elsewhere[] | select(.ticket=="1402") | "\(.progress) \(.quietSec) \(.steps) \(.startedAgoMin)"')"
want "the local row names its machine too"                 "laptop" "$(printf '%s' "$s" | jq -r '.live[0].host')"
r=$(page_render "$LV")
want_in "the heading counts both machines"                 '^buildinghead=Building now · 3$' "$r"
want_in "the local row says it is this machine"            '^building=.*Local build.*This machine \(laptop\) · ' "$r"
want_in "the remote row says where, and its step"          '^building=.*Remote fix.*On studio-mac · <b>Fixing</b> · claimed 20 min ago' "$r"
want_in "a claim with no step or time still renders"       '^building=.*Remote bare.*<div class="step">On studio-mac</div>' "$r"
want_not_in "nothing absent reads as a value"              '^building=.*(undefined|NaN|null)' "$r"
plant index.html "  const building = [...s.live, ...(s.elsewhere || [])]" "  const building = [...s.live]"
[ "$(page_render "$P2" | grep '^building=' | grep -c 'studio-mac')" = 0 ] \
  && ok "planted: the page drops the merge → no remote row → red" || bad "planted: the page drops the merge and the test cannot see it"
plant server.mjs "    seen.add(c.issue)" "    continue"
rm -f "$STATE/swarm/claims.json"
got=$(SWARM_CLAIM_LOCK="$BIN/claims-lock" psnap | jq '.elsewhere | length')
[ "$got" != "2" ] && ok "planted: the server drops the merge → $got remote rows → red" || bad "planted: the server drops the merge and the test cannot see it"
rm -f "$STATE"/runs/claim-1401-a.json "$STATE/swarm/claims.json" "$FIX/titles.json"

echo "--- the REAL claim-lock list reaches the page, under the env the page runs with ---"
# Measured 2026-10-21: 0.7.135 served elsewhere: [] beside 3 claims on the Windows
# VM. `claim-lock list` printed every claim and exited 1, the page took the exit
# as a failure, and claims.json was never written. A hand-made fixture exited 0.
CLS="$FIX/claim-sandbox"; mkdir -p "$CLS/bin" "$CLS/state"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CLS/bin/gh"; chmod +x "$CLS/bin/gh"
real_claims() { # <scripts dir> — a real claim taken and the page's snapshot of it
  ( for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
    unset CLAIM_RUN_ID HARNESS_STATE_DIR
    export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@test.local GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@test.local
    export HARNESS_CFG_PATH="$CLS/work/.claude/harness.json" PATH="$CLS/bin:$PATH"
    rm -rf "$CLS/origin.git" "$CLS/work" "$STATE/swarm/claims.json"
    git init -q --bare -b main "$CLS/origin.git"
    git clone -q "$CLS/origin.git" "$CLS/work" 2>/dev/null
    mkdir -p "$CLS/work/.claude"
    sed "s#/nonexistent-must-be-overridden#$CLS/state#; s#\"develop\"#\"main\"#" "$REPO/.claude/harness.json" > "$HARNESS_CFG_PATH"
    git -C "$CLS/work" add -f .claude/harness.json && git -C "$CLS/work" commit -qm init && git -C "$CLS/work" push -q origin main
    CLAIM_REPO="$CLS/work" bash "$1/claim-lock.sh" acquire 1501 --branch tkt-1501/x --worktree "$CLS/wt" --pid $$ >/dev/null 2>&1 \
      || echo "the sandbox claim was not taken" >&2
    # The page's own wiring: the real script, the queue's clone as CLAIM_REPO, and a
    # host name of its own so this machine's claim reads as another machine's.
    SWARM_CLAIM_LOCK="$1/claim-lock.sh" SWARM_QUEUE_REPO="$CLS/work" SNAP_HOST=page-host BRANCH_PREFIX=tkt- snap )
}
CLAIM_HOST=$(bash -c '. "$1/claim-proc.sh"; claim_host' _ "$HERE/../../scripts" 2>/dev/null)
s=$(real_claims "$HERE/../../scripts")
want "the real list's claim is a row, with the host it was taken on" "1501 $CLAIM_HOST" \
  "$(printf '%s' "$s" | jq -r '[.elsewhere[]? | "\(.ticket) \(.host)"] | join(" ")')"
want "and its step is absent, not invented"                "null" \
  "$(printf '%s' "$s" | jq -r '.elsewhere[]? | select(.ticket=="1501") | .claimStep')"
want "the list it read is kept for the next refresh"       "1501" \
  "$(jq -r '[.claims[].issue] | join(" ")' "$STATE/swarm/claims.json" 2>/dev/null)"
# Plant: the listing's old ending, a bare test as its last command, back in a copy.
CP="$FIX/scripts-plant"; rm -rf "$CP"; cp -R "$HERE/../../scripts" "$CP"
python3 - "$CP/claim-lock.sh" <<'PY' || bad "plant did not land"
import sys
p = sys.argv[1]; s = open(p).read()
a = 'if [ -n "$legacy" ]; then while IFS= read -r n; do\n      jq -r'
b = 'done <<<"$legacy"; fi\n  fi\n}'
if s.count(a) != 1 or s.count(b) != 1: sys.exit(1)
s = s.replace(a, '[ -n "$legacy" ] && while IFS= read -r n; do\n      jq -r').replace(b, 'done <<<"$legacy"\n  fi\n}')
a = 'if [ -n "$legacy" ]; then while IFS= read -r n; do\n        jq -c'
b = 'done <<<"$legacy"; fi\n    } | jq'
if s.count(a) != 1 or s.count(b) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, '[ -n "$legacy" ] && while IFS= read -r n; do\n        jq -c').replace(b, 'done <<<"$legacy"\n    } | jq'))
PY
grep -qF 'if [ -n "$legacy" ]' "$CP/claim-lock.sh" && bad "plant: the listing still ends on an if"
got=$(real_claims "$CP" | jq '[.elsewhere[]?] | length')
[ "$got" = "0" ] && ok "planted: the list exits 1 again → $got remote rows → red" || bad "planted: the list exits 1 and the test cannot see it ($got)"
rm -rf "$CP" "$CLS" "$STATE/swarm/claims.json"

echo "--- by area: open tickets grouped by the project's sections, tooling and the rest apart ---"
# Dom, 2026-10-23: "update the tracker so I can see all this properly, per area".
areas() { # <server.mjs> [sections json]
  local secs='[{"label":"section:pulse","name":"Pulse"},{"label":"section:one-desk","name":"One Desk"}]'
  SWARM_SECTIONS="${2-$secs}" \
    SWARM_RELEASE_PRIORITIES="P0 P1" SWARM_TOOLING_LABELS="repo:agent-harness" SERVER_MJS="$1" node --input-type=module -e '
  import { pathToFileURL } from "node:url"
  const { areasOf } = await import(pathToFileURL(process.env.SERVER_MJS).href)
  const board = { claims: [], open: [
    { number: 1, title: "a", labels: ["section:pulse", "P1", "status:ready"] },
    { number: 2, title: "b", labels: ["section:one-desk", "P0", "status:blocked"] },
    { number: 3, title: "c", labels: ["section:pulse", "P3", "status:ready"] },
    { number: 4, title: "d", labels: ["repo:agent-harness", "P1"] },
    { number: 5, title: "e", labels: ["P1", "status:ready"] },
    { number: 6, title: "f", labels: ["section:pulse", "P1", "status:ready"] } ] }
  const a = areasOf(board, { prRows: {}, live: new Set(["6"]), liveHosts: [] })
  console.log(a ? a.groups.map((g) => g.name + "=" + g.rows.map((r) => r.number + r.bucket[0]).join(",")).join(";") : "null")' 2>/dev/null
}
want "each section its own group, building first, tooling and the rest apart" \
  "Pulse=6b,1r,3l;One Desk=2s;Tooling=4o;Other=5r" "$(areas "$SERVER_URLPATH")"
want "no sections set: no block"                          "null" "$(areas "$SERVER_URLPATH" '[]')"
plant server.mjs "    const g = toolingOf(labels, i.raw ?? i.title) ? '__tooling' : (sections.find((s) => labels.includes(s.label)) || { label: '__other' }).label" \
  "    const g = (sections.find((s) => labels.includes(s.label)) || { label: '__other' }).label"
got=$(areas "$P2/server.mjs")
[ "$got" != "Pulse=6b,1r,3l;One Desk=2s;Tooling=4o;Other=5r" ] && ok "planted: tooling not split out → $got → red" || bad "planted: the tooling split deleted and the test cannot see it"
want_not_in "the page no longer has the By area block"   'id="areas"' "$(cat "$LV/index.html")"

suite_end "$FAILED"
