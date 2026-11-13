#!/usr/bin/env bash
# rebuild.sh — rebuild, don't repair. A pull request that cannot merge within about an
# hour is closed and its ticket built again, fresh from the integration branch.
#
#   . scripts/rebuild.sh      (after coordinator-env.sh, pr-red.sh, issue-status.sh)
#   rebuild_pass                       one pass over the tick's open PRs (PRS, CLAIMED)
#   rebuild_fresh <ticket> <why> [pr-json]   close the PR, keep its head, queue the ticket fresh
#   rebuild_pr_state <ticket> <pr-json>      "<state>\t<why>": stuck | base-red | pending | green | unread
#   rebuild_held <ticket> <pr-json> <labels-csv>   0 when a person owns it; echoes why
#   rebuild_park <ticket> <why> <pr-json> <builds>  past coordinator.rebuildMax: close, keep the head, park for the PM
#   rebuild_fix <ticket> <pr-json> <why> <kind>     a red or clashing PR goes back to its builder, on its own branch
#   rebuild_park_open <ticket> <why> <pr-json> <rounds>  past coordinator.fixRounds: park for the PM, the PR left open
#   rebuild_resume_draft <ticket> <pr-json>         a draft whose build is unfinished here is queued to be resumed
#
# WHY. Measured 22 Oct: 80% of build time went to repairs of stale changes, and the 12
# most-repaired PRs used 48% of three days' repair usage. A repair re-enters a stale
# branch, merges the trunk, reads a CI log and guesses; a rebuild starts from the
# trunk as it is, with the reviewed plan and what the last build learned as its brief.
#
# THE TRIGGER. Each open ticket PR is read every tick against the base's live rules
# (pr-red.sh). One that is STUCK — a required check settled red or cancelled, timed out or
# never run, a clash with its base, or a draft nothing is building — starts a clock
# (rebuild-clock.<mode>.tsv: pr \t epoch first seen stuck \t why). The clock runs through a
# re-run's pending checks and a new head (keep-fresh's merge), and stops when the PR goes
# green or something works it. Past coordinator.rebuildAfterMin (60; 0 is off) it is rebuilt.
# A cancelled check is also re-run (coordinator.rerunCancelled, 2 a head); left off the
# clock, a cancel held an open-work place for 12 hours.
#
# THE FIX ROUNDS (owner, 2026-11-09: "A broken PR goes back to its builder for 2 fix rounds,
# then parks for the PM"). While a stuck PR waits, or with the rebuild off, one whose required
# check settled red on its own code is queued for its builder with a "Fix:" brief: the PR's
# branch, the failing checks and their job logs, nothing else. The driver continues that
# branch and pushes to the same PR. A queued round goes ahead of every new build
# (coord_queue_ordered) and is spent only once its run starts (rebuild_fix_started, from the
# tick's spawn); queued and not started, it has cost nothing. One round per PR head: a started
# round whose run is gone (no claim, no live process) and left the head where it was is
# released, and the next is spent on the same head. coordinator.fixRounds (2) per PR,
# counted in fix-rounds.<mode>.tsv and never reset by a new head; past it the ticket parks
# for the PM with the PR left open. A clash gets one update from its base first
# (clash-updates.<mode>.tsv), then counts as a red. Never for a cancelled check (re-run
# above), a base-red, a PR a person owns or a ticket something works. Nothing else sends
# work to an open PR: no fixer, no stall guard.
#
# BEFORE A ROUND IS SPENT (measured 2026-11-11/12: four PRs red only on tests their base had
# since fixed, a draft one plan task into its build, and seven tickets re-parked every tick):
#   - a red PR is brought up to date with its base first, with no builder: one request per
#     PR head and base tip (stale-updates.<mode>.tsv). Whether it is behind is not asked: an
#     update never changes the PR's own code, so a red of its own is still red afterwards and
#     the round is spent then, on the head the update made. Refused (up to date, or it
#     conflicts), the round is spent at once.
#   - a draft whose build is unfinished on this host (the driver's record has steps done and
#     no ship) and that nothing is running is queued to be resumed, ahead of new builds;
#     its ticket set ready as a fix round's is; never a fix round, never parked for its
#     checks. coordinator.draftResumes (2) times per
#     head and step count; a record on another host cannot be seen, and it says so.
#   - the park for the PM after the fix rounds is written once per PR head
#     (fix-parks.<mode>.tsv); the same head later writes nothing, a new head re-arms it.
#   - the ticket's labels are read again the moment before a park or a fix round is written:
#     a person's label put on since the tick's read is left exactly as it is.
#
# WHAT IS NEVER REBUILT.
#   - anything, while every CI runner is offline or the runner list cannot be read (ci-runners.sh):
#     no close, rebuild, fix round or re-run. A draft is still resumed, a clash still gets its
#     one update from its base, and a held ticket's clock still stops.
#   - a person owns it: the hold label, do-not-merge, a person's own draft (person-stop.sh),
#     or a ticket waiting on a person (needs-human, owner or PM decision, parked, blocked,
#     gated, batched). It is left exactly as it is, clock and all.
#   - something works it: the ticket is claimed on any host or has a live run here.
#   - BASE-RED: every failing required check also failed on the base's newest completed
#     run (read per check, never assumed). No change on the PR can fix that, so it waits
#     for the base; its clock is stopped and it is told once. When the base passes again
#     its failed jobs are re-run once on that head (free) before the clock starts again.
#   - a red only on a check the base does not require, or on release.nonBlockingChecks,
#     or the sign-off hold's own check: that is not red (pr-red.sh).
#
# THE REBUILD. The PR's head is kept at refs/stale/<ticket>/pr-<n>, the PR is closed with
# a note and its branch deleted, this host's driver record is archived, the ticket goes
# back to ready, and it is queued at the front of its priority as new work with a
# "Rebuild:" brief (the driver sets aside any local state for a brief that starts so, on
# every host): the reviewed plan, the last review's findings and why it could not merge.
# Each required check it failed goes on the class ledger as check:<name>; housekeeping reads
# those logs later for test:<file> (finding-class.sh), so no tick waits on a log.
[ -z "${_REBUILD_SH:-}" ] || return 0
_REBUILD_SH=1
: "${QUEUE:=$KIT_ROOT/scripts/coordinator-queue.sh}"
: "${FINDING_CLASS:=$KIT_ROOT/scripts/finding-class.sh}"
declare -F say >/dev/null || say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
declare -F open_work_person_drafted >/dev/null || . "$KIT_ROOT/scripts/open-work.sh" || return 1

REBUILD_AFTER_MIN="${COORDINATOR_REBUILD_AFTER_MIN:-$(swarm_opt coordinator.rebuildAfterMin 60)}"
case "$REBUILD_AFTER_MIN" in ''|*[!0-9]*) REBUILD_AFTER_MIN=60 ;; esac
REBUILD_CLOCK="$COORD_DIR/rebuild-clock.$(coord_mode).tsv"   # pr \t epoch first seen stuck \t why
REBUILD_CI_DOWN="$COORD_DIR/rebuild-ci-down.$(coord_mode).tsv"   # epoch every CI runner was first seen down
# A ticket built this many times already parks for the PM instead of building again
# (coordinator.rebuildMax; 0 is no cap). Measured 2026-11-09: one ticket rebuilt 12
# times in a week, 568 PRs thrown away against 478 merged. Each build left a
# refs/stale/<ticket>/pr-<n>, so those refs are the count.
REBUILD_MAX="${COORDINATOR_REBUILD_MAX:-$(swarm_opt coordinator.rebuildMax 2)}"
case "$REBUILD_MAX" in ''|*[!0-9]*) REBUILD_MAX=2 ;; esac
# A PR red on its own code goes back to its builder this many times, then parks for the PM
# with the PR left open (coordinator.fixRounds; 0 is off). A hard cap per PR: repairs were
# deleted when the 12 most-repaired PRs used 48% of repair usage.
FIX_ROUNDS="${COORDINATOR_FIX_ROUNDS:-$(swarm_opt coordinator.fixRounds 2)}"
case "$FIX_ROUNDS" in ''|*[!0-9]*) FIX_ROUNDS=2 ;; esac
FIX_LEDGER="$COORD_DIR/fix-rounds.$(coord_mode).tsv"        # pr \t round \t the head it was sent for \t queued|started
CLASH_UPDATES="$COORD_DIR/clash-updates.$(coord_mode).tsv"  # pr \t epoch: its one update from the base
STALE_UPDATES="$COORD_DIR/stale-updates.$(coord_mode).tsv"  # pr \t head \t base tip \t epoch \t ok|refused \t the head after it (- until seen)
FIX_PARKS="$COORD_DIR/fix-parks.$(coord_mode).tsv"          # pr \t the head it was parked for the PM at \t epoch
DRAFT_RESUMES="$COORD_DIR/draft-resumes.$(coord_mode).tsv"  # pr \t head \t steps done \t times queued to resume
# An accepted update moves the head within seconds; this long with the old head still read, it is waited for.
REBUILD_UPDATE_WAIT_SEC="${REBUILD_UPDATE_WAIT_SEC:-600}"
case "$REBUILD_UPDATE_WAIT_SEC" in ''|*[!0-9]*) REBUILD_UPDATE_WAIT_SEC=600 ;; esac
DRAFT_RESUME_MAX="${COORDINATOR_DRAFT_RESUMES:-$(swarm_opt coordinator.draftResumes 2)}"
case "$DRAFT_RESUME_MAX" in ''|*[!0-9]*) DRAFT_RESUME_MAX=2 ;; esac
# A cancelled, timed-out or runner-less required check is re-run this many times a head.
COORD_RERUN_MAX="${COORDINATOR_RERUN_CANCELLED:-$(swarm_opt coordinator.rerunCancelled 2)}"
case "$COORD_RERUN_MAX" in ''|*[!0-9]*) COORD_RERUN_MAX=2 ;; esac
# The base branch's required checks, read from its live rules once per tick (pr-red.sh).
PR_RED_REQ_FILE="$COORD_DIR/required-checks.$(coord_mode)"; : > "$PR_RED_REQ_FILE" 2>/dev/null; export PR_RED_REQ_FILE
REBUILD_BASE_RED="$COORD_DIR/base-red.$(coord_mode).tsv"            # pr \t head \t checks \t epoch
REBUILD_BASE_RERUNS="$COORD_DIR/base-red-reruns.$(coord_mode).tsv"  # pr_red_rerun's ledger, one a head
REBUILD_BASE_CACHE="$COORD_DIR/base-red-cache.$(coord_mode)"        # the base's runs, read once a tick
rm -rf "$REBUILD_BASE_CACHE" 2>/dev/null; mkdir -p "$REBUILD_BASE_CACHE" 2>/dev/null
REBUILD_BASE_DEPTH="${REBUILD_BASE_DEPTH:-5}"
REBUILD_RERUNS="$COORD_DIR/reruns.tsv"                              # pr_red_rerun's ledger for a cancelled check
BASE_RED_MARK='<!-- harness:base-red -->'

