#!/usr/bin/env bash
# signoff-push-guard.sh — sign-off comes last: once the owner has signed a PR's
# screens, a push whose head differs from the signed head in one of them is
# refused, unless a commit since the signed head says why in a
# `pixel-change-after-signoff: <why>` trailer. Then the hold goes back on, the PR
# gets a before/after comment, and the owner's next batch carries it
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
# Wired from the consuming repo's own pre-push (the kit ships no git hook), last —
# after its own push checks, so a push they refuse never re-adds the hold — with
# the ref lines it saved:
#   printf '%s\n' "$REFS" | bash "<kit>/scripts/signoff-push-guard.sh" "$@" || exit 1
#
# THE TREES, NOT THE COMMITS. The signed head and the pushed head are compared
# directly, so a merge taking the trunk's side, a resolution dropping a screen, a
# force-push to an earlier commit and a commit that reached the remote through
# another branch all show. A file counts only when it is the PR's own at either
# head (it differs from where that head meets <remote>/<integrationBranch>), and
# only when the PR's own change to it differs between the heads (approval-kept.sh
# own-changed): a trunk edit elsewhere in a shared file is a trunk merge, as
# approval-kept.sh check reads it.
#
# SIGNED = approval-kept.sh signed-head: a review, a marked clear-hold, or a person
# removing the hold on GitHub (its head is the PR's head then). A sign-off whose head
# cannot be placed uses the remote's current head. A PR still carrying the hold is
# not signed — the owner signs what lands — so it passes, with no new comment.
#
# SCREENS = approval-kept.sh screens, the one screen set the briefs name too:
# design.surfacePaths plus design.extraScreens, never a test, design.neverScreens
# or release notes (Markdown, docs/, .changeset/, CHANGELOG — their wording may
# change after sign-off, owner 2026-10-18). A server-only fix is not a screen here.
# approval-kept.sh check keeps its wider rule for the merge lane; its header says why.
#
# SIGNOFF_GUARD_DRYRUN=1 (a trial run, never a real push): the same decision, the
# same refusal line and exit code, and no label, comment or notify.
#
# The hold goes back on BEFORE the push is accepted (git has no post-push hook), and
# the comment says so. A screen change whose sign-off cannot be read is refused:
# the guard fails shut, and only for screens — a push that changes no screen
# relative to the remote's head asks GitHub nothing.
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
TRUNK="refs/remotes/$REMOTE/$INTEGRATION_BRANCH"

say() { printf '%s\n' "$*" >&2; }
nonzero() { case "$1" in *[!0]*) return 0 ;; *) return 1 ;; esac; }
has() { git cat-file -e "$1^{commit}" 2>/dev/null; }

screens() { # paths on stdin, the screen set
  local s; s=$(bash "$KEPT" screens) || return 1
  printf '%s\n' "$s" | sed '/^$/d'
}

own() { # <sha> — the files that head changes against where it meets the trunk
  local mb; mb=$(git merge-base "$TRUNK" "$1" 2>/dev/null) || return 1
  git diff --name-only --no-renames "$mb" "$1"
}

moved() { # <from> <to> — the PR's own screens that differ between two heads; 1 unreadable
  local d o oa ob
  d=$(git diff --name-only --no-renames "$1" "$2") || return 1
  [ -n "$d" ] || return 0
  d=$(printf '%s\n' "$d" | screens) || return 1
  [ -n "$d" ] || return 0
  # No trunk or no merge-base (a shallow clone): whose a screen is cannot be told, so it counts.
  if git rev-parse -q --verify "$TRUNK" >/dev/null; then
    oa=$(own "$1") && ob=$(own "$2") || return 1
    o=$(printf '%s\n%s\n' "$oa" "$ob" | sed '/^$/d' | sort -u)
    d=$(comm -12 <(printf '%s\n' "$d" | sort -u) <(printf '%s\n' "$o"))
    # A file the trunk also edited differs between the heads; only the PR's own edit counts.
    [ -z "$d" ] || d=$(printf '%s\n' "$d" | bash "$KEPT" own-changed "$1" "$2" "$TRUNK") || return 1
  fi
  [ -n "$d" ] && printf '%s\n' "$d"
  return 0
}

whys() { # <signed> <head> — the trailers on this PR's own commits since the signed head
  local c w out="" cs
  # The trunk's squash commits carry other PRs' bodies, reasons included: never theirs.
  cs=$(git rev-list "$2" --not "$1" "$TRUNK" 2>/dev/null) || return 0
  for c in $cs; do
    w=$(git log -1 --format=%B "$c" | git interpret-trailers --parse 2>/dev/null \
        | grep -i "^$TRAILER:" | sed 's/^[^:]*:[[:space:]]*//' | sed '/^[[:space:]]*$/d' | head -1)
    [ -z "$w" ] || out="$out${out:+; }$w"
  done
  printf '%s' "$out"
}

