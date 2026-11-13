#!/usr/bin/env bash
# paperwork-off.test.sh — three retired steps stay retired: the PR body's Lesson section
# (lessons off, owner 2026-11-02), the UI-Gate trailer (the front-end gate off, the
# same day) and the .deploy-trigger stamp (no project reads it; owner 2026-11-09). Nothing a builder runs or reads may write or require either again. The
# driver's own ship body is checked on a real run in quick-route.test.sh; this reads
# every live source, so a step brought back anywhere fails here by file and line.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../.." && pwd)"
FAILED=0
ok()   { printf 'OK       %s\n' "$1"; }
bad()  { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/paperwork-off-XXXXXX"); on_exit_keep_status 'rm -rf "$TMP"'

# live_sources <kit root> — every file a builder runs or reads: skills, briefs, hooks,
# the driver and its steps, templates, shared instructions, rules and agents. Tests and
# reference/ (the retired copies, never loaded) are not live.
live_sources() {
  local k="$1"
  { find "$k/skills" "$k/briefs" "$k/templates" "$k/shared" "$k/rules" "$k/agents" -type f 2>/dev/null
    find "$k/hooks" "$k/driver" -type f \( -name '*.sh' -o -name 'build-ticket' \) 2>/dev/null; } \
    | grep -vE '(\.test\.sh$|/tests/|/fixtures/|/examples/)' | sort
}
# asks <kit root> <pattern> — each non-comment line matching the pattern, as file:line.
# A comment is one `#` and a space; `## Lesson` is a heading in a body or a skill, and counts.
asks() {
  local k="$1" re="$2" f
  live_sources "$k" | while IFS= read -r f; do
    grep -nE -- "$re" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#([[:space:]!]|$)' | sed "s#^#${f#"$k"/}:#"
  done
}
UIGATE='UI-Gate:'
DEPLOY='(check:deploy-trigger|bump-deploy-trigger|\.deploy-trigger)'
LESSON='(^|[^a-z])(## Lesson|[Ll]esson:|ships a lesson|lesson section)'

echo "--- nothing live writes or requires a UI-Gate trailer ---"
want "no line outside a comment" "" "$(asks "$KIT" "$UIGATE")"
echo "--- nothing live writes or requires a Lesson section ---"
want "no line outside a comment" "" "$(asks "$KIT" "$LESSON")"
echo "--- nothing live runs or writes the .deploy-trigger stamp ---"
want "no line outside a comment" "" "$(asks "$KIT" "$DEPLOY")"
want "the ship body names no Lesson heading" "0" "$(grep -c '## Lesson' "$KIT/driver/steps/ship.sh")"

echo "--- plant the step back: each case goes red ---"
mkdir -p "$TMP/kit/driver/steps" "$TMP/kit/skills/finish" "$TMP/kit/hooks"
printf '#!/usr/bin/env bash\nbody="## Summary\n## Lesson\n<what this teaches>"\n' > "$TMP/kit/driver/steps/ship.sh"
[ -n "$(asks "$TMP/kit" "$LESSON")" ] && ok "planted: ship writes a Lesson heading → caught" || bad "planted: a Lesson heading in ship.sh went unseen"
printf 'git commit --allow-empty -m "chore: ui-gate" -m "UI-Gate: SHIP (agent) <fp>"\n' > "$TMP/kit/skills/finish/SKILL.md"
[ -n "$(asks "$TMP/kit" "$UIGATE")" ] && ok "planted: finish writes a UI-Gate trailer → caught" || bad "planted: a UI-Gate trailer in finish went unseen"
printf '#!/usr/bin/env bash\ngit log --format=%%B | grep -q "UI-Gate:" || exit 2\n' > "$TMP/kit/hooks/pre-push-gate.sh"
want_n=$(asks "$TMP/kit" "$UIGATE" | grep -c 'hooks/pre-push-gate.sh')
want "planted: a hook requiring the trailer → caught" "1" "$want_n"
printf 'if ! npm run check:deploy-trigger; then\n  sh scripts/bump-deploy-trigger.sh\nfi\n' > "$TMP/kit/skills/finish/SKILL.md"
[ -n "$(asks "$TMP/kit" "$DEPLOY")" ] && ok "planted: finish runs the deploy-trigger stamp → caught" || bad "planted: the deploy-trigger step in finish went unseen"
printf 'git add .deploy-trigger\n' > "$TMP/kit/skills/finish/SKILL.md"
[ -n "$(asks "$TMP/kit" "$DEPLOY")" ] && ok "planted: finish stages a .deploy-trigger file → caught" || bad "planted: staging .deploy-trigger went unseen"
printf '#!/usr/bin/env bash\n# the UI-Gate: trailer was retired on 2026-11-02\n' > "$TMP/kit/hooks/history.sh"
want "a comment naming the retired trailer is history, not a step" "0" "$(asks "$TMP/kit" "$UIGATE" | grep -c 'hooks/history.sh')"

suite_end "$FAILED"
