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
#   driver_base_red_gate <tree> <cmd> <output> [prepush]   a LOCAL red (a self-check gate, a
#                                              fix-step gate finding) read the same way: the
#                                              comma-joined checks when every one is red on
#                                              the merged trunk commit too (DRIVER_BASE_RED_SHA)
#
# EVERY STEP THAT CHECKS, NOT ONLY THE PUSH. #13044 (2026-10-23) parked in the fix step
# asking "wait or fix here" on a test red on clean develop: the push read base-red, the
# steps before it did not. A gate whose output names failing test files is base-red when
# each of them, run alone at the trunk commit, fails there too and none is a file the
# branch changed; one naming no test file is base-red when its own command fails there.
# A changed-only gate sees no change on the trunk commit, so it reads green there: the
# branch's, as before.
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

# _driver_base_test_cmd <tree> <file> — the command that runs ONE test file: the config's
# tests.fileCommand with {file} filled in, else bash for a .sh, else the tree's vitest or jest.
_driver_base_test_cmd() {
  local tpl q; q=$(printf '%q' "$2")
  tpl=$(driver_opt tests.fileCommand "")
  if [ -n "$tpl" ]; then printf '%s' "${tpl//\{file\}/$q}"; return 0; fi
  case "$2" in *.sh) printf 'bash %s' "$q"; return 0 ;; esac
  [ -f "$1/package.json" ] || return 1
  if jq -e '[.dependencies, .devDependencies] | map(select(type == "object") | has("vitest")) | any' "$1/package.json" >/dev/null 2>&1; then
    printf 'npx vitest run %s' "$q"; return 0
  fi
  if jq -e '[.dependencies, .devDependencies] | map(select(type == "object") | has("jest")) | any' "$1/package.json" >/dev/null 2>&1; then
    printf 'npx jest %s' "$q"; return 0
  fi
  return 1
}

# driver_base_check <tree> <sha> <check> [kind] — kind `test`: <check> is a test file, run
# alone; `cmd`: <check> is the command itself; else a package script or gates.checkCommand.
# BASE_CHECK_OUT=<file> keeps what a run printed there (nothing when read from the cache).
# The cache key carries the kind, so a file and a script of one name never share a row.
driver_base_check() {
  local wt="$1" sha="$2" c="$3" kind="${4:-}" v dir cmd rc=0 out
  case "$kind" in test) c="test:$3" ;; cmd) c="cmd:$3" ;; esac
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
     && case "$kind" in
          test) cmd=$(_driver_base_test_cmd "$dir" "$3") ;;
          cmd)  cmd="$3" ;;
          *)    cmd=$(_driver_base_check_cmd "$dir" "$c") ;;
        esac; then
    out="$dir.out"
    ( cd "$dir" && driver_run_project "$DRIVER_CMD_TIMEOUT" "$cmd" ) > "$out" 2>&1 || rc=$?
    case "$rc" in
      0) v=green ;;
      124|126|127) v=unknown ;;
      *) v=red ;;
    esac
    [ -z "${BASE_CHECK_OUT:-}" ] || cp "$out" "$BASE_CHECK_OUT" 2>/dev/null
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

# _driver_base_failing_tests <output> — test files a runner printed on a failure line.
_driver_base_failing_tests() {
  perl -ne 's/\e\[[0-9;]*[A-Za-z]//g;
    next unless /(\bFAIL(ED)?\b|\bfailed\b|\bnot ok\b|\xe2\x9c\x97|\xc3\x97|\xe2\x9c\x95|\xe2\x9c\x98)/;
    while (m{((?:[\w@.+-]+/)*[\w@+-][\w.@+-]*\.(?:test|spec)\.[A-Za-z]+)}g) {
      my $p = $1; $p =~ s{^(\./)+}{}; print "$p\n" }' "$1" 2>/dev/null | awk '!seen[$0]++'
}

driver_base_red_gate() {
  local wt="$1" cmd="$2" out="$3" mode="${4:-}" sha tests branch f c v red="" kind="" s7
  DRIVER_BASE_RED_SHA=""; DRIVER_BASE_RED_WHY=""
  [ -f "$out" ] || return 1
  sha=$(driver_base_red_sha "$wt") || { DRIVER_BASE_RED_WHY="the $INTEGRATION_BRANCH commit this branch merged could not be read"; return 1; }
  s7=$(printf '%s' "$sha" | cut -c1-7)
  tests=$(_driver_base_failing_tests "$out")
  if [ -n "$tests" ]; then
    kind=test
    branch=$(driver_branch_files "$wt" 2>/dev/null)
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if printf '%s\n' "$branch" | awk -v f="$f" '$0 == f || (length($0) > length(f) && substr($0, length($0) - length(f)) == "/" f) { h = 1 } END { exit !h }'; then
        DRIVER_BASE_RED_WHY="$f is a file this branch changed"; return 1
      fi
    done <<<"$tests"
  elif [ "$mode" = prepush ]; then
    tests=$(driver_base_red_checks "$out")
  else
    kind=cmd; tests="$cmd"
  fi
  [ -n "$tests" ] || { DRIVER_BASE_RED_WHY="its output names no check"; return 1; }
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    v=$(driver_base_check "$wt" "$sha" "$c" "$kind")
    case "$v" in
      red) red="$red${red:+,}$c" ;;
      green) DRIVER_BASE_RED_WHY="$c is green on $INTEGRATION_BRANCH@$s7, so this branch's own"; return 1 ;;
      *) DRIVER_BASE_RED_WHY="$c could not be run on $INTEGRATION_BRANCH@$s7, so this branch's own"; return 1 ;;
    esac
  done <<<"$tests"
  DRIVER_BASE_RED_SHA="$sha"
  printf '%s' "$red"
}

# driver_base_red_say <ticket> <step> <label> <checks> — the step's line and the coordinator's row.
driver_base_red_say() {
  driver_say "↷ $2: $3 — base-red: ${4//,/, } is red on $INTEGRATION_BRANCH@$(printf '%s' "$DRIVER_BASE_RED_SHA" | cut -c1-7) too. This check is red on $INTEGRATION_BRANCH itself; the develop-red ticket owns it; carry on. Not counted against this branch, never parked."
  driver_base_red_note "$1" "$DRIVER_BASE_RED_SHA" "$4" "$(driver_state_get "$1" pr 2>/dev/null)"
}
