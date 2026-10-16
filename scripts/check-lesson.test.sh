#!/usr/bin/env bash
# Fixture test for check-lesson.sh.
#
# Every case builds a throwaway repo with a trunk and a branch, commits a fix (or
# not), hands the check a body, labels and closing issues, and asserts on the exit
# code and the line that says what is missing. Nothing here reads the real kit or
# talks to GitHub; the one case that takes the GitHub path runs a stub `gh`.
set -uo pipefail

SUT="${SUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-lesson.sh}"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

# A hook's inherited GIT_DIR / GIT_WORK_TREE aim every git below at the real repo.
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@test.local
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@test.local
export GIT_CONFIG_NOSYSTEM=1 HOME="${TMPDIR:-/tmp}/cl-home-$$"
unset HARNESS_GUARD_PATTERNS HARNESS_CFG_PATH HARNESS_SPAWN_CLASS GITHUB_REPOSITORY
mkdir -p "$HOME"

SB="${TMPDIR:-/tmp}/cl-fixture-$$"
mkdir -p "$SB"
trap 'rm -rf "$SB" "$HOME"' EXIT
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# Trunk: a source file, its test, and an untouched second test. Branch `fix` changes
# the source and the first test — the shape of a real fix with its guard.
repo() {
  R="$SB/$1"; rm -rf "$R"; mkdir -p "$R/src" "$R/.claude"
  git -C "$R" -c init.defaultBranch=main init -q
  printf 'export const idle = (s) => s.idle;\n' > "$R/src/cpu.ts"
  printf "it('reads idle', () => {});\n" > "$R/src/cpu.test.ts"
  printf "it('lists', () => {});\n" > "$R/src/other.test.ts"
  cat > "$R/.claude/harness.json" <<'JSON'
{ "tests": { "patterns": ["*.test.ts"] } }
JSON
  git -C "$R" add -A && git -C "$R" commit -qm trunk
  git -C "$R" checkout -q -b fix
  printf 'export const idle = (s) => (s == null ? 0 : s.idle);\n' > "$R/src/cpu.ts"
  printf "it('reads idle', () => {});\nit('a missing sample is never idle', () => {});\n" > "$R/src/cpu.test.ts"
  git -C "$R" add -A && git -C "$R" commit -qm "fix: a missing sample is not idle"
}
LESSON='## Summary
A failed CPU sample read as 100% idle.

## Lesson
- Principle: A missing reading never counts as safe to go.
- Guard: `src/cpu.test.ts`
- Before/after: the new case fails on trunk (idle of null throws) and passes on the fix.
- Reach: it covers every reader of a sample, the memory one included.

Closes #7'
check() { # <body> [extra args...]
  printf '%s\n' "$1" > "$SB/body.md"; shift
  OUT=$(bash "$SUT" --repo "$R" --base main --head fix --body-file "$SB/body.md" "$@" 2>&1); RC=$?
}
expect_rc() { # <want> <label>
  [ "$RC" -eq "$1" ] && ok "$2" || { bad "$2 (rc $RC, want $1)"; printf '%s\n' "$OUT" | sed 's/^/        /'; }
}
expect_out() { # <regex> <label>
  printf '%s' "$OUT" | grep -qE -- "$1" && ok "$2" || { bad "$2 — output did not match /$1/"; printf '%s\n' "$OUT" | sed 's/^/        /'; }
}
NONE='[]'; printf '%s' "$NONE" > "$SB/none.json"

echo "check-lesson fixture"

# --- 1. A fix with no Lesson: refused ------------------------------------------------
repo nolesson
check "## Summary
Fixed the idle reading." --labels bug --closing-file "$SB/none.json"
expect_rc 1 "a bug-labelled PR with no Lesson section is refused"
expect_out "^lesson: this is a fix pull request \(it carries the 'bug' label\), and its body has no '## Lesson' section\.$" \
  "the first line says it is a fix, why, and what is missing"
expect_out '^- Guard: `<a test, lint or gate file' "and hands back a section ready to paste"

