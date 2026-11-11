#!/usr/bin/env bash
# test-db.sh — a throwaway, migrated database for a project's own test runs.
#
#   driver_with_test_db [--soft] <why-file> <tree> <command…>
#
# A PLACEHOLDER WAS THE ONLY WAY TO ASK FOR ONE. A test that needs a real database
# (`*.db.test.ts`, skipped without DATABASE_URL) could not be proved: the builder
# wrote `DATABASE_URL=<throwaway postgres with migrations applied>`, which no shell
# can run, or left it out, and the skipped test read green before the change.
#
# Configured per project in harness.json, and absent is today's behaviour:
#
#   "tests": { "db": {
#     "urlTemplate": "postgresql://u:p@localhost:5432/{name}",   the test URL; {name} required
#     "admin":       "postgresql://u:p@localhost:5432/postgres",  where CREATE/DROP run
#     "setup":       "npx prisma migrate deploy" } }              run in the tree, optional
#
# Each call creates a database named hp_<ticket>_<pid>_<n>, runs `setup` in <tree>
# with DATABASE_URL at it, runs the command with DATABASE_URL exported, and drops it
# on the way out — a failing command, a timeout and a signal included.
#
# IT ONLY EVER DROPS WHAT IT MADE. A name outside the prefix is refused, and so is a
# name this shell did not create: createdb refuses a name that exists, so an existing
# database is never adopted and never dropped.
#
# A database that could not be made is not a red: the reason goes to <why-file> and
# the call returns 125 with the command never run. With --soft (an agent step, which
# can still do its other work) the command runs anyway, with DATABASE_URL unset so it
# reaches no database it was not given.
#
# With --for <test-file> (a proof), a test that needs no database runs without one
# when none can be made: a unit test fails only on itself, never on the host. A test
# needs one when its name matches tests.db.match (default `\.db\.test\.`) or it
# reads DATABASE_URL.

DRIVER_TEST_DB_PREFIX="hp_"
_DRIVER_TEST_DB_MINE=""

# driver_test_db_cfg <field> — tests.db.<field> as a string, or nothing.
driver_test_db_cfg() {
  [ -n "${HARNESS_CFG:-}" ] && [ -f "$HARNESS_CFG" ] || return 0
  jq -r --arg f "$1" '(.tests.db // {}) | if type == "object" then (.[$f] // "") else "" end
    | if type == "string" then . else "" end' "$HARNESS_CFG" 2>/dev/null
}

# driver_test_db_on — 0 when this project configures a test database.
driver_test_db_on() { [ -n "$(driver_test_db_cfg urlTemplate)" ]; }

# driver_test_db_name_ok <name> — 0 for a name this facility could have made.
driver_test_db_name_ok() {
  [[ "${1:-}" =~ ^hp_[a-z0-9_]{1,60}$ ]]
}

# driver_test_db_name <ticket> — a fresh name under the prefix.
driver_test_db_name() {
  local t
  t=$(printf '%s' "${1:-x}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | cut -c1-20)
  printf '%s%s_%s_%s' "$DRIVER_TEST_DB_PREFIX" "${t:-x}" "${BASHPID:-$$}" "$RANDOM$RANDOM"
}

# driver_test_db_url <name> — the template with {name} filled; 1 when it has no {name}.
driver_test_db_url() {
  local tpl; tpl=$(driver_test_db_cfg urlTemplate)
  case "$tpl" in *'{name}'*) ;; *) return 1 ;; esac
  printf '%s' "${tpl//\{name\}/$1}"
}

# A SERVER THAT DID NOT ANSWER IN TIME IS A WAIT, NOT A REFUSAL. At load 42 and 59 on
# 10 cores the setup's connect timed out (P1001) with the server up and 6 of 100
# connections in use, and a finished build was parked on it. A failure whose output
# reads as a connect timeout is tried again, DRIVER_TEST_DB_RETRIES more times (3),
# after DRIVER_TEST_DB_RETRY_DELAY seconds (15), doubling: 15, 30, 60. A server that
# pg_isready finds down is not waited for, and any other failure fails at once.
_DRIVER_TEST_DB_TIMEOUT_RE="P1001|Can't reach database server|timeout exceeded when trying to connect|Connection terminated due to connection timeout|could not connect to server"
DRIVER_TEST_DB_TIMED_OUT=""

