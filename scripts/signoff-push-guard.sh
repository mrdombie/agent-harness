#!/usr/bin/env bash
# signoff-push-guard.sh — sign-off comes last: once the owner has signed a PR's
# screens, a push that changes one of them is refused, unless every commit doing it
# says why in a `pixel-change-after-signoff: <why>` trailer. Then the hold goes back
# on, the PR gets a before/after comment, and the owner's next batch carries it
# (coordinator-notify, kind lane-hold).
#
#   signoff-push-guard.sh <remote> [<url>]   git's pre-push contract: on stdin, one
#                                            "<local ref> <local sha> <remote ref> <remote sha>"
#                                            line per ref pushed
#   exit 0 the push may go · 1 refused
#
# Owner's rule, 2026-10-17. Measured that day: of three screens he re-signed, two
# came back because a builder pushed a real screen change after his sign-off.
#
# Wired from the consuming repo's own pre-push (the kit ships no git hook):
#   bash "<kit>/scripts/signoff-push-guard.sh" "$@" || exit 1
# before anything else in it reads stdin, or with the ref lines saved and replayed.
#
# Signed = approval-kept.sh approved-head names a head (a review's commit, or
# clear-hold's comment that the hold's removal followed). Screen = approval-kept.sh
# screens (design.surfacePaths / surfacePathsComplete / neverScreens). A merge counts
# only for the files its resolution changed against every parent; a commit already
# on the remote (the trunk a merge brings) is not this push's. Commits under the
# approved head are what was signed. A screen change on a branch whose
# sign-off cannot be read is refused: the guard fails shut, and only for screens —
# a push that changes no screen asks GitHub nothing.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || { echo "✗ pre-push blocked: signoff-push-guard could not load harness.json" >&2; exit 1; }
. "$SELF_DIR/gh-batch.sh" || exit 1
. "$SELF_DIR/branch-ticket.sh" || exit 1
KEPT="$SELF_DIR/approval-kept.sh"
NOTIFY="$SELF_DIR/coordinator-notify.sh"
REPO="${GH_REPO:-$REPO_SLUG}"
REMOTE="${1:-origin}"
TRAILER="pixel-change-after-signoff"

say() { printf '%s\n' "$*" >&2; }
nonzero() { case "$1" in *[!0]*) return 0 ;; *) return 1 ;; esac; }
why_of() { # <commit> — the trailer's text, empty when absent
  git log -1 --format=%B "$1" | git interpret-trailers --parse 2>/dev/null \
    | grep -i "^$TRAILER:" | sed 's/^[^:]*:[[:space:]]*//' | sed '/^[[:space:]]*$/d' | head -1
}

