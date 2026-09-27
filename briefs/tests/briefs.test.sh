#!/usr/bin/env bash
# briefs.test.sh — the briefs themselves: one per step, thin, and pointing at a
# skill rather than repeating one.
#
# The rule these assertions exist for: Superpowers is CALLED, never copied. A
# brief carries this project's facts, which skill to invoke, and the JSON the
# driver checks. A copy of a skill's content drifts and loses every upgrade, so
# the size ceiling and the copy probe are both here.
set -uo pipefail
BRIEFS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FACTS="$BRIEFS/facts.json"

FAILED=0
ok()  { printf 'OK       %s\n' "$1"; }
bad() { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }

# The per-step word ceiling. The epic's budget is 3,000 words per step; this is
# well inside it deliberately, because the failure being guarded against is a
# brief that GROWS by absorbing a skill's content, and 3,000 would not notice.
CEILING=900

[ -f "$FACTS" ] || { printf 'MISMATCH no briefs/facts.json — the driver has nothing to substitute from\n'; exit 1; }
jq -e . "$FACTS" >/dev/null 2>&1 || { printf 'MISMATCH briefs/facts.json does not parse\n'; exit 1; }

steps=$(jq -r '.steps | keys[]' "$FACTS")
[ -n "$steps" ] || { printf 'MISMATCH facts.json declares no steps — refusing to report clean\n'; exit 1; }

# Every schema has a step and every step has a schema. Either half missing is a
# brief the driver cannot validate, or a contract nothing is written against.
for f in "$BRIEFS/schemas"/*.json; do
  s=$(basename "$f" .json)
  jq -e --arg s "$s" '.steps[$s]' "$FACTS" >/dev/null 2>&1 \
    && ok "schemas/$s.json has a step in facts.json" \
    || bad "schemas/$s.json has no step in facts.json"
done

allow=$(jq -r '.skills | keys[]' "$FACTS")

for step in $steps; do
  brief="$BRIEFS/$step.md"
  if [ ! -f "$brief" ]; then bad "$step has no brief at $step.md"; continue; fi
  [ -f "$BRIEFS/schemas/$step.json" ] && ok "$step has a schema" || bad "$step has no schemas/$step.json"

  words=$(wc -w < "$brief" | tr -d ' ')
  if [ "$words" -le "$CEILING" ]; then ok "$step.md is $words words (ceiling $CEILING)"
  else bad "$step.md is $words words — over the $CEILING ceiling, which is what absorbing a skill's content looks like"; fi

  # --- the skill it invokes ---------------------------------------------------
  named=$(grep -oE 'superpowers:[a-z][a-z-]*' "$brief" | sort -u)
  declared=$(jq -r --arg s "$step" '.steps[$s].skills[]' "$FACTS" | sort -u)
  [ -n "$named" ] && ok "$step.md names a skill" || bad "$step.md names no superpowers skill"
  want "$step.md names exactly its declared skills" "$declared" "$named"
  for k in $named; do
    printf '%s\n' "$allow" | grep -qx "$k" \
      && ok "  $k is in the allowlist" \
      || bad "  $step.md names $k, which facts.json does not list under .skills"
  done
  grep -q 'superpowers:brainstorming' "$brief" \
    && bad "$step.md names brainstorming — it waits on a person, so an unattended step cannot invoke it" \
    || ok "$step.md does not reach for brainstorming"

  # --- the contract it returns against ---------------------------------------
  grep -qF "schemas/$step.json" "$brief" \
    && ok "$step.md names its contract" \
    || bad "$step.md never names schemas/$step.json"

  # --- placeholders: the only coupling with the driver ------------------------
  used=$(grep -oE '\{\{[^}]*\}\}' "$brief" | sed 's/^{{//; s/}}$//' | sort -u)
  known=$(jq -r --arg s "$step" '.steps[$s].facts | keys[]' "$FACTS" | sort -u)
  for p in $used; do
    case "$p" in
      *[!A-Z0-9_]*) bad "$step.md has placeholder {{$p}} — only UPPER_SNAKE is substituted, so this one ships literally" ;;
      *) printf '%s\n' "$known" | grep -qx "$p" \
           && ok "  {{$p}} is declared" \
           || bad "  $step.md uses {{$p}} and facts.json never tells the driver to substitute it" ;;
    esac
  done
  for p in $known; do
    printf '%s\n' "$used" | grep -qx "$p" \
      && ok "  fact $p is used" \
      || bad "  facts.json declares $p for $step and the brief never uses it"
  done
done

# --- the copy probe ------------------------------------------------------------
# A real measurement of copying: the longest run of words a brief shares with a
# skill it names. Twelve consecutive words is well past coincidence in prose.
#
# It needs a superpowers checkout. When there is none it says SKIP and why — a
# probe that reports nothing found when it could not look is the third meaning of
# a zero, and the one that reads as clean.
SP="${SUPERPOWERS_DIR:-}"
if [ -z "$SP" ]; then
  SP=$(ls -d "$HOME"/.claude/plugins/cache/*/superpowers/*/skills 2>/dev/null | sort -V | tail -1)
fi
if [ -z "$SP" ] || [ ! -d "$SP" ]; then
  echo "SKIP     copy probe — no superpowers checkout found (set SUPERPOWERS_DIR to run it)"
else
  for step in $steps; do
    brief="$BRIEFS/$step.md"
    [ -f "$brief" ] || continue
    for k in $(grep -oE 'superpowers:[a-z][a-z-]*' "$brief" | sort -u); do
      sk="$SP/${k#superpowers:}/SKILL.md"
      [ -f "$sk" ] || { bad "$step.md names $k and $sk does not exist"; continue; }
      run=$(BRIEF="$brief" SKILL="$sk" python3 - <<'PY'
import os, re
def words(p):
    t = open(p, encoding='utf-8').read().lower()
    return re.findall(r"[a-z0-9']+", t)
b, s = words(os.environ['BRIEF']), words(os.environ['SKILL'])
N = 12
grams = {tuple(s[i:i+N]) for i in range(len(s)-N+1)}
hit = next((' '.join(b[i:i+N]) for i in range(len(b)-N+1) if tuple(b[i:i+N]) in grams), '')
print(hit)
PY
)
      if [ -z "$run" ]; then ok "$step.md shares no 12-word run with $k"
      else bad "$step.md copies $k: \"$run\""; fi
    done
  done
fi

[ "$FAILED" = 0 ] && echo "briefs: all good"
exit "$FAILED"
