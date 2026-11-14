#!/usr/bin/env bash
# owed-missing-script.test.sh — an `owed` check naming an npm script the project does
# not have is a settings fault, said once; it is not "owed", so nothing parks and no
# reviewer runs.
#
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
# A driver session exports its own DRIVER_*, STATE_DIR and config: inherited, they aim this suite at the real state.
for _v in $(env | sed -n -E 's/^(DRIVER_[A-Z_]*|STATE_DIR|HARNESS_CFG)=.*/\1/p'); do unset "$_v"; done
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../push-requires.sh" || exit 1

cat > "$FIX/reviewer" <<SH
#!/usr/bin/env sh
echo x >> "$FIX/reviewer.calls"
echo 'VERDICT: SHIP — nothing in this change blocks.'
SH
cat > "$FIX/recorder" <<SH
#!/usr/bin/env sh
echo x >> "$FIX/recorder.calls"
git commit --allow-empty --no-verify -q -m "chore: gate" -m "Gate: SHIP (agent)"
echo recorded
SH
cat > "$FIX/owed" <<'SH'
#!/usr/bin/env sh
git log -1 --format=%B | grep -q 'Gate: SHIP' && { echo "✓ attested"; exit 0; }
echo "✗ check:ui-gate-attested — no matching verdict."; exit 1
SH
chmod +x "$FIX/reviewer" "$FIX/recorder" "$FIX/owed"
jq --arg r "$FIX/reviewer" --arg w "$FIX/recorder" \
   '.review = {"attest":{"ui-gate":{"owed":"npm run -s check:ui-gate-attested","review":$r,"record":$w}}}' \
   "$HARNESS_CFG_PATH" > "$FIX/cfg.tmp" && cat "$FIX/cfg.tmp" > "$HARNESS_CFG_PATH"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "a project whose pre-push wants a ui-gate verdict"

# tkt <n> <package.json> — a fresh ticket on its own branch carrying that package.json.
tkt() {
  fix_issue "$1" OPEN "status:claimed,screen:inbox"
  git -C "$REPO" worktree add -q "$FIX/wt$1" -b "tkt-$1/work" develop
  git -C "$FIX/wt$1" config user.email t@e.invalid; git -C "$FIX/wt$1" config user.name T
  mkdir -p "$FIX/wt$1/screens"; printf 'x\n' > "$FIX/wt$1/screens/Inbox.tsx"
  printf '%s\n' "$2" > "$FIX/wt$1/package.json"
  git -C "$FIX/wt$1" add -A && git -C "$FIX/wt$1" commit -qm "feat: inbox"
  driver_state_init "$1" --worktree "$FIX/wt$1" --branch "tkt-$1/work"
  : > "$FIX/reviewer.calls"; : > "$FIX/recorder.calls"
}
calls() { wc -l < "$FIX/$1.calls" | tr -d ' '; }

echo "--- an owed check naming a missing npm script is a settings fault, said once ---"
tkt 601 '{"name":"p","scripts":{"test":"true"}}'
rc=0; out=$(driver_push_requires 601 2>&1) || rc=$?
want "the step returns 0" "0" "$rc"
want "nothing parks" "" "$(driver_state_get 601 park_note)"
want "no reviewer ran" "0" "$(calls reviewer)"
want "no recorder ran" "0" "$(calls recorder)"
cfg=$(basename "$HARNESS_CFG_PATH")
said=$(printf '%s\n' "$out" | grep -c "✋ push-requires: 'ui-gate'.*names npm script check:ui-gate-attested, which package.json does not have.*$cfg")
want "exactly one line names the row, the script and the settings file" "1" "$said"

echo "--- control: with the script present and owed, the reviewer runs ---"
tkt 602 "{\"name\":\"p\",\"scripts\":{\"check:ui-gate-attested\":\"sh $FIX/owed\"}}"
rc=0; out=$(driver_push_requires 602 2>&1) || rc=$?
want "the reviewer ran once" "1" "$(calls reviewer)"
want "and its verdict was recorded" "1" "$(calls recorder)"
want "and the step passes" "0" "$rc"

suite_end "$FAILED"
