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

echo "--- the checker brief carries every row unchanged, the five verdicts and the no-new-rows rule ---"
ROWS="$REPO/rows.md"
cat > "$ROWS" <<'ROWS_EOF'
1. E-01 · [CORE] Somebody opens the queue from the nav → sees the oldest item first
2. A-03 · [EDGE] Somebody approves an item twice → the second click does nothing
3. F-12 · [CORE] The save fails → the screen says so and offers a retry

Self-check: every axis walked — yes
ROWS_EOF
STORY="http://localhost:6006/iframe.html?id=pictures-x--populated"
out=$(bash "$SUT" brief checker --rows "$ROWS" --story "$STORY" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "checker brief exits 0" || bad "checker brief: exit $rc, want 0: $out"
while IFS= read -r row; do
  printf '%s\n' "$out" | grep -qxF "$row" && ok "row carried unchanged: ${row:0:12}" \
    || bad "row rewritten or dropped: $row"
done < <(grep -E '(^|[^A-Z])[EAIDFRXC]-[0-9]{2}' "$ROWS")
printf '%s' "$out" | grep -qF "$STORY" && ok "carries the story URL" || bad "story URL missing"
for v in PRESENT PARTIAL WRONG ABSENT UNVERIFIED; do
  printf '%s' "$out" | grep -qw "$v" && ok "names verdict $v" || bad "verdict $v missing"
done
printf '%s' "$out" | grep -qiF 'never add' && ok "carries the no-new-rows rule" || bad "no-new-rows rule missing"
n_in=$(grep -cE '[EAIDFRXC]-[0-9]{2}' "$ROWS")
n_out=$(printf '%s\n' "$out" | grep -cE '[EAIDFRXC]-[0-9]{2}')
[ "$n_out" -eq "$n_in" ] && ok "no row added: $n_in in, $n_out out" || bad "row count changed: $n_in in, $n_out out"

echo "--- a story that is not a clickable Storybook story is refused ---"
for s in ".design/x-mock.html" "http://localhost:6006/?path=/story/pictures-x--populated" "file:///tmp/x.html"; do
  out=$(bash "$SUT" brief checker --rows "$ROWS" --story "$s" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && ok "exit 2 for story: $s" || bad "story $s: exit $rc, want 2"
  printf '%s' "$out" | grep -qF 'not a clickable story' && ok "names 'not a clickable story' for: $s" \
    || bad "refusal for $s does not say 'not a clickable story': $out"
  printf '%s' "$out" | grep -qF 'E-01' && bad "refusal still printed the rows for: $s" || ok "no brief for: $s"
done

echo "--- a rows file with no row is refused ---"
EMPTY="$REPO/empty.md"; printf 'Self-check: every axis walked — yes\n' > "$EMPTY"
out=$(bash "$SUT" brief checker --rows "$EMPTY" --story "$STORY" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "rows file with no row is exit 2" || bad "empty rows: exit $rc, want 2: $out"
printf '%s' "$out" | grep -qF 'UNVERIFIED' && bad "empty rows still printed the brief" || ok "no brief for empty rows"
printf '%s' "$out" | grep -qF 'no row' && ok "the refusal says the file holds no row" || bad "empty-rows refusal does not say 'no row': $out"
out=$(bash "$SUT" brief checker --rows "$REPO/missing.md" --story "$STORY" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "missing rows file is exit 2" || bad "missing rows: exit $rc, want 2"
out=$(bash "$SUT" brief checker --story "$STORY" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "no --rows is exit 2" || bad "no --rows: exit $rc, want 2"

echo "--- the checker agent names no project tool ---"
CHK="$KIT/agents/flow-checker.md"
[ -f "$CHK" ] && ok "agents/flow-checker.md exists" || bad "no agents/flow-checker.md"
cfm=$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$CHK" 2>/dev/null)
printf '%s\n' "$cfm" | grep -q '^name: flow-checker$' && ok "agent is named flow-checker" || bad "agent name is not flow-checker"
for t in pnpm npx storybook-shot playwright.config 'apps/'; do
  grep -qiF "$t" "$CHK" 2>/dev/null && bad "checker agent names project tool '$t'" || ok "checker agent does not name '$t'"
done

echo "--- gate: an open STRANDS or LIES gap holds the picture; SILENT and ROUGH never do; no rows is void ---"
FX="$KIT/scripts/fixtures/flow-audit"
out=$(bash "$SUT" gate "$FX/open-strands.md" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "open STRANDS gap exits 1" || bad "open STRANDS: exit $rc, want 1: $out"
printf '%s' "$out" | grep -qF 'GAP-01' && ok "names GAP-01" || bad "open STRANDS does not name GAP-01: $out"
printf '%s' "$out" | grep -qF 'GAP-02' && bad "names the ROUGH GAP-02 as holding" || ok "ROUGH GAP-02 is not named"
LIES="$REPO/open-lies.md"; sed 's/^### GAP-01 · STRANDS ·/### GAP-01 · LIES ·/' "$FX/open-strands.md" > "$LIES"
out=$(bash "$SUT" gate "$LIES" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "open LIES gap exits 1" || bad "open LIES: exit $rc, want 1: $out"
printf '%s' "$out" | grep -qF 'GAP-01' && ok "LIES names GAP-01" || bad "open LIES does not name GAP-01: $out"
out=$(bash "$SUT" gate "$FX/fixed-strands.md" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "a STRANDS gap with a Fixed line exits 0" || bad "fixed STRANDS: exit $rc, want 0: $out"
EMPTYFIX="$REPO/empty-fixed.md"; sed 's/^\*\*Fixed:\*\* .*/**Fixed:**  /' "$FX/fixed-strands.md" > "$EMPTYFIX"
grep -qx '\*\*Fixed:\*\*  ' "$EMPTYFIX" && ok "empty-Fixed fixture built" || bad "empty-Fixed fixture not built"
out=$(bash "$SUT" gate "$EMPTYFIX" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "an empty Fixed line exits 1" || bad "empty Fixed: exit $rc, want 1: $out"
printf '%s' "$out" | grep -qF 'GAP-01' && ok "empty Fixed names GAP-01" || bad "empty Fixed does not name GAP-01: $out"
out=$(bash "$SUT" gate "$FX/rough-only.md" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "SILENT/ROUGH only exits 0" || bad "rough-only: exit $rc, want 0: $out"
out=$(bash "$SUT" gate "$FX/no-rows.md" 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "no coverage rows exits 3" || bad "no rows: exit $rc, want 3: $out"
printf '%s' "$out" | grep -qiF 'void' && ok "no rows says void" || bad "no rows does not say void: $out"
out=$(bash "$SUT" gate "$REPO/missing.md" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "a missing report is exit 2" || bad "missing report: exit $rc, want 2"

echo "--- owed: only a picture label pays for the two agents; every other change runs none ---"
NOCFG="$REPO/none.json"; printf '{}\n' > "$NOCFG"
out=$(HARNESS_CFG="$NOCFG" bash "$SUT" owed screen:redesign P0 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "screen:redesign among other labels is owed" || bad "screen:redesign P0: exit $rc, want 0: $out"
out=$(HARNESS_CFG="$NOCFG" bash "$SUT" owed type:feature 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "type:feature is not owed" || bad "type:feature: exit $rc, want 1: $out"
out=$(HARNESS_CFG="$NOCFG" bash "$SUT" owed P0,screen:new 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "a comma list holding screen:new is owed" || bad "P0,screen:new: exit $rc, want 0: $out"
out=$(HARNESS_CFG="$REPO/absent.json" bash "$SUT" owed screen:new 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "no project config takes the default labels" || bad "no cfg: exit $rc, want 0: $out"
out=$(HARNESS_CFG="$NOCFG" bash "$SUT" owed 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "no labels is not owed" || bad "no labels: exit $rc, want 1: $out"

echo "--- owed: a project's custom pictureLabels replace the default ---"
CUSTOM="$REPO/custom.json"; printf '{"design":{"baselineRoute":{"pictureLabels":["ui:new"]}}}\n' > "$CUSTOM"
out=$(HARNESS_CFG="$CUSTOM" bash "$SUT" owed ui:new 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "custom ui:new is owed" || bad "custom ui:new: exit $rc, want 0: $out"
out=$(HARNESS_CFG="$CUSTOM" bash "$SUT" owed screen:new 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "screen:new is not owed once the project replaces the labels" || bad "custom screen:new: exit $rc, want 1: $out"

suite_end "$fail"
