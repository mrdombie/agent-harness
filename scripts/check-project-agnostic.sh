#!/usr/bin/env bash
# The kit's acceptance test: nothing it ships names the project it was extracted
# from. README.md is the one file allowed to tell that story; this probe carries
# the names it looks for and is skipped for the same reason.
#
# Reported WITH a control. The first run of this grep on the empty skeleton
# returned 0 because there were no files, not because they were clean — a zero
# from a strictness probe means clean, suppressed, or never ran.
set -u
cd "$(dirname "$0")/.." || exit 1
NAMES="${HARNESS_ORIGIN_NAMES:-maktura|socialhub|social-hub|mrdombie}"
control=$(git ls-files | grep -vE '^(README\.md|scripts/check-project-agnostic\.sh)$' | xargs grep -lE 'harness' 2>/dev/null | wc -l | tr -d ' ')
hits=$(git ls-files | grep -vE '^(README\.md|scripts/check-project-agnostic\.sh)$' | xargs grep -niE "$NAMES" 2>/dev/null)
n=$(printf '%s' "$hits" | grep -c . )
printf 'control, probe can see files : %s match "harness"\n' "$control"
printf 'names the origin project     : %s (want 0)\n' "$n"
[ "$control" -gt 0 ] || { echo "probe saw no files — refusing to report clean"; exit 2; }
[ "$n" -eq 0 ] || { printf '%s\n' "$hits"; exit 1; }