open_pr_json() { # <ticket> — its open PR as this tick read it, or nothing
  printf '%s' "${PRS:-[]}" | jq -c --arg pre "$BRANCH_PREFIX" --arg t "$1" \
    "$BRANCH_TICKET_JQ"'[.[] | select(.headRefName | branch_is_ticket($pre; $t))] | sort_by(.number) | last // empty' 2>/dev/null
}

# ---- the base's newest completed run of a check ---------------------------------
# _rebuild_base_runs <sha> — that commit's check runs, every run of each check.
_rebuild_base_runs() {
  # gh-read-ok: an unreadable base decides nothing — the red stays the PR's own
  swarm_gh api "repos/${REPO_SLUG:?}/commits/$1/check-runs?per_page=100&filter=all" 2>/dev/null \
    | jq -c '[.check_runs[]? | {name, id, status: ((.status // "") | ascii_upcase),
              conclusion: ((.conclusion // "") | ascii_upcase), completedAt: (.completed_at // ""),
              startedAt: (.started_at // ""), detailsUrl: (.details_url // "")}]' 2>/dev/null
}
# _rebuild_base_latest_done <base> <name> <cache-dir> — the check's newest completed run on
# the base: at its head, else the commit before, up to REBUILD_BASE_DEPTH back. Nothing when none.
_rebuild_base_latest_done() {
  local base="$1" n="$2" c="$3" sha runs hit
  # The caller reads this through `IFS=<tab> read <<<"$(…)"`, and bash 3.2 hands that IFS to
  # the substitution: unset here, five shas were one word and one request for a commit
  # named by all five (2026-11-11), so the base's runs were never read on macOS.
  local IFS=$' \t\n'
  if [ ! -f "$c/base-shas" ]; then
    # gh-read-ok: unreadable base commits decide nothing — the red stays the PR's own
    swarm_gh api "repos/${REPO_SLUG:?}/commits?sha=$base&per_page=$REBUILD_BASE_DEPTH" 2>/dev/null \
      | jq -r '.[]?.sha // empty' > "$c/base-shas" 2>/dev/null || : > "$c/base-shas"
  fi
  for sha in $(cat "$c/base-shas"); do
    [ -f "$c/runs-$sha" ] || _rebuild_base_runs "$sha" > "$c/runs-$sha"
    runs=$(cat "$c/runs-$sha"); [ -n "$runs" ] || continue
    hit=$(printf '%s' "$runs" | jq -c --arg n "$n" "$CHECK_NEWEST_JQ"'
      [ .[] | select(.status == "COMPLETED") ] | newest_runs | map(select(.name == $n)) | first // empty' 2>/dev/null)
    [ -n "$hit" ] && { printf '%s' "$hit" | jq -c --arg s "$sha" '. + {sha: $s}'; return 0; }
  done
  return 1
}

# rebuild_base_red <ticket> <pr-json> [hold] [nb-json] [also-required-json] — 0 when the
# PR's red is its own; else echoes why it waits: every failing required check failed on the
# base's newest completed run too (base-red), or the base went green and its failed jobs
# are re-run first. Measured 31 Oct - 1 Nov: 32 of 61 repair spawns and 13 of 17 rebuilds
# were of PRs whose only red required check had failed on develop's newest push run too.
rebuild_base_red() {
  local t="$1" pj="$2" n head base fails name rid c r notred="" unread="" names="" rids="" did
  n=$(jq -r '.number // empty' <<<"$pj" 2>/dev/null); head=$(jq -r '.headRefOid // empty' <<<"$pj" 2>/dev/null)
  base=$(jq -r '.baseRefName // empty' <<<"$pj" 2>/dev/null); base="${base:-$INTEGRATION_BRANCH}"
  [ -n "$n" ] && [ -n "$head" ] || return 0
  fails=$(pr_red_failed "$pj" "${3-approval}" "${4:-[]}" "${5:-[]}") && [ -n "$fails" ] || return 0
  c="$REBUILD_BASE_CACHE/$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_')"; mkdir -p "$c" 2>/dev/null || return 0
  while IFS=$'\t' read -r name rid; do
    [ -n "$name" ] || continue
    names="$names${names:+, }$name"; [ -z "$rid" ] || case " $rids " in *" $rid "*) ;; *) rids="$rids${rids:+ }$rid" ;; esac
    r=$(_rebuild_base_latest_done "$base" "$name" "$c") && [ -n "$r" ] || { unread=1; continue; }
    jq -r '.conclusion // ""' <<<"$r" 2>/dev/null | grep -qE '^(FAILURE|ERROR|TIMED_OUT)$' || notred="$notred${notred:+, }$name"
  done <<<"$fails"
  if [ -z "$notred" ] && [ -z "$unread" ]; then
    if ! awk -F'\t' -v p="$n" -v h="$head" '$1 == p && $2 == h { f = 1 } END { exit !f }' "$REBUILD_BASE_RED" 2>/dev/null; then
      printf '%s\t%s\t%s\t%s\n' "$n" "$head" "$names" "$(date +%s)" >> "$REBUILD_BASE_RED"
      coord_shadow || swarm_gh api "repos/$REPO_SLUG/issues/$n/comments" -X POST -f body="Not rebuilt: $names failed on $base's newest completed run too, so no change here can turn it green. It waits for $base to go green; its rebuild clock starts again after that.
$BASE_RED_MARK" >/dev/null 2>&1 || true
    fi
    echo "base-red on $names — waits for $base to go green"; return 1
  fi
  [ -n "$notred" ] || return 0
  # The base passes again: a head that waited on it is re-run once before its clock runs.
  awk -F'\t' -v p="$n" -v h="$head" '$1 == p && $2 == h { f = 1 } END { exit !f }' "$REBUILD_BASE_RED" 2>/dev/null || return 0
  [ -n "$rids" ] || return 0
  if coord_shadow; then echo "PR #$n waited on $base, which passes $notred now — would re-run its failed jobs ($rids) first"; return 1; fi
  did=$(pr_red_rerun "$n" "$head" "$rids" "$REBUILD_BASE_RERUNS" 1) || return 0
  echo "PR #$n waited on $base, which passes $notred now — $did, its failed jobs, first"; return 1
}

# rebuild_pr_state <ticket> <pr-json> — one line "<state>\t<why>":
#   stuck     a required check settled red (and the base passes it) or cancelled (re-run now too),
#             a clash, or a settled draft
#   base-red  its red is the base's, or its failed jobs were just re-run after the base went green
#   pending   a required check still running
#   green     nothing required failed and nothing clashes
#   unread    the PR or its base's rules could not be read
# A stuck line carries a third field, red or clash, when a fix round may take it (rebuild_fix).
rebuild_pr_state() {
  local t="$1" pj="$2" v kind why ids n cl hold nbj crit w
  n=$(jq -r '.number // empty' <<<"$pj" 2>/dev/null)
  cl=$(release_labels_of "$n" "$t")
  hold="${COORDINATOR_HOLD_CHECK:-$(swarm_opt coordinator.holdCheck approval)}"; nbj=$(release_nonblocking_json "$cl"); crit=$(release_critic_required "$cl")
  v=$(pr_red_verdict "$pj" "$hold" "$nbj" "$crit")
  IFS=$'\t' read -r kind why ids <<<"$v"
  case "$kind" in
    red)
      if w=$(rebuild_base_red "$t" "$pj" "$hold" "$nbj" "$crit"); then printf 'stuck\t%s\tred\n' "$why"
      else printf 'base-red\t%s\n' "$w"; fi ;;
    clash)  printf 'stuck\t%s\tclash\n' "$why" ;;
    finish) printf 'stuck\ta draft nothing is building, its checks settled\n' ;;
    rerun)
      local did
      if [ -n "${REBUILD_CI_HOLD:-}" ]; then did="not re-run: $REBUILD_CI_HOLD"
      elif coord_shadow; then did="would re-run ${ids:-nothing named}"
      else did=$(pr_red_rerun "$n" "$(jq -r '.headRefOid // ""' <<<"$pj")" "$ids" "$REBUILD_RERUNS" "$COORD_RERUN_MAX"); fi
      say "rebuild: PR #$n $why — $did" >&2
      printf 'stuck\t%s\n' "$why" ;;
    pending|green) printf '%s\t%s\n' "$kind" "$why" ;;
    *) printf 'unread\t%s\n' "${why:-its checks could not be read}" ;;
  esac
}

