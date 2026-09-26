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
SERVER="$(dirname "${BASH_SOURCE[0]}")/live-view/server.mjs"

if [ "${1:-}" = "--print" ]; then
  exec node --input-type=module -e "
    import { snapshot } from '$(cd "$(dirname "$SERVER")" && pwd)/server.mjs'
    console.log(JSON.stringify(snapshot(), null, 2))"
fi
echo "live-view on http://127.0.0.1:$SWARM_PORT"
exec node "$SERVER"
