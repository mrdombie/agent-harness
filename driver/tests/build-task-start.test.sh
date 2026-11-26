#!/usr/bin/env bash
# build-task-start.test.sh — a task's start head is kept across its own tries, so a
# retry still sees what an earlier try of it committed; but once another task is
# proved after it, that task's commits are not this task's, so the head starts fresh.
# Real git; run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fixture_path REPO "$FIX"
. "$HERE/../steps/build.sh" || exit 1
FAILED=0
want() { if [ "$2" = "$3" ]; then echo "OK       $1"; else echo "MISMATCH $1 — wanted '$2', got '$3'"; FAILED=$((FAILED+1)); fi; }

STEPS="$FIX/steps"; mkdir -p "$STEPS"
commit() { printf '%s\n' "$1" > "$REPO/$1.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "$1"; git -C "$REPO" rev-parse HEAD; }

if suite_case "a retry of the same task keeps its first head"; then
  A=$(commit first-try)
  got=$(_driver_build_task_start "$STEPS/build-task-1.started" 1 "$REPO")
  want "the first try starts at HEAD" "$A" "$got"
  commit own-try >/dev/null
  got=$(_driver_build_task_start "$STEPS/build-task-1.started" 1 "$REPO")
  want "the retry measures from the first head" "$A" "$got"
fi

if suite_case "once another task is proved after it, the head starts fresh"; then
  sleep 1
  commit task-2 >/dev/null; B=$(git -C "$REPO" rev-parse HEAD)
  printf '{}\n' > "$STEPS/build-task-2.proved"
  got=$(_driver_build_task_start "$STEPS/build-task-1.started" 1 "$REPO")
  want "the retry starts at the head after task 2" "$B" "$got"
  got=$(jq -r .head "$STEPS/build-task-1.started")
  want "and keeps that as its new start" "$B" "$got"
fi

suite_end "$FAILED"
