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

echo "--- an owed-only row naming a missing npm script parks nothing, before or at the push ---"
cp "$HARNESS_CFG" "$FIX/cfg.full"
jq '.review = {"attest":{"ui-gate":"npm run check:ui-gate-attested"}}' "$FIX/cfg.full" > "$FIX/cfg.tmp" && cat "$FIX/cfg.tmp" > "$HARNESS_CFG"
tkt 603 '{"name":"p","scripts":{"test":"true"}}'
rc=0; out=$(driver_push_requires_unpayable 603 2>&1) || rc=$?
want "the pre-review check returns 0" "0" "$rc"
want "and parks nothing" "" "$(driver_state_get 603 park_note)"
rc=0; out2=$(driver_push_requires 603 2>&1) || rc=$?
want "the push requirements return 0" "0" "$rc"
want "and still park nothing" "" "$(driver_state_get 603 park_note)"
said=$(printf '%s\n%s\n' "$out" "$out2" | grep -c "names npm script check:ui-gate-attested, which package.json does not have")
want "the fault is said once across both" "1" "$said"
cat "$FIX/cfg.full" > "$HARNESS_CFG"

echo "--- the fault names the repo's settings file, never the temp snapshot it was read through ---"
rel=".claude/$(basename "$HARNESS_CFG_PATH")"
SNAP="$FIX/$(basename "$HARNESS_CFG_PATH").abcdef012345"; cp "$HARNESS_CFG" "$SNAP"
tkt 604 '{"name":"p","scripts":{"test":"true"}}'
out=$(HARNESS_CFG="$SNAP" HARNESS_CFG_FROM="origin/develop@1a2b3c4" driver_push_requires 604 2>&1)
want_in "it names the repo's settings file and where it was read" "a settings fault in $rel .read from origin/develop@1a2b3c4." "$out"
want_not_in "and not the snapshot" "$(basename "$SNAP")" "$out"

echo "--- only the plain 'npm run [-s] <name>' form is classified ---"
mkdir -p "$FIX/pj"; printf '%s\n' '{"name":"p","scripts":{"test":"true"}}' > "$FIX/pj/package.json"
for c in 'npm run -w apps/web check:x' 'npm run --workspace=apps/web check:x' 'npm run --if-present check:x' \
         'npm run --prefix apps/web check:x' 'npm run "check:x"' "npm run 'check:x'"; do
  rc=0; _driver_owed_missing_script "$c" "$FIX/pj" >/dev/null || rc=$?
  want "not classified: $c" "1" "$rc"
done
rc=0; n=$(_driver_owed_missing_script 'npm run --silent check:x' "$FIX/pj") || rc=$?
want "classified: npm run --silent check:x" "0:check:x" "$rc:$n"

echo "--- a package.json that does not parse is not a missing script ---"
printf '<<<<<<< HEAD\n{"scripts":{}}\n' > "$FIX/pj/package.json"
rc=0; _driver_owed_missing_script 'npm run check:x' "$FIX/pj" >/dev/null || rc=$?
want "unparseable: not classified" "1" "$rc"
printf '%s\n' '{"scripts":["check:x"]}' > "$FIX/pj/package.json"
rc=0; _driver_owed_missing_script 'npm run check:x' "$FIX/pj" >/dev/null || rc=$?
want ".scripts not an object: not classified" "1" "$rc"

suite_end "$FAILED"
