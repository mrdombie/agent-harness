#!/usr/bin/env bash
# base-red.sh — a pre-push check red on the trunk commit a branch merged is the trunk's
# to fix, never the branch's. Sourced by steps/ship.sh after driver-env.sh.
#
# Measured 2026-10-23: a merge-first merge left the trunk red on a pre-push check four
# times in one night, and every builder that merged it was refused at the push and
# parked with a question until a person fixed the trunk by hand. So a refused push asks
# one more thing before it counts: are the same checks red on the commit it merged?
#
#   driver_base_red_checks <push-output>       the checks a refused pre-push named, one a line
#   driver_base_red_sha <tree>                 the trunk commit the branch merged (its merge-base)
#   driver_base_check <tree> <sha> <check>     red | green | unknown — run once per (check, sha)
#                                              on the host, in a scratch tree at <sha>, and
#                                              cached for every builder in base-checks.tsv
#   driver_base_red_note <ticket> <sha> <checks> [pr]   a row for the coordinator, which files
#                                              ONE "trunk is red" ticket (scripts/develop-red.sh)
#
# READ, NEVER ASSUMED. A check is base-red only when it ran on the base commit and failed.
# One that could not be set up, could not be found (126/127) or timed out is unknown, and
# an unknown red is the branch's, as before. A scratch tree set up wrongly reads every
# check red, so a failed install link or prepare makes every check unknown, never red.
#
#   base-checks.tsv  <sha> \t <check> \t red|green \t <epoch> \t <exit>
#   develop-red.tsv  <sha> \t <checks, sorted, comma-joined> \t <ticket> \t <pr> \t <epoch>

BASE_CHECKS="${BASE_CHECKS_FILE:-${STATE_DIR:-${TMPDIR:-/tmp}}/swarm/base-checks.tsv}"
DEVELOP_RED="${DEVELOP_RED_FILE:-${STATE_DIR:-${TMPDIR:-/tmp}}/swarm/develop-red.tsv}"
BASE_CHECK_WAIT_SECS="${BASE_CHECK_WAIT_SECS:-1800}"

driver_base_red_checks() {
  local f="$1" line
  [ -f "$f" ] || return 0
  # The suite's own summary, "N of M failed: a, b", names every check; one per ✗ line otherwise.
  line=$(grep -E '[0-9]+ of [0-9]+ failed: ' "$f" 2>/dev/null | tail -1)
  if [ -n "$line" ]; then
    printf '%s\n' "${line##*failed: }" | tr ',' '\n'
  else
    grep -E '^[[:space:]]*✗ [A-Za-z][A-Za-z0-9:_./-]*([[:space:]]|$)' "$f" 2>/dev/null | grep -v ' failed: ' \
      | sed -E 's/^[[:space:]]*✗ ([^[:space:]]+).*/\1/'
  fi | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -E '^[A-Za-z0-9][A-Za-z0-9:_./-]*$' | awk '!seen[$0]++'
}

driver_base_red_sha() {
  local s
  s=$(git -C "$1" merge-base HEAD "origin/$INTEGRATION_BRANCH" 2>/dev/null) && [ -n "$s" ] || return 1
  printf '%s' "$s"
}

# _driver_base_check_cmd <tree> <check> — the command that runs one check: harness.json's
# gates.checkCommand with {check} filled in, else the tree's package script of that name.
_driver_base_check_cmd() {
  local tpl
  tpl=$(driver_opt gates.checkCommand "")
  if [ -n "$tpl" ]; then printf '%s' "${tpl//\{check\}/$2}"; return 0; fi
  [ -f "$1/package.json" ] && jq -e --arg c "$2" '(.scripts // {}) | has($c)' "$1/package.json" >/dev/null 2>&1 || return 1
  printf 'npm --silent run %s' "$2"
}

_driver_base_cached() { # <sha> <check> — red|green from the shared cache, or nothing
  awk -F'\t' -v s="$1" -v c="$2" '$1 == s && $2 == c { v = $3 } END { if (v != "") print v }' "$BASE_CHECKS" 2>/dev/null
}

# _driver_base_lock <sha> — one run per base commit on the host; a peer waits, then reads
# the cache. A holder gone for an hour is stale and taken over.
_driver_base_lock() {
  local l="$BASE_CHECKS.lock-$1" waited=0 since
  mkdir -p "$(dirname "$BASE_CHECKS")" 2>/dev/null
  until mkdir "$l" 2>/dev/null; do
    since=$(cat "$l/since" 2>/dev/null); case "$since" in ''|*[!0-9]*) since=0 ;; esac
    if [ "$since" -gt 0 ] && [ $(( $(date +%s) - since )) -gt 3600 ]; then rm -rf "$l"; continue; fi
    [ "$waited" -lt "$BASE_CHECK_WAIT_SECS" ] || return 1
    sleep 5; waited=$((waited + 5))
  done
  date +%s > "$l/since"
}
_driver_base_unlock() { rm -rf "$BASE_CHECKS.lock-$1"; }

driver_base_check() {
  local wt="$1" sha="$2" c="$3" v dir cmd rc=0 out
  v=$(_driver_base_cached "$sha" "$c"); [ -z "$v" ] || { printf '%s' "$v"; return 0; }
  _driver_base_lock "$sha" || { printf unknown; return 0; }
  # A peer may have run it while this one waited.
  v=$(_driver_base_cached "$sha" "$c"); if [ -n "$v" ]; then _driver_base_unlock "$sha"; printf '%s' "$v"; return 0; fi
  dir="$(dirname "$BASE_CHECKS")/base-check-$(printf '%s' "$sha" | cut -c1-12)-$$"
  rm -rf "$dir"
  if ! git -C "$wt" worktree add -q --detach "$dir" "$sha" >/dev/null 2>&1; then
    _driver_base_unlock "$sha"; printf unknown; return 0
  fi
  v=unknown
  if { [ ! -d "$MAIN_REPO/node_modules" ] || driver_link_install "$MAIN_REPO" "$dir" >/dev/null 2>&1; } \
     && driver_prepare_worktree "$dir" >/dev/null 2>&1 \
     && cmd=$(_driver_base_check_cmd "$dir" "$c"); then
    out="$dir.out"
    ( cd "$dir" && driver_run_project "$DRIVER_CMD_TIMEOUT" "$cmd" ) > "$out" 2>&1 || rc=$?
    case "$rc" in
      0) v=green ;;
      124|126|127) v=unknown ;;
      *) v=red ;;
    esac
    rm -f "$out"
    [ "$v" = unknown ] || printf '%s\t%s\t%s\t%s\t%s\n' "$sha" "$c" "$v" "$(date +%s)" "$rc" >> "$BASE_CHECKS"
  fi
  git -C "$wt" worktree remove --force "$dir" >/dev/null 2>&1 || rm -rf "$dir"
  git -C "$wt" worktree prune >/dev/null 2>&1
  _driver_base_unlock "$sha"
  printf '%s' "$v"
}

driver_base_red_note() {
  mkdir -p "$(dirname "$DEVELOP_RED")" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$1" "${4:-}" "$(date +%s)" >> "$DEVELOP_RED"
}
