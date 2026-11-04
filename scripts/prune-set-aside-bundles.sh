#!/usr/bin/env bash
# prune-set-aside-bundles.sh — the rebuild set-aside's local bundles, kept only while
# they can matter: the newest per ticket, and none once the ticket is closed.
#
#   prune-set-aside-bundles.sh [--dry-run] [--offline]
#
# driver_rebuild_set_aside (driver/build-ticket) writes <driver>/<ticket>.local-<epoch>.bundle
# when the set-aside push to origin fails. Nothing removed them, and a rebuild loop wrote
# one a run: 149 of about 1.7 GB each filled 238 GB on one Mac (2026-11-04). A newer
# bundle holds the ticket's later work, so the older ones go; a closed ticket is never
# built again, so all of its go. --offline skips the one GitHub read and prunes only the
# older copies. The first line is the count, then one line a file.
# Exit: 0 done · 1 the tickets' states could not be read (older copies still pruned).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 1
declare -F gh_issues_batch >/dev/null 2>&1 || . "$SELF_DIR/gh-batch.sh" || exit 1
DRY=0; OFFLINE=0
for a in "$@"; do
  case "$a" in --dry-run) DRY=1 ;; --offline) OFFLINE=1 ;; *) echo "usage: $0 [--dry-run] [--offline]" >&2; exit 2 ;; esac
done
D="${DRIVER_DIR:-$STATE_DIR/driver}"
[ -d "$D" ] || exit 0

# GNU first: on Linux `stat -f` is file-system status and "succeeds" with junk; BSD stat has no -c.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
# "<ticket>\t<mtime>\t<file>", newest first within a ticket.
rows=""
for f in "$D"/*.local-*.bundle; do
  [ -f "$f" ] || continue
  t=$(basename "$f"); t="${t%%.local-*}"
  case "$t" in ''|*[!0-9]*) continue ;; esac
  rows+="$t"$'\t'"$(mtime "$f")"$'\t'"$f"$'\n'
done
[ -n "$rows" ] || exit 0
rows=$(printf '%s' "$rows" | sort -t$'\t' -k1,1n -k2,2nr)

rc=0; states='{}'
if [ "$OFFLINE" = 0 ]; then
  # shellcheck disable=SC2046  # a list of numbers, split on purpose
  states=$(gh_issues_batch $(printf '%s\n' "$rows" | cut -f1 | sort -un) 2>/dev/null) \
    && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$states" \
    || { states='{}'; rc=1; }
fi

out=""; n=0; bytes=0; prev=""
while IFS=$'\t' read -r t _m f; do
  [ -n "$t" ] || continue
  why=""
  [ "$(jq -r --arg t "$t" '.[$t].state // ""' <<<"$states")" = CLOSED ] && why="#$t is closed"
  [ -z "$why" ] && [ "$t" = "$prev" ] && why="a newer bundle for #$t is kept"
  prev="$t"
  [ -n "$why" ] || continue
  n=$((n + 1)); bytes=$((bytes + $(wc -c < "$f" | tr -d ' ')))
  if [ "$DRY" = 1 ]; then out+="would remove $f — $why"$'\n'
  elif rm -f "$f"; then out+="removed $f — $why"$'\n'
  else out+="could not remove $f"$'\n'; fi
done <<< "$rows"
[ "$n" -gt 0 ] || { [ "$rc" = 0 ] || echo "set-aside bundles: the tickets' states could not be read; only older copies were pruned"; exit "$rc"; }
printf 'set-aside bundles: %s %d file(s), %d MB\n' "$([ "$DRY" = 1 ] && echo 'would remove' || echo removed)" "$n" $((bytes / 1048576))
printf '%s' "$out"
[ "$rc" = 0 ] || echo "set-aside bundles: the tickets' states could not be read; only older copies were pruned"
exit "$rc"
