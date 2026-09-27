#!/usr/bin/env bash
# schemas.test.sh — every step's JSON contract, against a valid and an invalid
# example. The schema is what the driver validates a step's answer with, so an
# unvalidated schema is a contract nobody has read.
#
# The suite is driven by what is on disk: it enumerates briefs/schemas/*.json and
# demands, per step, at least one valid example and at least one invalid one. That
# demand is the point. A loop over examples alone reports a clean run when a step
# has no examples at all, which is the same output as a step that passes — and a
# zero from a strictness probe means clean, suppressed, or never ran.
set -uo pipefail
BRIEFS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V="$BRIEFS/validate.sh"

FAILED=0
ok()  { printf 'OK       %s\n' "$1"; }
bad() { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }
want_in() {
  if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"
  else bad "$1 — no '$2' in: $(printf '%s' "$3" | tr '\n' '|')"; fi
}

[ -x "$V" ] || { printf 'MISMATCH validate.sh is missing or not executable: %s\n' "$V"; exit 1; }

steps=$(ls "$BRIEFS/schemas"/*.json 2>/dev/null | while read -r f; do basename "$f" .json; done)
[ -n "$steps" ] || { printf 'MISMATCH no schemas in %s/schemas — refusing to report clean\n' "$BRIEFS"; exit 1; }

# The loop below is schema-driven, so an example whose step has NO schema is
# invisible to it: nothing validates the file and nothing says so. Assert the
# other direction first, by name.
for f in "$BRIEFS/examples"/*.json; do
  ex_step=$(basename "$f"); ex_step=${ex_step%%.*}
  if [ -f "$BRIEFS/schemas/$ex_step.json" ]; then :
  else bad "$(basename "$f") names step '$ex_step' and there is no schemas/$ex_step.json"; fi
done

# The draft pin, which has no behavioural shadow and so has to be read off the
# file. validate.sh passes --spec=draft7 explicitly, so that flag is the
# load-bearing half at runtime; this asserts the schema SAYS the same thing, for
# the next reader and for any other tool pointed at it.
for f in "$BRIEFS/schemas"/*.json; do
  s=$(basename "$f" .json)
  want "schemas/$s.json pins its draft" \
    "http://json-schema.org/draft-07/schema#" "$(jq -r '."$schema" // "(none)"' "$f")"
done

for step in $steps; do
  valid=$(ls "$BRIEFS/examples/$step".valid*.json 2>/dev/null)
  invalid=$(ls "$BRIEFS/examples/$step".invalid-*.json 2>/dev/null)

  # Both halves are asserted by NAME. A step with no invalid example proves
  # nothing about the schema's strictness, and silence would read as a pass.
  if [ -z "$valid" ]; then bad "$step has no .valid example"; else
    for f in $valid; do
      out=$("$V" "$step" "$f" 2>&1); rc=$?
      want "$step accepts $(basename "$f")" 0 "$rc"
      [ "$rc" = 0 ] || printf '         %s\n' "$out"
    done
  fi

  # Two invalid examples every step must carry, named individually. Left to the
  # generic "has at least one invalid example" demand, four of the five schemas
  # could drop `skills` from `required` and both suites stayed green — measured
  # by planting it. The driver cross-checks `skills` against the run log, so a
  # step whose contract stops requiring it takes that check down silently.
  for must in no-skills unknown-key; do
    [ -f "$BRIEFS/examples/$step.invalid-$must.json" ] \
      && ok "$step carries an invalid-$must example" \
      || bad "$step has no examples/$step.invalid-$must.json — nothing pins that half of the contract"
  done

  if [ -z "$invalid" ]; then bad "$step has no .invalid- example"; else
    for f in $invalid; do
      # rc is captured on its own line. Read inside the call — `want "… $(basename
      # "$f")" 1 "$?"` — the command substitution in the label runs FIRST and
      # leaves its own 0 in $?, so every rejection case reported a pass.
      "$V" "$step" "$f" >/dev/null 2>&1; rc=$?
      want "$step rejects $(basename "$f")" 1 "$rc"
    done
  fi
done

# --- the refusals. Exit 2, distinct from 1, so the driver can tell "this answer
# is wrong" from "I could not check the answer at all". A validator that answers
# 0 when it validated nothing is worse than no validator.
out=$("$V" 2>&1); rc=$?; want "no arguments refuses" 2 "$rc"
want_in "  and says how to call it" "usage:" "$out"

out=$("$V" nosuchstep "$BRIEFS/examples"/*.valid*.json 2>&1); rc=$?; want "unknown step refuses" 2 "$rc"
want_in "  and names the step"      "nosuchstep" "$out"

out=$("$V" "$(printf '%s' "$steps" | head -1)" "$BRIEFS/does-not-exist.json" 2>&1); rc=$?; want "missing data file refuses" 2 "$rc"
want_in "  and names the file"      "does-not-exist.json" "$out"

# BRIEFS_SCHEMAS, the seam the driver calls through. Without it the driver would
# have had to re-derive the check against its own DRIVER_SCHEMAS, which is how the
# half a validator got written in the first place.
TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT
mkdir -p "$TD/schemas"
first=$(printf '%s' "$steps" | head -1)
cp "$BRIEFS/schemas/$first.json" "$TD/schemas/$first.json"
BRIEFS_SCHEMAS="$TD/schemas" "$V" "$first" "$BRIEFS/examples/$first".valid.json >/dev/null 2>&1; rc=$?
want "BRIEFS_SCHEMAS is honoured" 0 "$rc"
printf '{"required": [\n' > "$TD/schemas/$first.json"
BRIEFS_SCHEMAS="$TD/schemas" "$V" "$first" "$BRIEFS/examples/$first".valid.json >/dev/null 2>&1; rc=$?
want "a schema that does not parse is a 2, not a 1" 2 "$rc"

# A LAUNCHER'S EXIT 1 IS NOT AJV'S EXIT 1. `npx --yes ajv-cli@5` exits 1 for an
# unfetchable package, an unreachable registry and a cold `only-if-cached` alike —
# measured, all three identical to "the data is invalid". So a machine that could
# not GET the validator was blaming the model for an answer nothing read. ajv names
# the data file on its verdict line; npm never does.
printf '#!/bin/sh\necho "npm error code ECONNREFUSED" >&2\nexit 1\n' > "$TD/nofetch"
chmod +x "$TD/nofetch"
BRIEFS_AJV="$TD/nofetch" "$V" "$first" "$BRIEFS/examples/$first".valid.json >/dev/null 2>&1; rc=$?
want "a validator that could not be reached is a 2, not a 1" 2 "$rc"
printf '#!/bin/sh\nfor a; do case "$a" in *.json) last=$a ;; esac; done\necho "$last invalid"\nexit 1\n' > "$TD/reject"
chmod +x "$TD/reject"
BRIEFS_AJV="$TD/reject" "$V" "$first" "$BRIEFS/examples/$first".valid.json >/dev/null 2>&1; rc=$?
want "and a real verdict is still a 1"                        1 "$rc"

# Several files in one call: 2 outranks 1 in either order, because "the answer is
# wrong" must never be said about a batch part of which was never checked. Nothing
# pinned this and a bare rc=1 passed the whole suite.
BRIEFS_SCHEMAS="$BRIEFS/schemas" "$V" "$first" \
  "$BRIEFS/examples/$first".valid.json "$BRIEFS/examples/$first".invalid-unknown-key.json >/dev/null 2>&1; rc=$?
want "valid + invalid is 1"        1 "$rc"
cp "$BRIEFS/schemas/$first.json" "$TD/schemas/$first.json"
printf '#!/bin/sh\nfor a; do case "$a" in *invalid-unknown-key.json) echo "$a invalid" >&2; exit 1 ;; esac; done\nexit 2\n' > "$TD/mixed"
chmod +x "$TD/mixed"
BRIEFS_AJV="$TD/mixed" "$V" "$first" \
  "$BRIEFS/examples/$first".invalid-unknown-key.json "$BRIEFS/examples/$first".valid.json >/dev/null 2>&1; rc=$?
want "a 1 then a 2 is still a 2"   2 "$rc"

[ "$FAILED" = 0 ] && echo "briefs/schemas: all good"
exit "$FAILED"