refused=0
# Read whole first: a command in the loop that reads stdin would eat the next ref.
REFS=$(cat)
while read -r _lref lsha rref rsha; do
  [ -n "${lsha:-}" ] && nonzero "$lsha" || continue
  case "$rref" in refs/heads/*) ;; *) continue ;; esac
  branch=${rref#refs/heads/}
  if [ -n "${rsha:-}" ] && nonzero "$rsha" && has "$rsha"; then base="$rsha"
  else base=$(git merge-base "$TRUNK" "$lsha" 2>/dev/null) || base=""; fi
  if [ -n "$base" ]; then
    first=$(moved "$base" "$lsha") || { say "✗ pre-push blocked: could not tell which files of $branch are screens"; refused=1; continue; }
    [ -n "$first" ] || continue
  fi

  prs=$(gh_call pr list --repo "$REPO" --head "$branch" --state open --json number,labels 2>/dev/null)
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$prs" \
    || { say "✗ pre-push blocked: $branch changes screens and its pull request could not be read, so whether the owner signed it is unknown. Try again."; refused=1; continue; }
  pr=$(jq -r '.[0].number // empty' <<<"$prs")
  [ -n "$pr" ] || continue
  jq -e --arg h "$HOLD_LABEL" 'any(.[0].labels[]?; .name == $h)' >/dev/null <<<"$prs" && continue

  signed=$(bash "$KEPT" signed-head "$pr" 2>/dev/null); src=$?
  case "$src" in
    1) continue ;;
    0) [ -n "$signed" ] || src=2 ;;
    3) signed="$base"; [ -n "$signed" ] || src=2 ;;
  esac
  [ "$src" -eq 0 ] || [ "$src" -eq 3 ] \
    || { say "✗ pre-push blocked: PR #$pr's sign-offs could not be read, and this push changes its screens. Try again."; refused=1; continue; }
  has "$signed" || git fetch -q "$REMOTE" "$signed" 2>/dev/null || true
  has "$signed" || { say "✗ pre-push blocked: PR #$pr was signed at ${signed:0:7}, which this clone cannot read. Fetch it and push again."; refused=1; continue; }
  files=$(moved "$signed" "$lsha") || { say "✗ pre-push blocked: could not compare $branch with the signed ${signed:0:7}"; refused=1; continue; }
  [ -n "$files" ] || continue
  list=$(printf '%s\n' "$files" | tr '\n' ' ' | sed 's/ $//')
  why=$(whys "$signed" "$lsha")

  if [ -z "$why" ]; then
    say "✗ pre-push blocked: sign-off comes last. The owner signed PR #$pr at ${signed:0:7}, and this push changes its screens: $list"
    [ "$src" -eq 3 ] && say "  (the sign-off was a label removal no commit could place, so the remote's head stands in for it)"
    say "  A review note that would change pixels becomes a follow-up ticket, not a commit here."
    say "  A required fix that must change pixels says why in a commit message since the sign-off, as a trailer:"
    say "    $TRAILER: <why>"
    say "  and the hold goes back on for the owner to sign again."
    refused=1; continue
  fi

  # A trial run (a driver self-check) decides the same and touches nothing.
  if [ "${SIGNOFF_GUARD_DRYRUN:-}" = 1 ]; then
    say "signoff-push-guard: dry run — PR #$pr changes screens signed at ${signed:0:7} ($why); a real push would put the hold back on"
    continue
  fi
  # Every screen change says why: the owner signs again.
  if ! gh_call pr edit "$pr" --repo "$REPO" --add-label "$HOLD_LABEL" >/dev/null 2>&1; then
    say "✗ pre-push blocked: PR #$pr changes signed screens and the hold could not be put back on. Try again."
    refused=1; continue
  fi
  issue=$(printf '%s\n' "$branch" | branch_tickets | cut -f1)
  [ -z "$issue" ] || gh_call issue edit "$issue" --repo "$REPO" --add-label "$HOLD_LABEL" >/dev/null 2>&1 || true
  cmp="https://github.com/$REPO/compare/$signed...$lsha"
  gh_call pr comment "$pr" --repo "$REPO" --body "\`$HOLD_LABEL\` is back on: a pixel change after sign-off, pending its push (if the push does not land, the hold stays on until it is signed again).

- **Before:** the signed head \`${signed:0:7}\`
- **After:** \`${lsha:0:7}\` — $cmp
- **Screens:** $list
- **Why:** $why

CI photographs the new head; compare its shots with the ones signed at \`${signed:0:7}\`." >/dev/null 2>&1 \
    || say "signoff-push-guard: the hold is back on PR #$pr; its before/after comment could not be posted"
  COORDINATOR_SHADOW=0 bash "$NOTIFY" --class agent "lane-hold:$pr:${lsha:0:7}" \
    "PR #$pr needs your sign-off again: changed after sign-off — before ${signed:0:7}, after ${lsha:0:7} ($list): $why" >/dev/null 2>&1 || true
  say "signoff-push-guard: PR #$pr changes screens signed at ${signed:0:7} ($why) — the hold is back on and the owner signs again"
done <<<"$REFS"
exit "$refused"
