#!/usr/bin/env bash
# picture-fetch.sh <ticket> <ref> <tree> — the binding picture, on this machine.
#
# The other half of picture-approve.sh. A plan's designRef is often a path on the
# machine where the picture was drawn (~/.claude/plans/…/desk-mock.html), and a
# builder on any other machine finds nothing there. When the ref names a local file
# that does not exist here, this reads the ticket's newest "**Picture for any
# machine**" comment naming that file, fetches its raw gist, checks the sha256 the
# comment carries, and writes it into <tree> where the project keeps approved
# pictures (the directory of review.judge.mockGlob, default .design/, as
# <stem>-mock.html). A ref that is already a path in the tree keeps that path.
#
# With no such comment, a gist the ticket's body (or its parent's) names as the approved
# picture is that copy already: its file of the ref's name is read with gh, checked to be
# non-empty HTML, and used the same way. This reads a picture the ticket names as
# approved; it approves nothing.
#
# Prints the ref to record on stdout: unchanged when there is nothing to fetch (a
# URL, a file that exists here, no picture path at all), else the tree-relative
# path written. The caller commits it.
#
# AN APPROVAL BINDS BY ITS BYTES, NOT BY A NAME. Whatever the ref, the newest approval
# per file on the ticket (or on the parent it was split from) must have a byte-identical
# file directly in the approved-pictures dir: a same-named mock with other bytes, or an
# approval never committed, is refused by its sha. A ticket with no approval passes as
# before. The comments are read on every call, so a gh read failure exits 1 even when
# the ref's file is here.
#
# Exit: 0 resolved or nothing to do · 3 the file is missing and no published copy
# could be used (none posted and no readable gist named, unreachable, or its sha256
# does not match) · 4 an
# approval binding the ticket has no byte-identical file in the approved-pictures dir ·
# 1 the ticket's comments could not be read · 2 bad arguments. The reason is on stderr.
#   PICTURE_FETCH_CURL  the downloader (default curl), for tests
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" || exit 1

die() { echo "picture-fetch: $2" >&2; exit "$1"; }
T="${1:-}"; REF="${2:-}"; TREE="${3:-}"
case "$T" in ''|*[!0-9]*) die 2 "usage: picture-fetch.sh <ticket> <ref> <tree>" ;; esac
[ -d "$TREE" ] || die 2 "'$TREE' is not a tree"
REPO="${GH_REPO:-$REPO_SLUG}"

# The picture path inside the ref: its first token that names a picture file and is
# not a URL. A ref with none (a URL, prose) has nothing on disk to look for.
tok=$(printf '%s\n' "$REF" | tr -s ' \t' '\n\n' | sed -e 's/^[`"(<]*//' -e 's/[`")>,;.:]*$//' \
  | grep -viE '^[a-z]+://' | grep -iE '\.(html?|png|jpe?g|svg|webp)$' | head -1)
