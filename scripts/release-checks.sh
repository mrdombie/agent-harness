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
#   CHECK_NEWEST_JQ                   → jq def `newest_runs`: each check's newest run only
#   RELEASE_NB_JQ                     → CHECK_NEWEST_JQ, and jq defs: `release_nb($nb)` on a rollup entry is true
#                                       when it is listed; `release_red` when it settled red
#   release_blocking_required <json>  → gates.requiredChecks less the listed checks
#   release_warn_reds <rollup-json>   → the listed checks whose newest run is red, ", "-joined
#   release_warn_pr <pr> <head> <names> <log-fn> — the warning, logged and commented once per head
#   release_merge_first               → 0 while release.mergeFirst is true and release.done is not
#
# MERGE FIRST, FIX AFTER (the owner, 2026-10-22): "release": {"mergeFirst": true} is the one
# switch for every gate that holds a change for a person or a picture until the release.
# While it is on: no step adds the hold label; the review blocks on a Critical only, and
# every Major and Minor becomes a follow-up ticket at the front of the queue (a Minor on a
# screen goes on its polish list); only a screen:new or screen:redesign ticket owes a
# picture; nothing waits for CI's shots or picture parity; and the design critic and the
# picture check warn like a listed check. Real gates (typecheck, lint, tests) still block.
# Off, or release.done true: every gate is what it was.

# CHECK_NEWEST_JQ — `newest_runs` on a rollup array: one entry per check, its NEWEST run.
# A re-run sits beside the run it replaced, so reading every run counts a cleared red.
# A run still going is newest; then the latest finish (start, for a commit status).
CHECK_NEWEST_JQ='def newest_runs: [ .[]? | select(type == "object") ]
  | group_by((.workflowName // "") + "\u0000" + (.name // .context // "?"))
  | map(max_by([ (if ((.status // "COMPLETED") != "COMPLETED") or ((.state // "") | test("PENDING|EXPECTED")) then 1 else 0 end),
                 ([.completedAt, .startedAt, .createdAt] | map(select(type == "string" and . != "" and (startswith("0001-") | not))) | first // "") ]));'

RELEASE_NB_JQ="$CHECK_NEWEST_JQ"'def release_nb($nb): ((.name // .context // "") | ascii_downcase) as $n
  | (((.workflowName // "") + " / " + (.name // "")) | ascii_downcase) as $w
  | any($nb[]; . == $n or . == $w);
def release_red: (.conclusion // .state // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE");'

# _release_cfg — the file the release block is read from: the trunk's harness.json as
# origin has it now, when that carries a release block; else the run's own config.
# A run snapshots its config when it starts and a coordinator pins a copy, so a switch
# flipped on the trunk mid-run reached neither: a repair begun before mergeFirst landed
# still parked a signed-off screen's Major for the owner. The trunk ref is fetched at
# most every HARNESS_RELEASE_FETCH_SECS (default 120) per clone.
_release_cfg() {
  local repo="${MAIN_REPO:-}" br="${INTEGRATION_BRANCH:-}" blob f stamp now was
  if [ -n "$repo" ] && [ -n "$br" ] && git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    stamp="${TMPDIR:-/tmp}"; stamp="${stamp%/}/harness-release-fetch.$(printf '%s' "$repo:$br" | cksum | cut -d' ' -f1)"
    now=$(date +%s); was=$(stat -c %Y "$stamp" 2>/dev/null || stat -f %m "$stamp" 2>/dev/null || echo 0)
    if [ $((now - was)) -ge "${HARNESS_RELEASE_FETCH_SECS:-120}" ]; then
      : > "$stamp" 2>/dev/null
      GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5}" \
        git -C "$repo" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 fetch -q origin "+refs/heads/$br:refs/remotes/origin/$br" >/dev/null 2>&1 || true
    fi
    blob=$(git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$br:.claude/harness.json" 2>/dev/null)
    if [ -n "$blob" ]; then
      f="${TMPDIR:-/tmp}"; f="${f%/}/harness.json.$(printf '%.12s' "$blob")"
      [ -s "$f" ] || { git -C "$repo" cat-file blob "$blob" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f"; } || rm -f "$f.$$"
      if [ -s "$f" ] && jq -e '(.release // null) | type == "object"' "$f" >/dev/null 2>&1; then printf '%s' "$f"; return 0; fi
    fi
  fi
  printf '%s' "${HARNESS_CFG:-}"
}

release_nonblocking_json() {
  local cfg out; cfg=$(_release_cfg)
  if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then printf '[]'; return 0; fi
  # Merge first adds the design checks: the critic's status and the picture check warn.
  out=$(jq -c 'if ((.release // {}) | type) != "object" or (.release.done // false) == true then []
               else [ (.release.nonBlockingChecks // [])[]?,
                      (if .release.mergeFirst == true
                       then ((.review.judge.context // "Design critic"), (.evidence.gapChecks // ["Approved picture"])[]?)
                       else empty end)
                    | strings | ascii_downcase | select(. != "")]
                  | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end) end' "$cfg" 2>/dev/null)
  printf '%s' "${out:-[]}"
}

# release_merge_first — 0 while harness.json says release.mergeFirst true and the release
# is not done. A missing or unreadable config is off: every gate stays.
release_merge_first() {
  local cfg; cfg=$(_release_cfg)
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 1
  jq -e '(.release // {}) | type == "object" and .mergeFirst == true and (.done // false) != true' "$cfg" >/dev/null 2>&1
}

# THE DESIGN CRITIC IS OFF UNTIL THE RELEASE (the owner, 2026-10-22: "anything after
# release … turn it off"). While its check (review.judge.context) is listed here and the
# release is not done, nothing calls the critic model, files its findings, hands them
# to a step or asks about them: the sweep, a judge run, the driver's facts, fix and
# review lists, the healing brief and the owner channel all ask this one predicate,
# read live (_release_cfg). review.judge.duringRelease true keeps it running.
#   release_critic_paused  → 0 while it is off
#   RELEASE_CRITIC_ID_RE   → a finding id that is the critic's ("critic-…"), any case
RELEASE_CRITIC_OFF="design critic: off until the release"
RELEASE_CRITIC_ID_RE='^critic[-_:]'
release_critic_paused() {
  local cfg ctx f
  cfg=$(_release_cfg)
  for f in "$cfg" "${HARNESS_CFG:-}"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    [ "$(jq -r '.review.judge.duringRelease // false' "$f" 2>/dev/null)" = true ] && return 1
  done
  ctx=$(jq -r '.review.judge.context // empty' "${HARNESS_CFG:-/dev/null}" 2>/dev/null)
  release_check_nonblocking "${ctx:-Design critic}"
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
    [ newest_runs | .[]
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
