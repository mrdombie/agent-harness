#!/usr/bin/env bash
# runner-pin.test.sh — every hosted job names an exact runner image, never `*-latest`.
# A `-latest` label moves under the kit without a commit: on 2026-10-27 ubuntu-latest
# became ubuntu26 and a suite that passed on ubuntu24 went red on every branch.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }

# Prints <file>:<line>: <value> for each runs-on that floats.
floating() {
  local f
  for f in "$@"; do
    awk -v f="$f" '
      /^[[:space:]]*runs-on:/ { v = $0; sub(/^[[:space:]]*runs-on:[[:space:]]*/, "", v)
                                if (v ~ /-latest/) printf "%s:%d: %s\n", f, NR, v }
      /^[[:space:]]*default:/ && prev ~ /runs-on/ { v = $0; if (v ~ /-latest/) printf "%s:%d: %s\n", f, NR, v }
      { if ($0 ~ /runs-on:/) prev = $0; else if ($0 !~ /^[[:space:]]*(description|required|type):/) prev = "" }
    ' "$f"
  done
}

echo "--- the kit's own workflows pin their runner image ---"
found=$(floating "$ROOT"/.github/workflows/*.yml)
[ -z "$found" ] && ok "no workflow runs on a -latest image" || bad "floating runner image: $found"

echo "--- the check sees a floating image ---"
T=$(mktemp -d); on_exit_keep_status 'rm -rf "$T"'
printf 'jobs:\n  a:\n    runs-on: ubuntu-latest\n' > "$T/plant.yml"
[ -n "$(floating "$T/plant.yml")" ] && ok "ubuntu-latest is flagged" || bad "ubuntu-latest was not flagged"
printf 'jobs:\n  a:\n    runs-on: ubuntu-24.04\n  b:\n    runs-on: ${{ fromJSON(inputs.runs-on) }}\n' > "$T/pinned.yml"
[ -z "$(floating "$T/pinned.yml")" ] && ok "a pinned image and an input are not flagged" || bad "flagged a pinned file"

echo
[ "$fail" -eq 0 ] && echo "runner-pin: all cases pass" || echo "runner-pin: FAILURES above"
suite_end "$fail"
