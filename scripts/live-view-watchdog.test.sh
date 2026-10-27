#!/usr/bin/env bash
# live-view-watchdog.test.sh — a live view that is up and answers nothing is
# restarted after two failed probes in a row; a healthy one is never touched.
#
# Measured 2026-10-20: alive for 1h41m, every request timed out, and launchd,
# which restarts a job only when it exits, left it there.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture
SERVERS="$FIX/servers"; : > "$SERVERS"
on_exit_keep_status 'for p in $(cat "$SERVERS" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done; rm -rf "$FIX"'
command -v node >/dev/null 2>&1 || { suite_skip "SKIP live-view-watchdog: node is not on PATH"; }
WD="$HERE/live-view-watchdog.sh"
# The fixture's curl answers from a file; the probe here is against a real socket.
export SWARM_CURL=$(PATH=$(getconf PATH):/usr/local/bin:/opt/homebrew/bin command -v curl)
export COORDINATOR_SHADOW=0 LIVE_VIEW_PROBE_SEC=1 HOME="$FIX/home"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$BIN/launchctl" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FIX/launchctl.log"
# A restart: the hung process goes, as launchd's -k would take it.
[ "$1" = kickstart ] && kill -9 "$(cat "$FIX/hung.pid")" 2>/dev/null
exit 0
SH
chmod +x "$BIN/launchctl"
export LIVE_VIEW_LAUNCHCTL="$BIN/launchctl"

# start <hung|healthy> — a server on a free port; sets PORT and SRV_PID.
start() {
  local pf="$FIX/port-$RANDOM"
  MODE="$1" PORT_FILE="$pf" node -e "
    const http = require('http'), fs = require('fs')
    const s = http.createServer((req, res) => { if (process.env.MODE === 'healthy') res.end('{}') })
    s.listen(0, '127.0.0.1', () => fs.writeFileSync(process.env.PORT_FILE, String(s.address().port)))
    setTimeout(() => process.exit(0), 60000)" &
  SRV_PID=$!; disown "$SRV_PID" 2>/dev/null; echo "$SRV_PID" >> "$SERVERS"
  local i; for i in $(seq 1 50); do [ -s "$pf" ] && break; sleep 0.1; done
  PORT=$(cat "$pf"); export SWARM_LIVE_URL="http://127.0.0.1:$PORT/api/agents"
}
tick() { bash "$WD" 2>&1; }
fresh() { rm -f "$STATE/swarm/live-view.fails" "$FIX/launchctl.log" "$FIX/started"; rm -f "$HOME/Library/LaunchAgents/"*; }
LABEL=$(bash -c '. "$1/../swarm/swarm-env.sh" >/dev/null 2>&1; swarm_job_label live-view' _ "$HERE")

echo "--- the label is the one install.sh gives the job ---"
want "same label" "$LABEL" "$(bash "$HERE/../swarm/install.sh" --print live-view 2>/dev/null | sed -n 's|.*<key>Label</key><string>\(.*\)</string>.*|\1|p')"

echo "--- macOS: a server that never answers is kickstarted after the second probe ---"
fresh; : > "$HOME/Library/LaunchAgents/$LABEL.plist"
start hung; echo "$SRV_PID" > "$FIX/hung.pid"
export SWARM_UNAME=Darwin
out=$(tick)
want "one failed probe restarts nothing" "" "$(cat "$FIX/launchctl.log" 2>/dev/null)"
want_in "and says so" 'no answer .* \(1 of 2\)' "$out"
out=$(tick)
want "the second kickstarts the job" "kickstart -k gui/$(id -u)/$LABEL" "$(cat "$FIX/launchctl.log" 2>/dev/null)"
want_in "and logs it" "restarted $LABEL" "$out"
want_in "as an action" "restart-live-view" "$(cat "$STATE/coordinator/actions.log" 2>/dev/null)"
sleep 0.3; kill -0 "$SRV_PID" 2>/dev/null && bad "the hung server is still up" || ok "the hung server is gone"

echo "--- macOS: a healthy server is untouched ---"
fresh; : > "$HOME/Library/LaunchAgents/$LABEL.plist"
start healthy
tick >/dev/null; tick >/dev/null; out=$(tick)
want "three answered probes, no restart" "" "$(cat "$FIX/launchctl.log" 2>/dev/null)"
want "nothing counted" "no" "$([ -f "$STATE/swarm/live-view.fails" ] && echo yes || echo no)"
kill -0 "$SRV_PID" 2>/dev/null && ok "the healthy server is still up" || bad "the healthy server was stopped"

