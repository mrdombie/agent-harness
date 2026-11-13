#!/usr/bin/env bash
# review-guide.sh — the area review guides that apply to a change.
#
#   review-guide.sh <repo-root> [<ref>]
#                                 reads changed paths (one a line, repo-relative) on stdin
#                                 and prints, once each, the nearest REVIEW.md above every
#                                 path, under a heading naming the files it covers.
#                                 Prints nothing when no changed path has a guide.
#                                 With <ref>, every guide is read from that commit (the
#                                 trunk), never the working tree: a change may not write
#                                 the guide it is reviewed by. A changed REVIEW.md is named.
#
# The nearest REVIEW.md wins; the repo root's is the fallback (templates/REVIEW.md).
# Bounded: REVIEW_GUIDE_MAX guides (default 8), REVIEW_GUIDE_BYTES each (default 4000).
set -uo pipefail
root="${1:?usage: review-guide.sh <repo-root> [<ref>] < changed-paths}"
ref="${2:-}"
max="${REVIEW_GUIDE_MAX:-8}" cap="${REVIEW_GUIDE_BYTES:-4000}"
case "$max" in ''|*[!0-9]*) max=8 ;; esac
case "$cap" in ''|*[!0-9]*) cap=4000 ;; esac

has_guide() { # <repo-relative REVIEW.md>
  if [ -n "$ref" ]; then git -C "$root" cat-file -e "$ref:$1" 2>/dev/null; else [ -f "$root/$1" ]; fi
}
read_guide() { # <repo-relative REVIEW.md>
  if [ -n "$ref" ]; then git -C "$root" show "$ref:$1" 2>/dev/null; else cat "$root/$1"; fi
}

nearest() { # <path> — the repo-relative REVIEW.md nearest above it, or nothing
  local d="$1"
  while :; do
    case "$d" in */*) d="${d%/*}" ;; *) d="" ;; esac
    if [ -z "$d" ]; then has_guide REVIEW.md && printf 'REVIEW.md'; return; fi
    has_guide "$d/REVIEW.md" && { printf '%s/REVIEW.md' "$d"; return; }
  done
}

# bash 3.2: no associative arrays, so "guide<TAB>path" lines grouped with awk.
pairs="" edits=""
while IFS= read -r p; do
  p="${p#./}"; [ -n "$p" ] || continue
  # A '..' segment or an absolute path would read outside the repo.
  case "$p" in /*|..|../*|*/..|*/../*) continue ;; esac
  case "$p" in REVIEW.md|*/REVIEW.md) [ -z "$ref" ] || edits="${edits}${p}
" ;; esac
  g=$(nearest "$p"); [ -n "$g" ] || continue
  pairs="${pairs}${g}	${p}
"
done

while IFS= read -r e; do
  [ -n "$e" ] || continue
  printf '(this change edits its own guide %s; the %s version applies, not the change'"'"'s)\n' "$e" "$ref"
done <<<"$edits"
[ -n "$edits" ] && [ -n "$pairs" ] && printf '\n'
[ -n "$pairs" ] || exit 0
guides=$(printf '%s' "$pairs" | cut -f1 | awk '!seen[$0]++')
total=$(printf '%s\n' "$guides" | grep -c .)
n=0
while IFS= read -r g; do
  [ -n "$g" ] || continue
  n=$((n + 1))
  if [ "$n" -gt "$max" ]; then
    printf '(%s more guide(s) not shown: the change spans more than %s areas)\n' "$((total - max))" "$max"
    break
  fi
  files=$(printf '%s' "$pairs" | awk -F'\t' -v g="$g" '$1 == g { print $2 }')
  shown=$(printf '%s\n' "$files" | head -5 | paste -sd, - | sed 's/,/, /g')
  more=$(( $(printf '%s\n' "$files" | grep -c .) - 5 ))
  [ "$more" -le 0 ] || shown="$shown and $more more"
  printf '%s — for %s\n' "$g" "$shown"
  body=$(read_guide "$g")
  printf '%s\n' "$(printf '%s' "$body" | head -c "$cap")"
  [ "$(printf '%s' "$body" | wc -c)" -le "$cap" ] || printf '(cut at %s bytes)\n' "$cap"
  printf '\n'
done <<<"$guides"
