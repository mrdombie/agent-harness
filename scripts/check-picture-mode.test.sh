#!/usr/bin/env bash
# Fixture test for check-picture-mode.sh: the real kit passes, and each planted absence is refused by name.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
SUT="${SUT:-$HERE/check-picture-mode.sh}"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# A copy per case: plants never touch the real tree.
fresh() {
  local d; d="$(mktemp -d)"
  cp -R "$KIT/skills" "$KIT/agents" "$KIT/rules" "$d/"
  [ -d "$KIT/shared" ] && cp -R "$KIT/shared" "$d/"
  [ -d "$KIT/briefs" ] && cp -R "$KIT/briefs" "$d/"
  printf '%s' "$d"
}
run() { bash "$SUT" "$1" 2>&1; }

out="$(run "$KIT")"; rc=$?
[ $rc -eq 0 ] && ok "the kit as shipped passes" || bad "the kit as shipped is refused: $out"
n="$(printf '%s' "$out" | sed -n 's/.*ok (\([0-9]*\) skill.*/\1/p')"
[ "${n:-0}" -ge 3 ] && ok "it finds the senders ($n)" || bad "it found ${n:-0} senders; auto, bug and needsme all hand the operator a picture"

# Plant the absence in each real sender: every picture-mode line deleted.
for s in auto bug needsme; do
  d="$(fresh)"; f="$d/skills/$s/SKILL.md"
  grep -viE 'picture mode|KIT: MATCH' "$f" > "$f.new" && mv "$f.new" "$f"
  grep -qi 'picture mode' "$f" && bad "plant did not land in $s" && continue
  out="$(run "$d")"; rc=$?
  [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "skills/$s/SKILL.md" && ok "$s without picture mode is refused, named" || bad "$s without picture mode passed: $out"
  rm -rf "$d"
done

# A sibling: a new skill that sends a concept link and never runs the critic.
d="$(fresh)"; mkdir -p "$d/skills/sketch"
printf '# sketch\n\nDraw the concept and post the artifact URL on the ticket for the operator.\n' > "$d/skills/sketch/SKILL.md"
out="$(run "$d")"; rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'skills/sketch/SKILL.md' && ok "a new sender without picture mode is refused" || bad "a new sender passed: $out"
rm -rf "$d"

# The critic loses its picture-mode section.
d="$(fresh)"; c="$d/agents/design-critic.md"
awk '/^\*\*Picture mode\*\*/{skip=1} skip&&/^`KIT: DRIFT` is a/{skip=0; next} !skip' "$c" > "$c.new" && mv "$c.new" "$c"
grep -qF '**Picture mode**' "$c" && bad "critic plant did not land"
out="$(run "$d")"; rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'design-critic.md lost its picture mode' && ok "a critic without picture mode is refused" || bad "a critic without picture mode passed: $out"
rm -rf "$d"

# The critic loses the output block that carries the verdict.
d="$(fresh)"; c="$d/agents/design-critic.md"
grep -vF 'In picture mode, lead with this block' "$c" > "$c.new" && mv "$c.new" "$c"
out="$(run "$d")"; rc=$?
[ $rc -eq 1 ] && ok "a critic without the picture-mode output block is refused" || bad "a critic without the output block passed: $out"
rm -rf "$d"

# Real data: each sender loses its hold on the picture rules; the critic loses the real-data grade.
for s in auto bug needsme; do
  d="$(fresh)"; f="$d/skills/$s/SKILL.md"
  grep -vF 'picture-rules.md' "$f" > "$f.new" && mv "$f.new" "$f"
  out="$(run "$d")"; rc=$?
  [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "skills/$s/SKILL.md.*picture-rules.md" && ok "$s without the real-data picture rules is refused" || bad "$s without picture rules passed: $out"
  rm -rf "$d"
done
d="$(fresh)"; c="$d/agents/design-critic.md"
grep -vF 'REAL DATA: COVERED' "$c" > "$c.new" && mv "$c.new" "$c"
out="$(run "$d")"; rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q "no 'REAL DATA: COVERED'" && ok "a critic that no longer grades real data is refused" || bad "a critic without the real-data grade passed: $out"
rm -rf "$d"
d="$(fresh)"; rm "$d/shared/picture-rules.md"
out="$(run "$d")"; rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'picture-rules.md is missing' && ok "the picture rules removed is refused" || bad "no picture rules passed: $out"
rm -rf "$d"

# The standing rule is deleted.
d="$(fresh)"; r="$d/rules/standing-rules.md"
grep -vi 'picture mode' "$r" > "$r.new" && mv "$r.new" "$r"
out="$(run "$d")"; rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'standing-rules.md' && ok "rules without the picture-mode line are refused" || bad "rules without the line passed: $out"
rm -rf "$d"

# A skill that never sends a picture is not asked for picture mode.
d="$(fresh)"; mkdir -p "$d/skills/plain"
printf '# plain\n\nList the queue.\n' > "$d/skills/plain/SKILL.md"
out="$(run "$d")"; rc=$?
[ $rc -eq 0 ] && ok "a skill that sends no picture is left alone" || bad "a non-sender was flagged: $out"
rm -rf "$d"

suite_end "$fail"
