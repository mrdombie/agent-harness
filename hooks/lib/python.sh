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

# Prints the first interpreter that actually executes, as words to splice
# unquoted ("py -3" is two). HARNESS_PYTHON overrides the search.
harness_python() {
  local c
  for c in ${HARNESS_PYTHON:+"$HARNESS_PYTHON"} python3 python "py -3"; do
    # shellcheck disable=SC2086  # "py -3" must split
    if $c -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

# Exit 2 — Claude Code's "block" — naming the guard that could not run.
harness_python_refuse() {
  printf 'Blocked: the %s guard cannot run — no working Python 3 (tried %spython3, python, py -3). Install Python 3, or on Windows turn off the python App Execution Aliases so the real one is found. A guard that cannot run refuses instead of passing.\n' \
    "$1" "${HARNESS_PYTHON:+$HARNESS_PYTHON, }" >&2
  exit 2
}
