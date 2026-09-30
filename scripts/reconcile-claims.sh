#!/usr/bin/env bash
# reconcile-claims.sh — the ONE reconciler. Puts GitHub's status:claimed back to
# whatever the evidence shows, using `refs/claims/<issue>` as the claim.
#
# THE CLAIM IS A REF. `mkdir` is atomic on one machine; the queue is worked from
# more than one. The lock dir compensated with a cross-machine race detector that
# posted a claim comment and re-read the issue to see whose landed first — so two
# agents could both post, both read, and both conclude they had won. Measured on
# 2026-08-07: 15 tickets marked status:claimed against 4 real locks. Eleven held
# by nothing — invisible to /claim so never handed out, invisible to the sweeper
# so never reclaimed. `claim-lock.sh` now takes the ref with
# `push --force-with-lease`, a server-side compare-and-swap, and this reads it.
#
# A MISSING CLAIM IS NOT ABSENT WORK. The old rule sent every dead claim to
# status:needs-human on the grounds that a failure must be seen. That is right
# for a claim that died having done work and wrong for one that left no trace.
# On 2026-08-07 it would have been wrong 6 times out of 11: those six had open
# PRs with real work in them, and releasing them to ready would have had fresh
# agents rebuild all six from nothing — duplicate PRs racing the originals, the
# exact failure the queue exists to prevent, caused by the tool meant to prevent
# it. So the evidence decides:
#
#   claim ref, holder alive here   → live. Left alone.
#   claim ref, holder gone, the     → live. The holder is a step-runner between two
#     driver run record is fresh      steps, not an agent that died. Left alone.
#   claim ref, holder on ANOTHER   → reported. Cannot be checked from here, and
#     host                           a claim you cannot check is not a claim you
#                                    may break.
#   epic                           → kept. Ships as children; no PR-shaped
#                                    verdict describes it.
#   no claim, MERGED PR            → the work shipped and the close-out did not
#                                    run. Comment and close the ticket.
#   no claim, open PR              → status:in-review. NEVER released to ready.
#   no claim, branch but no PR     → status:partial, with where the branch is.
#   no claim, no branch, no PR     → status:ready. Genuinely nothing to lose.
#
# A VERDICT MUST BE REVISABLE. Parking a ticket at in-review/partial strips its
# ref, its status:claimed label and its lock, so the first three gather sources
# stopped matching it and no later sweep ever looked again — its PR could merge
# or close and the label stayed. Those two labels are now gathered as well, and
# `status:in-review` is claimable again from /claim (the discriminator for a
# ticket genuinely waiting on a human is `needs:human-approval`, not the status).
#
# Lock dirs are still read so a claim taken before the ref migration is not
# stranded, and are ignored once none remain. Two things they carry that a ref
# does not, both of which cost real work if dropped:
#
#   a lock with no ref   → a claim taken before the migration. LIVE. A dry run
#                          on 2026-08-08 reported the reconciler's own claim as
#                          releasable because only refs were consulted.
#   `awaiting` in meta   → PARKED for a human, deliberately. The whole point of
#                          the field is that "run ended, nothing merged" is what
#                          a dead agent and a parked one look like from outside.
#                          Releasing it undoes the park and the human never
#                          learns why.
#
# Called after every spawned agent exits (spawn-claim.sh), every 10 minutes by
# launchd, at /claim step 0, and on demand by /release-stale.
#
# Usage: reconcile-claims.sh [--dry-run] [--quiet]
#   --dry-run   report verdicts, mutate nothing (no ref delete, no mv, no gh)
# Env: STALE_HOURS (default 4), NOTIFY (default 1), CLAIM_REMOTE

set -uo pipefail

DRY_RUN=0
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --quiet) QUIET=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claim-proc.sh" || exit 1
# The second liveness answer, for a holder that is a RUN rather than a session.
# shellcheck source=claim-liveness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claim-liveness.sh" || exit 1
TICKETS_DIR="$STATE_DIR"
CLAIMS_DIR="$TICKETS_DIR/claims"
RECOVERED_DIR="$CLAIMS_DIR/.recovered"
STALE_HOURS="${STALE_HOURS:-4}"
NOTIFY="${NOTIFY:-1}"
GH_REPO="${GH_REPO:-$REPO_SLUG}"
NS="refs/claims"

