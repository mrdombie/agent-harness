#!/usr/bin/env bash
# Fixture test for check-lesson.sh.
#
# Every case builds a throwaway repo with a trunk and a branch, commits a fix (or
# not), hands the check a body, labels, title and linked issues, and asserts on the
# exit code and the line that says what is missing. Nothing here reads the real kit
# or talks to GitHub; the cases that take the GitHub path run a stub `gh`.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SUT:-$HERE/check-lesson.sh}"
WF_DIR="${WF_DIR:-$HERE/../.github/workflows}"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

# A hook's inherited GIT_DIR / GIT_WORK_TREE aim every git below at the real repo.
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@test.local
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@test.local
export GIT_CONFIG_NOSYSTEM=1 HOME="${TMPDIR:-/tmp}/cl-home-$$"
unset HARNESS_GUARD_PATTERNS HARNESS_CFG_PATH HARNESS_SPAWN_CLASS GITHUB_REPOSITORY GITHUB_EVENT_NAME GITHUB_HEAD_REF
mkdir -p "$HOME"

SB="${TMPDIR:-/tmp}/cl-fixture-$$"
mkdir -p "$SB"
on_exit_keep_status 'rm -rf "$SB" "$HOME"'
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# Trunk: a source file, its test, and an untouched second test. Branch `work` changes
# the source and the first test — the shape of a real fix with its guard.
repo() {
  R="$SB/$1"; rm -rf "$R"; mkdir -p "$R/src" "$R/.claude"
  git -C "$R" -c init.defaultBranch=main init -q
  printf 'export const idle = (s) => s.idle;\n' > "$R/src/cpu.ts"
  printf "it('reads idle', () => {});\n" > "$R/src/cpu.test.ts"
  printf "it('lists', () => {});\nit('sorts', () => {});\n" > "$R/src/other.test.ts"
  cat > "$R/.claude/harness.json" <<'JSON'
{ "tests": { "patterns": ["*.test.ts"] } }
JSON
  git -C "$R" add -A && git -C "$R" commit -qm trunk
  git -C "$R" checkout -q -b work
  printf 'export const idle = (s) => (s == null ? 0 : s.idle);\n' > "$R/src/cpu.ts"
  printf "it('reads idle', () => {});\nit('a missing sample is never idle', () => {});\n" > "$R/src/cpu.test.ts"
  git -C "$R" add -A && git -C "$R" commit -qm "a missing sample is not idle"
}
commit() { git -C "$R" add -A && git -C "$R" commit -qm "${1:-change}"; }
lesson() { # <guard path> — a complete Lesson naming that guard
  printf '%s\n' "## Summary
A failed CPU sample read as 100% idle.

## Lesson
- Principle: A missing reading never counts as safe to go.
- Guard: \`$1\`
- Before/after: the new case fails on trunk (idle of null throws) and passes on the fix.
- Reach: it covers every reader of a sample, the memory one included."
}
LESSON=$(lesson src/cpu.test.ts)
echo '[]' > "$SB/none.json"
# check <body> [args...] — labels "bug", a neutral title and branch, no linked issues;
# later args override these.
check() {
  printf '%s\n' "$1" > "$SB/body.md"; shift
  OUT=$(bash "$SUT" --repo "$R" --base main --head work --body-file "$SB/body.md" \
    --labels bug --title "Make the sampler honest" --branch work \
    --closing-file "$SB/none.json" --issues-file "$SB/none.json" "$@" 2>&1); RC=$?
}
expect_rc() { # <want> <label>
  [ "$RC" -eq "$1" ] && ok "$2" || { bad "$2 (rc $RC, want $1)"; printf '%s\n' "$OUT" | sed 's/^/        /'; }
}
expect_out() { # <regex> <label>
  printf '%s' "$OUT" | grep -qE -- "$1" && ok "$2" || { bad "$2 — output did not match /$1/"; printf '%s\n' "$OUT" | sed 's/^/        /'; }
}
first_line() { # <exact> <label>
  [ "$(printf '%s\n' "$OUT" | head -1)" = "$1" ] && ok "$2" || { bad "$2 — first line was: $(printf '%s\n' "$OUT" | head -1)"; }
}

echo "check-lesson fixture"

# === the five the issue names =======================================================
repo nolesson
check "## Summary
Fixed the idle reading."
expect_rc 1 "a fix PR with no Lesson section is refused"
first_line "lesson: this is a fix pull request (it carries the 'bug' label), and its body has no '## Lesson' section." \
  "the first line says it is a fix, why, and what is missing"
expect_out '^- Guard: `<a test, lint or gate file' "and hands back a section ready to paste"

repo untouched
check "$(lesson src/other.test.ts)"
expect_rc 1 "a Lesson whose guard the diff does not add or change is refused"
expect_out '`src/other.test.ts` is not added or changed by this pull request' "it names the guard and says the diff does not touch it"

repo valid
check "$LESSON"
expect_rc 0 "a fix with a complete Lesson and a guard in the diff passes"
expect_out '^lesson: complete — guard `src/cpu.test.ts` is in the diff' "and it says which guard it accepted"

repo notauto
check "## Lesson
Not automatable because the failure needs a real provider outage to reproduce it."
expect_rc 0 "'Not automatable because <8+ words>' passes"
expect_out '^lesson: not-automatable — the failure needs' "and prints a countable not-automatable line"

repo nonfix
check "## Summary
A new screen." --labels "type:feature"
expect_rc 0 "a PR that is not a fix owes no Lesson"
expect_out '^lesson: not a fix pull request' "and says so"

# === Major 1: everything it judges by comes from the base =============================
repo loosen-labels
cat > "$R/.claude/harness.json" <<'JSON'
{ "lesson": { "fixLabels": ["never"] } }
JSON
commit "loosen the labels"
check "no lesson"
expect_rc 1 "a PR that edits fixLabels at head is still judged by the base config"

repo loosen-patterns
mkdir -p "$R/notes" && printf 'we should test idle\n' > "$R/notes/idea.txt"
cat > "$R/.claude/harness.json" <<'JSON'
{ "lesson": { "guardPatterns": ["**/*"], "guardExclude": [] } }
JSON
commit "loosen the patterns"
check "$(lesson notes/idea.txt)"
expect_rc 1 "a PR that widens guardPatterns at head is still judged by the base patterns"

repo custom-base
git -C "$R" checkout -q main
cat > "$R/.claude/harness.json" <<'JSON'
{ "lesson": { "fixLabels": ["defect"], "guardPatterns": ["**/*.rules.yml"] } }
JSON
git -C "$R" commit -qam cfg && git -C "$R" checkout -q work && git -C "$R" rebase -q main
check "no lesson"
expect_rc 0 "fixLabels from the base config replace the default (bug is no longer a fix label)"
check "$LESSON" --labels defect
expect_rc 1 "guardPatterns from the base config replace the default (a .test.ts is no longer a guard)"

repo narrow-only
check "$(lesson src/cpu.ts)"
RC0=$RC
OUT=$(HARNESS_GUARD_PATTERNS='**/*' bash "$SUT" --repo "$R" --base main --head work --body-file "$SB/body.md" \
  --labels bug --title t --branch work --closing-file "$SB/none.json" --issues-file "$SB/none.json" 2>&1); RC=$?
[ "$RC0" -eq 1 ] || bad "fixture: a source file should not be a guard without the input (rc $RC0)"
expect_rc 1 "the guard-patterns input cannot widen the guard set"
printf '%s\n' "$LESSON" > "$SB/body.md"
OUT=$(HARNESS_GUARD_PATTERNS='**/*.spec.*' bash "$SUT" --repo "$R" --base main --head work --body-file "$SB/body.md" \
  --labels bug --title t --branch work --closing-file "$SB/none.json" --issues-file "$SB/none.json" 2>&1); RC=$?
expect_rc 1 "but it can narrow it (a .test.ts guard refused under '**/*.spec.*')"

# The CI seat: the kit judging itself takes the script from the BASE commit, and its
# caller passes no ref or pattern of its own. A loosened head script is never the judge.
WF="$WF_DIR/lesson.yml"; KWF="$WF_DIR/kit-lesson.yml"
if [ -f "$WF" ] && [ -f "$KWF" ]; then
  grep -qF "ref: \${{ inputs.harness-repo == github.repository && github.event.pull_request.base.sha || inputs.harness-ref }}" "$WF" \
    && ok "lesson.yml checks the kit out at the PR's base SHA when the kit judges itself" \
    || bad "lesson.yml does not take the script from the base SHA for the kit's own PRs"
  grep -qE '^[[:space:]]+(harness-ref|guard-patterns):' "$KWF" \
    && bad "kit-lesson.yml passes a ref or patterns of its own (a PR could loosen its judge)" \
    || ok "kit-lesson.yml passes no ref or patterns a PR could loosen"
  grep -qE '^ *bash "\$judge" ' "$WF" && grep -qF 'judge=kit/scripts/check-lesson.sh' "$WF" \
    && ok "the step runs the kit checkout's script, not the PR's" \
    || bad "the step does not run the kit checkout's script"
else bad "workflow files missing under $WF_DIR"; fi

# === Major 2: a guard is an executable check that changed in substance =================
repo docs
mkdir -p "$R/docs/gates" "$R/src"
for p in docs/gates/README.md docs/eslint-ideas.md check-list.md src/foo.test.md .github/workflows/ci.yml; do
  mkdir -p "$R/$(dirname "$p")"; printf 'a new rule: idle is never assumed\n' > "$R/$p"
done
commit "docs"
for p in docs/gates/README.md docs/eslint-ideas.md check-list.md src/foo.test.md .github/workflows/ci.yml; do
  check "$(lesson "$p")"
  expect_rc 1 "'$p' is not an executable guard"
done
expect_out 'is not an executable test, lint or gate file' "and the line says why"

repo realchecks
mkdir -p "$R/scripts" "$R/packages/x/eslint-rules"
printf '#!/bin/sh\ngrep -r "s.idle" src && exit 1\n' > "$R/scripts/check-idle.sh"
printf 'module.exports = {};\n' > "$R/packages/x/eslint-rules/no-assumed-idle.js"
commit "checks"
check "$(lesson scripts/check-idle.sh)"
expect_rc 0 "a new scripts/check-*.sh is a guard"
check "$(lesson packages/x/eslint-rules/no-assumed-idle.js)"
expect_rc 0 "a new lint rule is a guard"

repo baretest
mkdir -p "$R/scripts/foo" "$R/docs" "$R/pkg/tests"
printf '#!/bin/sh\n[ "$(idle)" = 0 ] || exit 1\n' > "$R/scripts/foo/test.sh"
printf '#!/bin/sh\n[ "$(idle)" = 0 ] || exit 1\n' > "$R/docs/test.sh"
printf 'idle_never_assumed() { :; }\n' > "$R/pkg/tests/idle.sh"
commit "bare suites"
check "$(lesson scripts/foo/test.sh)"
expect_rc 0 "a bare scripts/<name>/test.sh suite is a guard"
check "$(lesson pkg/tests/idle.sh)"
expect_rc 0 "a file under a tests/ directory is a guard"
check "$(lesson docs/test.sh)"
expect_rc 1 "a test.sh under docs/ is still excluded"
git -C "$R" checkout -q main && git -C "$R" branch -qD work && git -C "$R" checkout -q -b work
mkdir -p "$R/scripts/foo"
printf '#!/bin/sh\n[ "$(idle)" = 0 ] || exit 1\n' > "$R/scripts/foo/test.sh" && commit "suite on trunk"
git -C "$R" branch -qf main HEAD
printf '#!/bin/sh\n\n[ "$(idle)" = 0 ]   || exit 1\n\n' > "$R/scripts/foo/test.sh" && commit "re-space suite"
check "$(lesson scripts/foo/test.sh)"
expect_rc 1 "a whitespace-only edit to a bare test.sh is not a guard"
expect_out 'only moves or re-spaces' "and the line says so"

repo whitespace
printf "it('lists', () => {});   \nit('sorts', () => {});\n\n" > "$R/src/other.test.ts"
commit "re-space"
check "$(lesson src/other.test.ts)"
expect_rc 1 "a whitespace-only edit to a test is not a guard"
expect_out 'only moves or re-spaces' "and the line says so"

repo rename
git -C "$R" mv src/other.test.ts src/listing.test.ts && commit "move"
check "$(lesson src/listing.test.ts)"
expect_rc 1 "a pure rename of a test is not a guard"
printf "it('lists', () => {});\nit('sorts', () => {});\nit('never lists a missing sample', () => {});\n" > "$R/src/listing.test.ts"
commit "and a case"
check "$(lesson src/listing.test.ts)"
expect_rc 0 "a rename that also adds a case is a guard"

repo deleted
git -C "$R" rm -q src/other.test.ts && commit "drop other"
check "$(lesson src/other.test.ts)"
expect_rc 1 "naming a test the diff deletes is refused"

# === Major 3: a fix is known by what it is ===========================================
repo kinds
check "no lesson" --labels ""
expect_rc 0 "fixture: no tag at all is not a fix"
for t in "fix: idle is not assumed" "fix(cpu): idle is not assumed" "fix!: idle" "Fix(swarm): build"; do
  check "no lesson" --labels "" --title "$t"; expect_rc 1 "title '$t' is a fix"
done
for t in "fixture: add data" "feat: fix-up later" "prefix fix: x"; do
  check "no lesson" --labels "" --title "$t"; expect_rc 0 "title '$t' is not a fix"
done
for b in fix/cpu fix-cpu; do check "no lesson" --labels "" --branch "$b"; expect_rc 1 "branch '$b' is a fix"; done
check "no lesson" --labels "" --branch "tkt-12-prefix"; expect_rc 0 "branch 'tkt-12-prefix' is not a fix"
check "no lesson" --labels "class:repair"; expect_rc 1 "a class:repair label is a fix"
check "no lesson" --labels "" --class approved-merge; expect_rc 1 "--class approved-merge is a fix"
printf '[{"number": 7, "type": "Bug", "labels": []}]' > "$SB/bugtype.json"
check "no lesson" --labels "" --closing-file "$SB/bugtype.json"; expect_rc 1 "closing a Bug-typed issue is a fix"
printf '[{"number": 8, "type": null, "labels": ["type:bug"]}]' > "$SB/buglabel.json"
check "no lesson" --labels "" --closing-file "$SB/buglabel.json"; expect_rc 1 "closing an issue labelled type:bug is a fix"
printf '[{"number": 12789, "type": null, "labels": ["bug"]}, {"number": 5, "type": "Feature", "labels": ["type:feature"]}]' > "$SB/issues.json"
check "Refs #12789" --labels "" --issues-file "$SB/issues.json"
expect_rc 1 "a PR that only Refs a bug issue is a fix"
expect_out 'it references #12789, a bug' "and the line names the issue"
check "Closes #12789" --labels "" --issues-file "$SB/issues.json"
expect_rc 1 "'Closes #N' in the body counts even where GitHub links nothing (a non-default base)"
check "Refs #5" --labels "" --issues-file "$SB/issues.json"
expect_rc 0 "referencing a feature issue is not a fix"
check "<!-- Refs #12789 -->" --labels "" --issues-file "$SB/issues.json"
expect_rc 0 "a reference inside a comment does not count"

# === Minors: the parser ===========================================================
repo parser
check "## Lesson
<!--
- Principle: A missing reading never counts as safe to go.
- Guard: \`src/cpu.test.ts\`
- Before/after: fails on trunk and passes on the fix.
- Reach: every reader of a sample.
-->"
expect_rc 1 "lines inside an HTML comment do not count"
check "<!-- an unclosed comment
$LESSON"
expect_rc 1 "an unclosed <!-- runs to the end of the body"
check '```
## Lesson
Not automatable because it is quoted in a fence here and nowhere else at all.
```'
expect_rc 1 "a Lesson inside a code fence does not count"
check "\`\`\`
an unclosed fence
$LESSON"
expect_rc 1 "an unclosed fence runs to the end of the body"
check "$(printf '%s\n' "$LESSON" | sed 's/^/    /')"
expect_rc 1 "an indented (code) Lesson does not count"
check "## Lesson
Not automatable because it needs an outage."
expect_rc 1 "'Not automatable because' with fewer than eight words is refused"
expect_out 'at least eight words' "and the line says how many"
check "## Lesson
- Guard: \`src/cpu.test.ts\`
Not automatable because the failure needs a real provider outage to reproduce it."
expect_rc 1 "a Guard alongside 'Not automatable because' is refused"
expect_out 'one or the other' "and the line says to pick one"
check "### Lesson
- Principle: x"
expect_rc 1 "a near-miss heading is refused"
expect_out "found '### Lesson'; use '## Lesson'" "and named"
check "## Lessons learned"
expect_out "found '## Lessons learned'; use '## Lesson'" "a '## Lessons learned' heading is named too"
check "## Lesson
- Principle: fix it
- Guard: \`src/cpu.ts\`
- Before/after: <the guard fails on the pre-fix code>"
expect_rc 1 "a thin principle, a non-guard, a placeholder and no reach are refused"
expect_out 'no Principle line' "it names the thin principle"
expect_out 'no Before/after line' "it names the placeholder before/after"
expect_out 'no Reach line' "it names the missing reach"
TEMPLATE="$HERE/../templates/pull-request-lesson.md"
if [ -f "$TEMPLATE" ]; then
  check "$(cat "$TEMPLATE")"
  expect_rc 1 "the kit's PR template, unfilled, is refused"
else bad "the kit's PR template is missing at $TEMPLATE"; fi

# === Refusals: exit 2, and never a missing lesson ===================================
repo refusals
cat > "$SB/badcfg.json" <<'JSON'
{ "lesson": { "fixLabels": "bug" } }
JSON
printf '%s\n' "$LESSON" > "$SB/body.md"
OUT=$(HARNESS_CFG_PATH="$SB/badcfg.json" bash "$SUT" --repo "$R" --base main --head work --body-file "$SB/body.md" --labels bug --title t --branch b --closing-file "$SB/none.json" 2>&1); RC=$?
expect_rc 2 "a fixLabels that is not a list is a refusal, not the default"
OUT=$(bash "$SUT" --repo "$R" --base nope --head work --body-file "$SB/body.md" --labels bug --title t --branch b --closing-file "$SB/none.json" 2>&1); RC=$?
expect_rc 2 "a base that does not resolve refuses (exit 2)"
expect_out 'not a missing lesson' "and says it is not a missing lesson"
OUT=$(GITHUB_EVENT_NAME=pull_request_target bash "$SUT" --repo "$R" --base main --head work --body-file "$SB/body.md" --labels bug --title t --branch b --closing-file "$SB/none.json" 2>&1); RC=$?
expect_rc 2 "pull_request_target is refused"
first_line "lesson: refused to run on pull_request_target, not a missing lesson" "with a clear first line"

# === The event payload and the GitHub path (stub gh) =================================
repo event
jq -n --arg b "no lesson" '{pull_request: {number: 42, body: $b, title: "chore: x", head: {ref: "fix/cpu"}, labels: []}, repository: {full_name: "o/r"}}' > "$SB/event.json"
OUT=$(bash "$SUT" --repo "$R" --base main --head work --event "$SB/event.json" --closing-file "$SB/none.json" 2>&1); RC=$?
expect_rc 1 "title, branch, labels and body come from the event payload"
mkdir -p "$SB/bin"
jq -n --arg b "$LESSON
Refs #9" '{data: {repository: {pullRequest: {body: $b, title: "Sampler", headRefName: "work", labels: {nodes: []},
  closingIssuesReferences: {nodes: []}}}}}' > "$SB/gh.json"
cat > "$SB/bin/gh" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "api graphql") cat "$SB/gh.json" ;;
  "api repos/o/r/issues/9") echo "bug-type|" ;;
  *) echo "HTTP 404: Not Found" >&2; exit 1 ;;
esac
SH
chmod +x "$SB/bin/gh"
OUT=$(PATH="$SB/bin:$PATH" bash "$SUT" --repo "$R" --base main --head work --pr 42 --slug o/r 2>&1); RC=$?
expect_rc 0 "fixture: a referenced issue whose type is not Bug is not a fix"
sed -i.bak 's/bug-type|/Bug|/' "$SB/bin/gh"
OUT=$(PATH="$SB/bin:$PATH" bash "$SUT" --repo "$R" --base main --head work --pr 42 --slug o/r 2>&1); RC=$?
expect_rc 0 "with --pr alone, body and a Refs'd Bug issue come from GitHub, and the Lesson passes"
expect_out 'it references #9, a bug' "and the issue was looked up"
printf '#!/usr/bin/env bash\necho "HTTP 502" >&2; exit 1\n' > "$SB/bin/gh"
OUT=$(PATH="$SB/bin:$PATH" bash "$SUT" --repo "$R" --base main --head work --pr 42 --slug o/r 2>&1); RC=$?
expect_rc 2 "a GitHub read that fails refuses (exit 2), never passes"
first_line "lesson: could not read GitHub, not a missing lesson" "and its first line says so"

suite_end "$fail"
