#!/usr/bin/env bash
# check-suite-ending.sh — every suite cleans up through tests/lib/suite.sh and ends on suite_end.
# Usage: check-suite-ending.sh [suite ...]   (default: every suite .github/ci/shard.sh --all lists)
# A bare EXIT trap is one `exit` away from reporting a crash as green, and a suite
# with no suite_end prints no summary line, so .github/ci/run-suite.sh fails it anyway.
cd "$(dirname "$0")/.." || exit 2
if [ $# -gt 0 ]; then suites=("$@"); else
  suites=(); while IFS= read -r s; do suites+=("$s"); done < <(bash .github/ci/shard.sh --all)
fi
[ "${#suites[@]}" -gt 0 ] || { echo "check-suite-ending: no suites to check"; exit 2; }
bad=0
for f in "${suites[@]}"; do
  [ -f "$f" ] || { echo "  $f: not a file"; bad=1; continue; }
  # A commented-out trap is not one.
  hits=$(grep -nE '^[^#]*(^|[;&|{[:space:]])trap[[:space:]].*[[:space:]]EXIT([[:space:];&|}]|$)' "$f" || true)
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed "s|^|  $f:|; s|\$|   ← bare EXIT trap: use on_exit_keep_status|"; bad=1
  fi
  grep -qE '^[[:space:]]*\.[[:space:]].*tests/lib/suite\.sh' "$f" \
    || { echo "  $f: does not source tests/lib/suite.sh"; bad=1; }
  grep -qE '^[^#]*\bsuite_end\b' "$f" \
    || { echo "  $f: never calls suite_end, so it prints no summary line"; bad=1; }
done
if [ "$bad" -ne 0 ]; then
  echo "check-suite-ending: suites above can stop early and still look finished (see tests/lib/suite.sh)"
  exit 1
fi
echo "check-suite-ending: ${#suites[@]} suites clean up through on_exit_keep_status and end on suite_end"