# _driver_test_db_up <admin> — 1 only when pg_isready is here and gets no answer.
_driver_test_db_up() {
  command -v pg_isready >/dev/null 2>&1 || return 0
  # A down server refuses at once; a loaded one answers late, so the wait is long.
  pg_isready -q -t 30 -d "$1" >/dev/null 2>&1
  [ $? -ne 2 ]
}

# _driver_test_db_is_timeout <log> — 0 when the output reads as a connect timeout.
_driver_test_db_is_timeout() { grep -qE -- "$_DRIVER_TEST_DB_TIMEOUT_RE" "$1" 2>/dev/null; }

# _driver_test_db_wait <log> <admin> <tries-so-far> — 0 after waiting, to try again;
# 1 when the failure is no timeout, the server is down, or the tries are spent.
# Sets DRIVER_TEST_DB_TIMED_OUT to the words for a failure that was one.
_driver_test_db_wait() {
  local log="$1" admin="$2" n="$3" max="${DRIVER_TEST_DB_RETRIES:-3}" base="${DRIVER_TEST_DB_RETRY_DELAY:-15}" load="" secs i
  DRIVER_TEST_DB_TIMED_OUT=""
  case "$max" in ''|*[!0-9]*) max=3 ;; esac
  case "$base" in ''|*[!0-9]*) base=15 ;; esac
  _driver_test_db_is_timeout "$log" || return 1
  type swarm_load >/dev/null 2>&1 && load=$(swarm_load 2>/dev/null)
  load="${load:-unread}"
  if ! _driver_test_db_up "$admin"; then
    DRIVER_TEST_DB_TIMED_OUT=" — the database server is not answering at all (pg_isready), so it was not tried again"
    return 1
  fi
  if [ "$n" -ge "$max" ]; then
    DRIVER_TEST_DB_TIMED_OUT=" — a connect timeout, not a refusal: the test database did not answer in $((n + 1)) tries (load $load)"
    return 1
  fi
  secs=$base; i=0
  while [ "$i" -lt "$n" ]; do secs=$((secs * 2)); i=$((i + 1)); done
  driver_say "   the test database did not answer (load $load); trying again in ${secs}s ($((n + 1)) of $max)" >&2
  /bin/sleep "$secs"
  return 0
}

