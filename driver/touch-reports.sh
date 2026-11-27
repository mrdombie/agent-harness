#!/usr/bin/env bash
# touch-reports.sh — a report a project wants on every build that touches some of its
# paths, run by the driver on the builder's machine and plan, never by CI, and never
# blocking. Its results file is committed with the change, so review reads it and the
# pull request names its reds.
#
#   driver_touch_reports <ticket> <tree>    after the gates pass (steps/self-check.sh)
#   driver_touch_reports_section <ticket>   the "## Reports" body section (steps/ship.sh)
#
# The project names each report in harness.json; the kit names none:
#
#   "reports": { "onTouch": [ {
#     "name":        "Holly replay",
#     "paths":       ["apps/api/src/lib/agent/", …],   path prefixes; any changed file under one runs it
#     "run":         "npm run eval:holly-real",         run from the tree's root
#     "results":     "docs/evidence/{ticket}/x.json",   committed when the run writes it
#     "summary":     "<jq over the results file>",      lines for the pull request
#     "timeoutSecs": 3600,                              default 3600
#     "maxRuns":     2                                  per build, default 2
#   } ] }
#
# WHY IT NEVER BLOCKS. A report that has not yet been stable for a week is a measurement,
# not a gate (the owner, 2026-11-27): a red is named on the pull request and to the PM,
# and the build goes on. Exit code, timeout and a missing results file are all reported,
# never returned.
#
# WHY ONCE PER HEAD OF ITS PATHS. A run can cost hundreds of model calls (Maktura's replay
# set: 211 calls, 29 minutes). A fix round that leaves those paths unchanged runs nothing
# again; one that changes them runs again, up to maxRuns per build.

[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh" || exit 1

# _driver_touch_rows — one compact JSON object per configured report.
_driver_touch_rows() {
  jq -c '(.reports.onTouch // []) | if type == "array" then .[] | select(type == "object") else empty end' \
    "${HARNESS_CFG:-/dev/null}" 2>/dev/null
}

# _driver_touch_safe <name> — the report's name as a file and state key. Underscores, never
# hyphens: driver_state_get reads a key with a hyphen as a jq subtraction and answers empty,
# so a report keyed "holly-replay" never found its own last run and ran on every pass.
_driver_touch_safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_' | tr 'A-Z' 'a-z' | sed 's/__*/_/g; s/^_//; s/_$//'; }

# _driver_touch_base <tree> — where the branch left the trunk.
_driver_touch_base() {
  git -C "$1" merge-base "origin/$INTEGRATION_BRANCH" HEAD 2>/dev/null \
    || git -C "$1" merge-base "$INTEGRATION_BRANCH" HEAD 2>/dev/null
}

# _driver_touch_hit <tree> <base> <prefix…> — 0 when a file the branch changed starts
# with one of the prefixes.
_driver_touch_hit() {
  local wt="$1" base="$2" f p; shift 2
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for p in "$@"; do case "$f" in "$p"*) return 0 ;; esac; done
  done <<EOF
$(git -C "$wt" diff --name-only "$base" HEAD 2>/dev/null)
EOF
  return 1
}

# _driver_touch_fp <tree> <prefix…> — a hash of every blob under the prefixes at HEAD.
# Committing the results file leaves it standing, because the results live elsewhere.
_driver_touch_fp() {
  local wt="$1" p; shift
  for p in "$@"; do git -C "$wt" ls-tree -r HEAD 2>/dev/null | awk -F'\t' -v p="$p" 'index($2, p) == 1'; done \
    | shasum | cut -c1-12
}

