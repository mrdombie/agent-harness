#!/usr/bin/env bash
# flow-audit.sh — the briefs for the flow-coverage audit (skills/flows).
#
#   flow-audit.sh brief cartographer --job "<the screen's job, one line>"
#       prints the cartographer's whole prompt: the job line, then TAXONOMY.md.
#       Nothing from the repo is ever added — a model derived from the code
#       inherits the code's blind spots. A job line holding a path, a file name
#       or a URL is refused with exit 2, because it smuggles the code back in.
#
#   flow-audit.sh brief checker --rows <rows.md> --story <url> [--only <ids>]
#       prints the checker's prompt: the clickable Storybook story to drive,
#       every row line of the cartographer's file byte for byte, the five
#       verdicts and the rule that no row is added, merged or reworded. A story
#       URL without iframe.html?id= (a freehand HTML mock, the manager UI) is
#       refused, and so is a rows file holding no 'E-01'-shaped row. --only
#       'X-02,A-03' is the re-check after the redraw: just those rows, each of
#       which must be in the file.
#
#   flow-audit.sh gate <report.md>
#       holds the picture while the report has an open STRANDS or LIES gap. A
#       '### GAP-NN · STRANDS|LIES' section is closed only by a non-empty
#       '**Fixed:**' line AND every row its '**Rows:**' line names reading
#       PRESENT in the ledger — the re-check's verdict, not the builder's note.
#       A gap naming no row stays open. SILENT and ROUGH never hold it. A
#       report with no '| E-01 |' ledger row is void, never green.
#
#   flow-audit.sh story <surface>
#       prints the clickable story URL of the surface's picture, from the
#       project's design.pictureStory template ('<surface>' is replaced). A
#       project with no template, or one that is not an iframe.html?id= URL,
#       draws no clickable story: exit 2, and the picture parks rather than
#       skipping the audit.
#
#   flow-audit.sh report post <ticket> <report.md>
#   flow-audit.sh report get <ticket>
#       the report's one home: a ticket comment whose first line is
#       '## Flow audit report', the report below it unchanged. get prints the
#       newest one; exit 3 when the ticket has none, 1 when its comments cannot
#       be read (an unread list is not "no report"). The repo is GH_REPO, else
#       the project config's repo.
#
#   flow-audit.sh owed <label>...
#       exits 0 when one label (arguments, or comma lists) is one of
#       design.baselineRoute.pictureLabels — a new or redesigned screen, whose
#       picture pays for the two agents — and 1 for every other change.
#
# Exit: 0 printed or gate clear · 1 gate held or gh failed · 2 refused or bad usage · 3 void or no report.
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAXONOMY="$KIT/skills/flows/TAXONOMY.md"
ROW_RE='(^|[^A-Za-z0-9])[EAIDFRXC]-[0-9]{2}'

usage() {
  echo "usage: flow-audit.sh brief cartographer --job \"<one line>\"" >&2
  echo "       flow-audit.sh brief checker --rows <rows.md> --story <http(s)://.../iframe.html?id=...> [--only <ids>]" >&2
  echo "       flow-audit.sh gate <report.md>" >&2
  echo "       flow-audit.sh story <surface>" >&2
  echo "       flow-audit.sh report post <ticket> <report.md> | report get <ticket>" >&2
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
  local rows="" story="" only=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --rows)  [ $# -ge 2 ] || usage; rows=$2; shift 2 ;;
      --story) [ $# -ge 2 ] || usage; story=$2; shift 2 ;;
      --only)  [ $# -ge 2 ] || usage; only=$2; shift 2 ;;
      *) echo "flow-audit: the checker takes --rows, --story and --only only — refused: $1" >&2; exit 2 ;;
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
  if [ -n "$only" ]; then
    local id kept="" hit
    for id in $(printf '%s' "$only" | tr ',' ' '); do
      printf '%s' "$id" | grep -qE '^[EAIDFRXC]-[0-9]{2}$' || { echo "flow-audit: --only wants row ids like X-02 — got: $id" >&2; exit 2; }
      hit=$(printf '%s\n' "$lines" | grep -E "(^|[^A-Za-z0-9])$id([^0-9]|\$)")
      [ -n "$hit" ] || { echo "flow-audit: --only $id is no row in $rows" >&2; exit 2; }
      kept=$(printf '%s\n%s' "$kept" "$hit")
    done
    lines=$(printf '%s\n' "$lines" | grep -xF -f <(printf '%s\n' "$kept" | sed '/^$/d'))
  fi
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
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    # Pass 1: the ledger, row id -> verdict.
    NR == FNR {
      if ($0 ~ /^\|[[:space:]]*[EAIDFRXC]-[0-9][0-9][[:space:]]*\|/) {
        n = split($0, c, "|"); verdict[trim(c[2])] = trim(c[5])
      }
      next
    }
    function close_gap(   why, k, r) {
      if (id == "") return
      why = ""
      if (!fixed) why = "no **Fixed:** line"
      if (nrows == 0) why = why (why ? "; " : "") "names no row on a **Rows:** line"
      for (k = 1; k <= nrows; k++) {
        r = want[k]
        if (!(r in verdict)) why = why (why ? "; " : "") r " is not in the ledger"
        else if (verdict[r] != "PRESENT") why = why (why ? "; " : "") r " reads " verdict[r] ", not PRESENT"
      }
      if (why != "") print id " (" why ")"
      id = ""
    }
    /^#{2,3}[[:space:]]/ {
      close_gap()
      if ($0 ~ /^###[[:space:]]+GAP-[0-9]+[[:space:]]+·[[:space:]]+(STRANDS|LIES)([[:space:]]|$)/) {
        id = $2; fixed = 0; nrows = 0
      }
      next
    }
    id != "" && /^\*\*Fixed:\*\*[[:space:]]*[^[:space:]]/ { fixed = 1 }
    id != "" && /^\*\*Rows:\*\*/ {
      line = $0
      while (match(line, /[EAIDFRXC]-[0-9][0-9]/)) {
        want[++nrows] = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
      }
    }
    END { close_gap() }
  ' "$report" "$report")
  if [ -n "$open" ]; then
    echo "flow-audit: held — open STRANDS/LIES gap(s), each closed only by a **Fixed:** line and its rows re-checked PRESENT:" >&2
    printf '  %s\n' "$open" >&2
    exit 1
  fi
  echo "flow-audit: clear — no open STRANDS or LIES gap in $report"
}