echo "--- one miss between answers is not two in a row ---"
fresh; : > "$HOME/Library/LaunchAgents/$LABEL.plist"
start hung; HUNG=$SWARM_LIVE_URL; start healthy; GOOD=$SWARM_LIVE_URL
SWARM_LIVE_URL=$HUNG tick >/dev/null; SWARM_LIVE_URL=$GOOD tick >/dev/null; SWARM_LIVE_URL=$HUNG tick >/dev/null
want "miss, answer, miss: no restart" "" "$(cat "$FIX/launchctl.log" 2>/dev/null)"

echo "--- shadow says it would, and does nothing ---"
fresh; : > "$HOME/Library/LaunchAgents/$LABEL.plist"
start hung
COORDINATOR_SHADOW=1 tick >/dev/null; out=$(COORDINATOR_SHADOW=1 tick)
want "no kickstart in shadow" "" "$(cat "$FIX/launchctl.log" 2>/dev/null)"
want_in "it says it would" 'would restart' "$out"

echo "--- a job this machine never installed is not bounced ---"
fresh; start hung
tick >/dev/null; out=$(tick)
want "no plist, no kickstart" "" "$(cat "$FIX/launchctl.log" 2>/dev/null)"
want_in "named" "no $LABEL installed" "$out"

echo "--- off launchd: the recorded pid is killed and the live view started again ---"
fresh; start hung; echo "$SRV_PID" > "$STATE/swarm/live-view.pid"
export SWARM_UNAME=Linux LIVE_VIEW_START="echo started >> '$FIX/started'"
tick >/dev/null
kill -0 "$SRV_PID" 2>/dev/null && ok "one miss leaves it running" || bad "one miss killed it"
out=$(tick); sleep 0.5
kill -0 "$SRV_PID" 2>/dev/null && bad "the second miss left the hung pid alive" || ok "the second miss kills the recorded pid"
want "and starts it again" "started" "$(cat "$FIX/started" 2>/dev/null)"
want_in "logged" "killed $SRV_PID and started it again" "$out"
# A supervisor that is running starts it itself: the watchdog only kills.
fresh; start hung; echo "$SRV_PID" > "$STATE/swarm/live-view.pid"; echo "$$" > "$STATE/swarm/supervisor.pid"
tick >/dev/null; out=$(tick); sleep 0.5
want "with a supervisor up, nothing else is started" "" "$(cat "$FIX/started" 2>/dev/null)"
want_in "it is left to the supervisor" "the supervisor \($$\) starts it again" "$out"
rm -f "$STATE/swarm/supervisor.pid"

echo "--- the default probe waits 5 s ---"
fresh; start hung
t0=$(date +%s); LIVE_VIEW_PROBE_SEC= bash -c 'unset LIVE_VIEW_PROBE_SEC; bash "$0"' "$WD" >/dev/null 2>&1; t1=$(date +%s)
s=$((t1 - t0)); { [ "$s" -ge 4 ] && [ "$s" -le 9 ]; } && ok "one probe took ${s}s" || bad "one probe took ${s}s, wanted about 5"

