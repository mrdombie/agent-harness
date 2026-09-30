#!/usr/bin/env bash
# swarm-env.sh — the one place the swarm layer resolves WHERE things are and HOW
# it reaches the outside world.
#
#   . "$KIT_ROOT/swarm/swarm-env.sh" || exit 1
#
# Sets, on top of everything scripts/toolkit-env.sh sets:
#   SWARM_DIR        per-machine swarm state: the queue, repair attempts, holds
#   SWARM_LOGS       $STATE_DIR/logs — the same logs the spawner writes
#   RUNS_DIR         $STATE_DIR/runs — one record per spawned agent
#   SWARM_CAP        agents at once PER PROGRAMME (default 3)
#   SWARM_MAX_LOAD   hold above this 1-minute load average (default 32)
#   SWARM_LIVE_URL   the live view's snapshot endpoint
#   SWARM_STATUS_REPO  optional: a repo to dispatch a rebuild at (empty = skip)
#   SWARM_REPORT_URL   optional: where the reporter POSTs (empty = skip)
#
# EVERY call out of this process goes through a function here, and every one of
# them is overridable by an environment variable. That is not a convenience: a
# swarm made of eight scripts that shelled out to gh, curl, sysctl and a spawner
# inline could not be tested at all, which is how it reached 2026-09-26 with the
# cap, the queue order and the stop-after-3 all unverified. The seams are:
#
#   SWARM_GH     the GitHub CLI          (default: gh)
#   SWARM_CURL   the HTTP client         (default: curl)
#   SWARM_SPAWN  the agent spawner       (default: the kit's spawn-claim.sh)
#   SWARM_LOAD   the load average        (default: read from the kernel)
#   SWARM_NOW    the clock, epoch secs   (default: date +%s)
#
# A test points them at recorders and asserts on what was recorded. Nothing in
# the scripts themselves knows it is being tested.

_swarm_self="${BASH_SOURCE[0]}"
. "$(cd "$(dirname "$_swarm_self")/../scripts" && pwd)/toolkit-env.sh" || return 1 2>/dev/null || exit 1
. "$(cd "$(dirname "$_swarm_self")" && pwd)/time.sh" || return 1 2>/dev/null || exit 1
unset _swarm_self

# gh keeps its token in the macOS keychain, which a launchd job cannot read: the
# access prompt has nowhere to show, so gh hangs. Measured 2026-09-20 — the
# scheduler ran 8 times and logged nothing after its first pass. A 0600 file the
# operator writes with `gh auth token > <file>` is the way in. Rotate it there.
SWARM_TOKEN_FILE="${SWARM_TOKEN_FILE:-$STATE_DIR/swarm/gh-token}"
if [ -z "${GH_TOKEN:-}" ] && [ -s "$SWARM_TOKEN_FILE" ]; then
  GH_TOKEN="$(cat "$SWARM_TOKEN_FILE")"; export GH_TOKEN
fi

SWARM_DIR="${SWARM_DIR:-$STATE_DIR/swarm}"
SWARM_LOGS="${SWARM_LOGS:-$STATE_DIR/logs}"
RUNS_DIR="${RUNS_DIR:-$STATE_DIR/runs}"
mkdir -p "$SWARM_DIR" "$SWARM_LOGS" "$RUNS_DIR" 2>/dev/null || true

# swarm_opt <dotted.key> <default> — an OPTIONAL project fact.
#
# toolkit_cfg refuses a missing key by name, which is right for a fact the kit
# cannot invent (the repo slug, the label names). These are different: a cap, a
# load ceiling and a port are machine tuning, identical on every project until
# someone tunes them, so a default here names no project and hides nothing.
swarm_opt() { local v; v=$(toolkit_cfg "$1" 2>/dev/null) || v=""; printf '%s' "${v:-$2}"; }

SWARM_CAP="${SWARM_CAP:-$(swarm_opt swarm.cap 3)}"
SWARM_MAX_LOAD="${SWARM_MAX_LOAD:-$(swarm_opt swarm.maxLoad 32)}"
SWARM_PORT="${SWARM_PORT:-$(swarm_opt swarm.port 4777)}"
SWARM_LIVE_URL="${SWARM_LIVE_URL:-$(swarm_opt swarm.liveUrl "http://127.0.0.1:$SWARM_PORT/api/agents")}"
SWARM_STATUS_REPO="${SWARM_STATUS_REPO:-$(swarm_opt swarm.statusRepo "")}"
SWARM_REPORT_URL="${SWARM_REPORT_URL:-$(swarm_opt swarm.reportUrl "")}"
SWARM_BUDGET_USD="${SWARM_BUDGET_USD:-$(swarm_opt swarm.budgetUsd 150)}"
SWARM_GH="${SWARM_GH:-gh}"
SWARM_CURL="${SWARM_CURL:-curl}"
SWARM_SPAWN="${SWARM_SPAWN:-$KIT_ROOT/scripts/spawn-claim.sh}"
# The programme label namespace. `project:` is the kit's own vocabulary — the
# same prefix /project, /work and /standup already read — not a project's name.
SWARM_PROGRAMME_PREFIX="${SWARM_PROGRAMME_PREFIX:-project:}"