# --- 2. The guard path is a test the diff does not touch: refused --------------------
repo untouched
check "${LESSON/src\/cpu.test.ts/src/other.test.ts}" --labels bug --closing-file "$SB/none.json"
expect_rc 1 "a Lesson whose guard the diff does not add or change is refused"
expect_out '`src/other.test.ts` is not added or changed by this pull request' "it names the guard and says the diff does not touch it"

# --- 3. A valid Lesson: passes -------------------------------------------------------
repo valid
check "$LESSON" --labels bug --closing-file "$SB/none.json"
expect_rc 0 "a fix with a complete Lesson and a guard in the diff passes"
expect_out '^lesson: complete — guard `src/cpu.test.ts` is in the diff' "and it says which guard it accepted"

# --- 4. Not automatable because…: passes, and is countable -----------------------------
repo notauto
check "## Lesson
Not automatable because the failure needs a real provider outage to reproduce." --labels bug --closing-file "$SB/none.json"
expect_rc 0 "'Not automatable because <reason>' passes"
expect_out '^lesson: not-automatable — the failure needs' "and prints a countable not-automatable line"
check "## Lesson
Not automatable because" --labels bug --closing-file "$SB/none.json"
expect_rc 1 "'Not automatable because' with no reason is refused"

# --- 5. A non-fix PR: passes with nothing owed --------------------------------------
repo nonfix
check "## Summary
A new screen." --labels "type:feature" --closing-file "$SB/none.json"
expect_rc 0 "a PR that is not a fix owes no Lesson"
expect_out '^lesson: not a fix pull request' "and says so"

# --- 6. The other ways to be a fix --------------------------------------------------
repo classes
check "no lesson" --labels "class:repair" --closing-file "$SB/none.json"
expect_rc 1 "a PR labelled with a repair spawn class is a fix"
check "no lesson" --labels "" --class approved-merge --closing-file "$SB/none.json"
expect_rc 1 "--class approved-merge makes it a fix"
printf '[{"number": 7, "type": "Bug", "labels": []}]' > "$SB/bugtype.json"
check "no lesson" --labels "" --closing-file "$SB/bugtype.json"
expect_rc 1 "closing a Bug-typed issue makes it a fix"
expect_out "it closes #7, a Bug" "and the line names the issue"
printf '[{"number": 8, "type": null, "labels": ["type:bug"]}]' > "$SB/buglabel.json"
check "no lesson" --labels "" --closing-file "$SB/buglabel.json"
expect_rc 1 "closing an issue labelled type:bug makes it a fix"