echo "--- a healthy live view on an older kit is restarted onto the installed one ---"
CUR=$(jq -r .version "$HERE/../.claude-plugin/plugin.json")
# start_kit <version> — a healthy server whose command line is that kit's server.mjs.
start_kit() {
  local f="$FIX/cache/agent-harness/$1/swarm/live-view/server.mjs" pf="$FIX/port-$RANDOM"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'JS'
import http from 'node:http'
import fs from 'node:fs'
const s = http.createServer((req, res) => res.end('{}'))
s.listen(0, '127.0.0.1', () => fs.writeFileSync(process.env.PORT_FILE, String(s.address().port)))
setTimeout(() => process.exit(0), 60000)
JS
  PORT_FILE="$pf" node "$f" &
  SRV_PID=$!; disown "$SRV_PID" 2>/dev/null; echo "$SRV_PID" >> "$SERVERS"
  local i; for i in $(seq 1 50); do [ -s "$pf" ] && break; sleep 0.1; done
  export SWARM_LIVE_URL="http://127.0.0.1:$(cat "$pf")/api/agents"
  echo "$SRV_PID" > "$STATE/swarm/live-view.pid"; echo "$SRV_PID" > "$FIX/hung.pid"
}
export SWARM_UNAME=Darwin; unset LIVE_VIEW_START
fresh; : > "$HOME/Library/LaunchAgents/$LABEL.plist"; rm -f "$STATE/coordinator/actions.log"
start_kit 0.0.1
out=$(tick)
want "one probe kickstarts it" "kickstart -k gui/$(id -u)/$LABEL" "$(cat "$FIX/launchctl.log" 2>/dev/null)"
want_in "naming both kits" "running 0.0.1, installed $CUR — restarted $LABEL" "$out"
want_in "as an action" "restart-live-view.*running 0.0.1" "$(cat "$STATE/coordinator/actions.log" 2>/dev/null)"
fresh; : > "$HOME/Library/LaunchAgents/$LABEL.plist"
start_kit "$CUR"; tick >/dev/null; tick >/dev/null
want "on the installed kit, never" "" "$(cat "$FIX/launchctl.log" 2>/dev/null)"
fresh; : > "$HOME/Library/LaunchAgents/$LABEL.plist"
start_kit 0.0.1; out=$(COORDINATOR_SHADOW=1 tick)
want "shadow restarts nothing" "" "$(cat "$FIX/launchctl.log" 2>/dev/null)"
want_in "and says it would" "running 0.0.1, installed $CUR — would restart" "$out"
# Off launchd a supervisor restarts it from the supervisor's own kit: bouncing it would loop.
fresh; export SWARM_UNAME=Linux LIVE_VIEW_START="echo started >> '$FIX/started'"; echo "$$" > "$STATE/swarm/supervisor.pid"
start_kit 0.0.1; tick >/dev/null; sleep 0.3
kill -0 "$SRV_PID" 2>/dev/null && ok "under a supervisor it is left alone" || bad "under a supervisor it was killed"
rm -f "$STATE/swarm/supervisor.pid"
fresh; start_kit 0.0.1; tick >/dev/null; sleep 0.5
kill -0 "$SRV_PID" 2>/dev/null && bad "off launchd with no supervisor the old kit stayed up" || ok "off launchd with no supervisor the old kit is killed"
want "and started again on this kit" "started" "$(cat "$FIX/started" 2>/dev/null)"

echo "--- planted: the kit check deleted, the old kit is never restarted ---"
P="$FIX/wd-stale-plant.sh"; cp "$WD" "$P"
python3 - "$P" <<'PY' || bad "plant did not land"
import sys
p = sys.argv[1]; s = open(p).read()
a = 'rm -f "$LV_FAILS_FILE"; live_view_stale; return 0'
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, 'rm -f "$LV_FAILS_FILE"; return 0'))
PY
export SWARM_UNAME=Darwin; unset LIVE_VIEW_START
fresh; : > "$HOME/Library/LaunchAgents/$LABEL.plist"; start_kit 0.0.1
bash -c '. "$1/coordinator-env.sh" && . "$2" && live_view_watchdog' _ "$HERE" "$P" >/dev/null 2>&1
[ -z "$(cat "$FIX/launchctl.log" 2>/dev/null)" ] && ok "planted: no kit check → no restart → red" \
  || bad "planted: the kit check removed and it was still restarted → the test cannot see it"
export SWARM_UNAME=Linux LIVE_VIEW_START="echo started >> '$FIX/started'"

echo "--- planted: the restart deleted, the hung server is never restarted ---"
P="$FIX/wd-plant.sh"; cp "$WD" "$P"
python3 - "$P" <<'PY' || bad "plant did not land"
import sys
p = sys.argv[1]; s = open(p).read()
a = '  if lv_restart "$why"; then'
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, '  if false; then'))
PY
fresh; start hung; echo "$SRV_PID" > "$STATE/swarm/live-view.pid"
pt() { bash -c '. "$1/coordinator-env.sh" && . "$2" && live_view_watchdog' _ "$HERE" "$P" >/dev/null 2>&1; }
pt; pt; sleep 0.5
want "the planted copy ran both probes" 2 "$(cat "$STATE/swarm/live-view.fails" 2>/dev/null)"
kill -0 "$SRV_PID" 2>/dev/null && [ ! -s "$FIX/started" ] && ok "planted: no restart → hung server still up → red" \
  || bad "planted: the restart removed and the server was still restarted → the test cannot see it"

suite_end "$FAILED"
