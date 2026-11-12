#!/usr/bin/env bash
# flow-audit.sh — the briefs for the flow-coverage audit (skills/flows).
#
#   flow-audit.sh brief cartographer --job "<the screen's job, one line>"
#       prints the cartographer's whole prompt: the job line, then TAXONOMY.md.
#       Nothing from the repo is ever added — a model derived from the code
#       inherits the code's blind spots. A job line holding a path, a file name
#       or a URL is refused with exit 2, because it smuggles the code back in.
#
# Exit: 0 printed · 2 refused or bad usage.
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAXONOMY="$KIT/skills/flows/TAXONOMY.md"

usage() { echo "usage: flow-audit.sh brief cartographer --job \"<one line>\"" >&2; exit 2; }

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

[ $# -ge 2 ] || usage
case "$1 $2" in
  "brief cartographer") shift 2; brief_cartographer "$@" ;;
  *) usage ;;
esac