# The ticket labels that mean a person acts next: a PR under one is theirs, never closed.
rebuild_person_labels() {
  printf '%s\n' "$LBL_NEEDS_HUMAN" "$LBL_OWNER_DECISION" "${LBL_PM_DECISION:-}" "$LBL_PARKED" "$LBL_BLOCKED" \
    "$LBL_EXTERNAL_BLOCKED" "$LBL_GATED" "${LBL_BATCHED:-}" "$HOLD_LABEL" $DECISION_LABELS | awk 'NF && !seen[$0]++'
}
# rebuild_held <ticket> <pr-json> <ticket-labels-csv> — 0 when a person owns the PR or its
# ticket; echoes why. An unreadable draft timeline is held too: unknown is never "the machine's".
rebuild_held() {
  local t="$1" pj="$2" lab="$3" l pl pr at
  pl=$(jq -r '[.labels[]?.name] | join(",")' <<<"$pj" 2>/dev/null)
  for l in "$HOLD_LABEL" "${LBL_DO_NOT_MERGE:-do-not-merge}"; do
    [ -n "$l" ] || continue
    case ",$pl," in *",$l,"*) echo "the PR carries $l"; return 0 ;; esac
  done
  while read -r l; do
    [ -n "$l" ] || continue
    case ",$lab," in *",$l,"*) echo "#$t waits on a person ($l)"; return 0 ;; esac
  done <<< "$(rebuild_person_labels)"
  if [ "$(jq -r '.isDraft // false' <<<"$pj" 2>/dev/null)" = true ]; then
    pr=$(jq -r '.number' <<<"$pj"); at=$(jq -r '.updatedAt // ""' <<<"$pj")
    open_work_person_drafted "$pr" "$at" >/dev/null
    case $? in 0) echo "a person put it back to draft"; return 0 ;; 2) echo "its draft timeline could not be read"; return 0 ;; esac
  fi
  return 1
}

# ---- the clock ---------------------------------------------------------------------
rebuild_clock_since() { awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' "$REBUILD_CLOCK" 2>/dev/null; }
rebuild_clock_start() { # <pr> <why> — the epoch the clock started, set now if it had none
  local s; s=$(rebuild_clock_since "$1")
  case "$s" in ''|*[!0-9]*) s=$(swarm_now); printf '%s\t%s\t%s\n' "$1" "$s" "$(printf '%s' "$2" | tr '\t\n' '  ')" >> "$REBUILD_CLOCK" ;; esac
  printf '%s' "$s"
}
# rebuild_clock_pause <runner state> — offline: the epoch CI went down is kept; up again: every
# clock moves on by the time it was down, so a stuck PR is not charged for an outage. Unread
# is no outage: it marks nothing and slides nothing, or a flaky read would push every clock back.
rebuild_clock_pause() {
  local now down slide; now=$(swarm_now)
  case "$1" in
    offline) [ -s "$REBUILD_CI_DOWN" ] || printf '%s\n' "$now" > "$REBUILD_CI_DOWN"; return 0 ;;
    unread) return 0 ;;
  esac
  [ -f "$REBUILD_CI_DOWN" ] || return 0
  down=$(head -1 "$REBUILD_CI_DOWN" 2>/dev/null)
  case "$down" in ''|*[!0-9]*) rm -f "$REBUILD_CI_DOWN"; return 0 ;; esac
  slide=$(( now - down )); [ "$slide" -gt 0 ] || slide=0
  if [ -f "$REBUILD_CLOCK" ]; then
    awk -F'\t' -v s="$slide" 'BEGIN { OFS = "\t" } $2 ~ /^[0-9]+$/ { $2 += s; } { print }' "$REBUILD_CLOCK" > "$REBUILD_CLOCK.$$" 2>/dev/null \
      && mv -f "$REBUILD_CLOCK.$$" "$REBUILD_CLOCK" || return 0
  fi
  rm -f "$REBUILD_CI_DOWN"
  say "rebuild: CI was down $(( slide / 60 )) min — every stuck clock moves on by that"
}
rebuild_clock_stop() { # <pr>
  [ -f "$REBUILD_CLOCK" ] || return 0
  awk -F'\t' -v p="$1" '$1 != p' "$REBUILD_CLOCK" > "$REBUILD_CLOCK.$$" 2>/dev/null && mv -f "$REBUILD_CLOCK.$$" "$REBUILD_CLOCK"
}

# ---- the rebuild ---------------------------------------------------------------------
# rebuild_archive_state <ticket> — this host's driver record of it forgets every step: the
# answers move to steps/archive/, the finished list empties. Left done, each rebuild run said
# "nothing left to do" and exited 0 (15735: 22 times a day). Another host's record is caught
# by the driver itself: a "Rebuild:" brief, or shipped with no PR open or merged, is fresh there too.
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
    && mv "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; say "rebuild: #$t's driver record could not be reset — the driver sets it aside on the Rebuild: brief"; }
}

