#!/usr/bin/env bash
# signoff-last.test.sh — sign-off comes last, and every brief a builder works from
# says so in its first line: the claim and finish skills (the first line after the
# front matter) and every driver step brief briefs/facts.json declares carry
# shared/signoff-last.md word for word; the review brief carries its reviewer's
# form (a pixel finding on a signed PR is a follow-up). The spawned prompt and the
# repair brief are pinned in spawn-claim.test.sh and repair-watch.test.sh.
# Run: bash "$0"
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
cd "$(dirname "$0")/.." || exit 2
RULE=$(head -1 shared/signoff-last.md 2>/dev/null)
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }
[ -n "$RULE" ] || { bad "shared/signoff-last.md has no rule"; exit 1; }
case "$RULE" in *pixel-change-after-signoff:*) ok "the rule names the trailer" ;;
  *) bad "the rule does not name the pixel-change-after-signoff trailer" ;; esac
for s in skills/claim/SKILL.md skills/finish/SKILL.md; do
  first=$(awk 'NR == 1 && /^---$/ { fm = 1; next } fm && /^---$/ { fm = 0; next } fm { next } NF { print; exit }' "$s")
  [ "$first" = "$RULE" ] && ok "$s leads with it" || bad "$s leads with: $(printf '%s' "$first" | cut -c1-80)"
done
steps=$(jq -r '.steps | keys[]' briefs/facts.json 2>/dev/null)
[ -n "$steps" ] || bad "briefs/facts.json lists no steps"
for st in $steps; do
  b="briefs/$st.md"; first=$(head -1 "$b" 2>/dev/null)
  if [ "$st" = review ]; then
    case "$first" in "**Sign-off comes last:**"*follow-up*pixel-change-after-signoff:*) ok "$b leads with the reviewer's form" ;;
      *) bad "$b leads with: $(printf '%s' "$first" | cut -c1-80)" ;; esac
  else
    [ "$first" = "$RULE" ] && ok "$b leads with it" || bad "$b leads with: $(printf '%s' "$first" | cut -c1-80)"
  fi
done
suite_end "$fail"
