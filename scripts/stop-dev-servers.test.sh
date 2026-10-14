#!/usr/bin/env bash
# Fixture test for stop-dev-servers.sh — stand-in server processes in fake
# worktrees, one case per rule the sweep must hold, and --worktree.
#
# The stand-ins are `sleep`, renamed with `exec -a` so `ps` shows them as a
# Next.js server or its launcher, started with their working directory in the
# fixture. The sweep is handed the fixture's claim list and branch prefix; no
# real claim or server is ever a candidate, because every real one lives outside
# this test's temp directory and none is named like its ticket folders.
set -uo pipefail

SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stop-dev-servers.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }
command -v lsof >/dev/null || { echo "  SKIP — no lsof"; exit 0; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }

T=$(cd "$(mktemp -d)" && pwd -P)
PIDS=()
# Plus anything still sitting in $T: a stand-in's orphaned worker is ours too.
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  for p in $(lsof -a -d cwd -Fpn 2>/dev/null | awk -v t="$T/" '/^p/{p=substr($0,2)} /^n/{if (index(substr($0,2) "/", t) == 1) print p}'); do kill "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT

# Output goes nowhere: a stand-in holding the $(...) pipe would make the capture
# wait for the whole sleep.
serve() { mkdir -p "$1"; (cd "$1" && exec -a next-server sleep 600) >/dev/null 2>&1 & echo $!; }
# A launcher named <name> in <dir> whose child is a stand-in server. Prints "<launcher> <server>".
launch() {
  mkdir -p "$2"
  # The launcher starts its server, then BECOMES a sleep under its own name: it
  # outlives its child on its own (so a launcher gone afterwards was stopped, not
  # left with nothing to wait for) and has no other child sitting in the worktree.
  (cd "$2" && exec bash -c '(exec -a next-server sleep 600) & exec -a "$0" sleep 600' "$1") >/dev/null 2>&1 &
  local l=$! s=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do s=$(pgrep -P "$l" 2>/dev/null | head -1); [ -n "$s" ] && break; sleep 0.2; done
  echo "$l $s"
}
# Alive and not a zombie: a stand-in parent that became a bare `sleep` never
# reaps its stopped child, which then lingers as <defunct> — stopped all the same.
alive() { kill -0 "$1" 2>/dev/null && ! ps -o stat= -p "$1" 2>/dev/null | grep -q Z; }
sweep() { STOP_DEV_BRANCH_PREFIX=tk- STOP_DEV_CLAIMED="$1" STOP_DEV_MIN_AGE="$2" bash "$SUT" --sweep ${3:-}; }

echo "stop-dev-servers: sweep"
free=$(serve "$T/tk-101-free/apps/api");        PIDS+=("$free")
held=$(serve "$T/tk-102-held/apps/web");        PIDS+=("$held")
mine=$(serve "$T/tk-develop-view/apps/web");    PIDS+=("$mine")   # a preview: no ticket number
own=$(serve "$T/my-checkout/apps/web");         PIDS+=("$own")    # the owner's own checkout
busy=$(serve "$T/tk-104-busy/apps/web");        PIDS+=("$busy")
mkdir -p "$T/tk-104-busy/apps"; (cd "$T/tk-104-busy/apps" && exec bash -c 'sleep 600') >/dev/null 2>&1 &
occ=$!; PIDS+=("$occ")                                           # somebody's shell sits in tk-104
read -r lnch lsrv <<<"$(launch "npm exec next start" "$T/tk-105-launched/apps/web")"; PIDS+=("$lnch" "$lsrv")
read -r agent asrv <<<"$(launch "claude --name claim-next" "$T/tk-106-agent/apps/web")"; PIDS+=("$agent" "$asrv")
# A real Next server runs workers in its own folder: they are the server's, not somebody.
worker_srv=$( (mkdir -p "$T/tk-108-workers/apps/web"; cd "$T/tk-108-workers/apps/web" && exec -a next-server bash -c '(exec -a turbopack-worker sleep 600) & exec -a next-server sleep 600') >/dev/null 2>&1 & echo $!)
PIDS+=("$worker_srv")
# /claim names the folder without the prefix when the ticket was given as digits.
bare=$(serve "$T/109-bare-digits/apps/web"); PIDS+=("$bare")
sleep 1
CLAIMED=$(printf '102\n999\n')

