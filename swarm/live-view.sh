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
# The coordinator's settings too (it sources swarm-env.sh): what counts as our own
# tooling is its call, read here rather than kept a second time.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/coordinator-env.sh" || exit 1
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
# The open PRs the tick shares, what is left of the allowance, and the call log.
export SWARM_PRS_FILE="${SWARM_PRS_FILE:-$(gh_prs_file)}" SWARM_GH_ALLOWANCE="${SWARM_GH_ALLOWANCE:-$(gh_allowance_file)}"
export SWARM_GH_CALLS="${SWARM_GH_CALLS:-$(gh_calls_file)}" GH_ALLOWANCE_LOW_PCT
# The coordinator's queue, and what hold-status.sh needs to answer without
# resolving the project config again on every ask.
export SWARM_COORD_QUEUE="${SWARM_COORD_QUEUE:-${COORDINATOR_DIR:-$STATE_DIR/coordinator}/queue.json}"
# Who "Waiting on …" names on a finished row; unset reads "the owner".
export SWARM_OWNER_NAME="${SWARM_OWNER_NAME:-$(swarm_opt swarm.ownerName "")}"
# Every open ticket, counted once per five minutes. The release is the tickets at
# swarm.releasePriorities, less those set after launch (the label, or one of
# swarm.postLaunchMilestones by title), less parked work and the wrappers below.
export SWARM_BOARD_FILE="${SWARM_BOARD_FILE:-$SWARM_DIR/board.json}"
export SWARM_AFTER_LAUNCH_LABEL="${SWARM_AFTER_LAUNCH_LABEL:-$(swarm_opt swarm.afterLaunchLabel after-launch)}"
export SWARM_RELEASE_PRIORITIES="${SWARM_RELEASE_PRIORITIES:-$(swarm_opt swarm.releasePriorities "P0 P1")}"
# Milestone titles hold spaces, so they travel as the JSON array the config holds.
[ -n "${SWARM_POST_LAUNCH_MILESTONES:-}" ] || SWARM_POST_LAUNCH_MILESTONES=$(jq -c '.swarm.postLaunchMilestones // empty | arrays' "$HARNESS_CFG" 2>/dev/null)
export SWARM_POST_LAUNCH_MILESTONES
# Product against our own tooling, split as the coordinator orders it (coord_tooling).
export SWARM_TOOLING_LABELS="${SWARM_TOOLING_LABELS:-$COORD_TOOLING_LABELS}" SWARM_TOOLING_SCOPES="${SWARM_TOOLING_SCOPES:-$COORD_TOOLING_SCOPES}"
# Needs you: every open issue and pull request carrying one of these.
export SWARM_OWNER_LABELS="${SWARM_OWNER_LABELS:-$(swarm_opt swarm.ownerLabels "${LBL_OWNER_DECISION:-needs:owner-decision} ${LBL_NEEDS_HUMAN:-status:needs-human} needs:data-model ${HOLD_LABEL:-needs:human-approval}")}"
# Batch wrappers, epics and programmes hold other tickets: left out of every release count.
export SWARM_WRAPPER_TITLE_PREFIXES="${SWARM_WRAPPER_TITLE_PREFIXES-$(swarm_opt swarm.wrapperTitlePrefixes "Batch PROGRAMME EPIC")}"
export SWARM_WRAPPER_LABELS="${SWARM_WRAPPER_LABELS-$(swarm_opt swarm.wrapperLabels "epic programme")}"
# The day "Progress to launch" counts done tickets from, and the pace file it reads.
export SWARM_PROGRESS_SINCE="${SWARM_PROGRESS_SINCE:-$(swarm_opt swarm.progressSince 2026-10-13)}"
export SWARM_TREND_FILE="${SWARM_TREND_FILE:-$SWARM_DIR/trend.json}"
export SWARM_PACE_FILE="${SWARM_PACE_FILE:-${COORDINATOR_DIR:-$STATE_DIR/coordinator}/pace.tsv}"
export HARNESS_CFG_PATH="${HARNESS_CFG_PATH:-$HARNESS_CFG}" HARNESS_STATE_DIR="$STATE_DIR" HARNESS_MAIN_REPO="$MAIN_REPO" KIT_ROOT
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