driver_touch_reports() { # <ticket> <tree>
  local t="$1" wt="$2" row name safe cmd results summary secs maxr base fp runs rc out md lines
  local -a paths
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    name=$(jq -r '.name // ""' <<<"$row"); cmd=$(jq -r '.run // ""' <<<"$row")
    [ -n "$name" ] || name="report"
    safe=$(_driver_touch_safe "$name")
    paths=()
    while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done < <(jq -r '(.paths // [])[]? | strings' <<<"$row")
    if [ -z "$cmd" ] || [ "${#paths[@]}" -eq 0 ]; then
      driver_say "⚠ report: harness.json reports.onTouch '$name' names no run command or no paths, so it never runs"
      continue
    fi
    base=$(_driver_touch_base "$wt")
    [ -n "$base" ] || { driver_say "⚠ report: $name — no merge base with $INTEGRATION_BRANCH, so what the branch touched is unknown; not run"; continue; }
    _driver_touch_hit "$wt" "$base" "${paths[@]}" || continue
    fp=$(_driver_touch_fp "$wt" "${paths[@]}")
    if [ "$(driver_state_get "$t" "touch_${safe}_fp")" = "$fp" ]; then
      driver_say "   report: $name — already run on this head of its paths ($fp)"
      continue
    fi
    maxr=$(jq -r '.maxRuns // 2' <<<"$row"); case "$maxr" in ''|*[!0-9]*) maxr=2 ;; esac
    runs=$(driver_state_count "$t" "touch_${safe}")
    if [ "${runs:-0}" -ge "$maxr" ]; then
      driver_say "   report: $name — $maxr run(s) are used on this build; not run again on $fp"
      continue
    fi
    secs=$(jq -r '.timeoutSecs // 3600' <<<"$row"); case "$secs" in ''|*[!0-9]*) secs=3600 ;; esac
    results=$(jq -r '.results // ""' <<<"$row"); results=${results//\{ticket\}/$t}
    summary=$(jq -r '.summary // ""' <<<"$row")
    out="$(driver_state_dir "$t")/steps/report-$safe.out"; mkdir -p "$(dirname "$out")"
    md="$(driver_state_dir "$t")/steps/report-$safe.md"
    driver_state_bump "$t" "touch_${safe}"
    driver_say "   report: $name — the branch touches its paths, running \`$cmd\` (not blocking, up to ${secs}s)"
    rc=0; ( cd "$wt" && driver_run_project "$secs" "$cmd" ) > "$out" 2>&1 || rc=$?
    driver_state_set "$t" "touch_${safe}_fp" "$fp"
    lines=""
    if [ -n "$results" ] && [ -f "$wt/$results" ]; then
      [ -z "$summary" ] || lines=$(jq -r "$summary" "$wt/$results" 2>/dev/null | head -40)
      git -C "$wt" add -f -- "$results" 2>/dev/null
      if ! git -C "$wt" diff --cached --quiet -- "$results" 2>/dev/null; then
        git -C "$wt" commit -q -m "chore(#$t): $name report" \
          -m "no-changelog: a report the driver ran on this build, not a change" -- "$results" >/dev/null 2>&1 \
          || driver_say "⚠ report: $name — the results file could not be committed; it stays in $wt/$results"
      fi
    fi
    {
      printf -- '- **%s**: `%s` exit %s on paths head %s' "$name" "$cmd" "$rc" "$fp"
      [ -n "$results" ] && { [ -f "$wt/$results" ] && printf '; results `%s`' "$results" || printf '; wrote no results file (`%s`)' "$results"; }
      printf '\n'
      [ -z "$lines" ] || printf '%s\n' "$lines" | sed 's/^/  - /'
      [ -n "$lines" ] || [ "$rc" -eq 0 ] || tail -5 "$out" | cut -c1-200 | sed 's/^/  > /'
    } > "$md"
    driver_say "   report: $name — exit $rc$( [ -z "$lines" ] || printf '; %s' "$(printf '%s\n' "$lines" | head -1)" ) (not blocking)"
  done <<EOF
$(_driver_touch_rows)
EOF
  return 0
}

# driver_touch_reports_section <ticket> — the body section, or nothing when no report ran.
driver_touch_reports_section() {
  local d f any=""; d="$(driver_state_dir "$1")/steps"
  for f in "$d"/report-*.md; do [ -s "$f" ] && any=1; done
  [ -n "$any" ] || return 0
  printf '## Reports (not blocking)\nRun by the driver on the builder, because this change touches their paths. A red here is a measurement; it never blocks the merge.\n'
  cat "$d"/report-*.md 2>/dev/null
}
