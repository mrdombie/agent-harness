#!/usr/bin/env bash
# coordinator-tick-lint.test.sh — the tick passes the lint job's shellcheck: a directive
# misplaced inside a loop makes the loop unparseable and turns the lint check red.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v shellcheck >/dev/null || suite_skip "shellcheck is not installed"

FAILED=0
echo "--- the lint job's check passes on coordinator-tick.sh ---"
if out=$(bash "$HERE/check-changed-shell.sh" --files "$HERE/coordinator-tick.sh" 2>&1); then
  echo "ok: shellcheck parses coordinator-tick.sh"
else
  echo "FAIL: shellcheck refuses coordinator-tick.sh"; echo "$out"; FAILED=1
fi

suite_end "$FAILED"
