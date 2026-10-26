#!/usr/bin/env bash
# coordinator-housekeeping.sh — the slow half of a coordinator tick: the merge
# lane, reconcile, the sweeps, the disk pass, the judge, and the host's own shared
# state (its shared install, its stranded worktrees). coordinator-tick.sh
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
# A start refused here ran nothing: the tick's interval stamp goes, so the next tick
# starts one the moment this holder ends, not a whole interval after.
coord_lock "$LOCK" housekeeping || { rm -f "$COORD_DIR/housekeeping.stamp"; say "housekeeping: $COORD_LOCK_WHY — not started again"; exit 0; }
trap 'rm -rf "$LOCK"' EXIT
export GH_CALLER=coordinator-housekeeping

# Writes an event once; the id is what makes it once.
event() { # <id> <kind> <judge:true|false> <ticket> <pr> <detail>
  grep -qF "\"id\":\"$1\"" "$COORD_EVENTS" 2>/dev/null && return 1
  jq -cn --arg id "$1" --arg kind "$2" --argjson judge "$3" --arg t "$4" --arg pr "$5" \
     --arg d "$6" --arg at "$(swarm_stamp)" \
     '{id:$id, at:$at, kind:$kind, judge:$judge, ticket:$t, pr:$pr, detail:$d}' >> "$COORD_EVENTS"
  say "event: $2 ${4:+#$4 }${5:+PR $5 }— $6"
  return 0
}

# While GitHub is refusing the token (scripts/gh-batch.sh's backoff), the passes
# that are mostly GitHub reads wait for the next run: pressing on keeps the limit,
# and keeps it shut for every builder on the same token too.
GH_WAIT=""; if until=$(gh_backoff_active); then GH_WAIT="GitHub is rate-limiting this token until $(swarm_iso "$until")"; fi

[ -n "$GH_WAIT" ] || bash "${COORDINATOR_KEEP_FRESH:-$SELF_DIR/keep-fresh.sh}" >> "$COORD_LOG" 2>&1 || say "keep-fresh exited $?"   # mechanical clashes, before the lane reads them

# ---- 5b. the merge lane -------------------------------------------------------
# Only where the project names a merge method. Its own lock, its own shadow.
LANE="${COORDINATOR_LANE:-$SELF_DIR/merge-lane.sh}"
if [ -n "$GH_WAIT" ]; then
  say "merge lane: $GH_WAIT — next pass"
elif toolkit_cfg merge.method >/dev/null 2>&1; then
  bash "$LANE" >> "$COORD_LOG" 2>&1 || say "merge lane exited $?"
else
  say "merge lane: off — harness.json has no merge.method"
fi

# ---- 5c. the independent design critic --------------------------------------------
# The design status is set only by a critic the build never started, on CI's pinned
# shots of the head (critic-judge.sh). This pass starts one for each PR owed one.
# Report-only until the release (release.nonBlockingChecks): no judge spends usage then.
CRITIC="${COORDINATOR_CRITIC_JUDGE:-$SELF_DIR/critic-judge.sh}"
if [ -n "$GH_WAIT" ]; then say "design critic: $GH_WAIT — next pass"
elif why=$(bash "$CRITIC" paused 2>/dev/null) && [ -n "$why" ]; then say "$why"
elif coord_shadow; then bash "$CRITIC" sweep --dry-run >> "$COORD_LOG" 2>&1 || say "design critic sweep (dry) exited $?"
else bash "$CRITIC" sweep >> "$COORD_LOG" 2>&1 || say "design critic sweep exited $?"; fi

