#!/usr/bin/env bash
# suite.sh — how a test suite cleans up, and how it says it reached its end.
#
# Sourced by every suite. A suite that stops partway must never look finished:
#   on_exit_keep_status <cleanup>  run <cleanup> at exit, then exit with the status
#                                  the shell was already leaving with. A bare EXIT
#                                  trap whose cleanup calls `exit` reports its own
#                                  status instead and turns a crash green.
#   suite_end <failures>           the suite's last line: prints the summary line the
#                                  CI runner (.github/ci/run-suite.sh) requires, and
#                                  exits 1 on any failure. `exit $count` wraps at 256.
#   suite_skip <why>               an early, deliberate exit 0 that still prints a
#                                  summary line, so CI tells a skip from a stop.
#   fixture_path <var> <root>      refuse to go on unless the path held in <var> is
#                                  non-empty and inside <root>: `git -C ""` is the
#                                  directory the suite was started from, the operator's
#                                  own clone. Call it in the suite's shell, never in $( ).

__SUITE_CLEANUP=

on_exit_keep_status() { # <cleanup command string>
  __SUITE_CLEANUP=$1
  trap '__suite_rc=$?; eval "$__SUITE_CLEANUP"; exit "$__suite_rc"' EXIT
}

__suite_name() { basename "$0"; }

suite_end() { # <failures: a count or 0/1 flag>
  local n="${1-}" name
  name=$(__suite_name)
  case "$n" in
    '' | *[!0-9]*) echo "SUITE-END $name: FAIL (failure count '$n' is not a number)"; exit 1 ;;
  esac
  if [ "$n" -eq 0 ]; then echo "SUITE-END $name: PASS"; exit 0; fi
  echo "SUITE-END $name: FAIL ($n)"
  exit 1
}

suite_skip() { # <why>
  echo "SUITE-END $(__suite_name): SKIP (${1:-no reason given})"
  exit 0
}

fixture_path() { # <var-name> <root>
  local name="${1-}" root="${2-}" val real_root real_val
  val=${!name-}
  if [ -z "$root" ]; then
    echo "  FAIL — fixture_path $name: no root to hold it to"
  elif [ -z "$val" ]; then
    echo "  FAIL — refused: \$$name is empty, and git -C \"\" would act on $(pwd -P)"
  else
    case "$val" in "$root"/*) return 0 ;; esac
    real_root=$(cd "$root" 2>/dev/null && pwd -P)
    real_val=$(cd "$val" 2>/dev/null && pwd -P)
    if [ -n "$real_root" ] && [ -n "$real_val" ]; then
      case "$real_val" in "$real_root"/*) return 0 ;; esac
    fi
    echo "  FAIL — refused: \$$name is $val, outside $root"
  fi
  suite_end 1
}
