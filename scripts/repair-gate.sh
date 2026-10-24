#!/usr/bin/env bash
# repair-gate.sh — the one check every repair start goes through. No path spawns a repair
# without it: the coordinator's pick, the stall guard, the merge lane's fixer and
# repair-watch's pass (swarm/repair-watch.sh) all call repair_gate.
#
#   . scripts/repair-gate.sh      (after coordinator-env.sh, pr-red.sh, issue-status.sh)
#   repair_gate <ticket> [pr-json]   0 when a repair may start; else echoes why not.
#     the ticket is open · it has an open PR · that PR is really red: a check the base's
#     live rules require concluded failure, or it truly clashes (pr-red.sh), a cancelled
#     required check being re-run instead · it has not already been repaired
#     coordinator.rebuildAfterRepairs times (then it is rebuilt fresh, and that is said)
#   repair_record <ticket>           note a repair spawn, for the rebuild count
#
# Seen 2026-10-23: repair-watch spawned a repair on Maktura #5989 whose only red was
# "Capture and pin the evidence", a check develop does not require, and it parked to the
# owner. The coordinator's pick refused it; the watcher had a gate of its own.
# PRS (the open PRs, as gh_open_prs gives them) and PRS_STALE are read when no pr-json is given.
[ -z "${_REPAIR_GATE_SH:-}" ] || return 0
_REPAIR_GATE_SH=1
: "${QUEUE:=$KIT_ROOT/scripts/coordinator-queue.sh}"
declare -F say >/dev/null || say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

open_pr_json() { # <ticket> — its open PR as this tick read it, or nothing
  printf '%s' "${PRS:-[]}" | jq -c --arg pre "$BRANCH_PREFIX" --arg t "$1" \
    "$BRANCH_TICKET_JQ"'[.[] | select(.headRefName | branch_is_ticket($pre; $t))] | sort_by(.number) | last // empty' 2>/dev/null
}