# ---- 6. housekeeping ---------------------------------------------------------
# GitHub closes "Closes #N" only on the default branch; a merge into the integration
# branch closes its tickets here. Ahead of reconcile, which reads a shipped ticket whose
# branch is gone as "no branch, no PR" and puts it back on the queue.
CLOSE_MERGED="${COORDINATOR_CLOSE_MERGED:-$SELF_DIR/close-merged.sh}"
if [ -n "$GH_WAIT" ]; then say "merged closer: $GH_WAIT — next pass"
elif coord_shadow; then bash "$CLOSE_MERGED" --dry-run >> "$COORD_LOG" 2>&1 || say "merged closer (dry) exited $?"
else bash "$CLOSE_MERGED" >> "$COORD_LOG" 2>&1 || say "merged closer exited $?"; fi
# Merge first, fix after: a PR's held review findings are filed once it merges, dropped if
# it closes unmerged; a follow-up already filed for an open PR waits for it (follow-up.sh).
FOLLOW_UP="${COORDINATOR_FOLLOW_UP:-$SELF_DIR/follow-up.sh}"
if [ "$FOLLOW_UP" = off ]; then :
elif [ -n "$GH_WAIT" ]; then say "follow-ups: $GH_WAIT — next pass"
elif coord_shadow; then bash "$FOLLOW_UP" settle --dry-run >> "$COORD_LOG" 2>&1 || say "follow-up settle (dry) exited $?"
else bash "$FOLLOW_UP" settle >> "$COORD_LOG" 2>&1 || say "follow-up settle exited $?"; fi
# A ticket waiting on others ("Blocked until #…", gated or blocked) is ready once they landed.
UNBLOCK="${COORDINATOR_UNBLOCK:-$SELF_DIR/unblock-waiting.sh}"
if [ "$UNBLOCK" = off ]; then :
elif [ -n "$GH_WAIT" ]; then say "unblock: $GH_WAIT — next pass"
elif coord_shadow; then bash "$UNBLOCK" --dry-run >> "$COORD_LOG" 2>&1 || say "unblock (dry) exited $?"
else bash "$UNBLOCK" >> "$COORD_LOG" 2>&1 || say "unblock exited $?"; fi
# A batch's held child goes back to ready once its batch is closed by any route (release-batch-children.sh).
RELEASE_BATCH="${COORDINATOR_RELEASE_BATCH:-$SELF_DIR/release-batch-children.sh}"
if [ "$RELEASE_BATCH" = off ]; then :
elif [ -n "$GH_WAIT" ]; then say "batch children: $GH_WAIT — next pass"
elif coord_shadow; then bash "$RELEASE_BATCH" --dry-run >> "$COORD_LOG" 2>&1 || say "batch children (dry) exited $?"
else bash "$RELEASE_BATCH" >> "$COORD_LOG" 2>&1 || say "batch children exited $?"; fi
# A park the machine caused is tried again once, fresh, on any host; twice the same is the PM's.
MACHINE_PARKS="${COORDINATOR_MACHINE_PARKS:-$SELF_DIR/retry-machine-parks.sh}"
if [ "$MACHINE_PARKS" = off ]; then :
elif [ -n "$GH_WAIT" ]; then say "machine parks: $GH_WAIT — next pass"
elif coord_shadow; then bash "$MACHINE_PARKS" --dry-run >> "$COORD_LOG" 2>&1 || say "machine parks (dry) exited $?"
else bash "$MACHINE_PARKS" >> "$COORD_LOG" 2>&1 || say "machine parks exited $?"; fi
if [ -n "$GH_WAIT" ]; then say "reconcile: $GH_WAIT — next pass"
elif coord_shadow; then bash "$RECONCILE" --dry-run --quiet >> "$COORD_LOG" 2>&1 || say "reconcile (dry) exited $?"
else bash "$RECONCILE" --quiet >> "$COORD_LOG" 2>&1 || say "reconcile exited $?"; fi
# A polish item is ticked only once the PR that fixed it merges, freed when that PR
# closes unmerged, and a list closes once nothing is left on it.
POLISH="${COORDINATOR_POLISH_LIST:-$SELF_DIR/polish-list.sh}"
if [ -n "$GH_WAIT" ]; then say "polish lists: $GH_WAIT — next pass"
elif coord_shadow; then bash "$POLISH" sweep --dry-run >> "$COORD_LOG" 2>&1 || say "polish-list sweep (dry) exited $?"
else bash "$POLISH" sweep >> "$COORD_LOG" 2>&1 || say "polish-list sweep exited $?"; fi
if coord_shadow; then bash "$SWEEP" --sweep --dry-run >> "$COORD_LOG" 2>&1 || say "server sweep (dry) exited $?"
else bash "$SWEEP" --sweep >> "$COORD_LOG" 2>&1 || say "server sweep exited $?"; fi
# Any other process a dead or finished run left in its worktree: CPU the starts count as taken.
STRAY_ENV=(STOP_DEV_STRAY_MIN_AGE=$((COORD_STRAY_MIN_AGE_MIN * 60)) STOP_DEV_STRAY_MAX_AGE=$((COORD_STRAY_MAX_AGE_MIN * 60)) STOP_DEV_STRAY_GRACE="$COORD_STRAY_GRACE_SEC")
if coord_shadow; then env "${STRAY_ENV[@]}" bash "$SWEEP" --strays --dry-run >> "$COORD_LOG" 2>&1 || say "stray sweep (dry) exited $?"
else env "${STRAY_ENV[@]}" bash "$SWEEP" --strays >> "$COORD_LOG" 2>&1 || say "stray sweep exited $?"; fi
# ---- 6b. this host's own shared state -----------------------------------------
# What only a person kept current: the shared clone's install at the trunk's lockfile
# (shared-install.sh), and worktree commits on no ref of origin (stranded-sweep.sh).
# Before the worktree sweep: that runs for most of an hour on a full root, and the
# backup of a tree's commits belongs ahead of anything that may remove trees.
for own in "${COORDINATOR_SHARED_INSTALL:-$SELF_DIR/shared-install.sh}" "${COORDINATOR_STRANDED_SWEEP:-$SELF_DIR/stranded-sweep.sh}"; do
  [ "$own" = off ] || bash "$own" 2>&1 || say "${own##*/} exited $?"
done
# An agent that dies never reaches /finish's cleanup, so its worktree stays until this runs.
WT_SWEEP="${COORDINATOR_WORKTREE_SWEEP:-$SELF_DIR/sweep-orphan-worktrees.sh}"
WT_STAMP="$COORD_DIR/worktree-sweep.stamp"
if [ -n "$GH_WAIT" ]; then :
elif [ -z "$(find "$WT_STAMP" -mmin -"$COORD_SWEEP_EVERY_MIN" 2>/dev/null)" ]; then
  touch "$WT_STAMP"
  if coord_shadow; then bash "$WT_SWEEP" >> "$COORD_LOG" 2>&1 || say "worktree sweep (dry) exited $?"
  else bash "$WT_SWEEP" --apply >> "$COORD_LOG" 2>&1 || say "worktree sweep exited $?"; fi
fi

# ---- 7. disk -----------------------------------------------------------------
CACHE="${COORDINATOR_CACHE:-$SELF_DIR/sweep-orphan-worktrees.sh}"
free_gb() {
  if [ -n "${COORDINATOR_DF:-}" ]; then "$COORDINATOR_DF"
  elif [ -n "${COORDINATOR_FREE_GB:-}" ]; then printf '%s\n' "$COORDINATOR_FREE_GB"
  else STATE_DIR="$STATE_DIR" bash "$SELF_DIR/disk-guard.sh" free 2>/dev/null; fi   # WSL: the lower of Linux and the host
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
if [ -n "$GH_WAIT" ]; then say "judge: $GH_WAIT — next pass"
else bash "$JUDGE" >> "$COORD_LOG" 2>&1 || say "judge exited $?"; fi
say "housekeeping: done"
