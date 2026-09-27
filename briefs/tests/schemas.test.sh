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

[ "$FAILED" = 0 ] && echo "briefs/schemas: all good"
exit "$FAILED"
