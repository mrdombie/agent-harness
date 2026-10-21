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

# driver_test_db_create <name> <tree> — create, then set up in <tree>. Sets
# DRIVER_TEST_DB_WHY and returns 1 when either fails; a half-made one is dropped.
DRIVER_TEST_DB_WHY=""
driver_test_db_create() {
  local name="$1" tree="$2" admin setup url log rc
  DRIVER_TEST_DB_WHY=""
  if ! driver_test_db_name_ok "$name"; then
    DRIVER_TEST_DB_WHY="refused to create '$name': a test database is always named ${DRIVER_TEST_DB_PREFIX}<ticket>_<pid>_<n>"; return 1
  fi
  admin=$(driver_test_db_cfg admin)
  [ -n "$admin" ] || { DRIVER_TEST_DB_WHY="tests.db has no admin URL, so no test database could be created"; return 1; }
  url=$(driver_test_db_url "$name") || {
    DRIVER_TEST_DB_WHY="tests.db.urlTemplate has no {name}, so it would point the test at a database the driver did not create"; return 1; }
  log=$(mktemp "${TMPDIR:-/tmp}/driver-testdb-XXXXXX")
  createdb --maintenance-db="$admin" "$name" >"$log" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    DRIVER_TEST_DB_WHY="the test database $name could not be created (createdb exit $rc): $(tail -3 "$log" | tr '\n' ' ' | cut -c1-300)"
    rm -f "$log"; return 1
  fi
  _DRIVER_TEST_DB_MINE="$_DRIVER_TEST_DB_MINE $name "
  setup=$(driver_test_db_cfg setup)
  if [ -n "$setup" ]; then
    ( cd "$tree" && DATABASE_URL="$url" driver_run_project "${DRIVER_CMD_TIMEOUT:-900}" "$setup" ) >"$log" 2>&1; rc=$?
    if [ "$rc" -ne 0 ]; then
      DRIVER_TEST_DB_WHY="the test database's setup ($setup) failed with exit $rc: $(tail -3 "$log" | tr '\n' ' ' | cut -c1-300)"
      rm -f "$log"; driver_test_db_drop "$name" >/dev/null 2>&1; return 1
    fi
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

driver_with_test_db() {
  local soft=0
  [ "${1:-}" = --soft ] && { soft=1; shift; }
  local whyf="$1" tree="$2"; shift 2
  driver_test_db_on || { "$@"; return $?; }
  (
    name=$(driver_test_db_name "${DRIVER_TICKET:-x}")
    trap 'driver_test_db_drop "$name" >/dev/null 2>&1' EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    if ! driver_test_db_create "$name" "$tree"; then
      printf '%s\n' "$DRIVER_TEST_DB_WHY" > "$whyf"
      [ "$soft" -eq 1 ] || exit 125
      unset DATABASE_URL
      "$@"; exit $?
    fi
    DATABASE_URL=$(driver_test_db_url "$name"); export DATABASE_URL
    "$@"
  )
}