# rebuild_brief <ticket> <pr> <why> <ref> — the queue note the fresh build carries: the
# reason, the reviewed plan and the last review's findings from this host's record, cut to
# fit a brief (driver_keep_brief keeps 4 KB). A plan another host made is not here to read:
# the brief says so, and the ticket's own body and answers are read by every step anyway.
rebuild_brief() {
  local t="$1" pr="$2" why="$3" ref="$4" d plan="" learned=""
  d="${DRIVER_DIR:-$STATE_DIR/driver}/$t/steps"
  [ -s "$d/plan.json" ] && plan=$(jq -r '
      [ (.tasks // [])[] | "- " + (.title // .item // "a task") + (if (.files // []) | length > 0 then " (" + ((.files // [])[:4] | join(", ")) + ")" else "" end) ]
      | join("\n")' "$d/plan.json" 2>/dev/null | cut -c1-240 | head -20)
  [ -s "$d/review.json" ] && learned=$(jq -r '
      [ (.findings // [])[] | "- " + (.grade // "?") + ": " + ((.summary // .reason // "") | gsub("[\n\t]"; " ")) + (if .file then " (" + .file + ")" else "" end) ]
      | join("\n")' "$d/review.json" 2>/dev/null | cut -c1-240 | head -12)
  printf 'Rebuild: PR #%s could not merge within %s min (%s). Build the ticket fresh from %s; the old head is kept at %s for reference only — read it, never resume it.\n' \
    "$pr" "$REBUILD_AFTER_MIN" "$why" "$INTEGRATION_BRANCH" "$ref"
  if [ -n "$plan" ]; then printf '\nThe reviewed plan the last build made:\n%s\n' "$plan"
  else printf '\nThe last build'"'"'s plan is not on this host: plan again from the ticket.\n'; fi
  [ -z "$learned" ] || printf '\nWhat its last review found:\n%s\n' "$learned"
  printf '\nWhy it could not merge: %s. Build so that does not happen again.\n' "$why"
}

# rebuild_count_failures <ticket> <pr> <pr-json> — one sighting per required check it failed.
# Never stops a rebuild: a count it could not take is said.
rebuild_count_failures() {
  local t="$1" pr="$2" pj="$3" cl hold nbj crit fails name rid job
  cl=$(release_labels_of "$pr" "$t")
  hold="${COORDINATOR_HOLD_CHECK:-$(swarm_opt coordinator.holdCheck approval)}"; nbj=$(release_nonblocking_json "$cl"); crit=$(release_critic_required "$cl")
  fails=$(pr_red_failed "$pj" "$hold" "$nbj" "$crit") || { say "rebuild: PR #$pr's failed checks could not be read — not counted"; return 0; }
  while IFS=$'\t' read -r name rid; do
    [ -n "$name" ] || continue
    job=$(jq -r --arg n "$name" '[(.statusCheckRollup // [])[] | select((.name // .context // "") == $n)] | max_by(.completedAt // "") | (.detailsUrl // .targetUrl // "") | capture("/job/(?<j>[0-9]+)").j? // ""' <<<"$pj" 2>/dev/null)
    bash "$FINDING_CLASS" check-failed "$t" "$pr" "$name" "$job" >/dev/null 2>&1 \
      || say "rebuild: PR #$pr's failed check $name could not be counted"
  done <<<"$fails"
}

rebuild_fresh() { # <ticket> <why> [pr-json] — 0 when the PR was closed and the ticket queued fresh
  local t="$1" why="$2" pj="${3:-}" pr sha ref note brief
  [ -n "$pj" ] || pj=$(open_pr_json "$t"); [ -n "$pj" ] || { say "rebuild: #$t has no open PR this tick — nothing to close"; return 1; }
  pr=$(jq -r .number <<<"$pj"); sha=$(jq -r '.headRefOid // ""' <<<"$pj"); ref="refs/stale/$t/pr-$pr"
  coord_act_log rebuild "$t" "PR #$pr: $why"
  if coord_shadow; then say "rebuild: would close PR #$pr ($why) and build #$t fresh from $INTEGRATION_BRANCH"; return 0; fi
  [ -n "$sha" ] && swarm_gh api "repos/$REPO_SLUG/git/refs" -f ref="$ref" -f sha="$sha" >/dev/null 2>&1 \
    || swarm_gh api "repos/$REPO_SLUG/git/refs/${ref#refs/}" -X PATCH -f sha="$sha" -F force=true >/dev/null 2>&1 \
    || { say "rebuild: #$t — PR #$pr's head could not be kept at $ref; the PR is left open"; return 1; }
  brief=$(rebuild_brief "$t" "$pr" "$why" "$ref")
  note="Closed to rebuild fresh: this PR could not merge within $REBUILD_AFTER_MIN minutes ($why), so ticket #$t builds again from $INTEGRATION_BRANCH (coordinator.rebuildAfterMin). Its work is kept at \`$ref\` ($sha)."
  swarm_gh pr close "$pr" --repo "$REPO_SLUG" --delete-branch --comment "$note" >/dev/null 2>&1 \
    || { say "rebuild: #$t — PR #$pr could not be closed; left as it is"; return 1; }
  rebuild_count_failures "$t" "$pr" "$pj"
  rebuild_archive_state "$t"
  issue_status_set "$t" "$LBL_READY" >/dev/null 2>&1 || say "rebuild: #$t could not be set $LBL_READY"
  bash "$QUEUE" add "$t" --class new --first --note "$brief" >/dev/null 2>&1 \
    || say "rebuild: #$t could not be queued — the next seed finds it ready"
  coord_record_class "$t" rebuild
  rebuild_clock_stop "$pr"
  say "rebuild: closed PR #$pr ($why; head kept at $ref) — #$t is queued to build fresh from $INTEGRATION_BRANCH"
}

# rebuild_prior <ticket> — how many times it was rebuilt already (its refs/stale/<t>/ refs),
# or nothing when they could not be read: an unread count never parks a ticket.
rebuild_prior() {
  # gh-read-ok: an unread count leaves the rebuild as it was
  swarm_gh api "repos/${REPO_SLUG:?}/git/matching-refs/stale/$1/" 2>/dev/null | jq -r 'if type == "array" then length else empty end' 2>/dev/null
}

rebuild_park() { # <ticket> <why> <pr-json> <builds> — 0 when the PR was closed and the ticket parked for the PM
  local t="$1" why="$2" pj="$3" n="$4" pr sha ref fails note
  pr=$(jq -r .number <<<"$pj"); sha=$(jq -r '.headRefOid // ""' <<<"$pj"); ref="refs/stale/$t/pr-$pr"
  coord_act_log rebuild-park "$t" "PR #$pr: $why (built $n times)"
  if coord_shadow; then say "rebuild: would park #$t for the PM — built $n times, PR #$pr still cannot merge ($why)"; return 0; fi
  [ -n "$sha" ] && swarm_gh api "repos/$REPO_SLUG/git/refs" -f ref="$ref" -f sha="$sha" >/dev/null 2>&1 \
    || swarm_gh api "repos/$REPO_SLUG/git/refs/${ref#refs/}" -X PATCH -f sha="$sha" -F force=true >/dev/null 2>&1 \
    || { say "rebuild: #$t — PR #$pr's head could not be kept at $ref; the PR is left open"; return 1; }
  fails=$(pr_red_failed "$pj" "${COORDINATOR_HOLD_CHECK:-$(swarm_opt coordinator.holdCheck approval)}" "[]" "" 2>/dev/null | cut -f1 | grep -v '^$' | sed 's/^/- /')
  note="Parked for the PM: ticket #$t has been built $n times and PR #$pr still cannot merge ($why), so it is not built again (coordinator.rebuildMax $REBUILD_MAX). Its work is kept at \`$ref\` ($sha)."
  swarm_gh pr close "$pr" --repo "$REPO_SLUG" --delete-branch --comment "$note" >/dev/null 2>&1 \
    || { say "rebuild: #$t — PR #$pr could not be closed; left as it is"; return 1; }
  rebuild_count_failures "$t" "$pr" "$pj"
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "$note${fails:+

Failing checks on the last build:
$fails}" >/dev/null 2>&1 || say "rebuild: #$t could not be told why it parked"
  issue_status_set "$t" "$LBL_PARKED" --also "${LBL_PM_DECISION:-status:pm-decision}" >/dev/null 2>&1 \
    || say "rebuild: #$t could not be parked; the next seed may build it again"
  rebuild_clock_stop "$pr"
  say "rebuild: parked #$t for the PM — built $n times, PR #$pr closed ($why; head kept at $ref)"
}

# ---- the fix rounds ------------------------------------------------------------------
# rebuild_fix_checks <ticket> <pr-json> — the required checks that failed on the PR's own
# code: one "name \t job url" line each. 1 when they could not be read.
rebuild_fix_checks() {
  local t="$1" pj="$2" pr cl hold nbj crit fails name rid url
  pr=$(jq -r '.number // empty' <<<"$pj" 2>/dev/null)
  cl=$(release_labels_of "$pr" "$t")
  hold="${COORDINATOR_HOLD_CHECK:-$(swarm_opt coordinator.holdCheck approval)}"; nbj=$(release_nonblocking_json "$cl"); crit=$(release_critic_required "$cl")
  fails=$(pr_red_failed "$pj" "$hold" "$nbj" "$crit") || return 1
  while IFS=$'\t' read -r name rid; do
    [ -n "$name" ] || continue
    url=$(jq -r --arg n "$name" '[(.statusCheckRollup // [])[] | select((.name // .context // "") == $n)] | max_by(.completedAt // "") | (.detailsUrl // .targetUrl // "")' <<<"$pj" 2>/dev/null)
    printf '%s\t%s\n' "$name" "$url"
  done <<<"$fails"
}

# rebuild_fix_brief <pr> <branch> <base> <why> <kind> <round> <checks> — the queue note a fix
# run carries. Narrow on purpose: the branch, what failed and where its log is. No plan, no
# review history. The driver reads its first line: "Fix: PR #<n>" continues that PR's branch.
rebuild_fix_brief() {
  local pr="$1" br="$2" base="$3" why="$4" kind="$5" round="$6" checks="$7"
  printf 'Fix: PR #%s — %s\n' "$pr" "$why"
  printf '\nFix round %s of %s. The pull request is open on %s and this run continues on that branch: cut no new branch and do not open a new pull request.\n' "$round" "$FIX_ROUNDS" "$br"
  if [ "$kind" = clash ]; then
    printf '\nIt conflicts with %s. Merge origin/%s into %s, resolve the conflicts, and change nothing else.\n' "$base" "$base" "$br"
  else
    printf '\nThe required checks that failed, each with its job log:\n'
    printf '%s\n' "$checks" | awk -F'\t' 'NF { printf "- %s%s\n", $1, ($2 != "" ? ": " $2 : "") }'
    printf '\nFix only what those checks report, and change nothing else.\n'
  fi
  printf 'The fix ships as a push to %s, which the open pull request picks up.\n' "$br"
}

# rebuild_fix_note_pr <queue note> — the PR a fix round's note names, or nothing.
rebuild_fix_note_pr() { printf '%s\n' "${1:-}" | sed -n '1s/^Fix: PR #\([0-9][0-9]*\).*/\1/p'; }
# rebuild_fix_queued <ticket> <pr> — 0 while that PR's fix round is on the coordinator's queue.
rebuild_fix_queued() {
  [ "$(rebuild_fix_note_pr "$(jq -r --argjson n "$1" '.tickets[]? | select(.n == $n) | .note // ""' "$COORD_QUEUE" 2>/dev/null)")" = "$2" ]
}
# rebuild_fix_run_alive <ticket> — 0 while something works the ticket: a claim on any host, or a live run here.
rebuild_fix_run_alive() { grep -qx "$1" <<<"${CLAIMED:-}" || swarm_ticket_live "$1"; }
# rebuild_fix_started <queue note> — the run of the fix round that note carries has started:
# the round is spent from now. The tick calls it when the spawn succeeded.
rebuild_fix_started() {
  local pr n; pr=$(rebuild_fix_note_pr "${1:-}"); [ -n "$pr" ] || return 0
  if awk -F'\t' -v p="$pr" '$1 == p { f = 1 } END { exit !f }' "$FIX_LEDGER" 2>/dev/null; then
    awk -F'\t' -v OFS='\t' -v p="$pr" '$1 == p { $4 = "started" } { print }' "$FIX_LEDGER" > "$FIX_LEDGER.$$" 2>/dev/null \
      && mv -f "$FIX_LEDGER.$$" "$FIX_LEDGER"
  else
    # No row to mark: counted from the brief, so a lost ledger never makes a round free.
    n=$(printf '%s\n' "$1" | sed -n 's/^Fix round \([0-9][0-9]*\) of .*/\1/p' | head -1)
    printf '%s\t%s\t-\tstarted\n' "$pr" "${n:-1}" >> "$FIX_LEDGER"
  fi
}
# rebuild_fix_due <ticket> — 0 while the ticket's open PR is still red or clashing, so a
# queued fix round has something to fix. A re-run that passed meanwhile sends no builder.
rebuild_fix_due() {
  local t="$1" pj n cl hold nbj crit v
  pj=$(open_pr_json "$t"); [ -n "$pj" ] || return 1
  n=$(jq -r '.number // empty' <<<"$pj" 2>/dev/null)
  cl=$(release_labels_of "$n" "$t")
  hold="${COORDINATOR_HOLD_CHECK:-$(swarm_opt coordinator.holdCheck approval)}"; nbj=$(release_nonblocking_json "$cl"); crit=$(release_critic_required "$cl")
  v=$(pr_red_verdict "$pj" "$hold" "$nbj" "$crit")
  case "${v%%$'\t'*}" in red|clash) return 0 ;; *) return 1 ;; esac
}

# rebuild_labels_now <ticket> — the ticket's labels read this moment into REBUILD_LABELS_NOW,
# one a line. 0 when a person holds it, the label in REBUILD_HELD_BY; 1 when nobody does; 2 unread.
# The read issue_status_set would make itself: handed on as ISSUE_STATUS_CURRENT, it costs nothing
# more. Never called inside $( ): it answers in variables.
rebuild_labels_now() {
  local l
  REBUILD_HELD_BY=""
  REBUILD_LABELS_NOW=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json labels -q '.labels[].name' 2>/dev/null) || return 2
  while read -r l; do
    [ -n "$l" ] || continue
    if grep -qxF -- "$l" <<<"$REBUILD_LABELS_NOW"; then REBUILD_HELD_BY="$l"; return 0; fi
  done <<< "$(rebuild_person_labels)"
  return 1
}

# rebuild_parked_at <pr> <head> — 0 when the PM park after the fix rounds was written for this head.
rebuild_parked_at() { awk -F'\t' -v p="$1" -v h="$2" '$1 == p && $2 == h { f = 1 } END { exit !f }' "$FIX_PARKS" 2>/dev/null; }

# rebuild_ledger_put <file> <pr> <row…> — the PR's one row in a ledger, replaced.
rebuild_ledger_put() {
  local f="$1" p="$2"; shift 2
  { awk -F'\t' -v p="$p" '$1 != p' "$f" 2>/dev/null; (IFS=$'\t'; printf '%s\n' "$p${*:+$IFS$*}"); } > "$f.$$" && mv -f "$f.$$" "$f"
}

# rebuild_base_tip <base> — its newest commit as this tick read it (rebuild_base_red's cache), or -.
rebuild_base_tip() {
  local f s=""
  f="$REBUILD_BASE_CACHE/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')/base-shas"
  [ -s "$f" ] && s=$(sed -n 1p "$f")
  printf '%s' "${s:--}"
}

# rebuild_stale_update <pr> <head> <base> <why> — 0 when the red PR was just brought up to date
# with its base, or waits on that update; 1 when the red is to be treated as its own. One
# request per PR head and base tip. The head an update made gets no second one: red there,
# the round is spent.
rebuild_stale_update() {
  local pr="$1" head="$2" base="$3" why="$4" tip uh="" ub="" at="" res="" after="" now
  tip=$(rebuild_base_tip "$base"); now=$(swarm_now)
  IFS=$'\t' read -r uh ub at res after <<<"$(awk -F'\t' -v p="$pr" '$1 == p { r = $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 } END { print r }' "$STALE_UPDATES" 2>/dev/null)"
  if [ "$res" = ok ]; then
    if [ "$uh" = "$head" ]; then
      case "$at" in ''|*[!0-9]*) at=0 ;; esac
      if [ $((now - at)) -lt "$REBUILD_UPDATE_WAIT_SEC" ]; then
        say "rebuild: PR #$pr is stuck ($why) — its update from $base was accepted and the new head is not read yet; it waits for that"
        return 0
      fi
    elif [ "${after:--}" = - ]; then
      after="$head"; rebuild_ledger_put "$STALE_UPDATES" "$pr" "$uh" "$ub" "$at" ok "$after"
      say "rebuild: PR #$pr is still red on the head its update from $base made ($why) — the red is its own"
    fi
    [ "$after" != "$head" ] || return 1
  fi
  [ "$uh" != "$head" ] || [ "$ub" != "$tip" ] || return 1
  if coord_shadow; then say "rebuild: would bring PR #$pr up to date with $base once ($why) before any fix round"; return 1; fi
  if swarm_gh api "repos/$REPO_SLUG/pulls/$pr/update-branch" -X PUT -f expected_head_sha="$head" >/dev/null 2>&1; then
    rebuild_ledger_put "$STALE_UPDATES" "$pr" "$head" "$tip" "$now" ok -
    say "rebuild: PR #$pr is red ($why) and was brought up to date with $base first — no builder sent, no fix round spent"
    return 0
  fi
  rebuild_ledger_put "$STALE_UPDATES" "$pr" "$head" "$tip" "$now" refused -
  say "rebuild: PR #$pr could not be brought up to date with $base (up to date already, or it conflicts) — the red is its own"
  return 1
}

# rebuild_draft_steps <ticket> — how many steps this host's driver record of it has finished,
# when its build is unfinished (steps done, none of them ship). 1 when it is not: no record
# here, an unreadable one, nothing done, or shipped.
rebuild_draft_steps() {
  local f n
  f="${DRIVER_DIR:-$STATE_DIR/driver}/$1/state.json"; [ -f "$f" ] || return 1
  n=$(jq -r '(.done // []) | if type == "array" and length > 0 and index("ship") == null then length else empty end' "$f" 2>/dev/null)
  [ -n "$n" ] && printf '%s' "$n"
}

# rebuild_resume_draft <ticket> <pr-json> — 0 when the PR is a draft whose build is unfinished
# on this host and it was queued to be resumed, or its resume already waits for a place.
# Never a fix round and never a park: unfinished work is not a red. 1 when it is not that.
rebuild_resume_draft() {
  local t="$1" pj="$2" pr head steps note tries
  [ "$(jq -r '.isDraft // false' <<<"$pj" 2>/dev/null)" = true ] || return 1
  [ "$DRAFT_RESUME_MAX" -gt 0 ] || return 1
  steps=$(rebuild_draft_steps "$t") || return 1
  pr=$(jq -r '.number // empty' <<<"$pj" 2>/dev/null); head=$(jq -r '.headRefOid // empty' <<<"$pj" 2>/dev/null)
  [ -n "$pr" ] && [ -n "$head" ] || return 1
  note=$(jq -r --argjson n "$t" '.tickets[]? | select(.n == $n) | .note // ""' "$COORD_QUEUE" 2>/dev/null)
  case "$note" in Resume:*)
    say "rebuild: PR #$pr is a draft part-way through its build ($steps step(s) done) — its resume is queued and waits for a place; no fix round"
    return 0 ;;
  esac
  tries=$(awk -F'\t' -v p="$pr" -v h="$head" -v s="$steps" '$1 == p && $2 == h && $3 == s { n = $4 } END { print n + 0 }' "$DRAFT_RESUMES" 2>/dev/null)
  case "$tries" in ''|*[!0-9]*) tries=0 ;; esac
  if [ "$tries" -ge "$DRAFT_RESUME_MAX" ]; then
    say "rebuild: PR #$pr is a draft part-way through its build, resumed $tries time(s) with no step finished and no push — treated as any stuck PR"
    return 1
  fi
  coord_act_log resume-draft "$t" "PR #$pr: $steps step(s) done, not shipped"
  if coord_shadow; then say "rebuild: would queue #$t to resume its unfinished build of draft PR #$pr ($steps step(s) done) — no fix round, no park"; return 0; fi
  # Ready, as a fix round sets it: an entry whose ticket wears another status never starts.
  rebuild_labels_now "$t"
  case $? in
    0) say "rebuild: PR #$pr left as it is — #$t waits on a person ($REBUILD_HELD_BY); its build is not resumed"; return 0 ;;
    1) ISSUE_STATUS_CURRENT="$REBUILD_LABELS_NOW" issue_status_set "$t" "$LBL_READY" >/dev/null 2>&1 || say "rebuild: #$t could not be set $LBL_READY" ;;
    *) say "rebuild: #$t could not be set $LBL_READY" ;;
  esac
  bash "$QUEUE" add "$t" --class new --first --note "Resume: PR #$pr is a draft part-way through its build ($steps step(s) done, not shipped) and no run holds it. Carry on from its branch and this host's record: cut no new branch and open no new pull request." >/dev/null 2>&1 \
    || { say "rebuild: #$t could not be queued to resume draft PR #$pr — tried again next tick"; return 0; }
  rebuild_ledger_put "$DRAFT_RESUMES" "$pr" "$head" "$steps" "$((tries + 1))"
  say "rebuild: PR #$pr is a draft part-way through its build ($steps step(s) done) — #$t is queued to resume it, ahead of new builds; no fix round, no park"
}

