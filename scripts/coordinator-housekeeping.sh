#!/usr/bin/env bash
# coordinator-housekeeping.sh — the slow half of a coordinator tick: the merge
# lane, reconcile, the sweeps, the disk pass and the judge. coordinator-tick.sh
# starts it in the background once its starts are made, so none of it delays a
# start. One at a time: a housekeeping still running means this one exits.
#
#   coordinator-housekeeping.sh     COORDINATOR_SHADOW=0 acts for real; anything else is shadow
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1

RECONCILE="${COORDINATOR_RECONCILE:-$SELF_DIR/reconcile-claims.sh}"
SWEEP="${COORDINATOR_SWEEP:-$SELF_DIR/stop-dev-servers.sh}"
JUDGE="${COORDINATOR_JUDGE:-$SELF_DIR/coordinator-judge.sh}"
NOTIFY="$SELF_DIR/coordinator-notify.sh"
touch "$COORD_EVENTS" "$COORD_ACTIONS"

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; swarm_log "$COORD_LOG" "$*"; }

LOCK="$COORD_DIR/housekeeping.lock"
coord_lock "$LOCK" housekeeping || { say "housekeeping: $COORD_LOCK_WHY — not started again"; exit 0; }
trap 'rm -rf "$LOCK"' EXIT

# Writes an event once; the id is what makes it once.
event() { # <id> <kind> <judge:true|false> <ticket> <pr> <detail>
  grep -qF "\"id\":\"$1\"" "$COORD_EVENTS" 2>/dev/null && return 1
  jq -cn --arg id "$1" --arg kind "$2" --argjson judge "$3" --arg t "$4" --arg pr "$5" \
     --arg d "$6" --arg at "$(swarm_stamp)" \
     '{id:$id, at:$at, kind:$kind, judge:$judge, ticket:$t, pr:$pr, detail:$d}' >> "$COORD_EVENTS"
  say "event: $2 ${4:+#$4 }${5:+PR $5 }— $6"
  return 0
}

# ---- 5b. the merge lane -------------------------------------------------------
# Only where the project names a merge method. Its own lock, its own shadow.
LANE="${COORDINATOR_LANE:-$SELF_DIR/merge-lane.sh}"
if toolkit_cfg merge.method >/dev/null 2>&1; then
  bash "$LANE" >> "$COORD_LOG" 2>&1 || say "merge lane exited $?"
else
  say "merge lane: off — harness.json has no merge.method"
fi

# ---- 6. housekeeping ---------------------------------------------------------
if coord_shadow; then
  bash "$RECONCILE" --dry-run --quiet >> "$COORD_LOG" 2>&1 || say "reconcile (dry) exited $?"
  bash "$SWEEP" --sweep --dry-run >> "$COORD_LOG" 2>&1 || say "server sweep (dry) exited $?"
else
  bash "$RECONCILE" --quiet >> "$COORD_LOG" 2>&1 || say "reconcile exited $?"
  bash "$SWEEP" --sweep >> "$COORD_LOG" 2>&1 || say "server sweep exited $?"
fi
# An agent that dies never reaches /finish's cleanup, so its worktree stays until this runs.
WT_SWEEP="${COORDINATOR_WORKTREE_SWEEP:-$SELF_DIR/sweep-orphan-worktrees.sh}"
WT_STAMP="$COORD_DIR/worktree-sweep.stamp"
if [ -z "$(find "$WT_STAMP" -mmin -"$COORD_SWEEP_EVERY_MIN" 2>/dev/null)" ]; then
  touch "$WT_STAMP"
  if coord_shadow; then bash "$WT_SWEEP" >> "$COORD_LOG" 2>&1 || say "worktree sweep (dry) exited $?"
  else bash "$WT_SWEEP" --apply >> "$COORD_LOG" 2>&1 || say "worktree sweep exited $?"; fi
fi

# ---- 7. disk -----------------------------------------------------------------
CACHE="${COORDINATOR_CACHE:-$SELF_DIR/sweep-orphan-worktrees.sh}"
free_gb() {
  if [ -n "${COORDINATOR_DF:-}" ]; then "$COORDINATOR_DF"
  elif [ -n "${COORDINATOR_FREE_GB:-}" ]; then printf '%s\n' "$COORDINATOR_FREE_GB"
  else df -Pk "$STATE_DIR" 2>/dev/null | awk 'NR==2{print int($4/1048576)}'; fi
}
FREE_GB=$(free_gb)
case "$FREE_GB" in ''|*[!0-9]*) say "disk: free space could not be read"; FREE_GB="" ;; esac
if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt "$COORD_MIN_FREE_GB" ]; then
  before="$FREE_GB"
  if coord_shadow; then bash "$CACHE" --caches-only >> "$COORD_LOG" 2>&1 || say "cache pass (dry) exited $?"
  else bash "$CACHE" --caches-only --apply >> "$COORD_LOG" 2>&1 || say "cache pass exited $?"; fi
  FREE_GB=$(free_gb); case "$FREE_GB" in ''|*[!0-9]*) FREE_GB="$before" ;; esac
  say "disk: $before GB free, below $COORD_MIN_FREE_GB GB — $FREE_GB GB after the cache pass"
fi
if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt "$COORD_MIN_FREE_GB" ]; then
  if event "disk-low:$(swarm_day)" disk-low false "" "" "${FREE_GB} GB free, below ${COORD_MIN_FREE_GB} GB"; then
    bash "$NOTIFY" --class owner "disk-low:$(swarm_day)" "Disk is low: ${FREE_GB} GB free (floor ${COORD_MIN_FREE_GB} GB)"
  fi
fi

# ---- 8. judgement ------------------------------------------------------------
bash "$JUDGE" >> "$COORD_LOG" 2>&1 || say "judge exited $?"
say "housekeeping: done"
