#!/usr/bin/env bash
# signoff-last.test.sh — sign-off comes last, and every brief a builder works from
# says so in its first line: the claim and finish skills (the first line after the
# front matter) carry shared/signoff-last.md word for word. The spawned prompt and
# the repair brief are pinned in spawn-claim.test.sh and repair-watch.test.sh.
# Run: bash "$0"
set -u
cd "$(dirname "$0")/.." || exit 2
RULE=$(head -1 shared/signoff-last.md 2>/dev/null)
fail=0
[ -n "$RULE" ] || { echo "  FAIL — shared/signoff-last.md has no rule"; exit 1; }
case "$RULE" in *pixel-change-after-signoff:*) echo "  ok   — the rule names the trailer" ;;
  *) echo "  FAIL — the rule does not name the pixel-change-after-signoff trailer"; fail=1 ;; esac
for s in skills/claim/SKILL.md skills/finish/SKILL.md; do
  first=$(awk 'NR == 1 && /^---$/ { fm = 1; next } fm && /^---$/ { fm = 0; next } fm { next } NF { print; exit }' "$s")
  if [ "$first" = "$RULE" ]; then echo "  ok   — $s leads with it"
  else echo "  FAIL — $s leads with: $(printf '%s' "$first" | cut -c1-80)"; fail=1; fi
done
exit "$fail"
