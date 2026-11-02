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
#   repair_base_red <ticket> <pr-json> [hold] [nb] [crit]   0 when the PR's red is its own; else
#     echoes why it waits: every failing required check failed on the base's newest completed
#     run too (base-red), or the base went green and the failed jobs are re-run first
#
# Seen 2026-10-23: repair-watch spawned a repair on the origin project's #5989 whose only red was
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
# were 48% of three days' repair usage. A PR repaired coordinator.rebuildAfterRepairs
# (2) times since its ticket last started fresh is not patched again: its head is kept at
# refs/stale/<ticket>/pr-<n>, the PR is closed with "closed to rebuild fresh" (follow-up.sh
# holds its findings for the next PR), its branch deleted, and the ticket queued at the
# front as a fresh build from the integration branch. 0 turns it off.
COORD_REBUILD_AFTER="${COORDINATOR_REBUILD_AFTER_REPAIRS:-$(swarm_opt coordinator.rebuildAfterRepairs 2)}"
case "$COORD_REBUILD_AFTER" in ''|*[!0-9]*) COORD_REBUILD_AFTER=2 ;; esac
# COUNTED ON THE PR, SO EVERY HOST AGREES. Each repair spawn leaves REPAIR_MARK in a comment
# on the ticket's open PR (repair_mark_pr, from coord_record_class), and the count is the marks
# on that PR: a rebuild closes it and a new build opens another, so the count starts again. A
# host's own run-classes file counted only its own spawns, and #13304 reached three repairs
# across two hosts, each seeing fewer than two. The local count stays as the fallback, and the
# higher of the two is used.
REPAIR_MARK='<!-- harness:repair-spawn -->'
# A PR seen base-red starts its count again: the repairs before were sent at a red no PR can fix.
BASE_RED_MARK='<!-- harness:base-red -->'
# A REPAIR THAT RAN NO MODEL STEP IS NOT A REPAIR. A repair spawn is counted when it starts,
# but a run that ends before any step called the model (GitHub unread at ship, a peer's
# claim, a usage wait, a start refused) repaired nothing. 31 Oct - 2 Nov: 15 of 36 rebuilds
# counted at least one such run, and one P0 ticket closed two green, mergeable PRs and
# built fresh three times on runs that only re-read a stop GitHub could not answer. Such a
# run's spawn is voided: locally (repair-void in run-classes) and on the PR (REPAIR_VOID_MARK).
REPAIR_VOID_MARK='<!-- harness:repair-void -->'
repairs_since_fresh() { # <ticket> [pr-json] — repair spawns since its last rebuild or new build
  local t="$1" pj="${2:-}" here there="" pr
  here=$(awk -F'\t' -v t="$t" '$2 == t { if ($3 == "repair") n++; else if ($3 == "repair-void") { if (n > 0) n-- } else if ($3 == "rebuild" || $3 == "new" || $3 == "base-red") n = 0 } END { print n + 0 }' "$COORD_RUN_CLASSES" 2>/dev/null || echo 0)
  [ -n "$pj" ] || pj=$(open_pr_json "$t")
  pr=$(jq -r '.number // empty' <<<"${pj:-null}" 2>/dev/null)
  # gh-read-ok: a failed read counts 0 here, so the host's own count stands, as before this read
  [ -z "$pr" ] || there=$(swarm_gh api "repos/$REPO_SLUG/issues/$pr/comments" --paginate \
      -q ".[] | (.body // \"\") | if contains(\"$REPAIR_MARK\") then \"r\" elif contains(\"$REPAIR_VOID_MARK\") then \"v\" elif contains(\"$BASE_RED_MARK\") then \"b\" else empty end" 2>/dev/null \
      | awk '$0 == "r" { n++ } $0 == "v" && n > 0 { n-- } $0 == "b" { n = 0 } END { print n + 0 }')
  case "$there" in ''|*[!0-9]*) there=0 ;; esac
  case "$here" in ''|*[!0-9]*) here=0 ;; esac
  [ "$there" -gt "$here" ] && echo "$there" || echo "$here"
}
repair_mark_pr() { # <ticket> [pr-json] — the spawn marked on its open PR, for every host's count
  local t="$1" pj="${2:-}" pr
  coord_shadow 2>/dev/null && return 0
  [ -n "$pj" ] || pj=$(open_pr_json "$t")
  pr=$(jq -r '.number // empty' <<<"${pj:-null}" 2>/dev/null); [ -n "$pr" ] || return 0
  swarm_gh api "repos/$REPO_SLUG/issues/$pr/comments" -X POST -f body="Repair started on $(hostname -s 2>/dev/null || echo this host) for #$t.
$REPAIR_MARK" >/dev/null 2>&1 || true
}
# rebuild_archive_state <ticket> — this host's driver record of it forgets every step, the
# way a new repair brief does: the answers move to steps/archive/, the finished list empties.
# Left done, each rebuild run said "nothing left to do" and exited 0 (15735: 22 times a day).
# Another host's record is caught by the driver itself: shipped, with no PR open or merged,
# is a fresh build there too.
rebuild_archive_state() {
  local t="$1" d f arch s
  d="${DRIVER_DIR:-$STATE_DIR/driver}/$t"; f="$d/state.json"
  [ -f "$f" ] || return 0
  arch="$d/steps/archive/$(date -u +%Y%m%dT%H%M%SZ)-rebuild"
  mkdir -p "$arch" 2>/dev/null
  for s in "$d"/steps/*; do
    case "$(basename "$s")" in archive|replaced.jsonl) continue ;; esac
    [ -e "$s" ] && mv "$s" "$arch/" 2>/dev/null
  done
  rmdir "$arch" 2>/dev/null || true
  jq --arg at "$(swarm_stamp)" '.done = [] | .step = "" | .mode = "build" | .rebuilt_at = $at | .updated_at = $at' "$f" > "$f.tmp.$$" 2>/dev/null \
    && mv "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; say "rebuild: #$t's driver record could not be reset — the driver resets it when it finds no PR"; }
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
  rebuild_archive_state "$t"
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

# A RED THE BASE HAS TOO WAITS FOR THE BASE. A PR cannot fix a check that fails on the base
# branch itself, so a repair sent at one fails, and two of them rebuild the PR from scratch.
# Measured 31 Oct - 1 Nov: 32 of 61 repair spawns were on PRs whose only red required check
# had failed on develop's newest completed push run too, and 13 of 17 rebuilds were of such
# PRs. Read per check, never assumed (base-wait.sh _base_latest_done): every failing required
# check's newest completed run on the base concluded failure. One check the base passes and
# the red is the PR's own; one the base cannot be read for decides nothing (a repair, as before).
# A head seen base-red is noted once (base-red.<mode>.tsv, and BASE_RED_MARK on the PR, which
# starts its rebuild count again). When the base passes again, the PR's failed jobs are re-run
# once on that head (free) before any repair.
declare -F _base_latest_done >/dev/null || . "$KIT_ROOT/scripts/base-wait.sh" || return 1
REPAIR_BASE_RED="$COORD_DIR/base-red.$(coord_mode).tsv"           # pr \t head \t checks \t epoch
REPAIR_BASE_RERUNS="$COORD_DIR/base-red-reruns.$(coord_mode).tsv"  # pr_red_rerun's ledger, one a head
REPAIR_BASE_CACHE="$COORD_DIR/base-red-cache.$(coord_mode)"        # the base's runs, read once a tick
rm -rf "$REPAIR_BASE_CACHE" 2>/dev/null; mkdir -p "$REPAIR_BASE_CACHE" 2>/dev/null
repair_base_red() { # <ticket> <pr-json> [hold] [nb-json] [also-required-json]
  local t="$1" pj="$2" n head base fails name rid c r notred="" unread="" names="" rids="" did
  n=$(jq -r '.number // empty' <<<"$pj" 2>/dev/null); head=$(jq -r '.headRefOid // empty' <<<"$pj" 2>/dev/null)
  base=$(jq -r '.baseRefName // empty' <<<"$pj" 2>/dev/null); base="${base:-$INTEGRATION_BRANCH}"
  [ -n "$n" ] && [ -n "$head" ] || return 0
  fails=$(pr_red_failed "$pj" "${3-approval}" "${4:-[]}" "${5:-[]}") && [ -n "$fails" ] || return 0
  c="$REPAIR_BASE_CACHE/$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_')"; mkdir -p "$c" 2>/dev/null || return 0
  while IFS=$'\t' read -r name rid; do
    [ -n "$name" ] || continue
    names="$names${names:+, }$name"; [ -z "$rid" ] || case " $rids " in *" $rid "*) ;; *) rids="$rids${rids:+ }$rid" ;; esac
    r=$(_base_latest_done "$base" "$name" "$c") && [ -n "$r" ] || { unread=1; continue; }
    jq -r '.conclusion // ""' <<<"$r" 2>/dev/null | grep -qE '^(FAILURE|ERROR|TIMED_OUT)$' || notred="$notred${notred:+, }$name"
  done <<<"$fails"
  if [ -z "$notred" ] && [ -z "$unread" ]; then
    if ! awk -F'\t' -v p="$n" -v h="$head" '$1 == p && $2 == h { f = 1 } END { exit !f }' "$REPAIR_BASE_RED" 2>/dev/null; then
      printf '%s\t%s\t%s\t%s\n' "$n" "$head" "$names" "$(date +%s)" >> "$REPAIR_BASE_RED"
      if ! coord_shadow; then
        printf '%s\t%s\t%s\t%s\n' - "$t" base-red "$(date +%s)" >> "$COORD_RUN_CLASSES"
        swarm_gh api "repos/$REPO_SLUG/issues/$n/comments" -X POST -f body="Not repaired: $names failed on $base's newest completed run too, so no change here can turn it green. It waits for $base to go green; the repairs before this do not count toward a rebuild.
$BASE_RED_MARK" >/dev/null 2>&1 || true
      fi
    fi
    echo "base-red on $names — waits for $base to go green"; return 1
  fi
  [ -n "$notred" ] || return 0
  # The base passes again: a head that waited on it is re-run once before it is repaired.
  awk -F'\t' -v p="$n" -v h="$head" '$1 == p && $2 == h { f = 1 } END { exit !f }' "$REPAIR_BASE_RED" 2>/dev/null || return 0
  [ -n "$rids" ] || return 0
  if coord_shadow; then echo "PR #$n waited on $base, which passes $notred now — would re-run its failed jobs ($rids) before any repair; no repair"; return 1; fi
  did=$(pr_red_rerun "$n" "$head" "$rids" "$REPAIR_BASE_RERUNS" 1) || return 0
  echo "PR #$n waited on $base, which passes $notred now — $did, its failed jobs before any repair; no repair"; return 1
}

repair_pr_red() { # <ticket> [pr-json] — 0 when its open PR is really red; else echoes why not
  local pj="${2:-}" v
  [ -n "$pj" ] || pj=$(open_pr_json "$1")
  if [ -z "$pj" ]; then
    # Only a fresh read can say there is none: a snapshot or no read at all decides nothing.
    if [ -n "${PRS:-}" ] && [ "${PRS_STALE:-0}" = 0 ]; then echo "has no open PR — nothing to repair"; return 1; fi
    return 0
  fi
  local n kind why ids did cl
  n=$(jq -r .number <<<"$pj")
  # A ticket that keeps the critic through the release: a red verdict is a red to repair.
  cl=$(release_labels_of "$n" "$1")
  local hold nbj crit
  hold="${COORDINATOR_HOLD_CHECK:-$(swarm_opt coordinator.holdCheck approval)}"; nbj=$(release_nonblocking_json "$cl"); crit=$(release_critic_required "$cl")
  if v=$(pr_red_verdict "$pj" "$hold" "$nbj" "$crit"); then
    [ "${v%%$'\t'*}" = red ] || return 0
    repair_base_red "$1" "$pj" "$hold" "$nbj" "$crit"; return
  fi
  IFS=$'\t' read -r kind why ids <<<"$v"
  # A cancelled required check is re-run, never repaired (coordinator.rerunCancelled, 2 a head).
  if [ "$kind" = rerun ]; then
    if coord_shadow; then did="would re-run ${ids:-nothing named}"
    else did=$(pr_red_rerun "$n" "$(jq -r '.headRefOid // ""' <<<"$pj")" "$ids" "$COORD_DIR/reruns.tsv" "$COORD_RERUN_MAX"); fi
    echo "PR #$n is not red ($why) — $did; no repair"; return 1
  fi
  echo "PR #$n is not red ($kind: $why) — no repair"
  return 1
}

# A HEALING ROW WHOSE PR IS GONE IS NEW WORK AGAIN. repair and approved-merge are set when a
# PR exists, by many hands (the finish pass, the merge lane, keep-fresh, base-wait, the judge,
# the PM), and nothing cleared them: 30 ready tickets sat queued as repair with no open PR,
# skipped "nothing to repair" on every tick, one 822 times in two days. Only a fresh read can
# say the PR is gone. The dead PR's note goes with it: a REPAIR brief re-seeds as a repair.
heal_pr_gone() { # <ticket> <class> — 0 when the row is new work now (in shadow, would be); says so
  local t="$1" cls="$2" st
  coord_healing_class "$cls" || return 1
  [ -n "${PRS:-}" ] && [ "${PRS_STALE:-0}" = 0 ] || return 1
  [ -z "$(open_pr_json "$t")" ] || return 1
  if declare -F coord_issue_meta >/dev/null && st=$(coord_issue_meta "$t") && [ -n "$st" ]; then st=${st%% *}
  else st=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json state -q .state 2>/dev/null) || return 1; fi
  if [ "$st" != OPEN ]; then
    [ -n "$st" ] || return 1
    coord_shadow && { say "#$t ($cls): $st with no open PR — would leave the queue"; return 1; }
    bash "$QUEUE" remove "$t" >/dev/null 2>&1 && say "#$t ($cls): $st with no open PR — left the queue"
    return 1
  fi
  coord_act_log reclass "$t" "$cls -> new: no open PR"
  if coord_shadow; then say "#$t ($cls): has no open PR — would go back to new work"; return 0; fi
  bash "$QUEUE" set-class "$t" new --note "" >/dev/null 2>&1 \
    || { say "#$t ($cls): has no open PR, and its queue entry could not be rewritten as new"; return 1; }
  say "#$t ($cls): has no open PR — back to new work"
}

# repair_ran_no_step <run log> — 0 when the run's log shows no step called the model. Every
# model step leaves "<step>: $<cost> · context" (driver/ai-step.sh driver_record_usage). A
# missing log is unknown, and counts as a repair, as before.
repair_ran_no_step() { [ -s "${1:-}" ] && ! grep -qE ': \$[0-9][0-9.]* · context ' "$1"; }
REPAIR_VOIDS=""   # tickets whose PR is told of a voided repair once this tick has read the PRs
repair_void() { # <ticket> <run-id> — the spawn no longer counts toward a rebuild
  printf '%s\t%s\trepair-void\t%s\n' "$2" "$1" "$(date +%s)" >> "$COORD_RUN_CLASSES"
  case " $REPAIR_VOIDS " in *" $1 "*) ;; *) REPAIR_VOIDS="$REPAIR_VOIDS${REPAIR_VOIDS:+ }$1" ;; esac
  say "repair: run $2 on #$1 ran no model step, so it is not counted as a repair (coordinator.rebuildAfterRepairs)"
}
repair_void_marks() { # — after PRS is read: each voided repair is marked on its open PR, for every host's count
  local t pj pr
  coord_shadow 2>/dev/null && return 0
  for t in $REPAIR_VOIDS; do
    pj=$(open_pr_json "$t"); pr=$(jq -r '.number // empty' <<<"${pj:-null}" 2>/dev/null); [ -n "$pr" ] || continue
    swarm_gh api "repos/$REPO_SLUG/issues/$pr/comments" -X POST -f body="A repair run on $(hostname -s 2>/dev/null || echo this host) for #$t ran no model step, so it is not counted toward a rebuild.
$REPAIR_VOID_MARK" >/dev/null 2>&1 || true
  done
  REPAIR_VOIDS=""
}
repair_record() { REPAIR_MARK_PJ="${2:-}" coord_record_class "$1" repair; }   # [pr-json]; coord_record_class marks the PR

repair_gate() { # <ticket> [pr-json]
  local t="$1" pj="${2:-}" st reps
  # The tick's batched read first (coord_issue_meta: its snapshot holds while the token is refused).
  if declare -F coord_issue_meta >/dev/null && st=$(coord_issue_meta "$t") && [ -n "$st" ]; then st=${st%% *}
  else st=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json state -q .state 2>/dev/null) || { echo "#$t could not be read"; return 1; }; fi
  [ "$st" = OPEN ] || { echo "#$t is $st"; return 1; }
  repair_pr_red "$t" "$pj" || return 1
  if [ "$COORD_REBUILD_AFTER" -gt 0 ] && reps=$(repairs_since_fresh "$t" "$pj") && [ "$reps" -ge "$COORD_REBUILD_AFTER" ]; then
    rebuild_fresh "$t" "$reps" "$pj" >&2 || true
    echo "repaired $reps times since it last started fresh — rebuilt from $INTEGRATION_BRANCH instead (coordinator.rebuildAfterRepairs)"; return 1
  fi
  return 0
}