fetch=0; path=""
g=$(toolkit_cfg review.judge.mockGlob 2>/dev/null) || g=""; [ -n "$g" ] || g=".design/*-mock.html"
dir=$(dirname "$g")
if [ -n "$tok" ]; then
  # A bare file name is a picture's name, not a place: it lives where approved pictures do.
  case "$tok" in
    "~/"*) path="$HOME/${tok#\~/}" ;;
    */*) path="$tok" ;;
    *-mock.html) path="$dir/$tok" ;;
    *.html|*.htm) path="$dir/${tok%.*}-mock.html" ;;
    *) path="$dir/$tok" ;;
  esac
  case "$path" in
    /*) [ -f "$path" ] || fetch=1 ;;
    *)  [ -f "$TREE/$path" ] || fetch=1 ;;
  esac
fi
sha_of() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1" 2>/dev/null; } | awk 'NR == 1 { print $1 }'; }

NAME=$(basename "${tok:-none}")
HEAD_LINE="**Picture for any machine**"
if [ "$fetch" -eq 1 ]; then why="the picture $tok is not on this machine, and #$T's comments could not be read to find its published copy"
else why="#$T's comments could not be read to check its approved pictures against $dir/"; fi
[ -n "$REPO" ] || die 1 "no repo: harness.json names none, so #$T's comments cannot be read"
comments=$(gh issue view "$T" --repo "$REPO" --json comments,body 2>/dev/null) \
  && jq -e '.comments | type == "array"' >/dev/null 2>&1 <<<"$comments" \
  || die 1 "$why"
# The approval is a COMMENT, never a body: text in a ticket's body proves nothing.
approval() { jq -r --arg h "$HEAD_LINE" --arg f "file=$NAME " '[.comments[] | .body // "" | select(startswith($h) and contains($f))] | last // empty' <<<"$1"; }
# approvals <json> — the newest approval per file, one "<sha> <file>" line each.
approvals() { jq -r --arg h "$HEAD_LINE" '[.comments[] | .body // "" | select(startswith($h))
  | capture("picture-approve: sha256=(?<s>[0-9a-f]{64}) file=(?<f>[^ ]+)")?]
  | reduce .[] as $a ({}; .[$a.f] = $a.s) | to_entries[] | "\(.value) \(.key)"' <<<"$1"; }
# A PART OF A SPLIT IS BOUND BY ITS PARENT'S APPROVAL, by link: its body says "split from
# #<parent>", and the parent's own comment is read and checked exactly as on the parent.
parent=$(jq -r '.body // ""' <<<"$comments" | grep -oiE 'split from #[0-9]+' | head -1 | grep -oE '[0-9]+')
[ "$parent" != "$T" ] || parent=""
pc=""
read_parent() { # <why> — the parent's comments, read once
  [ -z "$pc" ] || return 0
  pc=$(gh issue view "$parent" --repo "$REPO" --json comments,body 2>/dev/null) \
    && jq -e '.comments | type == "array"' >/dev/null 2>&1 <<<"$pc" \
    || die 1 "$1, and the comments of #$parent (#$T was split from it) could not be read"
}
bound=$(approvals "$comments"); BFROM="$T"
if [ -z "$bound" ] && [ -n "$parent" ]; then
  read_parent "#$T has no approved picture of its own"; bound=$(approvals "$pc"); BFROM="$parent"
fi

# check_present [<sha about to land in dir>] — each binding approval is byte-identical in dir.
check_present() {
  local held=() f s a want file mock
  for f in "$TREE/$dir"/*; do [ -f "$f" ] && held+=("$(sha_of "$f")"); done
  [ -z "${1:-}" ] || held+=("$1")
  while read -r want file; do
    [ -n "$want" ] || continue
    for a in ${held[@]+"${held[@]}"}; do [ "$a" = "$want" ] && continue 2; done
    case "$file" in *-mock.html) mock="$file" ;; *.html|*.htm) mock="${file%.*}-mock.html" ;; *) mock="$file" ;; esac
    s=""; for f in "$TREE/$dir/$file" "$TREE/$dir/$mock"; do [ -f "$f" ] && { s="$dir/${f##*/} is a different file (sha $(sha_of "$f" | cut -c1-12))"; break; }; done
    [ -n "$s" ] || s="nothing in $dir/ has that sha256; commit it byte-identical as $dir/$mock"
    die 4 "approved picture ${want:0:12} is not in $dir/ ($file, approved on #$BFROM): $s"
  done <<<"$bound"
}
[ "$fetch" -eq 1 ] || { check_present; printf '%s' "$REF"; exit 0; }

body=$(approval "$comments"); FROM="$T"
if [ -z "$body" ] && [ -n "$parent" ]; then
  read_parent "the picture $tok is not on this machine"
  body=$(approval "$pc"); [ -z "$body" ] || FROM="$parent"
fi
out=$(mktemp "${TMPDIR:-/tmp}/picture-fetch.XXXXXX") || die 3 "no temp file"
trap 'rm -f "$out"' EXIT

