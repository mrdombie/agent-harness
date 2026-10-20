#!/usr/bin/env bash
# Refuses a skill that hands the operator a picture without the critic's picture mode, or a critic that lost it.
# Usage: check-picture-mode.sh [kit-root]   (default: this kit)
# Exit 0: every sender names picture mode and KIT: MATCH, and the critic defines the mode. Exit 1: names each gap.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -d "$ROOT" ] || { echo "check-picture-mode: no such kit root: $ROOT" >&2; exit 2; }

# What "hands the operator a picture" looks like in a skill's own words.
SENDS='artifact (url|link)|concept link|url, not a screenshot|claude\.ai/'
fail=0 senders=0

while IFS= read -r f; do
  grep -qiE "$SENDS" "$f" || continue
  senders=$((senders + 1))
  rel="${f#"$ROOT"/}"
  grep -qi 'picture mode' "$f" || { echo "check-picture-mode: $rel hands the operator a picture and never runs the critic's picture mode" >&2; fail=1; }
  grep -q 'KIT: MATCH' "$f" || { echo "check-picture-mode: $rel hands the operator a picture and never says it waits for KIT: MATCH" >&2; fail=1; }
  grep -q 'picture-rules.md' "$f" || { echo "check-picture-mode: $rel hands the operator a picture and never holds it to shared/picture-rules.md (evidence regions, real data)" >&2; fail=1; }
done < <(find "$ROOT/skills" "$ROOT/shared" "$ROOT/briefs" -name '*.md' -type f 2>/dev/null | sort)

CRITIC="$ROOT/agents/design-critic.md"
if [ ! -f "$CRITIC" ]; then
  echo "check-picture-mode: agents/design-critic.md is missing" >&2; fail=1
else
  for want in '**Picture mode**' 'KIT: MATCH' 'KIT: DRIFT' 'design.reference' 'In picture mode, lead with this block' 'REAL DATA: COVERED' 'duplicate-names' 'longest-names' 'scrolled' 'data-evidence-shot'; do
    grep -qF -- "$want" "$CRITIC" || { echo "check-picture-mode: design-critic.md lost its picture mode — no '$want'" >&2; fail=1; }
  done
fi

PRULES="$ROOT/shared/picture-rules.md"
if [ ! -f "$PRULES" ]; then echo "check-picture-mode: shared/picture-rules.md is missing" >&2; fail=1
else
  for want in 'data-evidence-shot' 'data-evidence-viewport' 'data-real-data' 'duplicate-names' 'picture-evidence.py" lint'; do
    grep -qF -- "$want" "$PRULES" || { echo "check-picture-mode: shared/picture-rules.md no longer states '$want'" >&2; fail=1; }
  done
fi

RULES="$ROOT/rules/standing-rules.md"
grep -qi 'picture mode' "$RULES" 2>/dev/null || { echo "check-picture-mode: rules/standing-rules.md no longer states the picture-mode rule" >&2; fail=1; }

[ "$fail" -eq 0 ] && echo "check-picture-mode: ok ($senders skill file(s) hand the operator a picture, all gated on KIT: MATCH)"
exit "$fail"
