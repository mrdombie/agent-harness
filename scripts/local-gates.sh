#!/usr/bin/env bash
# local-gates.sh — the project's local gate commands, one per line. Every prose path
# (claim, finish, gate-runner, the whole-app hook) reads them here, so the rule lives once.
# Usage: local-gates.sh [--joined] [<harness.json>]
#   default config: ./.claude/harness.json, the checkout's own, as the skills read it
#   before (HARNESS_CFG_PATH can name a coordinator's copy, so it is not read)
#   --joined        one line, the commands joined with " && "
# The rule: with `gates.localOnly: true`, `gates.local` is the whole local set and
# gates.changed (which may hold test:changed) is never printed; every test runs once, in
# CI, and the only local test run is the one test file a change names for its
# red-then-green proof. Without the setting, gates.changed as before.
# Exit 0 with the list (empty when the config names none); 2 when the config is
# unreadable, or localOnly is set with no non-empty gates.local list — refusing, so a
# caller never falls back to gates.changed and runs the tests the setting kept off.
set -uo pipefail
joined=0
[ "${1:-}" = --joined ] && { joined=1; shift; }
cfg="${1:-.claude/harness.json}"
[ -f "$cfg" ] || { echo "local-gates: no config at $cfg" >&2; exit 2; }
jq -e . "$cfg" >/dev/null 2>&1 || { echo "local-gates: $cfg is not JSON" >&2; exit 2; }

if jq -e '((.gates // {}) | type) == "object" and .gates.localOnly == true' "$cfg" >/dev/null 2>&1; then
  jq -e '(.gates.local | type) == "array" and (.gates.local | length) > 0' "$cfg" >/dev/null 2>&1 || {
    echo "local-gates: $cfg sets gates.localOnly but gates.local is not a non-empty list — refusing rather than run gates.changed, tests and all" >&2
    exit 2
  }
  path='.gates.local'
else
  path='(.gates.changed // [])'
fi
if [ "$joined" = 1 ]; then
  jq -r "$path | join(\" && \")" "$cfg"
else
  jq -r "$path | .[]" "$cfg"
fi