# gists_named <issue json> — the gist ids a body names as its approved picture: a gist link
# on a line that says "approved", or under a heading that does. Any other gist link is not one.
gists_named() {
  jq -r '.body // ""' <<<"$1" | awk '
    { l = tolower($0) }
    /^[[:space:]]*#+[[:space:]]/ { head = (l ~ /approved/) }
    head || l ~ /approved/ { print }' \
    | grep -oE 'https://gist\.github\.com/([A-Za-z0-9_-]+/)?[0-9a-f]{20,}' | sed 's|.*/||' | awk '!seen[$0]++'
}
# gist_read <id> — that gist's file named $NAME into $out: non-empty and HTML, or it is no picture.
gist_read() {
  perl -e 'alarm shift; exec @ARGV' 60 gh gist view "$1" --raw --filename "$NAME" > "$out" 2>/dev/null \
    && [ -s "$out" ] && grep -qiE '<(!doctype|html|head|title|body|style|meta|div)[ >]' "$out"
}
via=""
if [ -z "$body" ]; then
  miss="the picture $tok is not on this machine and #$T has no \"Picture for any machine\" comment naming $NAME${parent:+, nor has #$parent it was split from}"
  tried=""
  for src in "$T" $parent; do
    if [ "$src" = "$T" ]; then j="$comments"; else j="$pc"; fi
    for id in $(gists_named "$j"); do
      if gist_read "$id"; then via="$id"; FROM="$src"; break 2; fi
      tried="$tried${tried:+, }$id on #$src"
    done
  done
  if [ -z "$via" ]; then
    : > "$out"
    [ -z "$tried" ] || die 3 "$miss, and the gist named as the approved picture ($tried) gave no non-empty HTML file $NAME"
    die 3 "$miss, and ${parent:+neither body names}${parent:-its body names no} gist as the approved picture (scripts/picture-approve.sh publishes one)"
  fi
  have=$(sha_of "$out"); sha="$have"
else

sha=$(printf '%s\n' "$body" | sed -n 's/.*picture-approve: sha256=\([0-9a-f]\{64\}\) .*/\1/p' | head -1)
gid=$(printf '%s\n' "$body" | sed -n 's/.*picture-approve: .* gist=\([0-9A-Za-z]*\).*/\1/p' | head -1)
raw=$(printf '%s\n' "$body" | sed -n 's/^- Raw: \(https:[^ ]*\).*/\1/p' | head -1)
[ -n "$sha" ] || die 3 "#$T's \"Picture for any machine\" comment for $NAME carries no sha256, so a fetched copy could not be checked"

got=0
if [ -n "$raw" ] && "${PICTURE_FETCH_CURL:-curl}" -fsSL --max-time 60 "$raw" > "$out" 2>/dev/null && [ -s "$out" ]; then got=1; fi
if [ "$got" -eq 0 ] && [ -n "$gid" ] && gh gist view "$gid" --raw --filename "$NAME" > "$out" 2>/dev/null && [ -s "$out" ]; then got=1; fi
[ "$got" -eq 1 ] || die 3 "#$T's published copy of $NAME could not be fetched (raw ${raw:-none}, gist ${gid:-none})"
have=$(sha_of "$out")
[ "$have" = "$sha" ] || die 3 "#$T's published copy of $NAME does not match its sha256 (wanted ${sha:0:12}, fetched ${have:0:12}) — not the picture that was approved"
fi

case "$path" in
  /*) case "$NAME" in *-mock.html) dest="$dir/$NAME" ;; *.html|*.htm) dest="$dir/${NAME%.*}-mock.html" ;; *) dest="$dir/$NAME" ;; esac ;;
  *)  dest="$path" ;;
esac
# Checked before anything is written, counting the copy about to land in dir.
if [ "$(dirname "$dest")" = "$dir" ]; then check_present "$have"; else check_present; fi
mkdir -p "$TREE/$(dirname "$dest")" && cp "$out" "$TREE/$dest" || die 3 "could not write $dest in $TREE"
if [ -n "$via" ]; then
  echo "picture-fetch: $tok is not on this machine — read gist $via (sha256 ${sha:0:12}), which #$FROM's body names as the approved picture$([ "$FROM" = "$T" ] || echo ", the parent #$T was split from"), to $dest" >&2
  printf '%s' "$dest"; exit 0
fi
echo "picture-fetch: $tok is not on this machine — fetched #$FROM's published copy (sha256 ${sha:0:12})$([ "$FROM" = "$T" ] || echo ", the approval of #$FROM it was split from,") to $dest" >&2
printf '%s' "$dest"