sweep "$CLAIMED" 3600 >/dev/null
alive "$free" && ok "a server younger than the minimum age is kept" || fail "a young server was stopped"

out=$(sweep "$CLAIMED" 0 --dry-run)
{ alive "$free" && printf '%s' "$out" | grep -q "would stop $free"; } \
  && ok "--dry-run names the abandoned server and stops nothing" || fail "--dry-run: '$out'"

sweep FAIL 0 >/dev/null
alive "$free" && ok "a claim list that could not be read stops nothing" || fail "stopped a server without knowing the claims"

sweep "$CLAIMED" 0 >/dev/null
sleep 1
alive "$free"  && fail "the unclaimed ticket's server is still running"  || ok "a server in an unclaimed ticket worktree is stopped"
alive "$held"  && ok "a server in a claimed ticket's worktree is kept"   || fail "a claimed ticket's server was stopped"
alive "$mine"  && ok "a worktree with no ticket number (a preview) is kept" || fail "a preview's server was stopped"
alive "$own"   && ok "the owner's own checkout is kept"                  || fail "the owner's own server was stopped"
alive "$busy"  && ok "a worktree somebody's shell sits in is kept"       || fail "a server was stopped under somebody working there"
alive "$lsrv"  && fail "the launched server is still running"            || ok "a launched server is stopped"
alive "$lnch"  && fail "its npm-exec launcher is still running"          || ok "its Next launcher in the same worktree is stopped too"
# An agent session sitting in its worktree is somebody working there.
alive "$asrv"  && ok "a worktree an agent session sits in is kept" || fail "a server was stopped under a live agent session"
alive "$worker_srv" && fail "a server with its own worker in its folder was kept as if somebody were there" || ok "a server's own workers do not count as somebody working there"
alive "$bare" && fail "a ticket folder named without the prefix was not swept" || ok "a ticket folder named with bare digits (109-…) is swept"

echo "stop-dev-servers: sweep — a claimed ticket whose holder is gone"
# The holder states a claim can be in. Only proof the holder is gone stops anything.
HOST=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
STATE_T="$T/state"; mkdir -p "$STATE_T/runs"
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null                       # a pid that has exited
printf '{"run_id":"run-201","exit_code":0}\n' > "$STATE_T/runs/run-201.ended"
ended=$(serve "$T/tk-201-ended/apps/web");   PIDS+=("$ended")     # its run has an .ended record
dead=$(serve "$T/tk-202-dead/apps/web");     PIDS+=("$dead")      # held here by a pid that has exited
live=$(serve "$T/tk-203-live/apps/web");     PIDS+=("$live")      # held here by a live pid
away=$(serve "$T/tk-204-away/apps/web");     PIDS+=("$away")      # held on another machine
sat=$(serve "$T/tk-205-sat/apps/web");       PIDS+=("$sat")       # holder gone, somebody sits there
(cd "$T/tk-205-sat/apps" && exec bash -c 'sleep 600') >/dev/null 2>&1 & PIDS+=("$!")
# The shape a real `npm run dev` leaves: npm → sh -c next dev → the server, all in the worktree.
mkdir -p "$T/tk-206-npm/apps/web"
(cd "$T/tk-206-npm/apps/web" && exec -a "npm run dev" bash -c '(exec -a "sh -c next dev" bash -c "(exec -a next-server sleep 600) & exec -a \"sh -c next dev\" sleep 600") & exec -a "npm run dev" sleep 600') >/dev/null 2>&1 &
npm=$!; PIDS+=("$npm")
for _ in 1 2 3 4 5 6 7 8 9 10; do
  npmsh=$(pgrep -P "$npm" 2>/dev/null | head -1); [ -n "$npmsh" ] && npmsrv=$(pgrep -P "$npmsh" 2>/dev/null | head -1)
  [ -n "${npmsrv:-}" ] && break; sleep 0.2; done