# rebuild_park_open <ticket> <why> <pr-json> <rounds> — 0 when the ticket was parked for the
# PM. The PR is left open, exactly as it is: its branch is the work the PM decides on.
# Written once per PR head (FIX_PARKS), and never over a label a person has put on since.
rebuild_park_open() {
  local t="$1" why="$2" pj="$3" n="$4" pr head fails
  pr=$(jq -r .number <<<"$pj"); head=$(jq -r '.headRefOid // ""' <<<"$pj")
  coord_act_log fix-park "$t" "PR #$pr: $why ($n fix rounds)"
  if coord_shadow; then say "rebuild: would park #$t for the PM — $n fix round(s), PR #$pr still cannot merge ($why); the PR would stay open"; return 0; fi
  rebuild_labels_now "$t"
  case $? in
    0) say "rebuild: PR #$pr left as it is — #$t waits on a person ($REBUILD_HELD_BY); not parked over it"; return 0 ;;
    2) say "rebuild: #$t could not be read before its park — tried again next tick"; return 1 ;;
  esac
  # The label first: a park that could not be set is said again next tick, never twice on the ticket.
  ISSUE_STATUS_CURRENT="$REBUILD_LABELS_NOW" issue_status_set "$t" "$LBL_PARKED" --also "${LBL_PM_DECISION:-status:pm-decision}" >/dev/null 2>&1 \
    || { say "rebuild: #$t could not be parked after its fix rounds — tried again next tick"; return 1; }
  rebuild_ledger_put "$FIX_PARKS" "$pr" "$head" "$(swarm_now)"
  fails=$(rebuild_fix_checks "$t" "$pj" 2>/dev/null | awk -F'\t' 'NF { printf "- %s%s\n", $1, ($2 != "" ? ": " $2 : "") }')
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "Parked for the PM: PR #$pr had $n fix round(s) on its own branch and still cannot merge ($why), so no builder is sent to it again (coordinator.fixRounds $FIX_ROUNDS). The PR is left open.${fails:+