# #8091 — this value reaches an integer comparison, and `[` FAILS OPEN: a
# non-integer exits 2 with "integer expression expected", and because this runs
# `set -uo pipefail` without `-e`, execution falls straight past the live branch
# into the release path for every claim it reaches. A bad window must stop the
# sweep, never silently widen it.
case "$STALE_HOURS" in
  ''|*[!0-9]*)
    echo "reconcile-claims: STALE_HOURS must be a whole number of hours, got '$STALE_HOURS'." >&2
    echo "  Refusing to sweep — that value reaches an integer comparison which fails OPEN," >&2
    echo "  and would release every claim rather than none." >&2
    exit 2
    ;;
esac

say() { [ "$QUIET" -eq 1 ] || echo "$@" >&2; }

REPO="$MAIN_REPO"
# The test harness points this at a local bare repo so refs can be planted
# without touching the real origin.
CLAIM_REMOTE="${CLAIM_REMOTE:-origin}"

THIS_HOST="$(claim_host)"
NOW_EPOCH=$(date +%s)

# Evidence probes must be ANSWERED before anything is released. An unreachable
# GitHub looks identical to "no PR exists", and that difference is the whole
# classification — a network blip would release every claim to ready.
gh_ok=1
gh api "repos/$GH_REPO" -q .full_name >/dev/null 2>&1 || gh_ok=0
if [ "$gh_ok" -eq 0 ]; then
  say "[reconcile-claims] cannot reach $GH_REPO — every verdict here depends on"
  say "  'does a PR exist', and an unreachable API answers that identically to 'no'."
  say "  Reporting only; nothing will be released."
fi


# Both conventions are in use and both must match, or stranded work is missed.
# ANCHORED: an unanchored `8571` also matches `sh-85710/` and `fix/85712-…`, and
# a wrong match here releases the wrong ticket.
branch_for() {
  local n="$1"
  git -C "$REPO" ls-remote --heads "$CLAIM_REMOTE" 2>/dev/null \
    | awk -v n="$n" '
        { ref = $2; sub("refs/heads/", "", ref) }
        ref ~ ("^sh-" n "/")            { print ref; exit }
        ref ~ ("^[a-z]+/" n "-")        { print ref; exit }
      '
}

pr_state_for() {
  # Prints "<number> <state>" for this branch's PR, or nothing.
  #
  # An OPEN PR wins over a newer closed one. `--limit 1` alone takes the newest
  # and nothing else, so a branch that was re-PR'd after a close reported the
  # closed one and the live work read as stranded.
  local branch="$1"
  [ -n "$branch" ] || return 0
  gh pr list --repo "$GH_REPO" --head "$branch" --state all \
    --json number,state --limit 20 2>/dev/null \
    | jq -r '(map(select(.state == "OPEN")) | first)
             // (map(select(.state == "MERGED")) | first)
             // .[0]
             | select(.) | "\(.number) \(.state)"' 2>/dev/null
}

# The claim record is the ref's commit message: {issue,agent,pid,branch,worktree,host,claimed_at}
claim_record() {
  git -C "$REPO" fetch -q "$CLAIM_REMOTE" "$NS/$1" 2>/dev/null || return 1
  git -C "$REPO" log -1 --format=%B FETCH_HEAD 2>/dev/null
}

holder_alive() {
  # $1 host, $2 pid. Only answerable for a claim taken on THIS host.
  [ "$1" = "$THIS_HOST" ] || return 2
  [ -n "$2" ] && [ "$2" != "null" ] || return 1
  # The post-exit reconcile runs inside the wrapper that IS the recorded session,
  # so that pid is alive while being judged; spawn-claim names it as exited.
  [ -n "${CLAIM_EXITED_PID:-}" ] && [ "$2" = "$CLAIM_EXITED_PID" ] && return 1
  claim_pid_alive "$2"
}

release_ref() {
  local n="$1"
  [ "$DRY_RUN" -eq 1 ] && return 0
  git -C "$REPO" push -q "$CLAIM_REMOTE" ":$NS/$n" 2>/dev/null
}

