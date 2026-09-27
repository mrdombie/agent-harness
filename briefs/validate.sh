#!/usr/bin/env bash
# validate.sh — check a step's answer against that step's contract.
#
#   briefs/validate.sh <step> <answer.json> [<answer.json>…]
#
# Exit codes, and the difference between them is the point:
#   0  every file validates
#   1  a file is invalid — the AI's answer does not meet the contract
#   2  the check could not be made — no step, an unknown step, a missing file
#
# A validator that answers 0 when it validated nothing reads exactly like one
# that validated everything, so the refusals are a separate code and every one
# of them names the thing it could not find.
#
# The validator itself is a seam: BRIEFS_AJV overrides it, so a machine with the
# tool installed does not pay for a download and a test can point it elsewhere.
set -uo pipefail

BRIEFS="$(cd "$(dirname "$0")" && pwd)"
AJV=${BRIEFS_AJV:-"npx --yes ajv-cli@5"}

die() { printf 'briefs/validate.sh: %s\n' "$1" >&2; exit 2; }

[ $# -ge 2 ] || die "usage: validate.sh <step> <answer.json> [<answer.json>…]"

step=$1; shift
schema="$BRIEFS/schemas/$step.json"
[ -f "$schema" ] || die "unknown step '$step' — no contract at schemas/$step.json (have: $(ls "$BRIEFS/schemas" 2>/dev/null | sed 's/\.json$//' | tr '\n' ' '))"

for f in "$@"; do
  [ -f "$f" ] || die "no such answer file: $f"
done

rc=0
for f in "$@"; do
  # Draft is pinned. Left to the tool's default it moves with the tool's major
  # version, and a schema silently read under a different draft is a contract
  # that changed without anybody editing it.
  if ! out=$($AJV validate --spec=draft7 -s "$schema" -d "$f" 2>&1); then
    printf '%s\n' "$out" >&2
    rc=1
  fi
done
exit "$rc"