swarm_gh()   { "$SWARM_GH" "$@"; }
swarm_curl() { "$SWARM_CURL" "$@"; }

# Epoch seconds. Overridable so a test can sit at a chosen minute instead of
# sleeping through one.
swarm_now() { if [ -n "${SWARM_NOW:-}" ]; then printf '%s' "$SWARM_NOW"; else date +%s; fi; }
swarm_stamp() { swarm_iso "$(swarm_now)"; }
swarm_day()   { swarm_iso "$(swarm_now)" | cut -dT -f1; }

# The 1-minute load average, as a whole number. sysctl on macOS, /proc on Linux
# — the CI runner is Linux and the operator's machine is not, so a script that
# knows only one of them is a script that is only ever tested on the other.
swarm_load() {
  if [ -n "${SWARM_LOAD:-}" ]; then printf '%s' "${SWARM_LOAD%%.*}"; return; fi
  local l=""
  l=$(/usr/sbin/sysctl -n vm.loadavg 2>/dev/null | awk '{print int($2)}')
  [ -n "$l" ] || l=$(awk '{print int($1)}' /proc/loadavg 2>/dev/null)
  printf '%s' "${l:-0}"
}

swarm_log() { # <logfile> <message…>
  local f="$1"; shift
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%s %s\n' "$(swarm_stamp)" "$*" >> "$f"
}

# ---- the live view -----------------------------------------------------------
# One snapshot, cached for this process, so a pass that asks three questions
# makes one request.
#
# STALE DATA IS NOT AN ANSWER. The snapshot carries the moment it was taken, and
# a view that is still serving a page from twenty minutes ago is describing a
# machine that no longer exists — a set of agents that have since exited, or a
# set that has since started. An answer older than SWARM_STALE_SEC is discarded
# here, which sends every caller down the same path as no answer at all: busy.
SWARM_STALE_SEC="${SWARM_STALE_SEC:-$(swarm_opt swarm.staleSec 120)}"
swarm_snapshot() {
  if [ -z "${_SWARM_SNAP+x}" ]; then
    local raw at age
    raw=$(swarm_curl -s -m 5 "$SWARM_LIVE_URL" 2>/dev/null || true)
    if [ -n "$raw" ]; then
      at=$(printf '%s' "$raw" | jq -r '.at // empty' 2>/dev/null)
      if [ -n "$at" ]; then
        age=$(( $(swarm_now) - $(swarm_epoch "$at") ))
        if [ "$age" -gt "$SWARM_STALE_SEC" ] || [ "$age" -lt -"$SWARM_STALE_SEC" ]; then
          _SWARM_SNAP_STALE="$age"; raw=""
        fi
      fi
    fi
    _SWARM_SNAP="$raw"
  fi
  printf '%s' "$_SWARM_SNAP"
}
# Why the snapshot was unusable, for a log line that distinguishes "nothing
# answered" from "something answered with yesterday".
swarm_snapshot_why() {
  if [ -n "${_SWARM_SNAP_STALE:-}" ]; then printf 'its answer was %ss old' "$_SWARM_SNAP_STALE"
  else printf 'it did not answer'; fi
}

# How many agents are running for one programme, per the live view.
#
# NO ANSWER MEANS BUSY, NEVER ROOM. A down live view used to read as zero
# agents, so the scheduler filled every slot on a machine that already had a
# full set running. 99 is the number the original scripts used and it is the
# whole safety property of this function: the swarm holds when it cannot see.
swarm_live_count() { # <programme>
  local snap n
  snap=$(swarm_snapshot)
  [ -n "$snap" ] || { printf '99'; return; }
  n=$(printf '%s' "$snap" | jq --arg p "${1:-}" \
        '[.live[] | select($p == "" or .project == $p)] | length' 2>/dev/null)
  case "$n" in ''|*[!0-9]*) printf '99' ;; *) printf '%s' "$n" ;; esac
}