# Path of this ticket's lock dir in whichever form it exists, or nothing.
lock_path() {
  local n="$1" form
  for form in "$n" "#$n" "SH-$n"; do
    [ -d "$CLAIMS_DIR/${form}.lock" ] && { echo "$CLAIMS_DIR/${form}.lock"; return 0; }
  done
  return 1
}

recover_lock() {
  # Move any lock dir aside so the two stores cannot disagree later.
  local n="$1" verdict="$2" form lock
  for form in "$n" "#$n" "SH-$n"; do
    lock="$CLAIMS_DIR/${form}.lock"
    [ -d "$lock" ] || continue
    [ "$DRY_RUN" -eq 1 ] && return 0
    mkdir -p "$RECOVERED_DIR"
    mv "$lock" "$RECOVERED_DIR/${form}.lock-${verdict}-$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null
    return 0
  done
  return 0
}

labels_of() {
  gh issue view "$1" --repo "$GH_REPO" --json labels -q '.labels[].name' 2>/dev/null
}

is_epic() {
  [ "$gh_ok" -eq 1 ] || return 1
  labels_of ""$1"" | grep -qx "epic"
}

relabel() {
  # Strips EVERY other status:* label, not just status:claimed. Removing one
  # while adding another left tickets wearing two, and every label reader took
  # whichever GitHub returned first — so the queue's view of a ticket was a coin
  # flip. Five open issues carried two status labels before this.
  #
  # Comments only when the label actually moves. The old unconditional post put
  # the same "Claim released, ticket not" note on #8326, #8475 and #8547 three
  # times each, once per sweep, which trains a reader to skip the channel.
  local n="$1" want="$2" body="$3" issue current drop
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ "$gh_ok" -eq 1 ] || return 0
  issue="$n"
  current=$(labels_of "$issue")

  if printf '%s\n' "$current" | grep -qx "$want"; then
    say "  (already $want — no relabel, no comment)"
    return 0
  fi

  # Built as a flat string, not an array: macOS ships bash 3.2, where expanding
  # an empty array under `set -u` is itself an error.
  drop=""
  while IFS= read -r l; do
    case "$l" in
      status:*) [ "$l" = "$want" ] || drop="$drop --remove-label $l" ;;
    esac
  done <<<"$current"

  # shellcheck disable=SC2086  # $drop is a built flag list, deliberately split
  gh issue edit "$issue" --repo "$GH_REPO" \
    $drop --add-label "$want" >/dev/null 2>&1
  [ -n "$body" ] && gh issue comment "$issue" --repo "$GH_REPO" --body "$body" >/dev/null 2>&1
  return 0
}

# --- gather ------------------------------------------------------------------
# Every ticket with a claim ref, plus every ticket GitHub still calls claimed.
# The second set is the one the old reconciler could not see: a label with no
# claim behind it holds a ticket out of the queue forever.
claimed_refs=$(git -C "$REPO" ls-remote "$CLAIM_REMOTE" "$NS/*" 2>/dev/null | sed 's|.*'"$NS"'/||' | sort -u)
labelled=""
if [ "$gh_ok" -eq 1 ]; then
  # status:in-review and status:partial are gathered too, and that is the whole
  # point of this list. Parking a ticket at either strips its claim ref, its
  # status:claimed label and its lock dir — so on the NEXT sweep it matched none
  # of the three sources and was never looked at again. Its PR could merge, or
  # close, and the ticket stayed open wearing a label nothing removes: held by
  # no one, offered to no one. 24 accumulated this way by 2026-08-11.
  for lbl in "$LBL_CLAIMED" "$LBL_IN_REVIEW" "$LBL_PARTIAL"; do
    labelled="$labelled
$(gh issue list --repo "$GH_REPO" --label "$lbl" --state open \
      --json number -q '.[].number' --limit 300 2>/dev/null)"
  done
  labelled=$(printf '%s\n' "$labelled" | sed '/^$/d' | sort -u)
fi
# Locks are read during migration so a pre-ref claim is not stranded.
legacy=""
if [ -d "$CLAIMS_DIR" ]; then
  legacy=$(ls -1 "$CLAIMS_DIR" 2>/dev/null | sed -n 's/^#\{0,1\}\(SH-\)\{0,1\}\([0-9][0-9]*\)\.lock$/\2/p' | sort -u)
