#!/usr/bin/env bash
# check-driver-only-spawn.sh — no unattended build runs the prose claim. Every build,
# repairs included, goes step by step through driver/build-ticket (the owner,
# 2026-10-22); the prose claim survives only for a person at a terminal (--fg) and for
# a project that sets swarm.builder "prose" on purpose.
#
#   check-driver-only-spawn.sh [kit-root]   default: this kit
#
# Three rules, each printed as <file>:<line>: <why> when broken; exit 1 when any is:
#   1. Outside scripts/spawn-claim.sh, no code line in scripts/, swarm/ or driver/
#      names /agent-harness:claim: a second launcher is a prose path nothing routes.
#   2. In spawn-claim.sh, every code line that sets BUILDER=prose carries the marker
#      `# prose: --fg only`. A literal prose fallback left in an unattended branch is
#      the class this exists for: a temporary route left wired in after its reason went.
#   3. spawn-claim.sh refuses an unattended run with no ticket (a `-z "$TICKET"` and
#      `"$FG" -eq 0` test followed within five lines by a non-zero exit).
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SPAWN="$ROOT/scripts/spawn-claim.sh"
bad=0
[ -f "$SPAWN" ] || { echo "$SPAWN: missing — nothing to check the spawner against"; exit 1; }

files=$(cd "$ROOT" && { git ls-files scripts swarm driver 2>/dev/null || find scripts swarm driver -type f; } \
  | grep -E '(\.sh$|/build-ticket$)' | grep -vE '(\.test\.sh$|/tests/|/fixtures/)' | grep -vx 'scripts/spawn-claim.sh')
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$ROOT/$f" ] || continue
  hits=$(awk '/^[[:space:]]*#/ { next } /agent-harness[:]claim([^-a-z]|$)/ { printf "%s:%d: launches the prose claim outside spawn-claim.sh — route the build through spawn-claim'"'"'s driver path\n", FILENAME, FNR }' "$ROOT/$f")
  [ -z "$hits" ] || { printf '%s\n' "$hits" | sed "s#^$ROOT/##"; bad=1; }
done <<<"$files"

hits=$(awk '/^[[:space:]]*#/ { next } /(^|[^A-Z_])BUILDER=prose/ && !/# prose: --fg only/ { printf "scripts/spawn-claim.sh:%d: sets BUILDER=prose without the `# prose: --fg only` marker — an unattended run must not fall back to the prose claim\n", FNR }' "$SPAWN")
[ -z "$hits" ] || { printf '%s\n' "$hits"; bad=1; }

if ! awk '/^[[:space:]]*#/ { next }
          /-z "\$TICKET"/ && /"\$FG" -eq 0/ { w = FNR + 5 }
          w && FNR <= w && /exit [1-9]/ { found = 1 }
          END { exit found ? 0 : 1 }' "$SPAWN"; then
  echo "scripts/spawn-claim.sh: no refusal of an unattended run with no ticket — pick-next would run the prose claim with nobody watching"
  bad=1
fi
exit "$bad"
