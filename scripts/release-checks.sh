#!/usr/bin/env bash
# release-checks.sh — the ONE switch for checks that report but do not block until a
# project's release. Sourced (toolkit-env.sh does it); every reader of a red asks here.
#
#   harness.json:  "release": { "nonBlockingChecks": ["Design critic", "..."], "done": false }
#
# While release.done is not true, a red in a listed check is a WARNING: noted in the log
# and once per head on the pull request, never a repair, a park, a fix round, a heal-all
# count or a wait. The check still runs and reports. release.done true, an empty list or
# no key: every check is what it was. A name matches a rollup entry's name, its context
# (a commit status), or "<workflow> / <job>", ignoring case.
#
#   release_nonblocking_json          → JSON array of the listed names, lowercased; [] when off
#   release_check_nonblocking <name>  → 0 when that check is listed and the switch is on
#   RELEASE_NB_JQ                     → jq defs: `release_nb($nb)` on a rollup entry is true
#                                       when it is listed; `release_red` when it settled red
#   release_blocking_required <json>  → gates.requiredChecks less the listed checks
#   release_warn_reds <rollup-json>   → the listed checks whose newest run is red, ", "-joined
#   release_warn_pr <pr> <head> <names> <log-fn> — the warning, logged and commented once per head

RELEASE_NB_JQ='def release_nb($nb): ((.name // .context // "") | ascii_downcase) as $n
  | (((.workflowName // "") + " / " + (.name // "")) | ascii_downcase) as $w
  | any($nb[]; . == $n or . == $w);
def release_red: (.conclusion // .state // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE");'

release_nonblocking_json() {
  local cfg="${HARNESS_CFG:-}" out
  if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then printf '[]'; return 0; fi
  out=$(jq -c 'if ((.release // {}) | type) != "object" or (.release.done // false) == true then []
               else [(.release.nonBlockingChecks // [])[]? | strings | ascii_downcase | select(. != "")] end' "$cfg" 2>/dev/null)
  printf '%s' "${out:-[]}"
}

release_check_nonblocking() { # <check name>
  [ -n "${1:-}" ] || return 1
  jq -e -n --argjson nb "$(release_nonblocking_json)" --arg n "$1" 'any($nb[]; . == ($n | ascii_downcase))' >/dev/null 2>&1
}

# release_blocking_required <required-checks json array> — the list less the listed checks.
release_blocking_required() {
  printf '%s' "${1:-[]}" | jq -c --argjson nb "$(release_nonblocking_json)" \
    'if type == "array" then map(select(type != "string" or ((ascii_downcase) as $r | any($nb[]; . == $r) | not))) else . end' 2>/dev/null \
    || printf '%s' "${1:-[]}"
}

release_warn_reds() { # <rollup json array>
  printf '%s' "${1:-[]}" | jq -r --argjson nb "$(release_nonblocking_json)" "$RELEASE_NB_JQ"'
    [ [.[]?] | group_by(.name // .context // "?") | map(max_by(.startedAt // .createdAt // "")) | .[]
      | select(release_nb($nb)) | select(release_red) | (.name // .context // "?") ] | unique | join(", ")' 2>/dev/null
}

# release_warn_pr <pr> <head> <names> <log-fn> — once per pull request, head and set of
# names: a line through <log-fn>, and a comment on the pull request. RELEASE_WARN_DRY=1
# says what it would post and records nothing.
release_warn_pr() {
  local pr="$1" head="$2" names="$3" logf="${4:-echo}" ledger key body
  [ -n "$pr" ] && [ -n "$names" ] || return 0
  ledger="${RELEASE_WARN_LEDGER:-${STATE_DIR:-${TMPDIR:-/tmp}}/swarm/release-warnings.tsv}"
  key="$pr	$head	$names"
  grep -qxF -- "$key" "$ledger" 2>/dev/null && return 0
  "$logf" "warning, not blocking: PR #$pr is red on $names at ${head:0:9} — listed in release.nonBlockingChecks, so no repair, park or heal count"
  [ "${RELEASE_WARN_DRY:-0}" = 1 ] && return 0
  body="**Warning, not blocking:** $names failed on \`${head:0:9}\`. Until the release these checks report but do not block (\`release.nonBlockingChecks\` in harness.json): nothing is sent to repair them, and they do not count this pull request as red. Read the check for what it found."
  local ghf=gh; type swarm_gh >/dev/null 2>&1 && ghf=swarm_gh
  if "$ghf" api "repos/${REPO_SLUG:?}/issues/$pr/comments" -X POST -f body="$body" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$ledger")" 2>/dev/null
    printf '%s\n' "$key" >> "$ledger"
  fi
  return 0
}