# --- 7. Incomplete lessons say exactly what is missing -------------------------------
repo partial
check "## Lesson
- Principle: fix it
- Guard: \`src/cpu.ts\`
- Before/after: <the guard fails on the pre-fix code>" --labels bug --closing-file "$SB/none.json"
expect_rc 1 "a Lesson with a thin principle, a non-guard path, a placeholder and no reach is refused"
expect_out 'no Principle line' "it names the thin principle"
expect_out '`src/cpu.ts` is not a test, lint or gate file' "it names the guard that is not a guard"
expect_out 'no Before/after line' "it names the placeholder before/after"
expect_out 'no Reach line' "it names the missing reach"

# --- 8. A template's placeholder is not an answer -----------------------------------
repo template
check "## Lesson
<!--
- Principle: A missing reading never counts as safe to go.
- Guard: \`src/cpu.test.ts\`
- Before/after: fails on trunk and passes on the fix.
- Reach: every reader of a sample.
-->" --labels bug --closing-file "$SB/none.json"
expect_rc 1 "lines inside an HTML comment do not count"
check '```
## Lesson
Not automatable because it is quoted in a fence here.
```' --labels bug --closing-file "$SB/none.json"
expect_rc 1 "a Lesson inside a code fence does not count"
TEMPLATE="$(cd "$(dirname "$SUT")/.." && pwd)/templates/pull-request-lesson.md"
if [ -f "$TEMPLATE" ]; then
  check "$(cat "$TEMPLATE")" --labels bug --closing-file "$SB/none.json"
  expect_rc 1 "the kit's PR template, unfilled, is refused"
  expect_out 'no Principle line.*no Guard line|no Principle line.*Guard names no file' "and every blank line in it is named"
else bad "the kit's PR template is missing at $TEMPLATE"; fi

# --- 9. A deleted guard is not a guard ----------------------------------------------
repo deleted
git -C "$R" rm -q src/other.test.ts && git -C "$R" commit -qm "drop other"
check "${LESSON/src\/cpu.test.ts/src/other.test.ts}" --labels bug --closing-file "$SB/none.json"
expect_rc 1 "naming a test the diff deletes is refused"

# --- 10. Config: read at base, so a PR cannot loosen it ------------------------------
repo loosen
cat > "$R/.claude/harness.json" <<'JSON'
{ "lesson": { "fixLabels": ["never"] } }
JSON
git -C "$R" commit -qam "loosen the check"
check "no lesson" --labels bug --closing-file "$SB/none.json"
expect_rc 1 "a PR that edits fixLabels is still judged by the base config"
repo custom
git -C "$R" checkout -q main
cat > "$R/.claude/harness.json" <<'JSON'
{ "lesson": { "fixLabels": ["defect"], "guardPatterns": ["*.rules.yml"] } }
JSON
git -C "$R" commit -qam cfg && git -C "$R" checkout -q fix && git -C "$R" rebase -q main
check "no lesson" --labels bug --closing-file "$SB/none.json"
expect_rc 0 "fixLabels from the project config replace the default"
check "$LESSON" --labels defect --closing-file "$SB/none.json"
expect_rc 1 "guardPatterns from the project config replace the default"
printf '{ "lesson": { "fixLabels": "bug" } }\n' > "$SB/badcfg.json"
OUT=$(HARNESS_CFG_PATH="$SB/badcfg.json" bash "$SUT" --repo "$R" --base main --head fix --body-file "$SB/body.md" --labels bug --closing-file "$SB/none.json" 2>&1); RC=$?
expect_rc 2 "a fixLabels that is not a list is a refusal, not the default"

# --- 11. A measurement that cannot be made is not clean ----------------------------------
repo badref
printf '%s\n' "$LESSON" > "$SB/body.md"
OUT=$(bash "$SUT" --repo "$R" --base nope --head fix --body-file "$SB/body.md" --labels bug --closing-file "$SB/none.json" 2>&1); RC=$?
expect_rc 2 "a base that does not resolve refuses (exit 2)"

# --- 12. The event payload and the GitHub path (stub gh) -----------------------------
repo event
jq -n --arg b "no lesson" '{pull_request: {number: 42, body: $b, labels: [{name: "bug"}]}, repository: {full_name: "o/r"}}' > "$SB/event.json"
OUT=$(bash "$SUT" --repo "$R" --base main --head fix --event "$SB/event.json" --closing-file "$SB/none.json" 2>&1); RC=$?
expect_rc 1 "labels and body come from the event payload"
mkdir -p "$SB/bin"
jq -n --arg b "$LESSON" '{data: {repository: {pullRequest: {body: $b, labels: {nodes: [{name: "bug"}]},
  closingIssuesReferences: {nodes: [{number: 7, issueType: {name: "Bug"}, labels: {nodes: []}}]}}}}}' > "$SB/gh.json"
printf '#!/usr/bin/env bash\n[ "$1 $2" = "api graphql" ] && cat "%s" && exit 0\nexit 1\n' "$SB/gh.json" > "$SB/bin/gh"
chmod +x "$SB/bin/gh"
OUT=$(PATH="$SB/bin:$PATH" bash "$SUT" --repo "$R" --base main --head fix --pr 42 --slug o/r 2>&1); RC=$?
expect_rc 0 "with --pr alone, body, labels and closing issues come from GitHub"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/bin/gh"
OUT=$(PATH="$SB/bin:$PATH" bash "$SUT" --repo "$R" --base main --head fix --pr 42 --slug o/r 2>&1); RC=$?
expect_rc 2 "a GitHub read that fails refuses (exit 2), never passes"

exit $fail