fi
tickets=$(printf '%s\n%s\n%s\n' "$claimed_refs" "$labelled" "$legacy" | sed '/^$/d' | sort -u)

checked=0; live=0; elsewhere=0; released=0; inreview=0; partial=0; kept=0; shipped=0

for n in $tickets; do
  checked=$((checked + 1))
  rec=""
  rec=$(claim_record "$n" 2>/dev/null)
  has_ref=0
  printf '%s\n' "$claimed_refs" | grep -qx "$n" && has_ref=1

  # A claim parked for a human is not a dead claim, whichever store holds it.
  lock=$(lock_path "$n" 2>/dev/null) || lock=""
  if [ -n "$lock" ] && [ -f "$lock/meta.json" ]; then
    awaiting=$(jq -r '.awaiting // empty' "$lock/meta.json" 2>/dev/null)
    if [ -n "$awaiting" ]; then
      say "  PARKED     #$n — awaiting a human ($awaiting); left alone"
      kept=$((kept + 1)); continue
    fi
  fi

  # A lock with no ref is a claim taken before the migration. It is held.
  if [ "$has_ref" -eq 0 ] && [ -n "$lock" ]; then
    say "  LIVE       #$n — pre-migration lock at $(basename "$lock"), no ref yet"
    live=$((live + 1)); continue
  fi

  if [ "$has_ref" -eq 1 ]; then
    host=$(printf '%s' "$rec" | jq -r '.host // empty' 2>/dev/null)
    pid=$(printf '%s' "$rec" | jq -r '.pid // empty' 2>/dev/null)
    holder_alive "$host" "$pid"; alive=$?
    if [ "$alive" -eq 0 ]; then
      say "  LIVE       #$n — held by pid $pid on $host"
      live=$((live + 1)); continue
    fi
    if [ "$alive" -eq 2 ]; then
      say "  ELSEWHERE  #$n — held on ${host:-unknown}, not this host; cannot check, leaving it"
      elsewhere=$((elsewhere + 1)); continue
    fi
    # A DEAD PID IS NOT A DEAD RUN. The step-runner's processes come and go — one per
    # step — so between two invocations of it there is no process to test, and the pid
    # on the claim names one that exited at the end of the last step. On 2026-09-27
    # this released #10867 out from under a trial that was still working it, reporting
    # "agent gone, no branch, no PR". The driver's own run record is the artifact that
    # says otherwise, and artifact freshness is already how this file judges staleness.
    if claim_run_fresh "$n" "$STATE_DIR" "$STALE_HOURS"; then
      say "  LIVE       #$n — pid $pid is gone, and the driver's run record was written inside the last ${STALE_HOURS}h"
      live=$((live + 1)); continue
    fi
  fi

  # No live claim. What did it leave behind?
  if [ "$gh_ok" -eq 0 ]; then
    say "  KEEP       #$n — no live claim, but the evidence probe is unavailable"
    kept=$((kept + 1)); continue
  fi

  # An epic never ships as one PR, so no PR-shaped verdict describes it. It was
  # reaching status:in-review off a child's branch and going unclaimable.
  if is_epic "$n"; then
    say "  KEEP       #$n — epic; ships as children, no PR verdict applies"
    kept=$((kept + 1)); continue
  fi

  branch=$(branch_for "$n")
  pr=$(pr_state_for "$branch")
  pr_num=$(printf '%s' "$pr" | awk '{print $1}')
  pr_state=$(printf '%s' "$pr" | awk '{print $2}')

  # The work SHIPPED and the close-out never ran. /finish's Step 7 is local and
  # dies with its session while `--auto` merges server-side regardless, so this
  # is the routine ending, not a rare one. Without this branch a merged PR fell
  # through to PARTIAL (branch still there) or all the way to status:ready — and
  # a fresh agent rebuilt something already on develop.
  if [ -n "$pr_num" ] && [ "$pr_state" = "MERGED" ]; then
    # A merged PR does NOT mean the ticket is done in these cases, and closing it
    # would be the destructive direction of this whole class of bug.
    #
    #   status:partial      — its own label reads "some phases shipped, more to
    #                         claim". A merged PR is the NORMAL state for one.
    #   needs:human-approval  — a human has not signed the work off yet, and the
    #                         reconciler is not that human.
    #   status:pm-track     — discovery/spec/strategy work a human drives.
    #   status:pm-decision  — the ticket IS an unanswered question.
    #
    # Caught by a dry run on 2026-08-11: #6997 is a P0 carrying both of the first
    # two, with PR #7010 merged since 07-19. Closing it would have buried live
    # work. The last two joined the list in #9125: #9086 was closed three times
    # while wearing status:pm-track, and a closed ticket is invisible to /claim,
    # to this reconciler and to every sweep — so the question it held would
    # simply have stopped existing.
    ticket_labels=$(labels_of ""$n"")
    if printf '%s\n' "$ticket_labels" | grep -qxE "$LBL_PARTIAL|$(tr ' ' '|' <<<"$DECISION_LABELS")|$LBL_PM_DECISION"; then
      say "  KEEP       #$n — PR #$pr_num merged, but the ticket is partial or waiting on a human; not closing"
      kept=$((kept + 1)); continue
    fi
    say "  SHIPPED    #$n — PR #$pr_num is merged; closing the ticket"
    [ "$has_ref" -eq 1 ] && release_ref "$n"
    recover_lock "$n" "shipped"
    if [ "$DRY_RUN" -eq 0 ] && [ "$gh_ok" -eq 1 ]; then
      issue="$n"
      gh issue comment "$issue" --repo "$GH_REPO" --body \
        "**Shipped.** PR #$pr_num merged, but the claim was still held and the ticket still open — \`/finish\`'s bookkeeping runs locally and dies with its session, while \`--auto\` merges server-side without it. Closing against the merged PR." >/dev/null 2>&1
      gh issue close "$issue" --repo "$GH_REPO" --reason completed >/dev/null 2>&1
    fi
    shipped=$((shipped + 1)); continue
  fi

  if [ -n "$pr_num" ] && [ "$pr_state" = "OPEN" ]; then
    say "  IN-REVIEW  #$n — PR #$pr_num is open; the work exists, not releasing"
    [ "$has_ref" -eq 1 ] && release_ref "$n"
    recover_lock "$n" "in-review"
    relabel "$n" "$LBL_IN_REVIEW" \
      "**Claim released, ticket not.** The agent holding this is gone, but PR #$pr_num is open with work in it. Marked \`$LBL_IN_REVIEW\` rather than \`$LBL_READY\` — releasing it would have a fresh agent rebuild what is already there."
    inreview=$((inreview + 1)); continue
  fi

  if [ -n "$branch" ]; then
    say "  PARTIAL    #$n — branch $branch exists, no PR; stranded, not releasing"
    [ "$has_ref" -eq 1 ] && release_ref "$n"
    recover_lock "$n" "partial"
    relabel "$n" "$LBL_PARTIAL" \
      "**Claim released, work stranded.** The agent holding this is gone and left branch \`$branch\` with no PR. Marked \`$LBL_PARTIAL\` — resume from that branch rather than starting over."
    partial=$((partial + 1)); continue
  fi

  say "  RELEASED   #$n — no claim, no branch, no PR; back to ready"
  [ "$has_ref" -eq 1 ] && release_ref "$n"
  recover_lock "$n" "released"
  relabel "$n" "$LBL_READY" \
    "**Claim released.** The agent holding this is gone and left no branch and no PR, so there is nothing to lose. Back to \`$LBL_READY\`."
  released=$((released + 1))
done

say "[reconcile-claims]$([ "$DRY_RUN" -eq 1 ] && echo ' (dry run)') checked $checked · live $live · elsewhere $elsewhere · shipped $shipped · in-review $inreview · partial $partial · released $released · kept $kept"

# #11167 — the dev servers a crashed or abandoned window left behind, in a
# worktree no claim holds any more. Every /claim runs this, so the sweep runs
# many times a day on every machine. Never allowed to fail the reconcile.
bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stop-dev-servers.sh" --sweep \
  $([ "$DRY_RUN" -eq 1 ] && echo --dry-run) 2>&1 | sed 's/^/[stop-dev-servers] /' || true

# Always 0. A stale claim being reconciled is a normal outcome, not a broken
# script, and this runs at /claim step 0 where a non-zero exit would block a
# fresh claim.
exit 0
