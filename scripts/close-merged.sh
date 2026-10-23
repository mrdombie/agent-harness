#!/usr/bin/env bash
# close-merged.sh — close every ticket a PR merged into the integration branch names
# with a closing keyword, whoever merged it.
#
#   close-merged.sh [--dry-run]
#
# GitHub closes "Closes #N" only on a merge into the DEFAULT branch. A project that
# merges to another integration branch gets nothing from it, so this does it: one
# REST page of the closed PRs into that branch, newest-updated first, and for each
# one merged since the last pass, every ticket its body names with close/closes/closed,
# fix/fixes/fixed or resolve/resolves/resolved (any case, an optional colon, "#N", this
# repo's "owner/repo#N" or its full issue URL). "Refs #N" and "Part of #N" close nothing.
#
# Each named ticket that is open and an issue gets one comment ("Closed by #PR, merged
# to <branch>"), loses every status label, is closed as completed and leaves the
# coordinator's queue. A polish list is left to polish-list.sh: it closes only when
# nothing is left on it.
#
# ONE MERGE IS NOT THE WHOLE TICKET: a ticket another OPEN PR still names (by a closing
# keyword, "Part of", or a branch that is the ticket's — ticket-open-prs.sh) stays open,
# with one "Merged #X; #Y is still open for this ticket." per pair, and waits in
# $COORD_DIR/close-merged.waiting. Each pass closes a waiting ticket once no open PR
# names it any more: it closes on the last merge, whichever PR that was.
#
# A PARKED OR BATCH RUN CLOSES NOTHING: a PR whose title opens "parked" or "WIP", or one
# naming a ticket whose body lists children (a batch), leaves every ticket it names open
# with "Merged by #PR, a parked/batch run; check this ticket's acceptance before
# closing." A batch's open children still labelled batched go back to ready, with it.
#
# The high-water mark is the newest merged_at handled, in $COORD_DIR/close-merged.hwm;
# with none, the pass looks back CLOSE_MERGED_LOOKBACK_DAYS (default 14). A read that
# fails changes nothing and moves no mark: the list unread ends the pass, a ticket
# unread holds the mark before its PR so the next pass tries it again. Exit 1 then.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 1
. "$SELF_DIR/gh-batch.sh" || exit 1
. "$SELF_DIR/pr-closes.sh" || exit 1
. "$SELF_DIR/issue-status.sh" || exit 1
. "$SELF_DIR/close-batch-children.sh" || exit 1
. "$SELF_DIR/ticket-open-prs.sh" || exit 1
export GH_CALLER="${GH_CALLER:-close-merged}"

DRY=0
case "${1:-}" in --dry-run) DRY=1 ;; '') ;; *) echo "usage: $(basename "$0") [--dry-run]" >&2; exit 2 ;; esac

DIR="${COORDINATOR_DIR:-$STATE_DIR/coordinator}"
HWM_FILE="$DIR/close-merged.hwm"
DONE_FILE="$DIR/close-merged.commented"
WAIT_FILE="$DIR/close-merged.waiting"
BASE="${INTEGRATION_BRANCH:?close-merged: no integration branch}"
QUEUE="${CLOSE_MERGED_QUEUE:-$SELF_DIR/coordinator-queue.sh}"
mkdir -p "$DIR" 2>/dev/null || true

iso_days_ago() { # <days>
  local s=$(( $(date +%s) - $1 * 86400 ))
  date -u -r "$s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$s" +%Y-%m-%dT%H:%M:%SZ
}
hwm=$(cat "$HWM_FILE" 2>/dev/null || true)
case "$hwm" in [0-9][0-9][0-9][0-9]-*T*Z) ;; *) hwm=$(iso_days_ago "${CLOSE_MERGED_LOOKBACK_DAYS:-14}") ;; esac

export CLOSE_MERGED_HWM="$hwm" CLOSE_MERGED_BASE="$BASE"
# The repo in a regex: its dots literal.
slug_re=$(printf '%s' "$REPO_SLUG" | sed 's/[].[^$*+?(){}|\\/]/\\&/g')
REF_RE="(?i)(?:^|[^A-Za-z0-9_])(?:${PR_CLOSES_KEYWORDS}):?[ \\t]+(?:#|${slug_re}#|https?://github\\.com/${slug_re}/issues/)([0-9]+)(?![0-9A-Za-z_])"