Failing checks:
$fails}" >/dev/null 2>&1 || say "rebuild: #$t could not be told why it parked"
  rebuild_clock_stop "$pr"
  say "rebuild: parked #$t for the PM — $n fix round(s), PR #$pr left open ($why)"
}

# rebuild_clash_update <pr-json> <why> — a clashing PR's one update from its base: 0 when it
# was made (or would be, in shadow), 1 when it was made before or is refused.
rebuild_clash_update() {
  local pj="$1" why="$2" pr base
  ! declare -F coord_sheet_role >/dev/null 2>&1 || [ "$(coord_sheet_role)" != reader ] || return 1
  pr=$(jq -r '.number // empty' <<<"$pj" 2>/dev/null); [ -n "$pr" ] || return 1
  base=$(jq -r '.baseRefName // empty' <<<"$pj" 2>/dev/null); base="${base:-$INTEGRATION_BRANCH}"
  ! awk -F'\t' -v p="$pr" '$1 == p { f = 1 } END { exit !f }' "$CLASH_UPDATES" 2>/dev/null || return 1
  if coord_shadow; then say "rebuild: would update PR #$pr from $base once ($why) before any fix round"; return 0; fi
  printf '%s\t%s\n' "$pr" "$(swarm_now)" >> "$CLASH_UPDATES"
  if swarm_gh api "repos/$REPO_SLUG/pulls/$pr/update-branch" -X PUT >/dev/null 2>&1; then
    say "rebuild: PR #$pr updated from $base ($why) — its one automatic update"
    return 0
  fi
  say "rebuild: PR #$pr's update from $base was refused — the clash counts as a fix round"
  return 1
}

# rebuild_fix <ticket> <pr-json> <why> <kind> — 0 when the fix path took the PR this tick
# (queued, waiting on its round, updated from its base, or parked); 1 when it is not the fix
# path's: coordinator.fixRounds 0, or a stuck that is neither the PR's own red nor a clash.
rebuild_fix() {
  local t="$1" pj="$2" why="$3" kind="${4:-}" pr head br base rounds last state onq="" checks="" brief
  [ "$FIX_ROUNDS" -gt 0 ] || return 1
  case "$kind" in red|clash) ;; *) return 1 ;; esac
  # One ledger counts the rounds. Under a shared sheet only its owner sends a PR back:
  # a reader's own ledger would spend the cap a second time on the same PR.
  ! declare -F coord_sheet_role >/dev/null 2>&1 || [ "$(coord_sheet_role)" != reader ] || return 1
  pr=$(jq -r '.number // empty' <<<"$pj" 2>/dev/null); head=$(jq -r '.headRefOid // empty' <<<"$pj" 2>/dev/null)
  br=$(jq -r '.headRefName // empty' <<<"$pj" 2>/dev/null)
  base=$(jq -r '.baseRefName // empty' <<<"$pj" 2>/dev/null); base="${base:-$INTEGRATION_BRANCH}"
  [ -n "$pr" ] && [ -n "$head" ] && [ -n "$br" ] || return 1
  if rebuild_parked_at "$pr" "$head"; then
    say "rebuild: PR #$pr is stuck ($why) — already parked for the PM at this head; nothing is written until it moves"
    return 0
  fi
  IFS=$'\t' read -r rounds last state <<<"$(awk -F'\t' -v p="$pr" '$1 == p { r = $2; h = $3; s = $4 } END { printf "%s\t%s\t%s\n", r + 0, h, s }' "$FIX_LEDGER" 2>/dev/null)"
  case "$rounds" in ''|*[!0-9]*) rounds=0 ;; esac
  ! rebuild_fix_queued "$t" "$pr" || onq=1
  # A row with no state was written when its round was queued: still queued, it never started.
  case "$state" in queued|started) ;; *) state=started; [ -z "$onq" ] || state=queued ;; esac
  # A round is spent once its run has started; a queued one has cost nothing yet.
  if [ "$state" = queued ] && [ "$rounds" -gt 0 ]; then rounds=$((rounds - 1)); else state=started; fi
  # One round per head. A queued round waits for its start, a started one for its run; a run
  # that is gone and left the head where it was is released: the next round is spent on the
  # same head, or the ticket parks at the cap. Never left red for ever.
  if [ "$last" = "$head" ]; then
    if [ "$state" = queued ] && [ -n "$onq" ]; then
      say "rebuild: PR #$pr is stuck ($why) — fix round $((rounds + 1)) of $FIX_ROUNDS is queued for this head and has not started; it goes ahead of new builds"
      return 0
    fi
    if [ "$state" = started ] && rebuild_fix_run_alive "$t"; then
      say "rebuild: PR #$pr is stuck ($why) — fix round $rounds of $FIX_ROUNDS was spent on this head; it waits for that run"
      return 0
    fi
    if [ "$state" = queued ]; then say "rebuild: PR #$pr — fix round $((rounds + 1)) left the queue without starting; no round spent"
    else say "rebuild: PR #$pr — fix round $rounds ended without a push; its run is gone, so it is released"; fi
  fi
  # A red may be the base's, since fixed there: one free update before any round or park.
  if [ "$kind" = red ] && rebuild_stale_update "$pr" "$head" "$base" "$why"; then return 0; fi
  [ "$(jq -r '.isDraft // false' <<<"$pj" 2>/dev/null)" != true ] || [ -f "${DRIVER_DIR:-$STATE_DIR/driver}/$t/state.json" ] \
    || say "rebuild: PR #$pr is a draft and #$t's build record is not on this host — whether its build is unfinished could not be seen; treated as any stuck PR"
  # A clash is updated from its base once per PR before any builder is sent.
  if [ "$kind" = clash ] && rebuild_clash_update "$pj" "$why"; then return 0; fi
  if [ "$rounds" -ge "$FIX_ROUNDS" ]; then
    rebuild_park_open "$t" "$why" "$pj" "$rounds" || true
    return 0
  fi
  if [ "$kind" = red ]; then
    checks=$(rebuild_fix_checks "$t" "$pj") && [ -n "$checks" ] \
      || { say "rebuild: PR #$pr's failed checks could not be read — no fix round this tick"; return 0; }
  fi
  coord_act_log fix "$t" "PR #$pr round $((rounds + 1)) of $FIX_ROUNDS: $why"
  if coord_shadow; then say "rebuild: would send PR #$pr back to its builder — fix round $((rounds + 1)) of $FIX_ROUNDS ($why)"; return 0; fi
  brief=$(rebuild_fix_brief "$pr" "$br" "$base" "$why" "$kind" "$((rounds + 1))" "$checks")
  # Read again now: a person's label put on since the tick's read is never set back to ready.
  rebuild_labels_now "$t"
  case $? in
    0) say "rebuild: PR #$pr left as it is — #$t waits on a person ($REBUILD_HELD_BY); no fix round queued"; return 0 ;;
    1) ISSUE_STATUS_CURRENT="$REBUILD_LABELS_NOW" issue_status_set "$t" "$LBL_READY" >/dev/null 2>&1 || say "rebuild: #$t could not be set $LBL_READY" ;;
    *) say "rebuild: #$t could not be set $LBL_READY" ;;
  esac
  bash "$QUEUE" add "$t" --class new --first --note "$brief" >/dev/null 2>&1 \
    || { say "rebuild: #$t could not be queued for its fix — no round spent, tried again next tick"; return 0; }
  awk -F'\t' -v p="$pr" '$1 != p' "$FIX_LEDGER" > "$FIX_LEDGER.$$" 2>/dev/null; mv -f "$FIX_LEDGER.$$" "$FIX_LEDGER" 2>/dev/null
  printf '%s\t%s\t%s\tqueued\n' "$pr" "$((rounds + 1))" "$head" >> "$FIX_LEDGER"
  say "rebuild: PR #$pr goes back to its builder on $br — fix round $((rounds + 1)) of $FIX_ROUNDS ($why)"
}

