#!/usr/bin/env bash
# PreToolUse(Bash): refuse `gh pr create|edit` whose body closes a ticket other than
# the one its branch names, or whose --body-file is not named for that ticket.
# Three PRs went up carrying a fourth PR's body from a shared scratch file (2026-10-14).
#
# Self-test: hooks/pr-body-matches-branch.test.sh
payload=$(cat)
case "$payload" in *gh*pr*) ;; *) exit 0 ;; esac
. "$(dirname "$0")/lib/python.sh"
harness_python || harness_python_refuse pr-body-matches-branch
printf '%s' "$payload" | exec "${HARNESS_PY[@]}" "$(dirname "$0")/pr-body-matches-branch.py"
