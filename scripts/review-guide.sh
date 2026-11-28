#!/usr/bin/env bash
# review-guide.sh — the area review guides that apply to a change.
#
#   review-guide.sh <repo-root>   reads changed paths (one a line, repo-relative) on stdin
#                                 and prints, once each, the nearest REVIEW.md above every
#                                 path, under a heading naming the files it covers.
#                                 Prints nothing when no changed path has a guide.
#
# A REVIEW.md says how to review the files under it: what failure looks like there,
# paths to skip, a nit cap, the evidence a finding needs (templates/REVIEW.md). The
# nearest one wins, the repo root's is the fallback, so an area overrides the whole.
# Bounded: REVIEW_GUIDE_MAX guides (default 8), REVIEW_GUIDE_BYTES each (default 4000).
set -uo pipefail
root="${1:?usage: review-guide.sh <repo-root> < changed-paths}"
max="${REVIEW_GUIDE_MAX:-8}" cap="${REVIEW_GUIDE_BYTES:-4000}"
case "$max" in ''|*[!0-9]*) max=8 ;; esac
case "$cap" in ''|*[!0-9]*) cap=4000 ;; esac

nearest() { # <path> — the repo-relative REVIEW.md nearest above it, or nothing
  local d="$1"
  while :; do
    case "$d" in */*) d="${d%/*}" ;; *) d="" ;; esac
    if [ -z "$d" ]; then [ -f "$root/REVIEW.md" ] && printf 'REVIEW.md'; return; fi
    [ -f "$root/$d/REVIEW.md" ] && { printf '%s/REVIEW.md' "$d"; return; }
  done
}

pairs=""
while IFS= read -r p; do
  p="${p#./}"; [ -n "$p" ] || continue
  case "$p" in /*|*..*) continue ;; esac
  g=$(nearest "$p"); [ -n "$g" ] || continue
  pairs="${pairs}${g}	${p}
"
done

[ -n "$pairs" ] || exit 0
guides=$(printf '%s' "$pairs" | cut -f1 | awk '!seen[$0]++')
n=0
while IFS= read -r g; do
  [ -n "$g" ] || continue
  n=$((n + 1))
  if [ "$n" -gt "$max" ]; then
    printf '(%s more guide(s) not shown: the change spans more than %s areas)\n' \
      "$(( $(printf '%s\n' "$guides" | grep -c .) - max ))" "$max"
    break
  fi
  files=$(printf '%s' "$pairs" | awk -F'\t' -v g="$g" '$1 == g { print $2 }')
  shown=$(printf '%s\n' "$files" | head -5 | paste -sd, - | sed 's/,/, /g')
  more=$(( $(printf '%s\n' "$files" | grep -c .) - 5 ))
  [ "$more" -le 0 ] || shown="$shown and $more more"
  printf '%s — for %s\n' "$g" "$shown"
  body=$(head -c "$cap" "$root/$g")
  printf '%s\n' "$body"
  [ "$(wc -c < "$root/$g")" -le "$cap" ] || printf '(cut at %s bytes)\n' "$cap"
  printf '\n'
done <<<"$guides"
