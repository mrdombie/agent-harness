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
# branch and pushes to the same PR. One round per PR head (a round that ended without a
# push spends the next on the same head), coordinator.fixRounds (2) per PR,
# counted in fix-rounds.<mode>.tsv and never reset by a new head; past it the ticket parks
# for the PM with the PR left open. A clash gets one update from its base first
# (clash-updates.<mode>.tsv), then counts as a red. Never for a cancelled check (re-run
# above), a base-red, a PR a person owns or a ticket something works. Nothing else sends
# work to an open PR: no fixer, no stall guard.
#
# WHAT IS NEVER REBUILT.
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
FIX_LEDGER="$COORD_DIR/fix-rounds.$(coord_mode).tsv"        # pr \t rounds \t last head sent for a fix
CLASH_UPDATES="$COORD_DIR/clash-updates.$(coord_mode).tsv"  # pr \t epoch: its one update from the base
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
      if coord_shadow; then did="would re-run ${ids:-nothing named}"
      else did=$(pr_red_rerun "$n" "$(jq -r '.headRefOid // ""' <<<"$pj")" "$ids" "$COORD_DIR/reruns.tsv" "$COORD_RERUN_MAX"); fi
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
# rebuild_fix_queued <ticket> — 0 while the ticket is on the coordinator's queue (its own read).
rebuild_fix_queued() {
  local q; q=$(coord_queue_ordered 2>/dev/null)
  awk -F'\t' -v t="$1" '$1 == t { f = 1 } END { exit !f }' <<<"$q"
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

# rebuild_park_open <ticket> <why> <pr-json> <rounds> — 0 when the ticket was parked for the
# PM. The PR is left open, exactly as it is: its branch is the work the PM decides on.
rebuild_park_open() {
  local t="$1" why="$2" pj="$3" n="$4" pr fails
  pr=$(jq -r .number <<<"$pj")
  coord_act_log fix-park "$t" "PR #$pr: $why ($n fix rounds)"
  if coord_shadow; then say "rebuild: would park #$t for the PM — $n fix round(s), PR #$pr still cannot merge ($why); the PR would stay open"; return 0; fi
  # The label first: a park that could not be set is said again next tick, never twice on the ticket.
  issue_status_set "$t" "$LBL_PARKED" --also "${LBL_PM_DECISION:-status:pm-decision}" >/dev/null 2>&1 \
    || { say "rebuild: #$t could not be parked after its fix rounds — tried again next tick"; return 1; }
  fails=$(rebuild_fix_checks "$t" "$pj" 2>/dev/null | awk -F'\t' 'NF { printf "- %s%s\n", $1, ($2 != "" ? ": " $2 : "") }')
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "Parked for the PM: PR #$pr had $n fix round(s) on its own branch and still cannot merge ($why), so no builder is sent to it again (coordinator.fixRounds $FIX_ROUNDS). The PR is left open.${fails:+

Failing checks:
$fails}" >/dev/null 2>&1 || say "rebuild: #$t could not be told why it parked"
  rebuild_clock_stop "$pr"
  say "rebuild: parked #$t for the PM — $n fix round(s), PR #$pr left open ($why)"
}

