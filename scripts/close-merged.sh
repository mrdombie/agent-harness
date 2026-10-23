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
export GH_CALLER="${GH_CALLER:-close-merged}"

DRY=0
case "${1:-}" in --dry-run) DRY=1 ;; '') ;; *) echo "usage: $(basename "$0") [--dry-run]" >&2; exit 2 ;; esac

DIR="${COORDINATOR_DIR:-$STATE_DIR/coordinator}"
HWM_FILE="$DIR/close-merged.hwm"
DONE_FILE="$DIR/close-merged.commented"
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

# One row per merged PR since the mark, oldest first: <merged_at> TAB <pr> TAB <ticket ticket…>
export CLOSE_MERGED_RE="$REF_RE"
rows=$(gh_read "the PRs merged into $BASE" api "repos/$REPO_SLUG/pulls?state=closed&base=$BASE&sort=updated&direction=desc&per_page=100" \
  --jq '[.[] | select(.merged_at != null and .merged_at > $ENV.CLOSE_MERGED_HWM and .base.ref == $ENV.CLOSE_MERGED_BASE)]
        | sort_by(.merged_at)[]
        | [.merged_at, (.number | tostring), ([(.body // "") | scan($ENV.CLOSE_MERGED_RE) | .[-1]] | unique | join(" "))] | @tsv') \
  || { echo "close-merged: nothing closed this pass"; exit 1; }

new_hwm="$hwm"; hold=""; rc=0; closed=0
while IFS=$'\t' read -r at pr tickets; do
  [ -n "${at:-}" ] || continue
  failed=0
  for t in $tickets; do
    info=$(gh_read "ticket #$t" api "repos/$REPO_SLUG/issues/$t" \
      --jq '[.state, (if .pull_request then "pr" else "issue" end), ([.labels[].name] | join("\n"))] | join("\t")'); r=$?
    [ "$r" -eq "$GH_READ_MISSING" ] && { echo "PR #$pr names #$t, which does not exist — skipped"; continue; }
    [ "$r" -eq 0 ] || { failed=1; continue; }
    state=${info%%$'\t'*}; rest=${info#*$'\t'}; kind=${rest%%$'\t'*}; labels=${rest#*$'\t'}
    [ "$kind" = issue ] || continue
    [ "$state" = open ] || continue
    if printf '%s\n' "$labels" | grep -qxF -- "${LBL_POLISH_LIST:-polish-list}"; then
      echo "PR #$pr names polish list #$t — left to the polish-list sweep"; continue
    fi
    if [ "$DRY" -eq 1 ]; then echo "would close #$t — PR #$pr merged to $BASE"; continue; fi
    args=""
    while IFS= read -r l; do
      case "$l" in "$(issue_status_prefix)"*) args="$args"$'\n'"--remove-label"$'\n'"$l" ;; esac
    done <<<"$labels"
    if ! grep -qxF "$t $pr" "$DONE_FILE" 2>/dev/null; then
      gh_call issue comment "$t" --repo "$REPO_SLUG" --body "Closed by #$pr, merged to $BASE." >/dev/null 2>&1 \
        || { echo "close-merged: could not comment on #$t" >&2; failed=1; continue; }
      echo "$t $pr" >> "$DONE_FILE"
    fi
    if [ -n "$args" ]; then
      ( IFS=$'\n'
        # shellcheck disable=SC2086  # a newline-separated flag list, split on newlines only
        gh_call issue edit "$t" --repo "$REPO_SLUG" ${args#$'\n'} >/dev/null 2>&1 ) \
        || { echo "close-merged: could not take #$t's status labels off" >&2; failed=1; continue; }
    fi
    gh_call issue close "$t" --repo "$REPO_SLUG" --reason completed >/dev/null 2>&1 \
      || { echo "close-merged: could not close #$t" >&2; failed=1; continue; }
    [ -s "${COORD_QUEUE:-$DIR/queue.json}" ] && bash "$QUEUE" remove "$t" >/dev/null 2>&1
    echo "closed #$t — PR #$pr merged to $BASE"; closed=$((closed + 1))
  done
  if [ "$failed" -eq 1 ]; then rc=1; [ -n "$hold" ] || hold="$at"; fi
  [ -n "$hold" ] || new_hwm="$at"
done <<<"$rows"

# A PR left half done holds the mark one second before it, so the next pass reads it again.
if [ -n "$hold" ]; then
  s=$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$hold" +%s 2>/dev/null || date -u -d "$hold" +%s 2>/dev/null)
  [ -n "$s" ] && new_hwm=$(date -u -r $((s - 1)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((s - 1))" +%Y-%m-%dT%H:%M:%SZ)
fi
[ "$DRY" -eq 1 ] || printf '%s\n' "$new_hwm" > "$HWM_FILE"
echo "close-merged: $closed closed; merged since $hwm read${hold:+; held at $new_hwm to retry}"
exit "$rc"
