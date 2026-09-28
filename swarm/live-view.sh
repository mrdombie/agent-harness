#!/usr/bin/env bash
# live-view.sh — run the live page, with every path and name resolved the one
# way the swarm resolves anything.
#
#   live-view.sh            serve on SWARM_PORT (default 4777)
#   live-view.sh --print    print one snapshot as JSON and exit
#
# The server itself takes no configuration of its own: this is the only place
# that reads harness.json, so a project's repo slug and state directory are
# named once, here, and nowhere in the JavaScript.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swarm-env.sh" || exit 1
command -v node >/dev/null 2>&1 || { echo "live-view: node is not on PATH" >&2; exit 1; }

export SWARM_RUNS_DIR="$RUNS_DIR" SWARM_PORT SWARM_REPO="$REPO_SLUG" SWARM_GH
export SWARM_PROGRAMME_PREFIX SWARM_TITLES="${SWARM_TITLES:-$SWARM_DIR/live-view-titles.json}"
# How far along each agent and each plan is. The reads are git and forge calls, so
# they are cached and refreshed off the request path; the claim ref is what names
# the branch, so the queue's own clone has to be nameable here too.
export SWARM_PROGRESS_MS="${SWARM_PROGRESS_MS:-$(( $(swarm_opt swarm.progressSec 60) * 1000 ))}"
export SWARM_PROGRESS_CACHE="${SWARM_PROGRESS_CACHE:-$SWARM_DIR/progress.json}"
export SWARM_PLAIN_TITLES="${SWARM_PLAIN_TITLES:-$STATE_DIR/plain-titles.json}"
export SWARM_CLAIM_LOCK="${SWARM_CLAIM_LOCK:-$CL}" SWARM_QUEUE_REPO="${SWARM_QUEUE_REPO:-$MAIN_REPO}"
export DRIVER_DIR="${DRIVER_DIR:-$STATE_DIR/driver}"
# The bash this runs under, by full path: node's own PATH lookup finds System32's
# WSL launcher first when started by Task Scheduler.
command -v cygpath >/dev/null 2>&1 && export SWARM_BASH="${SWARM_BASH:-$(cygpath -w "$BASH")}"
SERVER="$(dirname "${BASH_SOURCE[0]}")/live-view/server.mjs"

if [ "${1:-}" = "--print" ]; then
  # The path travels in the environment and becomes a file: URL inside node. A
  # path spliced into the script text is not converted for a native node on Git
  # Bash, and '/c/Users/…' resolves to 'C:\c\Users\…'.
  SWARM_SERVER_MJS="$(cd "$(dirname "$SERVER")" && pwd)/server.mjs"
  command -v cygpath >/dev/null 2>&1 && SWARM_SERVER_MJS=$(cygpath -m "$SWARM_SERVER_MJS")
  export SWARM_SERVER_MJS
  exec node --input-type=module -e "
    import { pathToFileURL } from 'node:url'
    const { snapshot } = await import(pathToFileURL(process.env.SWARM_SERVER_MJS).href)
    console.log(JSON.stringify(snapshot(), null, 2))"
fi
echo "live-view on http://127.0.0.1:$SWARM_PORT"
exec node "$SERVER"
