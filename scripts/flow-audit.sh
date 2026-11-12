#!/usr/bin/env bash
# flow-audit.sh — the briefs for the flow-coverage audit (skills/flows).
#
#   flow-audit.sh brief cartographer --job "<the screen's job, one line>"
#       prints the cartographer's whole prompt: the job line, then TAXONOMY.md.
#       Nothing from the repo is ever added — a model derived from the code
#       inherits the code's blind spots. A job line holding a path, a file name
#       or a URL is refused with exit 2, because it smuggles the code back in.
#
#   flow-audit.sh brief checker --rows <rows.md> --story <url>
#       prints the checker's prompt: the clickable Storybook story to drive,
#       every row line of the cartographer's file byte for byte, the five
#       verdicts and the rule that no row is added, merged or reworded. A story
#       URL without iframe.html?id= (a freehand HTML mock, the manager UI) is
#       refused, and so is a rows file holding no 'E-01'-shaped row.
#
#   flow-audit.sh gate <report.md>
#       holds the picture while the report has an open STRANDS or LIES gap: a
#       '### GAP-NN · STRANDS|LIES' section with no non-empty '**Fixed:**' line.
#       SILENT and ROUGH never hold it. A report with no '| E-01 |' ledger row
#       is void, never green.
#
#   flow-audit.sh owed <label>...
#       exits 0 when one label (arguments, or comma lists) is one of
#       design.baselineRoute.pictureLabels — a new or redesigned screen, whose
#       picture pays for the two agents — and 1 for every other change.
#
# Exit: 0 printed or gate clear · 1 gate held · 2 refused or bad usage · 3 void report.
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAXONOMY="$KIT/skills/flows/TAXONOMY.md"
ROW_RE='(^|[^A-Za-z0-9])[EAIDFRXC]-[0-9]{2}'

usage() {
  echo "usage: flow-audit.sh brief cartographer --job \"<one line>\"" >&2
  echo "       flow-audit.sh brief checker --rows <rows.md> --story <http(s)://.../iframe.html?id=...>" >&2
  echo "       flow-audit.sh gate <report.md>" >&2
  echo "       flow-audit.sh owed <label>..." >&2
  exit 2
}

# The first token that points at code rather than at what a person is doing.
leak_in() {
  local w; set -f
  for w in $1; do
    case "$w" in
      *://* | www.*) printf '%s' "$w"; return 0 ;;
      */*)           printf '%s' "$w"; return 0 ;;
    esac
    if printf '%s' "$w" | grep -qE '[A-Za-z0-9_-]{2,}\.[A-Za-z][A-Za-z0-9]{0,5}[[:punct:]]*$'; then
      printf '%s' "$w"; return 0
    fi
  done
  return 1
}

brief_cartographer() {
  local job="" have=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --job) [ $# -ge 2 ] || usage; job=$2; have=1; shift 2 ;;
      *) echo "flow-audit: the cartographer takes the job line only — refused: $1" >&2; exit 2 ;;
    esac
  done
  [ "$have" -eq 1 ] && [ -n "${job// /}" ] || usage
  case "$job" in *$'\n'*) echo "flow-audit: the job is one line" >&2; exit 2 ;; esac
  local hit
  if hit=$(leak_in "$job"); then
    echo "flow-audit: the job line names code, not a job — refused: $hit" >&2
    exit 2
  fi
  [ -f "$TAXONOMY" ] || { echo "flow-audit: no taxonomy at $TAXONOMY" >&2; exit 2; }
  printf "The screen's job: %s\n\n" "$job"
  cat "$TAXONOMY"
}

brief_checker() {
  local rows="" story=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --rows)  [ $# -ge 2 ] || usage; rows=$2; shift 2 ;;
      --story) [ $# -ge 2 ] || usage; story=$2; shift 2 ;;
      *) echo "flow-audit: the checker takes --rows and --story only — refused: $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$rows" ] && [ -n "$story" ] || usage
  case "$story" in
    http://*/iframe.html\?id=?* | https://*/iframe.html\?id=?*) ;;
    *) echo "flow-audit: not a clickable story — want a Storybook http(s)://.../iframe.html?id=... URL, got: $story" >&2
       exit 2 ;;
  esac
  [ -f "$rows" ] || { echo "flow-audit: no rows file at $rows" >&2; exit 2; }
  local lines
  lines=$(grep -E "$ROW_RE" "$rows")
  [ -n "$lines" ] || { echo "flow-audit: $rows holds no row (want lines like 'E-01 · ...')" >&2; exit 2; }
  cat <<EOF
Drive this clickable picture in a browser: $story

Check each expected-flow row below against what the picture does when you click it.
Never add, merge, split, renumber or reword a row. Return every row id exactly once,
in this order, each with exactly one verdict and the clicks that showed it:

- PRESENT — a click path handles it; name the clicks.
- PARTIAL — handled on one branch and not the others; say which.
- WRONG — handled, but the behaviour contradicts what the screen states or promises.
- ABSENT — no click path handles it. The finding.
- UNVERIFIED — something for it is on screen, but no click you made reached it.

## Expected rows

EOF
  printf '%s\n' "$lines"
}

gate() {
  [ $# -eq 1 ] || usage
  local report=$1
  [ -f "$report" ] || { echo "flow-audit: no report at $report" >&2; exit 2; }
  if ! grep -qE '^\|[[:space:]]*[EAIDFRXC]-[0-9]{2}[[:space:]]*\|' "$report"; then
    echo "flow-audit: void — $report has no coverage row (want ledger rows like '| E-01 | ...')" >&2
    exit 3
  fi
  local open
  open=$(awk '
    function close_gap() { if (id != "" && !fixed) print id; id = "" }
    /^#{2,3}[[:space:]]/ {
      close_gap()
      if ($0 ~ /^###[[:space:]]+GAP-[0-9]+[[:space:]]+·[[:space:]]+(STRANDS|LIES)([[:space:]]|$)/) {
        id = $2; fixed = 0
      }
      next
    }
    id != "" && /^\*\*Fixed:\*\*[[:space:]]*[^[:space:]]/ { fixed = 1 }
    END { close_gap() }
  ' "$report")
  if [ -n "$open" ]; then
    echo "flow-audit: held — open STRANDS/LIES gap(s) with no **Fixed:** line: $(printf '%s' "$open" | tr '\n' ' ')" >&2
    exit 1
  fi
  echo "flow-audit: clear — no open STRANDS or LIES gap in $report"
}

owed() {
  HARNESS_CFG="${HARNESS_CFG:-$(git rev-parse --show-toplevel 2>/dev/null)/.claude/harness.json}"
  . "$KIT/driver/size-rules.sh" || exit 2
  # An absent config still has the default labels; jq on a missing file prints none.
  [ -r "$HARNESS_CFG" ] || HARNESS_CFG=<(printf '{}')
  local want l
  want=$(driver_picture_labels)
  for l in $(printf '%s\n' "$@" | tr ',' '\n'); do
    printf '%s\n' "$want" | grep -qxF -- "$l" && return 0
  done
  return 1
}

[ $# -ge 1 ] || usage
if [ "$1" = owed ]; then shift; owed "$@"; exit $?; fi
if [ "$1" = gate ]; then shift; gate "$@"; exit $?; fi
[ $# -ge 2 ] || usage
case "$1 $2" in
  "brief cartographer") shift 2; brief_cartographer "$@" ;;
  "brief checker")      shift 2; brief_checker "$@" ;;
  *) usage ;;
esac
