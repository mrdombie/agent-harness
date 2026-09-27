#!/usr/bin/env bash
# validate.sh — check a step's answer against that step's contract.
#
#   briefs/validate.sh <step> <answer.json> [<answer.json>…]
#
# Exit codes, and the difference between them is the point:
#   0  every file validates
#   1  a file is invalid — the AI's answer does not meet the contract
#   2  the check could not be made — no step, an unknown step, a missing file,
#      a schema that does not parse, or a validator that could not be reached
#
# A validator that answers 0 when it validated nothing reads exactly like one
# that validated everything, so the refusals are a separate code and every one
# of them names the thing it could not find.
#
# The validator itself is a seam: BRIEFS_AJV overrides it, so a machine with the
# tool installed does not pay for a download and a test can point it elsewhere.
# BRIEFS_SCHEMAS is the second seam, and it is what lets the driver call this
# rather than re-deriving it: the driver resolves its own schemas directory
# (DRIVER_SCHEMAS, which a fixture points at a temp dir), and a validator that
# could only read the schemas beside itself would have been unusable from there.
set -uo pipefail

BRIEFS="$(cd "$(dirname "$0")" && pwd)"
SCHEMAS=${BRIEFS_SCHEMAS:-"$BRIEFS/schemas"}
AJV=${BRIEFS_AJV:-"npx --yes ajv-cli@5"}

die() { printf 'briefs/validate.sh: %s\n' "$1" >&2; exit 2; }

[ $# -ge 2 ] || die "usage: validate.sh <step> <answer.json> [<answer.json>…]"

step=$1; shift
schema="$SCHEMAS/$step.json"
[ -f "$schema" ] || die "unknown step '$step' — no contract at $schema (have: $(ls "$SCHEMAS" 2>/dev/null | sed 's/\.json$//' | tr '\n' ' '))"

for f in "$@"; do
  [ -f "$f" ] || die "no such answer file: $f"
done

rc=0
for f in "$@"; do
  # Draft is pinned. Left to the tool's default it moves with the tool's major
  # version, and a schema silently read under a different draft is a contract
  # that changed without anybody editing it.
  out=$($AJV validate --spec=draft7 -s "$schema" -d "$f" 2>&1); arc=$?
  case "$arc" in
    0) : ;;
    # ajv-cli exits 1 for data that does not meet the schema and 2 for anything
    # that stopped it reading one — a schema that does not parse, a missing file.
    # That second class is exactly this script's own exit 2, and collapsing it into
    # 1 would report "the AI answered wrongly" about an answer nothing ever looked
    # at. A schema shipped with a syntax error is the case that matters: it used to
    # make its step the one step with no validation, and said so nowhere.
    #
    # AND EXIT 1 IS NOT ONLY AJV'S. `$AJV` is a LAUNCHER by default — `npx --yes
    # ajv-cli@5` — and npm exits 1 for an unfetchable package, an unreachable
    # registry and a cold cache under `only-if-cached` alike. Measured: all three
    # come back as 1, identical to "the data is invalid", so a machine that cannot
    # GET the validator was reporting the model's answer as wrong. ajv names the
    # data file on its own verdict line and npm never does, so that line is what
    # separates a verdict from a failure to reach one.
    1) printf '%s\n' "$out" >&2
       if printf '%s\n' "$out" | grep -qF "$f invalid"; then
         [ "$rc" -eq 2 ] || rc=1
       else
         rc=2
       fi ;;
    *) printf '%s\n' "$out" >&2; rc=2 ;;
  esac
done
exit "$rc"