# driver_test_db_create <name> <tree> — create, then set up in <tree>. Sets
# DRIVER_TEST_DB_WHY and returns 1 when either fails; a half-made one is dropped.
DRIVER_TEST_DB_WHY=""
driver_test_db_create() {
  local name="$1" tree="$2" admin setup url log rc n
  DRIVER_TEST_DB_WHY=""
  if ! driver_test_db_name_ok "$name"; then
    DRIVER_TEST_DB_WHY="refused to create '$name': a test database is always named ${DRIVER_TEST_DB_PREFIX}<ticket>_<pid>_<n>"; return 1
  fi
  admin=$(driver_test_db_cfg admin)
  [ -n "$admin" ] || { DRIVER_TEST_DB_WHY="tests.db has no admin URL, so no test database could be created"; return 1; }
  url=$(driver_test_db_url "$name") || {
    DRIVER_TEST_DB_WHY="tests.db.urlTemplate has no {name}, so it would point the test at a database the driver did not create"; return 1; }
  log=$(mktemp "${TMPDIR:-/tmp}/driver-testdb-XXXXXX")
  n=0
  while :; do
    createdb --maintenance-db="$admin" "$name" >"$log" 2>&1; rc=$?
    [ "$rc" -ne 0 ] || break
    _driver_test_db_wait "$log" "$admin" "$n" && { n=$((n + 1)); continue; }
    DRIVER_TEST_DB_WHY="the test database $name could not be created (createdb exit $rc): $(tail -3 "$log" | tr '\n' ' ' | cut -c1-300)$DRIVER_TEST_DB_TIMED_OUT"
    rm -f "$log"; return 1
  done
  _DRIVER_TEST_DB_MINE="$_DRIVER_TEST_DB_MINE $name "
  setup=$(driver_test_db_cfg setup)
  if [ -n "$setup" ]; then
    n=0
    while :; do
      ( cd "$tree" && DATABASE_URL="$url" driver_run_project "${DRIVER_CMD_TIMEOUT:-900}" "$setup" ) >"$log" 2>&1; rc=$?
      [ "$rc" -ne 0 ] || break
      # The setup is run again on the same database: a migration run is safe to repeat.
      _driver_test_db_wait "$log" "$admin" "$n" && { n=$((n + 1)); continue; }
      DRIVER_TEST_DB_WHY="the test database's setup ($setup) failed with exit $rc: $(tail -3 "$log" | tr '\n' ' ' | cut -c1-300)$DRIVER_TEST_DB_TIMED_OUT"
      rm -f "$log"; driver_test_db_drop "$name" >/dev/null 2>&1; return 1
    done
  fi
  rm -f "$log"
  return 0
}

# driver_test_db_drop <name> — drop a database this shell created; refuse any other.
driver_test_db_drop() {
  local name="$1" admin
  if ! driver_test_db_name_ok "$name"; then
    echo "driver: refused to drop '$name' — not a ${DRIVER_TEST_DB_PREFIX} test database" >&2; return 1
  fi
  case "$_DRIVER_TEST_DB_MINE" in
    *" $name "*) ;;
    *) echo "driver: refused to drop '$name' — this run did not create it" >&2; return 1 ;;
  esac
  admin=$(driver_test_db_cfg admin)
  dropdb --if-exists --maintenance-db="$admin" "$name" || return 1
  _DRIVER_TEST_DB_MINE="${_DRIVER_TEST_DB_MINE// $name /}"
}

# driver_test_needs_db <tree> <test-file> — 0 when the test needs a database.
driver_test_needs_db() {
  local tree="$1" f="$2" pat
  pat=$(driver_test_db_cfg match); [ -n "$pat" ] || pat='\.db\.test\.'
  printf '%s' "$f" | grep -qE -- "$pat" && return 0
  [ -f "$tree/$f" ] && grep -q 'DATABASE_URL' "$tree/$f" && return 0
  return 1
}

# driver_test_db_tools_missing — the client tools a configured test database needs and
# this host lacks, space-separated; nothing when it has them or none is configured.
driver_test_db_tools_missing() {
  driver_test_db_on || return 0
  local t miss=""
  for t in createdb dropdb; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done
  printf '%s' "${miss# }"
}

driver_with_test_db() {
  local soft=0 tfile=""
  while :; do
    case "${1:-}" in
      --soft) soft=1; shift ;;
      --for)  tfile="${2:-}"; shift 2 ;;
      *) break ;;
    esac
  done
  local whyf="$1" tree="$2"; shift 2
  driver_test_db_on || { "$@"; return $?; }
  (
    name=$(driver_test_db_name "${DRIVER_TICKET:-x}")
    trap 'driver_test_db_drop "$name" >/dev/null 2>&1' EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    if ! driver_test_db_create "$name" "$tree"; then
      if [ -n "$tfile" ] && ! driver_test_needs_db "$tree" "$tfile"; then
        unset DATABASE_URL
        "$@"; exit $?
      fi
      printf '%s\n' "$DRIVER_TEST_DB_WHY" > "$whyf"
      [ "$soft" -eq 1 ] || exit 125
      unset DATABASE_URL
      "$@"; exit $?
    fi
    DATABASE_URL=$(driver_test_db_url "$name"); export DATABASE_URL
    "$@"
  )
}
