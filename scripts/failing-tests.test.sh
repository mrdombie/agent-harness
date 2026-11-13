#!/usr/bin/env bash
# failing-tests.test.sh — a failing test is named by its path from the repo root: a worktree's
# host path becomes the tracked file it ends with, and one no tracked file ends with is dropped.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/failing-tests.sh"
FIX=$(mktemp -d); on_exit_keep_status 'rm -rf "$FIX"'
FAILED=0
want() { if [ "$2" = "$3" ]; then echo "  ok — $1"; else echo "  FAIL — $1: wanted '$2', got '$3'"; FAILED=$((FAILED + 1)); fi; }

TREE="$FIX/tree"; mkdir -p "$TREE/apps/api/src/lib/jobs" "$TREE/src"
git -C "$TREE" init -q
: > "$TREE/apps/api/src/lib/jobs/x.test.ts"; : > "$TREE/src/y.test.ts"
git -C "$TREE" add -A; git -C "$TREE" -c user.email=t@t -c user.name=t commit -qm fixture

names() { printf '%s\n' "$1" > "$FIX/log"; failing_test_files "$FIX/log" "${2:-}" | tr '\n' ' ' | sed 's/ $//'; }

want "a worktree host path is the tracked repo-relative path" "apps/api/src/lib/jobs/x.test.ts" \
  "$(names ' FAIL  /Users/someone/proj-wt/sh-1-abc/apps/api/src/lib/jobs/x.test.ts > jobs > runs' "$TREE")"
want "an absolute path no tracked file ends with is nothing" "" \
  "$(names ' FAIL  /Users/someone/proj-wt/sh-1-abc/apps/web/src/gone.test.ts' "$TREE")"
want "a ./ path loses its ./" "src/y.test.ts" "$(names 'FAIL ./src/y.test.ts' "$TREE")"
want "a relative path is kept without a tree" "src/y.test.ts" "$(names 'FAIL src/y.test.ts')"

suite_end "$FAILED"