# rebuild_pass — every open ticket PR in this tick's read (PRS, fresh, PRS_STALE 0): its clock
# moved or stopped, and a stuck one past coordinator.rebuildAfterMin rebuilt. Says what it did.
rebuild_pass() {
  local pj pr t st why kind since age lab metas rows tickets now n
  [ -n "${PRS:-}" ] && [ "${PRS_STALE:-0}" = 0 ] || { say "rebuild: the open PRs are a snapshot this tick — no clock moves"; return 0; }
  # No runner to run a check: a red, a cancel or a never-run is not the PR's, so nothing is sent
  # or closed. What does not wait on CI still runs: resumes, clash updates, holds, the ledgers.
  local runners REBUILD_CI_HOLD=""; runners=$(ci_runners_state)
  rebuild_clock_pause "$runners"
  case "$runners" in
    offline) REBUILD_CI_HOLD="every CI runner is offline" ;;
    unread)  REBUILD_CI_HOLD="the CI runner list could not be read" ;;
  esac
  [ -z "$REBUILD_CI_HOLD" ] || say "rebuild: $REBUILD_CI_HOLD — no PR is closed, rebuilt or sent back to its builder this tick"
  rows=$(printf '%s' "$PRS" | jq -c --arg pre "$BRANCH_PREFIX" "$BRANCH_TICKET_JQ"'
    sort_by(.number) | .[] | (.headRefName | branch_ticket($pre)) as $t | select($t != "") | {t: $t, pr: .}' 2>/dev/null)
  # Only the PRs open now keep a clock.
  if [ -f "$REBUILD_CLOCK" ]; then
    jq -r '.pr.number' <<<"$rows" 2>/dev/null | awk -F'\t' 'NR == FNR { open[$1] = 1; next } $1 in open' - "$REBUILD_CLOCK" \
      > "$REBUILD_CLOCK.$$" 2>/dev/null && mv -f "$REBUILD_CLOCK.$$" "$REBUILD_CLOCK"
  fi
  local led
  for led in "$STALE_UPDATES" "$FIX_PARKS" "$DRAFT_RESUMES"; do
    [ -f "$led" ] || continue
    jq -r '.pr.number' <<<"$rows" 2>/dev/null | awk -F'\t' 'NR == FNR { open[$1] = 1; next } $1 in open' - "$led" \
      > "$led.$$" 2>/dev/null && mv -f "$led.$$" "$led"
  done
  [ -n "$rows" ] || return 0
  tickets=$(jq -r '.t' <<<"$rows" | sort -un | tr '\n' ' ')
  # shellcheck disable=SC2086  # a list of numbers, split on purpose
  metas=$(gh_issues_batch $tickets 2>/dev/null) || metas="{}"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$metas" || metas="{}"
  now=$(swarm_now)
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    t=$(jq -r '.t' <<<"$row"); pj=$(jq -c '.pr' <<<"$row"); pr=$(jq -r '.number' <<<"$pj")
    lab=$(jq -r --arg n "$t" '.[$n] // empty | (.state // "OPEN") + " " + ((.labels // []) | join(","))' <<<"$metas" 2>/dev/null)
    [ -n "$lab" ] || { say "rebuild: #$t (PR #$pr) could not be read — its clock stands"; continue; }
    [ "${lab%% *}" = OPEN ] || { rebuild_clock_stop "$pr"; continue; }
    lab=${lab#* }
    if why=$(rebuild_held "$t" "$pj" "$lab"); then rebuild_clock_stop "$pr"; say "rebuild: PR #$pr left as it is — $why"; continue; fi
    if grep -qx "$t" <<<"${CLAIMED:-}" || swarm_ticket_live "$t"; then rebuild_clock_stop "$pr"; continue; fi
    # Unfinished work is not a red: its build is resumed, and no check of it is read.
    if rebuild_resume_draft "$t" "$pj"; then rebuild_clock_stop "$pr"; continue; fi
    IFS=$'\t' read -r st why kind <<<"$(rebuild_pr_state "$t" "$pj")"
    case "$st" in
      green)    rebuild_clock_stop "$pr"; continue ;;
      base-red) rebuild_clock_stop "$pr"; say "rebuild: PR #$pr waits — $why"; continue ;;
      pending|unread)
        since=$(rebuild_clock_since "$pr")
        [ -z "$since" ] || say "rebuild: PR #$pr $st ($why) — its clock runs, $(( (now - since) / 60 )) of $REBUILD_AFTER_MIN min"
        continue ;;
    esac
    if [ -n "$REBUILD_CI_HOLD" ]; then
      # A clash is the base's doing, not CI's: its one update from the base still goes.
      if [ "$kind" = clash ] && [ "$FIX_ROUNDS" -gt 0 ] && rebuild_clash_update "$pj" "$why"; then continue; fi
      say "rebuild: PR #$pr waits — $REBUILD_CI_HOLD ($why)"; continue
    fi
    since=$(rebuild_clock_start "$pr" "$why"); age=$(( (now - since) / 60 ))
    if [ "$REBUILD_AFTER_MIN" -eq 0 ] || [ "$age" -lt "$REBUILD_AFTER_MIN" ]; then
      # The fix path replaces the wait: the PR's own red, or a clash, goes back to its builder.
      ! rebuild_fix "$t" "$pj" "$why" "$kind" || continue
      say "rebuild: PR #$pr is stuck ($why) — $age of $REBUILD_AFTER_MIN min$([ "$REBUILD_AFTER_MIN" -eq 0 ] && echo ' (coordinator.rebuildAfterMin 0: off)')"
      continue
    fi
    n=$(rebuild_prior "$t")
    if [ "$REBUILD_MAX" -gt 0 ] && [ -n "$n" ] && [ "$n" -ge "$REBUILD_MAX" ]; then
      rebuild_park "$t" "$why" "$pj" "$n" || say "rebuild: #$t could not be parked this tick — tried again next tick"
      continue
    fi
    rebuild_fresh "$t" "$why" "$pj" || say "rebuild: #$t could not be rebuilt this tick — tried again next tick"
  done <<< "$rows"
}

