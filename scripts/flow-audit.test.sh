#!/usr/bin/env bash
# flow-audit.sh — the cartographer's brief is blind: the job line and the
# taxonomy, nothing from the repo. A brief that carries a path hands the
# cartographer the code's blind spots, and the audit then only confirms what
# is already built.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
KIT="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$KIT/scripts/flow-audit.sh"
TAX="$KIT/skills/flows/TAXONOMY.md"
AGENT="$KIT/agents/flow-cartographer.md"
fail=0
ok(){ echo "  ok   — $1"; }; bad(){ echo "  FAIL — $1"; fail=1; }

# A consuming repo with a story and app code in it, run from inside, so a
# brief that reached for repo files would find some.
REPO=$(mktemp -d); on_exit_keep_status 'rm -rf "$REPO"'
mkdir -p "$REPO/apps/web/src/stories"
printf 'export const Queue = {}\n' > "$REPO/apps/web/src/stories/Queue.stories.tsx"

echo "--- the cartographer brief is the job line plus the taxonomy, nothing else ---"
JOB="Clear the compliance queue"
out=$(cd "$REPO" && bash "$SUT" brief cartographer --job "$JOB" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "exits 0" || bad "exit $rc, want 0: $out"
want=$(printf "The screen's job: %s\n\n" "$JOB"; cat "$TAX" 2>/dev/null)
[ -f "$TAX" ] && [ "$out" = "$want" ] && ok "brief is exactly the job line and TAXONOMY.md" \
  || bad "brief is not exactly job line + TAXONOMY.md"
printf '%s' "$out" | grep -qF "$JOB" && ok "carries the job line" || bad "job line missing"
printf '%s' "$out" | grep -qF '## Axis 1 — ENTRY' && ok "carries the taxonomy" || bad "taxonomy missing"
for leak in 'skills/' 'apps/' 'stories' "$REPO"; do
  printf '%s' "$out" | grep -qF "$leak" && bad "brief leaks '$leak'" || ok "no '$leak' in the brief"
done

echo "--- a job line holding a path, file name or URL is refused ---"
for j in "fix apps/web/page.tsx" "tidy page.tsx" "see https://example.com/x" "check www.example.com"; do
  out=$(bash "$SUT" brief cartographer --job "$j" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && ok "exit 2 for: $j" || bad "exit $rc, want 2 for: $j"
  printf '%s' "$out" | grep -qF '## Axis' && bad "refusal still printed the brief for: $j" || ok "no brief for: $j"
done
out=$(bash "$SUT" brief cartographer --job "fix apps/web/page.tsx" 2>&1)
printf '%s' "$out" | grep -qF 'apps/web/page.tsx' && ok "the refusal names the path" || bad "refusal does not name the path: $out"
out=$(bash "$SUT" brief cartographer 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "no --job is exit 2" || bad "no --job: exit $rc, want 2"
out=$(bash "$SUT" brief cartographer --job "$JOB" --story apps/web/src/stories/Queue.stories.tsx 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "a --story argument is refused, never appended" || bad "--story: exit $rc, want 2"

echo "--- the cartographer agent has no tools to open the repo ---"
fm=$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$AGENT" 2>/dev/null)
[ -n "$fm" ] && ok "agent has frontmatter" || bad "no frontmatter in agents/flow-cartographer.md"
tools=$(printf '%s\n' "$fm" | sed -n 's/^tools:[[:space:]]*//p')
printf '%s\n' "$fm" | grep -q '^tools:' && ok "tools is declared (an absent list inherits every tool)" \
  || bad "tools is not declared — the agent would inherit every tool"
case "$tools" in '[]' | '""' | "''") ok "tools list is empty" ;; *) bad "tools list is not empty: '$tools'" ;; esac
for t in Read Bash Grep Glob; do
  printf '%s' "$tools" | grep -qw "$t" && bad "cartographer has $t" || ok "cartographer lacks $t"
done

suite_end "$fail"