# REBUILD AFTER N REPAIRS. The 12 most-repaired PRs (14-18 Oct, each repaired 5-11 times)
# were 48% of three days' repair usage. A PR this host has repaired coordinator.rebuildAfterRepairs
# (2) times since its ticket last started fresh is not patched again: its head is kept at
# refs/stale/<ticket>/pr-<n>, the PR is closed with "closed to rebuild fresh" (follow-up.sh
# holds its findings for the next PR), its branch deleted, and the ticket queued at the
# front as a fresh build from the integration branch. 0 turns it off.
COORD_REBUILD_AFTER="${COORDINATOR_REBUILD_AFTER_REPAIRS:-$(swarm_opt coordinator.rebuildAfterRepairs 2)}"
case "$COORD_REBUILD_AFTER" in ''|*[!0-9]*) COORD_REBUILD_AFTER=2 ;; esac
repairs_since_fresh() { # <ticket> — repair spawns on record since its last rebuild or new build
  awk -F'\t' -v t="$1" '$2 == t { if ($3 == "repair") n++; else if ($3 == "rebuild" || $3 == "new") n = 0 } END { print n + 0 }' "$COORD_RUN_CLASSES" 2>/dev/null || echo 0
}
rebuild_fresh() { # <ticket> <repairs> [pr-json] — 0 when the PR was closed and the ticket queued fresh; says what it did
  local t="$1" n="$2" pj="${3:-}" pr sha ref note
  [ -n "$pj" ] || pj=$(open_pr_json "$t"); [ -n "$pj" ] || { say "rebuild: #$t has no open PR this tick — left as a repair"; return 1; }
  pr=$(jq -r .number <<<"$pj"); sha=$(jq -r '.headRefOid // ""' <<<"$pj"); ref="refs/stale/$t/pr-$pr"
  coord_act_log rebuild "$t" "PR #$pr repaired $n times"
  if coord_shadow; then say "rebuild: would close PR #$pr (repaired $n times) and build #$t fresh from $INTEGRATION_BRANCH"; return 0; fi
  [ -n "$sha" ] && swarm_gh api "repos/$REPO_SLUG/git/refs" -f ref="$ref" -f sha="$sha" >/dev/null 2>&1 \
    || swarm_gh api "repos/$REPO_SLUG/git/refs/${ref#refs/}" -X PATCH -f sha="$sha" -F force=true >/dev/null 2>&1 \
    || { say "rebuild: #$t — PR #$pr's head could not be kept at $ref; left as a repair"; return 1; }
  note="Closed to rebuild fresh: this PR was repaired $n times and is still not mergeable, so ticket #$t builds again from $INTEGRATION_BRANCH (coordinator.rebuildAfterRepairs). Its work is kept at \`$ref\` ($sha)."
  swarm_gh pr close "$pr" --repo "$REPO_SLUG" --delete-branch --comment "$note" >/dev/null 2>&1 \
    || { say "rebuild: #$t — PR #$pr could not be closed; left as a repair"; return 1; }
  issue_status_set "$t" "$LBL_READY" >/dev/null 2>&1 || say "rebuild: #$t could not be set $LBL_READY"
  bash "$QUEUE" add "$t" --class new --first --note "Rebuild: PR #$pr was closed after $n repairs. Build the ticket fresh from $INTEGRATION_BRANCH; the old head is at $ref for reference only." >/dev/null 2>&1 \
    || say "rebuild: #$t could not be queued — the next seed finds it ready"
  bash "$QUEUE" set-class "$t" new >/dev/null 2>&1 || true
  coord_record_class "$t" rebuild
  say "rebuild: closed PR #$pr after $n repairs (head kept at $ref) — #$t is queued to build fresh from $INTEGRATION_BRANCH"
}
# A cancelled, timed-out or runner-less required check is re-run this many times a head.
COORD_RERUN_MAX="${COORDINATOR_RERUN_CANCELLED:-$(swarm_opt coordinator.rerunCancelled 2)}"
case "$COORD_RERUN_MAX" in ''|*[!0-9]*) COORD_RERUN_MAX=2 ;; esac
# The base branch's required checks, read from its live rules once per tick (pr-red.sh).
PR_RED_REQ_FILE="$COORD_DIR/required-checks.$(coord_mode)"; : > "$PR_RED_REQ_FILE" 2>/dev/null; export PR_RED_REQ_FILE
repair_pr_red() { # <ticket> [pr-json] — 0 when its open PR is really red; else echoes why not
  local pj="${2:-}" v
  [ -n "$pj" ] || pj=$(open_pr_json "$1")
  if [ -z "$pj" ]; then
    # Only a fresh read can say there is none: a snapshot or no read at all decides nothing.
    if [ -n "${PRS:-}" ] && [ "${PRS_STALE:-0}" = 0 ]; then echo "has no open PR — nothing to repair"; return 1; fi
    return 0
  fi
  v=$(pr_red_verdict "$pj" "${COORDINATOR_HOLD_CHECK:-$(swarm_opt coordinator.holdCheck approval)}" "$(release_nonblocking_json)") && return 0
  local n kind why ids did
  n=$(jq -r .number <<<"$pj"); IFS=$'\t' read -r kind why ids <<<"$v"
  # A cancelled required check is re-run, never repaired (coordinator.rerunCancelled, 2 a head).
  if [ "$kind" = rerun ]; then
    if coord_shadow; then did="would re-run ${ids:-nothing named}"
    else did=$(pr_red_rerun "$n" "$(jq -r '.headRefOid // ""' <<<"$pj")" "$ids" "$COORD_DIR/reruns.tsv" "$COORD_RERUN_MAX"); fi
    echo "PR #$n is not red ($why) — $did; no repair"; return 1
  fi
  echo "PR #$n is not red ($kind: $why) — no repair"
  return 1
}

repair_record() { coord_record_class "$1" repair; }

repair_gate() { # <ticket> [pr-json]
  local t="$1" pj="${2:-}" st reps
  st=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json state -q .state 2>/dev/null) || { echo "#$t could not be read"; return 1; }
  [ "$st" = OPEN ] || { echo "#$t is $st"; return 1; }
  repair_pr_red "$t" "$pj" || return 1
  if [ "$COORD_REBUILD_AFTER" -gt 0 ] && reps=$(repairs_since_fresh "$t") && [ "$reps" -ge "$COORD_REBUILD_AFTER" ]; then
    rebuild_fresh "$t" "$reps" "$pj" >&2 || true
    echo "repaired $reps times since it last started fresh — rebuilt from $INTEGRATION_BRANCH instead (coordinator.rebuildAfterRepairs)"; return 1
  fi
  return 0
}
