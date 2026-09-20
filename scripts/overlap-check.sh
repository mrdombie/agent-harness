#!/usr/bin/env bash
# overlap-check.sh <issue> [--repo owner/name]
#
# Answers a question the ticket-number checks cannot: "is someone already
# editing the files this ticket is about?"
#
# /claim's Pass B looks for an open PR that NAMES the candidate, or a branch
# KEYED to its number. That catches the same ticket twice. It cannot catch two
# different tickets that land on the same file — which is the shape that
# actually cost us: on 2026-08-08 two peers filed and built #8764 and #8776
# against work already in flight under #8627 and #8629, and #8809 and #8762
# both edit .github/workflows/promote-uat.yml under unrelated numbers.
#
# Signal: the paths named in the candidate's issue body, intersected with the
# files changed by every open PR and every branch behind a live claim.
#
# Exit 0 always — this INFORMS a claim decision, it never blocks one. A false
# positive that halts the queue is worse than a warning an agent reads.

set -uo pipefail

ISSUE="${1:?usage: overlap-check.sh <issue> [--repo owner/name]}"; shift || true
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" || exit 1
REPO="$REPO_SLUG"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# --- the candidate's paths, as named in its own body -------------------------
# Tickets name files both ways — "apps/api/src/lib/jobs/queue.ts" and a bare
# "promote-uat.yml" — so match either. Requiring a directory segment missed the
# bare form, which is how the first version of this script reported "no paths"
# on a ticket whose body names two workflow files in its first sentence.
#
# Extensions are listed rather than globbed: `.md` and `.json` are excluded on
# purpose. Docs and lockfiles are touched by nearly every PR, so including them
# would make almost every candidate look contended, and a warning that always
# fires is one nobody reads.
EXT='ts|tsx|js|jsx|yml|yaml|sh|prisma|sql|css'
candidate_paths() {
  gh issue view "$ISSUE" --repo "$REPO" --json body,title -q '.title + "\n" + (.body // "")' 2>/dev/null \
    | grep -oE "([a-zA-Z0-9_.-]+/)*[a-zA-Z0-9_.-]+\.($EXT)\b" \
    | grep -vE '^(https?://|www\.)' \
    | sort -u
}

# A changed file matches when its full path is named, or when the ticket named
# it bare and the basename agrees. Bare-name matching is what makes a body that
# says "promote-uat.yml" line up with a diff that says
# ".github/workflows/promote-uat.yml".
match_files() {
  printf '%s\n' "$1" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    b="${f##*/}"
    printf '%s\n' $PATHS | while IFS= read -r c; do
      [ -n "$c" ] || continue
      case "$c" in
        */*) [ "$c" = "$f" ] && printf '%s\n' "$f" ;;
        *)   [ "$c" = "$b" ] && printf '%s\n' "$f" ;;
      esac
    done
  done | sort -u
}

PATHS=$(candidate_paths)
if [ -z "$PATHS" ]; then
  echo "overlap-check #$ISSUE: the body names no file paths — nothing to compare."
  echo "  A ticket whose spec names no files cannot be checked this way, and"
  echo "  usually is not specific enough to build from either."
  exit 0
fi

echo "overlap-check #$ISSUE — paths named in the ticket:"
printf '  %s\n' $PATHS
echo

# --- what every open PR touches ----------------------------------------------
HITS=0
while read -r PR HEAD TITLE; do
  [ -n "${PR:-}" ] || continue
  # Skip the candidate's OWN PR. Re-running this on a ticket already in flight
  # otherwise reports it as contending with itself, and a check that flags the
  # thing you are holding teaches you to ignore it. Anchored so #857 does not
  # match sh-8571/.
  case "$HEAD" in
    "$ISSUE"[-/]*|*"/$ISSUE"[-/]*|*"/sh-$ISSUE"[-/]*|"sh-$ISSUE"[-/]*) continue ;;
  esac
  FILES=$(gh pr diff "$PR" --repo "$REPO" --name-only 2>/dev/null) || continue
  [ -n "$FILES" ] || continue
  COMMON=$(match_files "$FILES")
  if [ -n "$COMMON" ]; then
    HITS=$((HITS + 1))
    echo "  ⚠ OPEN PR #$PR ($HEAD) — $TITLE"
    printf '      also edits: %s\n' $COMMON
  fi
done < <(gh pr list --repo "$REPO" --state open --limit 100 \
           --json number,headRefName,title -q '.[] | "\(.number) \(.headRefName) \(.title)"' 2>/dev/null)

# --- what every live claim's branch touches ----------------------------------
# A claim ref exists before its PR does. Without this, the window between
# "agent claimed and started editing" and "agent opened a PR" is invisible —
# and that window is exactly when a second agent picks up the same files.
while read -r _sha REF; do
  N="${REF##*/}"
  [ "$N" = "$ISSUE" ] && continue
  BR=$(git ls-remote --heads origin "*${N}*" 2>/dev/null | head -1 | sed 's|.*refs/heads/||')
  [ -n "$BR" ] || continue
  FILES=$(git diff --name-only "origin/develop...origin/$BR" 2>/dev/null) || continue
  [ -n "$FILES" ] || continue
  COMMON=$(match_files "$FILES")
  if [ -n "$COMMON" ]; then
    HITS=$((HITS + 1))
    echo "  ⚠ LIVE CLAIM #$N (branch $BR, no PR yet)"
    printf '      also edits: %s\n' $COMMON
  fi
done < <(git ls-remote origin 'refs/claims/*' 2>/dev/null)

if [ "$HITS" -eq 0 ]; then
  echo "  clean — no open PR or live claim touches the files this ticket names."
else
  echo
  echo "  $HITS overlap(s). This does NOT block the claim — two tickets can edit"
  echo "  one file legitimately. Read them before starting: if the other work"
  echo "  already does what this ticket asks, close or re-scope instead of"
  echo "  building a second implementation."
fi
exit 0
