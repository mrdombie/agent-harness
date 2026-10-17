#!/usr/bin/env bash
# Fixture test for check-first-look.sh: real critic-shaped answers in, exit code and reason out.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SUT:-$HERE/check-first-look.sh}"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

full() { cat <<EOF
**VERDICT: $1** — reason.

**First look:**
\`\`\`
For: $2
Happening: $3
Next: $4
\`\`\`
EOF
}
run() { printf '%s\n' "$1" | bash "$SUT" - 2>&1; }

out="$(run "$(full SHIP 'Writing a post.' 'A first draft is arriving.' 'Send it from the bar at the bottom.')")"; rc=$?
[ $rc -eq 0 ] && ok "three answers + SHIP passes" || bad "three answers + SHIP refused: $out"

out="$(run "$(full SHIP 'Writing a post.' 'CANNOT TELL' 'Send it.')")"; rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'Happening' && ok "SHIP over CANNOT TELL is refused, names it" || bad "SHIP over CANNOT TELL passed: $out"

out="$(run "$(full SLOP 'Writing a post.' 'CANNOT TELL' 'Send it.')")"; rc=$?
[ $rc -eq 0 ] && ok "SLOP over CANNOT TELL passes" || bad "SLOP over CANNOT TELL refused: $out"

# Plant the absence: delete each line in turn, the whole block, and an empty answer.
for gone in For Happening Next; do
  txt="$(full SHIP a b c | grep -v "^${gone}:")"
  out="$(run "$txt")"; rc=$?
  [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "$gone" && ok "missing $gone refused" || bad "missing $gone passed: $out"
done
out="$(run '**VERDICT: SHIP** — looks great.')"; rc=$?
[ $rc -eq 1 ] && ok "no first-look block refused" || bad "no first-look block passed: $out"
out="$(run "$(full SHIP 'Writing a post.' '' 'Send it.')")"; rc=$?
[ $rc -eq 1 ] && ok "empty answer refused" || bad "empty answer passed: $out"
out="$(run "$(full SHIP 'Writing a post.' '…' 'Send it.')")"; rc=$?
[ $rc -eq 1 ] && ok "template ellipsis refused" || bad "template ellipsis passed: $out"

# The critic's own contract still asks for the block this check reads.
CRITIC="$HERE/../agents/design-critic.md"
for label in For Happening Next; do
  grep -qE "^${label}: …$" "$CRITIC" && ok "critic asks for $label" || bad "critic no longer asks for $label"
done
# finish runs the check on the critic's answer.
grep -q 'check-first-look.sh' "$HERE/../skills/finish/SKILL.md" && ok "finish runs the check" || bad "finish does not run check-first-look.sh"

# The step driver runs the check before recording a design-critic verdict.
grep -q 'check-first-look.sh' "$HERE/../driver/push-requires.sh" && ok "the driver runs the check" || bad "driver/push-requires.sh does not run check-first-look.sh"

exit $fail
