# Sourced by the guard hooks that judge a command in Python.
#
# `command -v python3` is not proof there is a Python. Windows ships App
# Execution Alias stubs named python3 and python that print "Python was not
# found" and exit 49. Claude Code reads any exit other than 0 or 2 as a
# NON-blocking error, so a guard that exec'd the stub let every command
# through: 4,953 times on one machine over 2026-09-28/29 (#40), while Python
# 3.13 sat installed behind `py -3`.
#
# So an interpreter counts only when it runs. And when none does, the guard
# refuses rather than passes: a guard that cannot run has to say so.

# Git Bash rewrites a POSIX-looking environment value on its way into a native
# Windows program: HARNESS_WORKTREE_ROOT=/Users/me/wt reached Python as
# "C:/Program Files/Git/Users/me/wt", so no command ever matched the configured
# root. The judges compare these values as text; keep them as written.
export MSYS2_ENV_CONV_EXCL="HARNESS_${MSYS2_ENV_CONV_EXCL:+;$MSYS2_ENV_CONV_EXCL}"

_harness_python_runs() {
  "$@" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1
}

# Fills HARNESS_PY with the first interpreter that actually executes — an array,
# because `py -3` is two words and an override path may hold a space. Call it
# directly, not in $(...), or the array is lost with the subshell.
# HARNESS_PYTHON overrides the search.
harness_python() {
  HARNESS_PY=()
  if [ -n "${HARNESS_PYTHON:-}" ] && _harness_python_runs "$HARNESS_PYTHON"; then
    HARNESS_PY=("$HARNESS_PYTHON"); return 0
  fi
  local c
  for c in python3 python; do
    if _harness_python_runs "$c"; then HARNESS_PY=("$c"); return 0; fi
  done
  if _harness_python_runs py -3; then HARNESS_PY=(py -3); return 0; fi
  return 1
}

# Exit 2 — Claude Code's "block" — naming the guard that could not run.
harness_python_refuse() {
  printf 'Blocked: the %s guard cannot run — no working Python 3 (tried %spython3, python, py -3). Install Python 3, or on Windows turn off the python App Execution Aliases so the real one is found. A guard that cannot run refuses instead of passing.\n' \
    "$1" "${HARNESS_PYTHON:+$HARNESS_PYTHON, }" >&2
  exit 2
}
