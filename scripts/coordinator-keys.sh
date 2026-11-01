#!/usr/bin/env bash
# coordinator-keys.sh — every coordinator key that is documented or set is read by some code.
#   coordinator-keys.sh documented          the README's `coordinator` table keys
#   coordinator-keys.sh config <harness.json>  that config's top-level `coordinator` keys
# Prints "unread: <key>" for each key no code line reads; exit 1 when any is unread.
# A read is `coordinator.<key>` on a line of code that is not a comment, in a file that is
# not a test or a doc. COORDINATOR_KEYS_ROOT points it at another tree (tests).
set -uo pipefail
ROOT="${COORDINATOR_KEYS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

keys_documented() {
  awk '/^\| Key \(under `coordinator`\)/ { t = 1; next } t && !/^\|/ { exit } t' "$ROOT/README.md" \
    | awk -F'|' 'NR > 1 { print $2 }' | grep -oE '`[^`]+`' | tr -d '`'
}
keys_config() { jq -r '(.coordinator // {}) | keys[]' "$1"; }

# Every non-comment code line naming a coordinator key, once.
read_lines() {
  grep -rIhE 'coordinator\.[A-Za-z]' "$ROOT" \
    --exclude-dir=.git --exclude-dir=docs --exclude-dir=reference --exclude-dir=tests \
    --exclude='*.md' --exclude='*.test.sh' --exclude='*.test.mjs' --exclude='*.test.js' 2>/dev/null \
    | grep -vE '^[[:space:]]*(#|//)'
}

case "${1:-}" in
  documented) KEYS=$(keys_documented) ;;
  config) [ -f "${2:-}" ] || { echo "usage: coordinator-keys.sh config <harness.json>" >&2; exit 2; }
          KEYS=$(keys_config "$2") || exit 2 ;;
  *) echo "usage: coordinator-keys.sh documented | config <harness.json>" >&2; exit 2 ;;
esac
[ -n "$KEYS" ] || { echo "no coordinator keys found" >&2; exit 2; }

READS=$(read_lines)
unread=0
while IFS= read -r k; do
  [ -n "$k" ] || continue
  re="(^|[^A-Za-z0-9_])coordinator\\.$(printf '%s' "$k" | sed 's/\./\\./g')([^A-Za-z0-9_]|\$)"
  printf '%s\n' "$READS" | grep -qE "$re" || { echo "unread: $k"; unread=1; }
done <<< "$KEYS"
exit "$unread"