# One row per merged PR since the mark, oldest first:
# <merged_at> TAB <pr> TAB <parked|-> TAB <ticket ticket…>
# PARKED is a title that opens "parked" or "WIP", after the driver's "#N: " or a "[tag]".
export CLOSE_MERGED_RE="$REF_RE"
rows=$(gh_read "the PRs merged into $BASE" api "repos/$REPO_SLUG/pulls?state=closed&base=$BASE&sort=updated&direction=desc&per_page=100" \
  --jq '[.[] | select(.merged_at != null and .merged_at > $ENV.CLOSE_MERGED_HWM and .base.ref == $ENV.CLOSE_MERGED_BASE)]
        | sort_by(.merged_at)[]
        | [.merged_at, (.number | tostring),
           (if ((.title // "") | test("^\\s*(#[0-9]+\\s*:\\s*)?(\\[[^]]*\\]\\s*)?(parked|wip)([^a-z]|$)"; "i")) then "parked" else "-" end),
           ([(.body // "") | scan($ENV.CLOSE_MERGED_RE) | .[-1]] | unique | join(" "))] | @tsv') \
  || { echo "close-merged: nothing closed this pass"; exit 1; }

RD=$(mktemp -d "${TMPDIR:-/tmp}/close-merged.XXXXXX") || { echo "close-merged: no temp dir — nothing closed this pass"; exit 1; }
trap 'rm -rf "$RD"' EXIT
export TICKET_OPEN_PRS_CACHE="$RD/open-prs.json"

# The tickets a merge left open for another open PR: "<ticket> <merged pr>" a line.
wait_add() { # <ticket> <merged pr>
  [ "$DRY" -eq 0 ] || return 0
  grep -q "^$1 " "$WAIT_FILE" 2>/dev/null && return 0
  echo "$1 $2" >> "$WAIT_FILE"
}
wait_drop() { # <ticket>
  [ "$DRY" -eq 0 ] && [ -f "$WAIT_FILE" ] || return 0
  grep -v "^$1 " "$WAIT_FILE" > "$WAIT_FILE.t" 2>/dev/null; mv "$WAIT_FILE.t" "$WAIT_FILE"
}

# note_once <ticket> <pr> <body> — one comment per ticket and PR, ever. 1 when it failed.
note_once() {
  grep -qxF "$1 $2" "$DONE_FILE" 2>/dev/null && return 0
  gh_call issue comment "$1" --repo "$REPO_SLUG" --body "$3" >/dev/null 2>&1 \
    || { echo "close-merged: could not comment on #$1" >&2; return 1; }
  echo "$1 $2" >> "$DONE_FILE"
}

# A PARKED OR BATCH RUN'S MERGE CLOSES NOTHING. 23 Oct: a "parked — …" PR merged under
# merge-first; its "Closes" closed a batch ticket with 5 of its 6 children half done.
# Each named ticket is told to have its acceptance checked instead, and a batch's
# children still marked batched go back to ready, where a run can finish them.
unfinished() { # <pr> <why> <ticket…> — 1 when a write or a read failed
  local pr="$1" why="$2" t c info kids f=0 msg; shift 2
  msg="Merged by #$pr, a $why run; check this ticket's acceptance before closing."
  for t in "$@"; do
    if [ "$DRY" -eq 1 ]; then echo "would comment on #$t — PR #$pr was a $why run, so it is not closed"; else
      note_once "$t" "$pr" "$msg" || { f=1; continue; }
      wait_drop "$t"
      echo "left open #$t — PR #$pr was a $why run"
    fi
    kids=$(cut -f4 "$RD/$t" | base64 --decode 2>/dev/null | batch_children "$t")
    for c in $kids; do
      info=$(gh_read "batch child #$c" api "repos/$REPO_SLUG/issues/$c" \
        --jq '[.state, ([.labels[].name] | join(","))] | join("\t")') || { f=1; continue; }
      [ "${info%%$'\t'*}" = open ] || continue
      case ",${info#*$'\t'}," in *",${LBL_BATCHED:-status:batched},"*) ;; *) continue ;; esac
      if [ "$DRY" -eq 1 ]; then echo "would release batch child #$c to ${LBL_READY}"; continue; fi
      note_once "$c" "$pr" "$msg" || { f=1; continue; }
      issue_status_set "$c" "$LBL_READY" --drop "${LBL_BATCHED:-status:batched}" >/dev/null 2>&1 \
        || { echo "close-merged: could not release batch child #$c" >&2; f=1; continue; }
      echo "released #$c to $LBL_READY — batch #$t merged by #$pr"
    done
  done
  return "$f"
}

# close_one <ticket> <pr> <labels, a line each> <comment> — 1 when a write failed
close_one() {
  local t="$1" pr="$2" labels="$3" note="$4" args="" l
  if [ "$DRY" -eq 1 ]; then echo "would close #$t — PR #$pr merged to $BASE"; return 0; fi
  while IFS= read -r l; do
    case "$l" in "$(issue_status_prefix)"*) args="$args"$'\n'"--remove-label"$'\n'"$l" ;; esac
  done <<<"$labels"
  note_once "$t" "$pr" "$note" || return 1
  if [ -n "$args" ]; then
    ( IFS=$'\n'
      # shellcheck disable=SC2086  # a newline-separated flag list, split on newlines only
      gh_call issue edit "$t" --repo "$REPO_SLUG" ${args#$'\n'} >/dev/null 2>&1 ) \
      || { echo "close-merged: could not take #$t's status labels off" >&2; return 1; }
  fi
  gh_call issue close "$t" --repo "$REPO_SLUG" --reason completed >/dev/null 2>&1 \
    || { echo "close-merged: could not close #$t" >&2; return 1; }
  [ -s "${COORD_QUEUE:-$DIR/queue.json}" ] && bash "$QUEUE" remove "$t" >/dev/null 2>&1
  wait_drop "$t"
  echo "closed #$t — PR #$pr merged to $BASE"; closed=$((closed + 1))
}

new_hwm="$hwm"; hold=""; rc=0; closed=0
while IFS=$'\t' read -r at pr parked tickets; do
  [ -n "${at:-}" ] || continue
  failed=0; open_named=""; batch=0
  for t in $tickets; do
    info=$(gh_read "ticket #$t" api "repos/$REPO_SLUG/issues/$t" \
      --jq '[.state, (if .pull_request then "pr" else "issue" end), ([.labels[].name] | join(",")), ((.body // "") | @base64)] | join("\t")'); r=$?
    [ "$r" -eq "$GH_READ_MISSING" ] && { echo "PR #$pr names #$t, which does not exist — skipped"; continue; }
    [ "$r" -eq 0 ] || { failed=1; continue; }
    printf '%s\n' "$info" > "$RD/$t"
    [ "$(cut -f1,2 "$RD/$t")" = "open"$'\t'"issue" ] || continue
    open_named="$open_named $t"
    [ -z "$(cut -f4 "$RD/$t" | base64 --decode 2>/dev/null | batch_children "$t")" ] || batch=1
  done
  if [ "$failed" -eq 0 ] && { [ "$parked" = parked ] || [ "$batch" -eq 1 ]; }; then
    why=$([ "$parked" = parked ] && echo parked || echo batch)
    [ "$parked" != parked ] || [ "$batch" -eq 0 ] || why="parked batch"
    # shellcheck disable=SC2086  # a space-separated ticket list
    unfinished "$pr" "$why" $open_named || failed=1
    open_named=""
  fi
  [ "$failed" -eq 0 ] || open_named=""   # a ticket unread: nothing of this PR closes this pass
  for t in $open_named; do
    labels=$(cut -f3 "$RD/$t" | tr ',' '\n')
    if printf '%s\n' "$labels" | grep -qxF -- "${LBL_POLISH_LIST:-polish-list}"; then
      echo "PR #$pr names polish list #$t — left to the polish-list sweep"; continue
    fi
    # ONE MERGE IS NOT THE WHOLE TICKET: another open PR naming it keeps it open.
    others=$(ticket_open_prs "$t" "$pr") \
      || { echo "close-merged: the open pull requests could not be read, so whether #$t has work still open is unknown — not closed" >&2; failed=1; continue; }
    if [ -n "$others" ]; then
      for y in $others; do
        if [ "$DRY" -eq 1 ]; then echo "would leave #$t open — PR #$pr merged, #$y is still open"; continue; fi
        note_once "$t" "$pr $y" "Merged #$pr; #$y is still open for this ticket." || failed=1
      done
      wait_add "$t" "$pr"
      echo "left open #$t — PR #$pr merged; $(printf '#%s ' $others)still open for it"
      continue
    fi
    close_one "$t" "$pr" "$labels" "Closed by #$pr, merged to $BASE." || { failed=1; continue; }
  done
  if [ "$failed" -eq 1 ]; then rc=1; [ -n "$hold" ] || hold="$at"; fi
  [ -n "$hold" ] || new_hwm="$at"
done <<<"$rows"

# The tickets left open for another PR close once no open PR names them: the last merge.
if [ -s "$WAIT_FILE" ]; then
  while read -r t pr; do
    case "$t$pr" in ''|*[!0-9]*) continue ;; esac
    info=$(gh_read "waiting ticket #$t" api "repos/$REPO_SLUG/issues/$t" \
      --jq '[.state, ([.labels[].name] | join(","))] | join("\t")'); r=$?
    [ "$r" -eq "$GH_READ_MISSING" ] && { wait_drop "$t"; continue; }
    [ "$r" -eq 0 ] || { rc=1; continue; }
    [ "${info%%$'\t'*}" = open ] || { wait_drop "$t"; continue; }
    others=$(ticket_open_prs "$t" "$pr") || { rc=1; continue; }
    [ -z "$others" ] || continue
    close_one "$t" "$pr" "$(printf '%s' "${info#*$'\t'}" | tr ',' '\n')" \
      "Closed: #$pr merged to $BASE, and no open pull request names this ticket any more." || rc=1
  done < <(cat "$WAIT_FILE")
fi

# A PR left half done holds the mark one second before it, so the next pass reads it again.
if [ -n "$hold" ]; then
  s=$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$hold" +%s 2>/dev/null || date -u -d "$hold" +%s 2>/dev/null)
  [ -n "$s" ] && new_hwm=$(date -u -r $((s - 1)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((s - 1))" +%Y-%m-%dT%H:%M:%SZ)
fi
[ "$DRY" -eq 1 ] || printf '%s\n' "$new_hwm" > "$HWM_FILE"
echo "close-merged: $closed closed; merged since $hwm read${hold:+; held at $new_hwm to retry}"
exit "$rc"
