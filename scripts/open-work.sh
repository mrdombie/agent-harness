#!/usr/bin/env bash
# open-work.sh — sourced. What the coordinator's open-work count and repair-watch share
# about an open PR nothing may finish without a person.
#
#   open_work_person_drafted <pr> <updatedAt>
#       0  a person put it back to draft (person-stop.sh drafted; who and when on stdout)
#       1  not: the machine's draft, or never converted
#       2  could not be read
#
# One timeline read per draft per change: the verdict is kept against the PR's updatedAt
# (OPEN_WORK_DRAFTED_CACHE), so an unchanged draft is never asked twice. An unread
# verdict is never kept.
OPEN_WORK_DRAFTED_CACHE="${OPEN_WORK_DRAFTED_CACHE:-${SWARM_DIR:-${STATE_DIR:-/tmp}/swarm}/person-drafted.tsv}"

open_work_person_drafted() {
  local pr="${1:-}" at="${2:-}" hit out rc=0 cmd
  [ -n "$pr" ] || return 2
  hit=$(awk -F'\t' -v p="$pr" -v a="$at" '$1 == p && $2 == a { print $3 "\t" $4; exit }' "$OPEN_WORK_DRAFTED_CACHE" 2>/dev/null)
  if [ -n "$hit" ] && [ -n "$at" ]; then
    [ -z "${hit#*$'\t'}" ] || printf '%s\n' "${hit#*$'\t'}"
    return "${hit%%$'\t'*}"
  fi
  cmd="${OPEN_WORK_PERSON_STOP:-${KIT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/person-stop.sh}"
  out=$(bash "$cmd" drafted "$pr" 2>/dev/null) || rc=$?
  case "$rc" in 0|1) ;; *) return 2 ;; esac
  out=$(printf '%s' "$out" | head -1 | tr '\t' ' ')
  if [ -n "$at" ]; then
    mkdir -p "$(dirname "$OPEN_WORK_DRAFTED_CACHE")" 2>/dev/null
    { awk -F'\t' -v p="$pr" '$1 != p' "$OPEN_WORK_DRAFTED_CACHE" 2>/dev/null
      printf '%s\t%s\t%s\t%s\n' "$pr" "$at" "$rc" "$out"; } > "$OPEN_WORK_DRAFTED_CACHE.$$" \
      && mv -f "$OPEN_WORK_DRAFTED_CACHE.$$" "$OPEN_WORK_DRAFTED_CACHE"
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
  return "$rc"
}
