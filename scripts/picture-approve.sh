#!/usr/bin/env bash
# picture-approve.sh <ticket> <picture.html> — an approved picture, readable from any machine.
#
# The moment a picture is approved, publish the file itself, not only the link to
# where it was drawn: a claude.ai artifact opens only for the person who made it,
# so a builder on another machine (or in the cloud) cannot read the picture that
# binds its build. This puts the file in a SECRET gist and posts one ticket comment
# naming it:
#
#   **Picture for any machine** — `<name>`, approved for #<ticket>
#   - Gist (secret): <url>
#   - Raw: <raw url>
#   - sha256: `<sha of the file>`
#   <!-- picture-approve: sha256=<sha> file=<name> gist=<id> -->
#
# Idempotent: a "Picture for any machine" comment on the ticket that already names
# this file's sha means it was published, and nothing is created or posted. A new
# version of the picture (another sha) is published again. A ticket whose comments
# cannot be read publishes nothing: an unread list is not "never published".
#
# The gist's description is "<project> #<ticket> approved picture: <name>";
# <project> is harness.json `projectName`, else the repo's name, capitalised.
# Exit: 0 published or already published, 1 a read or write failed, 2 bad arguments.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" || exit 1

die() { echo "picture-approve: $2" >&2; exit "$1"; }
T="${1:-}"; F="${2:-}"
case "$T" in ''|*[!0-9]*) die 2 "usage: picture-approve.sh <ticket> <picture.html>" ;; esac
[ -f "$F" ] && [ -s "$F" ] || die 2 "'$F' is not a picture file — nothing published"
REPO="${GH_REPO:-$REPO_SLUG}"
[ -n "$REPO" ] || die 1 "no repo: harness.json names none — nothing published"

NAME=$(basename "$F")
SHA=$( { shasum -a 256 "$F" 2>/dev/null || sha256sum "$F" 2>/dev/null; } | awk 'NR == 1 { print $1 }')
printf '%s' "$SHA" | grep -qE '^[0-9a-f]{64}$' || die 1 "could not take the sha256 of $F — nothing published"
PROJECT=$(toolkit_cfg projectName 2>/dev/null) || PROJECT=""
if [ -z "$PROJECT" ]; then
  PROJECT=${REPO##*/}
  PROJECT="$(printf '%s' "${PROJECT:0:1}" | tr '[:lower:]' '[:upper:]')${PROJECT:1}"
fi
HEAD_LINE="**Picture for any machine**"

comments=$(gh issue view "$T" --repo "$REPO" --json comments 2>/dev/null) \
  && jq -e '.comments | type == "array"' >/dev/null 2>&1 <<<"$comments" \
  || die 1 "#$T's comments could not be read — nothing published"
prior=$(jq -r --arg h "$HEAD_LINE" --arg sha "$SHA" '
  [.comments[] | .body // "" | select(startswith($h) and contains($sha))] | last // empty' <<<"$comments")
if [ -n "$prior" ]; then
  url=$(printf '%s\n' "$prior" | grep -oE 'https://gist\.github\.com/[^ )>]+' | head -1)
  echo "already published: #$T's $NAME (sha256 ${SHA:0:12}) is ${url:-on the ticket} — nothing done"
  exit 0
fi

# gh gist create is secret unless told --public; it prints the gist's URL.
out=$(gh gist create --desc "$PROJECT #$T approved picture: $NAME" "$F" 2>&1) \
  || die 1 "the gist could not be made: $(printf '%s' "$out" | tail -1)"
url=$(printf '%s\n' "$out" | grep -oE 'https://gist\.github\.com/[^ ]+' | tail -1)
[ -n "$url" ] || die 1 "gh made no gist URL: $(printf '%s' "$out" | tail -1)"
id=${url##*/}
raw=$(gh api "gists/$id" --jq '[.files[] | .raw_url] | first // empty' 2>/dev/null) || raw=""
case "$raw" in
  https://*) ;;
  *) owner=${url#https://gist.github.com/}; owner=${owner%%/*}
     raw="https://gist.githubusercontent.com/$owner/$id/raw/$NAME" ;;
esac

body=$(printf '%s — `%s`, approved for #%s\n\n- Gist (secret): %s\n- Raw: %s\n- sha256: `%s`\n\nAny machine reads it with `gh gist view %s --raw --filename %s` or `curl -fsSL %s`.\n\n<!-- picture-approve: sha256=%s file=%s gist=%s -->\n' \
  "$HEAD_LINE" "$NAME" "$T" "$url" "$raw" "$SHA" "$id" "$NAME" "$raw" "$SHA" "$NAME" "$id")
gh issue comment "$T" --repo "$REPO" --body "$body" >/dev/null 2>&1 \
  || die 1 "the gist is made ($url) but the comment on #$T was refused — post the comment by hand (a rerun makes a second gist)"
echo "published: #$T's $NAME (sha256 ${SHA:0:12})"
echo "gist: $url"
echo "raw: $raw"