# ---- run records -------------------------------------------------------------
# A run is live when it has no .ended marker AND its agent's pid still exists.
# The marker alone is not enough: five August records had no marker and a dead
# pid, because the wrapper was killed before it could write one, and counting
# those as running made the launcher report eight running with three alive.
swarm_record_alive() { # <runs/xxx.json>
  [ -f "${1%.json}.ended" ] && return 1
  local pid
  pid=$(jq -r '.child_pid // .pid // 0' "$1" 2>/dev/null)
  [ "${pid:-0}" -gt 0 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null
}

swarm_ticket_live() { # <ticket> — 0 when an agent is running for it
  local j
  for j in "$RUNS_DIR"/claim-"$1"-*.json; do
    [ -f "$j" ] && swarm_record_alive "$j" && return 0
  done
  return 1
}

swarm_running_total() {
  local n=0 j
  for j in "$RUNS_DIR"/claim-*.json; do
    [ -f "$j" ] && swarm_record_alive "$j" && n=$((n+1))
  done
  printf '%s' "$n"
}

# ---- tickets -----------------------------------------------------------------
# The statuses that mean "a person or another PR owns this; never send an agent".
# Read from the config so a project's own names are honoured, plus needsHuman and
# the hold label, which are the two stops the swarm itself sets.
swarm_blocking_labels() {
  printf '%s\n' "$LBL_IN_REVIEW" "$LBL_BLOCKED" "$LBL_NEEDS_HUMAN" "$LBL_PARKED" "$HOLD_LABEL" $DECISION_LABELS \
    | awk 'NF && !seen[$0]++'
}

# Is this ticket spawnable right now? Echoes a reason and returns 1 when not.
#
# "The issue is open" is true of every ticket until its PR MERGES, which is why
# the open-PR probe is here: on 2026-09-19 a version without it re-spawned three
# tickets whose PRs were already open and waiting on a person.
swarm_spawnable() { # <ticket>
  local t="$1" meta st lab l openpr
  meta=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json state,labels \
           -q '.state+" "+([.labels[].name]|join(","))' 2>/dev/null)
  [ -n "$meta" ] || { echo "  #$t could not be read — skip"; return 1; }
  st=${meta%% *}; lab=${meta#* }
  [ "$st" = "OPEN" ] || { echo "  #$t $st — skip"; return 1; }
  while read -r l; do
    [ -n "$l" ] || continue
    case ",$lab," in *",$l,"*) echo "  #$t $l — skip"; return 1 ;; esac
  done <<EOS
$(swarm_blocking_labels)
EOS
  openpr=$(swarm_gh pr list --repo "$REPO_SLUG" --state open \
             --search "head:$BRANCH_PREFIX$t/" --json number -q 'length' 2>/dev/null)
  [ "${openpr:-0}" = "0" ] || { echo "  #$t has an open PR — skip"; return 1; }
  swarm_ticket_live "$t" && { echo "  #$t already running — skip"; return 1; }
  return 0
}

# A ticket's programme, from its labels; empty when it carries none.
swarm_programme_of() { # <ticket>
  swarm_gh issue view "$1" --repo "$REPO_SLUG" --json labels \
    -q "[.labels[].name | select(startswith(\"$SWARM_PROGRAMME_PREFIX\"))] | first // \"\"" 2>/dev/null \
    | sed "s/^$SWARM_PROGRAMME_PREFIX//"
}

# Spawn one agent. A brief file becomes CLAIM_EXTRA — that is the whole content
# of the 58 hand-written launchers this replaces.
#
# Output goes to a FILE, never a command substitution: the spawned agent inherits
# stdout, so capturing it with $(...) blocks until the agent exits. The scheduler
# logged nothing for forty minutes at a time while quietly spawning.
# The hold. `install.sh hold "<reason>"` writes it; while it exists nothing
# spawns, whichever job asks and however the supervisor came back. Stopping the
# task was not enough: on 2026-09-29 a stopped swarm was re-installed by someone
# nobody could name, waited out the plan's usage limit, and spent ~110M tokens in
# two hours re-running tickets that had failed the night before (#42).
SWARM_HOLD_FILE="${SWARM_HOLD_FILE:-$SWARM_DIR/HOLD}"
swarm_held() { [ -f "$SWARM_HOLD_FILE" ] || return 1; head -1 "$SWARM_HOLD_FILE"; }

swarm_spawn() { # <ticket> [brief-file] [budget]
  local t="$1" brief="${2:-}" budget="${3:-$SWARM_BUDGET_USD}" out
  local held
  if held=$(swarm_held); then
    echo "held — not spawning #$t: $held" >&2
    return 1
  fi
  out=$(mktemp)
  (
    [ -n "$brief" ] && [ -f "$brief" ] && CLAIM_EXTRA="$(cat "$brief")" && export CLAIM_EXTRA
    CLAIM_BUDGET_USD="$budget" CLAIM_REPO="${CLAIM_REPO:-$MAIN_REPO}" \
      "$SWARM_SPAWN" "$t" > "$out" 2>&1 < /dev/null
  )
  local rc=$?
  cat "$out"; rm -f "$out"
  return $rc
}

# Ask a status page to rebuild, when the project has one. No page: no ping, and
# nothing pretends otherwise.
swarm_ping_page() {
  [ -n "$SWARM_STATUS_REPO" ] || return 0
  swarm_gh api "repos/$SWARM_STATUS_REPO/dispatches" -f event_type=claim-changed >/dev/null 2>&1
}

export SWARM_DIR SWARM_HOLD_FILE SWARM_LOGS RUNS_DIR SWARM_CAP SWARM_MAX_LOAD SWARM_PORT SWARM_LIVE_URL
export SWARM_STATUS_REPO SWARM_REPORT_URL SWARM_BUDGET_USD SWARM_GH SWARM_CURL SWARM_SPAWN
export SWARM_PROGRAMME_PREFIX SWARM_TOKEN_FILE SWARM_STALE_SEC
