#!/usr/bin/env bash
# check-status-label-writes.sh — a ticket's status label is set only by
# scripts/issue-status.sh. Fails on any script or skill that adds a label to an
# issue (`issue edit … --add-label`, or a `gh api` labels write) unless the label
# is one this check knows is not a status. A status added beside the old one is
# how tickets came to wear ready, claimed, in-review and partial at once.
#
# Usage: check-status-label-writes.sh [root]   (default: this checkout)
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# Labels an issue edit may add directly: none of them is a status.
NOT_STATUS='^"?[$][{]?(HOLD_LABEL|LBL_OWNER_DECISION|LANE_LABEL|LABEL|COORD_SHEET_LABEL|LBL_POLISH_LIST|LBL_DESIGN)[}]?"?$'

files=$(cd "$ROOT" && git ls-files -co --exclude-standard -- '*.sh' '*.md' '*.py' '*.mjs' '*.js' 2>/dev/null \
  || find . -type f \( -name '*.sh' -o -name '*.md' -o -name '*.py' -o -name '*.mjs' -o -name '*.js' \) | sed 's|^\./||')
bad=0
while IFS= read -r f; do
  case "$f" in
    ''|reference/*|*/tests/*|*.test.sh|*.test.py|*.test.mjs|scripts/issue-status.sh|scripts/check-status-label-writes.sh) continue ;;
  esac
  [ -f "$ROOT/$f" ] || continue
  # Continuation lines joined, so a call split over `\` lines is read as one.
  out=$(awk -v F="$f" -v RE="$NOT_STATUS" '
    { line = (buf == "" ? $0 : buf " " $0); if (buf == "") start = NR }
    /\\[[:space:]]*$/ { sub(/\\[[:space:]]*$/, "", line); buf = line; next }
    { buf = ""
      if (line ~ /issue[[:space:]]+edit/ && line ~ /--add-label/) {
        n = split(line, w, /[[:space:]]+/)
        for (i = 1; i < n; i++) if (w[i] == "--add-label") {
          a = w[i+1]
          if (a ~ /status:/ || a !~ RE) { print F ":" start ": --add-label " a; break }
        }
      }
      if (line ~ /(^|[^a-z_])(gh|gh_call|swarm_gh)[[:space:]]+api/ && line ~ /(\/labels|labels\[\]=|-[fF][[:space:]]+"?labels)/ && (line ~ /status:/ || line ~ /[$][{]?(LBL_|STATUS_PREFIX|want)/))
        print F ":" start ": gh api labels write"
    }' "$ROOT/$f")
  [ -z "$out" ] || { printf '%s\n' "$out"; bad=1; }
done <<<"$files"

if [ "$bad" -ne 0 ]; then
  echo "check-status-label-writes: the lines above add a label to an issue without issue-status.sh." >&2
  echo "  A status goes on with issue_status_set <n> <status> (or bash scripts/issue-status.sh set …), which removes the old one;" >&2
  echo "  a decision marker with issue_status_mark. A label that is not a status belongs in NOT_STATUS here." >&2
  exit 1
fi
echo "check-status-label-writes: every status label is set through issue-status.sh"