PIDS+=("${npmsh:-}" "${npmsrv:-}")
# An agent's tool shell whose line merely mentions next is somebody there, not the launch chain.
read -r tsh tsrv <<<"$(launch "zsh -c source snap.sh && eval 'npx next dev'" "$T/tk-207-tool/apps/web")"; PIDS+=("$tsh" "$tsrv")
sleep 1
CLAIMED2=$(printf '102\n201\n202\n203\n204\n205\n')   # 102: claimed, no record
RECS=$(jq -cn --arg h "$HOST" --argjson dead "$DEAD" --argjson live "$$" '[
  {issue:201, host:$h, pid:$live, run_id:"run-201"},
  {issue:202, host:$h, pid:$dead},
  {issue:203, host:$h, pid:$live},
  {issue:204, host:"some-other-machine", pid:$dead},
  {issue:205, host:$h, pid:$dead} ]')
sweep2() { STOP_DEV_CLAIM_RECORDS="$RECS" STOP_DEV_STATE_DIR="$STATE_T" sweep "$CLAIMED2" "$@"; }

sweep2 3600 >/dev/null
sleep 1
alive "$dead" && ok "a claimed ticket's server younger than the minimum age is kept" || fail "a young server was stopped because its holder was gone"

sweep2 0 >/dev/null
sleep 1
alive "$ended" && fail "a server whose claim's run has ended is still running"   || ok "a claimed ticket whose run has an .ended record has its server stopped"
alive "$dead"  && fail "a server whose holder's pid is dead is still running"     || ok "a claimed ticket held by a dead pid on this host has its server stopped"
alive "$live"  && ok "a claimed ticket whose holder is alive here keeps its server" || fail "a live holder's server was stopped"
alive "$away"  && ok "a claim held on another machine keeps its server"            || fail "a server was stopped on a claim this host cannot check"
alive "$held"  && ok "a claimed ticket with no readable claim record keeps its server" || fail "a server was stopped on a claim with no record"
alive "$sat"   && ok "a gone holder's worktree somebody sits in keeps its server"  || fail "a server was stopped under somebody working there"
alive "$tsrv" && ok "an agent tool shell that mentions next still counts as somebody there" \
               || fail "a server was stopped under an agent's tool shell"
if [ -n "${npmsrv:-}" ]; then
  alive "$npmsrv" && fail "an npm-launched server was kept: its own npm and sh -c read as somebody there"                   || ok "a server's npm / sh -c launch chain does not count as somebody working there"
else fail "fixture: the npm-launched stand-in never started"; fi

echo "stop-dev-servers: --worktree"
a=$(serve "$T/wt/apps/web");   PIDS+=("$a")
b=$(serve "$T/wt-2/apps/web"); PIDS+=("$b")
sleep 1
bash "$SUT" --worktree "$T/wt" >/dev/null
sleep 1
alive "$a" && fail "--worktree left its server running" || ok "--worktree stops the servers inside it"
alive "$b" && ok "--worktree leaves a sibling whose name starts the same (wt-2) alone" || fail "--worktree matched wt-2 as a prefix of wt"
alive "$held" && ok "--worktree leaves servers elsewhere alone" || fail "--worktree stopped a server outside its path"
# Finishing a worktree stops the server an agent started, never the agent.
bash "$SUT" --worktree "$T/tk-106-agent" >/dev/null
sleep 1
alive "$asrv"  && fail "--worktree left the agent-started server running" || ok "--worktree stops a server an agent session started"
alive "$agent" && ok "the agent session itself is never stopped as a launcher" || fail "an agent session was stopped as a launcher"
# A shell whose command line runs `dotenv … next dev` matches the launcher shape;
# it is still a shell, somebody's, and is never stopped.
read -r shl ssrv <<<"$(launch "zsh -c dotenv -e .env -- next dev" "$T/tk-107-shell/apps/web")"; PIDS+=("$shl" "$ssrv")
sleep 1
bash "$SUT" --worktree "$T/tk-107-shell" >/dev/null
sleep 1
alive "$ssrv" && fail "--worktree left the shell-started server running" || ok "--worktree stops a server a shell started"
alive "$shl"  && ok "a shell running dotenv … next is never stopped as a launcher" || fail "a shell was stopped as a launcher"

echo "stop-dev-servers: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