# rebuild_fix <ticket> <pr-json> <why> <kind> — 0 when the fix path took the PR this tick
# (queued, waiting on its round, updated from its base, or parked); 1 when it is not the fix
# path's: coordinator.fixRounds 0, or a stuck that is neither the PR's own red nor a clash.
rebuild_fix() {
  local t="$1" pj="$2" why="$3" kind="${4:-}" pr head br base rounds last checks="" brief
  [ "$FIX_ROUNDS" -gt 0 ] || return 1
  case "$kind" in red|clash) ;; *) return 1 ;; esac
  # One ledger counts the rounds. Under a shared sheet only its owner sends a PR back:
  # a reader's own ledger would spend the cap a second time on the same PR.
  ! declare -F coord_sheet_role >/dev/null 2>&1 || [ "$(coord_sheet_role)" != reader ] || return 1
  pr=$(jq -r '.number // empty' <<<"$pj" 2>/dev/null); head=$(jq -r '.headRefOid // empty' <<<"$pj" 2>/dev/null)
  br=$(jq -r '.headRefName // empty' <<<"$pj" 2>/dev/null)
  base=$(jq -r '.baseRefName // empty' <<<"$pj" 2>/dev/null); base="${base:-$INTEGRATION_BRANCH}"
  [ -n "$pr" ] && [ -n "$head" ] && [ -n "$br" ] || return 1
  IFS=$'\t' read -r rounds last <<<"$(awk -F'\t' -v p="$pr" '$1 == p { r = $2; h = $3 } END { printf "%s\t%s\n", r + 0, h }' "$FIX_LEDGER" 2>/dev/null)"
  case "$rounds" in ''|*[!0-9]*) rounds=0 ;; esac
  # One round per head while its fix is still queued. Nothing claims or runs the ticket here
  # (rebuild_pass), so off the queue too means that round ended without a push: the next
  # round is spent on the same head, or the ticket parks at the cap. Never left red for ever.
  if [ "$last" = "$head" ]; then
    if rebuild_fix_queued "$t"; then
      say "rebuild: PR #$pr is stuck ($why) — fix round $rounds of $FIX_ROUNDS was spent on this head; it waits for that run"
      return 0
    fi
    say "rebuild: PR #$pr — fix round $rounds ended without a push"
  fi
  # A clash is updated from its base once per PR before any builder is sent.
  if [ "$kind" = clash ] && ! awk -F'\t' -v p="$pr" '$1 == p { f = 1 } END { exit !f }' "$CLASH_UPDATES" 2>/dev/null; then
    if coord_shadow; then say "rebuild: would update PR #$pr from $base once ($why) before any fix round"; return 0; fi
    printf '%s\t%s\n' "$pr" "$(swarm_now)" >> "$CLASH_UPDATES"
    if swarm_gh api "repos/$REPO_SLUG/pulls/$pr/update-branch" -X PUT >/dev/null 2>&1; then
      say "rebuild: PR #$pr updated from $base ($why) — its one automatic update"
      return 0
    fi
    say "rebuild: PR #$pr's update from $base was refused — the clash counts as a fix round"
  fi
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
  issue_status_set "$t" "$LBL_READY" >/dev/null 2>&1 || say "rebuild: #$t could not be set $LBL_READY"
  bash "$QUEUE" add "$t" --class new --first --note "$brief" >/dev/null 2>&1 \
    || { say "rebuild: #$t could not be queued for its fix — no round spent, tried again next tick"; return 0; }
  awk -F'\t' -v p="$pr" '$1 != p' "$FIX_LEDGER" > "$FIX_LEDGER.$$" 2>/dev/null; mv -f "$FIX_LEDGER.$$" "$FIX_LEDGER" 2>/dev/null
  printf '%s\t%s\t%s\n' "$pr" "$((rounds + 1))" "$head" >> "$FIX_LEDGER"
  say "rebuild: PR #$pr goes back to its builder on $br — fix round $((rounds + 1)) of $FIX_ROUNDS ($why)"
}

# rebuild_pass — every open ticket PR in this tick's read (PRS, fresh, PRS_STALE 0): its clock
# moved or stopped, and a stuck one past coordinator.rebuildAfterMin rebuilt. Says what it did.
rebuild_pass() {
  local pj pr t st why kind since age lab metas rows tickets now n
  [ -n "${PRS:-}" ] && [ "${PRS_STALE:-0}" = 0 ] || { say "rebuild: the open PRs are a snapshot this tick — no clock moves"; return 0; }
  rows=$(printf '%s' "$PRS" | jq -c --arg pre "$BRANCH_PREFIX" "$BRANCH_TICKET_JQ"'
    sort_by(.number) | .[] | (.headRefName | branch_ticket($pre)) as $t | select($t != "") | {t: $t, pr: .}' 2>/dev/null)
  # Only the PRs open now keep a clock.
  if [ -f "$REBUILD_CLOCK" ]; then
    jq -r '.pr.number' <<<"$rows" 2>/dev/null | awk -F'\t' 'NR == FNR { open[$1] = 1; next } $1 in open' - "$REBUILD_CLOCK" \
      > "$REBUILD_CLOCK.$$" 2>/dev/null && mv -f "$REBUILD_CLOCK.$$" "$REBUILD_CLOCK"
  fi
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
    IFS=$'\t' read -r st why kind <<<"$(rebuild_pr_state "$t" "$pj")"
    case "$st" in
      green)    rebuild_clock_stop "$pr"; continue ;;
      base-red) rebuild_clock_stop "$pr"; say "rebuild: PR #$pr waits — $why"; continue ;;
      pending|unread)
        since=$(rebuild_clock_since "$pr")
        [ -z "$since" ] || say "rebuild: PR #$pr $st ($why) — its clock runs, $(( (now - since) / 60 )) of $REBUILD_AFTER_MIN min"
        continue ;;
    esac
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