# ---- pull requests in a clone's repo -----------------------------------------------
# A repo:<name> ticket is built in a clone of <name> (driver_repo_clone_for) and its pull
# request opens in that repo, not this project's. The pass above reads this project's open
# PRs only, so a red, clashing or half-built one there was never sent back to its builder.
#
# CLONE_BUILDS (ticket \t repo name) is every ticket this queue started in a clone: the tick
# adds a row when that spawn succeeds. For each repo named there the pass makes ONE batched
# read of that repo's open PRs a tick, keeps the ones on those tickets' branches, and runs
# the same pass on them: the same caps, and ledgers of their own (a PR number in one repo is
# another PR in the other). Checks, rules, updates and the PR's own comments are read and
# written in the clone's repo; the ticket's labels and comments in this queue's. A row is
# dropped once its ticket has no open PR there, no claim and no live run, so a repo with
# nothing built in it costs no request at all.
CLONE_BUILDS="$COORD_DIR/clone-builds.tsv"
_rebuild_clone_key() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '_'; }
# rebuild_clone_prs_file <name> — that repo's open PRs for this queue's tickets, as this tick read them.
rebuild_clone_prs_file() { printf '%s/clone-prs.%s.json' "$COORD_DIR" "$(_rebuild_clone_key "$1")"; }
# rebuild_clone_note <ticket> <clone dir> — the ticket was started in that clone.
rebuild_clone_note() {
  local t="$1" url name
  url=$(git -C "$2" config --get remote.origin.url 2>/dev/null) || return 1
  url="${url%/}"; url="${url%.git}"; name=$(_rebuild_clone_key "${url##*/}"); [ -n "$name" ] || return 1
  awk -F'\t' -v t="$t" -v n="$name" '$1 == t && $2 == n { f = 1 } END { exit !f }' "$CLONE_BUILDS" 2>/dev/null \
    || printf '%s\t%s\n' "$t" "$name" >> "$CLONE_BUILDS"
}
# rebuild_clone_of <ticket> — the repo name whose clone the ticket was started in, or 1.
rebuild_clone_of() {
  local n; n=$(awk -F'\t' -v t="$1" '$1 == t { print $2; exit }' "$CLONE_BUILDS" 2>/dev/null)
  [ -n "$n" ] && printf '%s' "$n"
}
# rebuild_in_clone <name> <function> [args…] — run it as the pass reads that clone's repo:
# REPO_SLUG its repo, the tickets still this queue's, its own ledgers, PRS its open PRs as
# this tick read them (CLONE_PRS_READ=1 when it did). 1 when this host has no such clone.
rebuild_in_clone() {
  local name dir url slug trunk queue f
  name=$(_rebuild_clone_key "${1:-}"); shift
  dir=$(driver_repo_clone "$name") || return 1
  trunk=$(driver_repo_clone_trunk "$dir") || return 1
  url=$(git -C "$dir" config --get remote.origin.url 2>/dev/null) || return 1
  url="${url%/}"; url="${url%.git}"; slug=$(printf '%s' "$url" | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#')
  case "$slug" in */*) ;; *) return 1 ;; esac
  queue="${ISSUE_REF:-$REPO_SLUG}"
  (
    ISSUE_REF="$queue"; ISSUE_SLUG="$queue"; REPO_SLUG="$slug"; INTEGRATION_BRANCH="$trunk"; OPEN_WORK_REPO="$slug"
    REBUILD_CLONE="$name"
    for f in REBUILD_CLOCK REBUILD_CI_DOWN FIX_LEDGER CLASH_UPDATES STALE_UPDATES FIX_PARKS DRAFT_RESUMES REBUILD_BASE_RED REBUILD_BASE_RERUNS REBUILD_RERUNS OPEN_WORK_DRAFTED_CACHE; do
      eval "$f=\"\${$f%.tsv}.$name.tsv\""
    done
    PR_RED_REQ_FILE="$PR_RED_REQ_FILE.$name"; REBUILD_BASE_CACHE="$REBUILD_BASE_CACHE.$name"
    # The labels a release rule reads are asked of one repo for a PR and its ticket; here they are two.
    release_labels_of() { return 0; }
    PRS="[]"; PRS_STALE=0; CLONE_PRS_READ=0
    f=$(rebuild_clone_prs_file "$name")
    if [ -s "$f" ]; then PRS=$(cat "$f"); CLONE_PRS_READ=1; fi
    "$@"
  )
}
# _rebuild_clone_pass — inside rebuild_in_clone: the one read of that repo's open PRs, then the pass.
_rebuild_clone_pass() {
  local name="$REBUILD_CLONE" mine prs f t n kept=""
  f=$(rebuild_clone_prs_file "$name"); rm -f "$f"
  mine=$(awk -F'\t' -v n="$name" '$2 == n { print $1 }' "$CLONE_BUILDS" 2>/dev/null)
  if ! prs=$(gh_prs_paged "$GH_PRS_FIELDS" 2>/dev/null) || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$prs"; then
    say "rebuild: the open PRs of $REPO_SLUG could not be read — nothing there is sent back to its builder this tick"
    return 0
  fi
  PRS=$(printf '%s' "$prs" | jq -c --arg pre "$BRANCH_PREFIX" --arg mine "$mine" "$BRANCH_TICKET_JQ"'
    ($mine | split("\n") | map(select(length > 0))) as $m
    | [.[] | select((.headRefName | branch_ticket($pre)) as $t | $t != "" and ($m | index($t | tostring) != null))]' 2>/dev/null) || PRS="[]"
  [ -n "$PRS" ] || PRS="[]"
  printf '%s\n' "$PRS" > "$f.$$" && mv -f "$f.$$" "$f"
  # A ticket with no open PR there, no claim and no run is finished with: its row goes.
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ -n "$(open_pr_json "$t")" ] || grep -qx "$t" <<<"${CLAIMED:-}" || swarm_ticket_live "$t"; then kept="$kept$t"$'\n'; fi
  done <<<"$mine"
  { awk -F'\t' -v n="$name" '$2 != n' "$CLONE_BUILDS" 2>/dev/null
    printf '%s' "$kept" | awk -v n="$name" 'NF { print $1 "\t" n }'; } > "$CLONE_BUILDS.$$" && mv -f "$CLONE_BUILDS.$$" "$CLONE_BUILDS"
  n=$(jq 'length' <<<"$PRS" 2>/dev/null)
  say "rebuild: $REPO_SLUG — ${n:-0} open PR(s) on ticket(s) this queue built there"
  [ "${n:-0}" -gt 0 ] || return 0
  : > "$PR_RED_REQ_FILE" 2>/dev/null
  rm -rf "$REBUILD_BASE_CACHE" 2>/dev/null; mkdir -p "$REBUILD_BASE_CACHE" 2>/dev/null
  rebuild_pass
  return 0
}
# rebuild_clone_seed — once per host: the tickets already built in a clone before the ledger
# existed, read off this host's newest driver records (the worktree each names, and that
# tree's origin). No GitHub request. A ticket long finished is dropped by the first pass.
rebuild_clone_seed() {
  local stamp="$COORD_DIR/clone-builds.seeded" d="${DRIVER_DIR:-$STATE_DIR/driver}" f wt t url name self dir
  [ ! -e "$stamp" ] || return 0
  mkdir -p "$COORD_DIR" 2>/dev/null; : > "$stamp" 2>/dev/null || return 0
  self=$(driver_repo_self)
  while IFS=$'\t' read -r f wt; do
    t=$(basename "$(dirname "$f")")
    case "$t" in ''|*[!0-9]*) continue ;; esac
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    url=$(git -C "$wt" config --get remote.origin.url 2>/dev/null) || continue
    url="${url%/}"; url="${url%.git}"; name=$(_rebuild_clone_key "${url##*/}")
    [ -n "$name" ] && [ "$name" != "$self" ] || continue
    dir=$(driver_repo_clone "$name") || continue
    rebuild_clone_note "$t" "$dir" && say "rebuild: #$t was built in the clone of $name before now — its pull request there is watched from this tick"
  done <<<"$(ls -t "$d" 2>/dev/null | head -300 | while IFS= read -r t; do [ ! -f "$d/$t/state.json" ] || printf '%s\n' "$d/$t/state.json"; done \
             | xargs -n 50 jq -r '[input_filename, (.worktree // "")] | @tsv' 2>/dev/null)"
}
# rebuild_pass_clones — rebuild_pass for the open PRs in each clone's repo that this queue's
# tickets were built in. One PR list per such repo; none when no ticket was built in one.
rebuild_pass_clones() {
  local name
  rebuild_clone_seed
  [ -s "$CLONE_BUILDS" ] || return 0
  for name in $(cut -f2 "$CLONE_BUILDS" | awk 'NF && !s[$0]++'); do
    rebuild_in_clone "$name" _rebuild_clone_pass \
      || say "rebuild: this host has no clone of $name — its pull requests are not read here"
  done
}