story() {
  [ $# -eq 1 ] || usage
  local surface=$1 tpl url
  printf '%s' "$surface" | grep -qE '^[a-z0-9][a-z0-9-]*$' \
    || { echo "flow-audit: the surface is a slug (a-z, 0-9, -) — got: $surface" >&2; exit 2; }
  HARNESS_CFG="${HARNESS_CFG:-$(git rev-parse --show-toplevel 2>/dev/null)/.claude/harness.json}"
  tpl=$(jq -r '.design.pictureStory // empty' "$HARNESS_CFG" 2>/dev/null)
  url=${tpl//<surface>/$surface}
  case "$url" in
    http://*/iframe.html\?id=?* | https://*/iframe.html\?id=?*) printf '%s\n' "$url" ;;
    *) echo "flow-audit: no clickable story — park the picture: this project's design.pictureStory is '${tpl:-unset}', not an http(s)://.../iframe.html?id=...<surface>... template" >&2
       exit 2 ;;
  esac
}

REPORT_HEAD="## Flow audit report"

report_repo() {
  [ -n "${GH_REPO:-}" ] && { printf '%s' "$GH_REPO"; return 0; }
  ( . "$KIT/scripts/toolkit-env.sh" >/dev/null 2>&1 && printf '%s' "${REPO_SLUG:-}" )
}

report() {
  local verb=${1:-} t=${2:-} repo
  case "$t" in ''|*[!0-9]*) usage ;; esac
  case "$verb" in
    post) [ $# -eq 3 ] && [ -f "$3" ] || { echo "flow-audit: no report at ${3:-<none>}" >&2; exit 2; } ;;
    get)  [ $# -eq 2 ] || usage ;;
    *)    usage ;;
  esac
  repo=$(report_repo); [ -n "$repo" ] || { echo "flow-audit: no repo — set GH_REPO or the project config's repo" >&2; exit 2; }
  if [ "$verb" = post ]; then
    local body; body=$(mktemp) || exit 1
    { printf '%s\n\n' "$REPORT_HEAD"; cat "$3"; } > "$body"
    gh issue comment "$t" --repo "$repo" --body-file "$body" >/dev/null 2>&1 \
      || { rm -f "$body"; echo "flow-audit: the report comment on #$t was refused" >&2; exit 1; }
    rm -f "$body"; echo "flow-audit: report posted on #$t"
    return 0
  fi
  local comments last
  comments=$(gh issue view "$t" --repo "$repo" --json comments 2>/dev/null) \
    && jq -e '.comments | type == "array"' >/dev/null 2>&1 <<<"$comments" \
    || { echo "flow-audit: #$t's comments could not be read" >&2; exit 1; }
  last=$(jq -r --arg h "$REPORT_HEAD" '
    [.comments[] | .body // "" | select(startswith($h + "\n"))] | last // empty
    | ltrimstr($h + "\n") | ltrimstr("\n")' <<<"$comments")
  [ -n "$last" ] || { echo "flow-audit: #$t carries no '$REPORT_HEAD' comment" >&2; exit 3; }
  printf '%s\n' "$last"
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
if [ "$1" = story ]; then shift; story "$@"; exit $?; fi
if [ "$1" = report ]; then shift; report "$@"; exit $?; fi
[ $# -ge 2 ] || usage
case "$1 $2" in
  "brief cartographer") shift 2; brief_cartographer "$@" ;;
  "brief checker")      shift 2; brief_checker "$@" ;;
  *) usage ;;
esac