refused=0
# Read whole first: a command in the loop that reads stdin would eat the next ref.
REFS=$(cat)
while read -r _lref lsha rref rsha; do
  [ -n "${lsha:-}" ] && nonzero "$lsha" || continue
  case "$rref" in refs/heads/*) ;; *) continue ;; esac
  branch=${rref#refs/heads/}
  if [ -n "${rsha:-}" ] && nonzero "$rsha" && git cat-file -e "$rsha^{commit}" 2>/dev/null; then
    new=$(git rev-list "$lsha" --not "$rsha" --remotes="$REMOTE" 2>/dev/null)
  else
    new=$(git rev-list "$lsha" --not --remotes="$REMOTE" 2>/dev/null)
  fi
  [ -n "$new" ] || continue

  touched=""   # <sha> \t <screen files, space-joined>
  for c in $new; do
    if [ "$(git rev-list --parents -n1 "$c" | wc -w)" -gt 2 ]; then
      files=$(git diff-tree -c --no-commit-id --name-only -r "$c")
    else
      files=$(git diff-tree --no-commit-id --name-only -r --root "$c")
    fi
    [ -n "$files" ] || continue
    scr=$(printf '%s\n' "$files" | bash "$KEPT" screens) \
      || { say "✗ pre-push blocked: could not tell which files of ${c:0:7} are screens"; refused=1; continue 2; }
    [ -z "$scr" ] || touched="$touched$c"$'\t'"$(printf '%s' "$scr" | tr '\n' ' ' | sed 's/ $//')"$'\n'
  done
  [ -n "$touched" ] || continue

  prs=$(gh_call pr list --repo "$REPO" --head "$branch" --state open --json number 2>/dev/null)
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$prs" \
    || { say "✗ pre-push blocked: $branch changes screens and its pull request could not be read, so whether the owner signed it is unknown. Try again."; refused=1; continue; }
  pr=$(jq -r '.[0].number // empty' <<<"$prs")
  [ -n "$pr" ] || continue
  approved=$(bash "$KEPT" approved-head "$pr" 2>/dev/null); arc=$?
  [ "$arc" -eq 1 ] && continue
  [ "$arc" -eq 0 ] && [ -n "$approved" ] \
    || { say "✗ pre-push blocked: PR #$pr's sign-offs could not be read, and this push changes its screens. Try again."; refused=1; continue; }
  git cat-file -e "$approved^{commit}" 2>/dev/null || git fetch -q "$REMOTE" "$approved" 2>/dev/null || true

  after=""; missing=""; whys=""; files_all=""
  while IFS=$'\t' read -r c scr; do
    [ -n "$c" ] || continue
    git merge-base --is-ancestor "$c" "$approved" 2>/dev/null && continue
    after="$after$c "; files_all="$files_all $scr"
    w=$(why_of "$c")
    if [ -z "$w" ]; then missing="$missing  ${c:0:7} $(git log -1 --format=%s "$c" | cut -c1-70) — $scr"$'\n'
    else whys="$whys${whys:+; }$w"; fi
  done <<<"$touched"
  [ -n "$after" ] || continue
  files_all=$(printf '%s\n' $files_all | sort -u | tr '\n' ' ' | sed 's/ $//')

  if [ -n "$missing" ]; then
    say "✗ pre-push blocked: sign-off comes last. The owner signed PR #$pr at ${approved:0:7}, and this push changes its screens after that:"
    printf '%s' "$missing" >&2
    say "  A review note that would change pixels becomes a follow-up ticket, not a commit here."
    say "  A required fix that must change pixels says why in its commit message, as a trailer:"
    say "    $TRAILER: <why>"
    say "  and the hold goes back on for the owner to sign again."
    refused=1; continue
  fi

  # Every screen change says why: the owner signs again.
  if ! gh_call pr edit "$pr" --repo "$REPO" --add-label "$HOLD_LABEL" >/dev/null 2>&1; then
    say "✗ pre-push blocked: PR #$pr changes signed screens and the hold could not be put back on. Try again."
    refused=1; continue
  fi
  issue=$(printf '%s\n' "$branch" | branch_tickets | cut -f1)
  [ -z "$issue" ] || gh_call issue edit "$issue" --repo "$REPO" --add-label "$HOLD_LABEL" >/dev/null 2>&1 || true
  cmp="https://github.com/$REPO/compare/$approved...$lsha"
  gh_call pr comment "$pr" --repo "$REPO" --body "\`$HOLD_LABEL\` is back on: a pixel change after sign-off.

- **Before:** the signed head \`${approved:0:7}\`
- **After:** \`${lsha:0:7}\` — $cmp
- **Screens:** $files_all
- **Why:** $whys

CI photographs the new head; compare its shots with the ones signed at \`${approved:0:7}\`." >/dev/null 2>&1 \
    || say "signoff-push-guard: the hold is back on PR #$pr; its before/after comment could not be posted"
  COORDINATOR_SHADOW=0 bash "$NOTIFY" --class agent "lane-hold:$pr:${lsha:0:7}" \
    "PR #$pr needs your sign-off again: changed after sign-off — before ${approved:0:7}, after ${lsha:0:7} ($files_all): $whys" >/dev/null 2>&1 || true
  say "signoff-push-guard: PR #$pr changes screens signed at ${approved:0:7} ($whys) — the hold is back on and the owner signs again"
done <<<"$REFS"
exit "$refused"
