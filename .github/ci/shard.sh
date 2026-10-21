#!/usr/bin/env bash
# Prints the suites shard <index> of <total> runs (index 0-based), or with --all every suite.
# Usage: shard.sh <total> <index> | shard.sh --all
# Every shard lists the same suites in the same order and keeps only its own bin,
# so the shards cover each suite exactly once for any <total>.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Every tracked suite, globbed by directory, the same set the backstop in ci.yml checks.
suites() {
  local t
  for t in hooks/*.test.sh hooks/lib/*.test.sh tests/lib/*.test.sh scripts/*.test.sh swarm/tests/*.test.sh briefs/tests/*.test.sh driver/tests/*.test.sh; do
    [ -f "$t" ] && echo "$t"
  done
  return 0
}

if [ "${1:-}" = --all ]; then suites; exit 0; fi
total="${1:?usage: shard.sh <total> <index> | --all}"; index="${2:?usage: shard.sh <total> <index> | --all}"
case "$total$index" in *[!0-9]*) echo "shard.sh: total and index must be numbers" >&2; exit 2 ;; esac
[ "$index" -lt "$total" ] || { echo "shard.sh: index $index is not below total $total" >&2; exit 2; }

# Longest first into the lightest bin; ties broken by name so every shard agrees.
suites | awk -F'\t' '
  NR == FNR { if ($0 !~ /^#/) secs[$2] = $1; next }
  { s = ($0 in secs) ? secs[$0] : 20; printf "%010d\t%s\n", 1e9 - s, $0 }
' .github/ci/suite-seconds.tsv - \
  | LC_ALL=C sort \
  | awk -F'\t' -v total="$total" -v want="$index" '
      { s = 1e9 - $1; best = 0
        for (b = 1; b < total; b++) if (load[b] < load[best]) best = b
        load[best] += s
        if (best == want) print $2 }'
