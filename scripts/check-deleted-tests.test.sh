#!/usr/bin/env bash
# Fixture test for check-deleted-tests.sh.
#
# WHY THIS EXISTS
#   A guard for deleted tests is itself only worth its own tests. Every case below
#   builds a throwaway repo, commits a trunk, cuts a branch, PLANTS a deletion (or
#   one of the shapes that must NOT be flagged), and asserts on the gate's exit
#   code and on the path or case title it names. Nothing here reads the real kit.
#
#   The first case is the incident itself: a case called "a writer can post for a
#   teammate" leaves a file that stays, and nothing says where it went.
set -uo pipefail

SUT="${SUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-deleted-tests.sh}"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

# A git hook exports GIT_DIR / GIT_WORK_TREE to everything it runs; inherited, they
# aim every `git` below at the real repo — on the origin machine one such test set
# the shared clone's identity and five peer commits shipped under it. Drop them all.
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@test.local
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@test.local
export GIT_CONFIG_NOSYSTEM=1 HOME="${TMPDIR:-/tmp}/dt-home-$$"
unset HARNESS_TEST_PATTERNS HARNESS_CFG_PATH
mkdir -p "$HOME"

SB="${TMPDIR:-/tmp}/dt-fixture-$$"
mkdir -p "$SB"
trap 'rm -rf "$SB" "$HOME"' EXIT
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# A throwaway repo whose trunk carries two test files and a source file, with a
# branch `work` cut from it. The caller changes things on `work` and calls check.
repo() {
  R="$SB/$1"; rm -rf "$R"; mkdir -p "$R/src"
  git -C "$R" -c init.defaultBranch=main init -q
  cat > "$R/src/desk.test.ts" <<'TS'
describe('desk', () => {
  it('opens the desk', () => {});
  it('a writer can post for a teammate', () => {
    expect(post({ createdForId: 'mate' })).toBe(true);
  });
  test("shows the queue", () => {});
});
TS
  cat > "$R/src/inbox.test.tsx" <<'TS'
it('lists messages', () => {});
TS
  printf 'export const post = () => true;\n' > "$R/src/desk.ts"
  git -C "$R" add -A && git -C "$R" commit -qm trunk
  git -C "$R" checkout -q -b work
}
commit() { git -C "$R" add -A && git -C "$R" commit -qm "${1:-change}"; }
check() { # [body]
  printf '%s\n' "${1:-}" > "$SB/body.md"
  OUT=$(bash "$SUT" --repo "$R" --base main --head work --body-file "$SB/body.md" 2>&1); RC=$?
}
expect_rc() { # <want> <label>
  [ "$RC" -eq "$1" ] && ok "$2" || { bad "$2 (rc $RC, want $1)"; printf '%s\n' "$OUT" | sed 's/^/        /'; }
}
expect_out() { # <regex> <label>
  printf '%s' "$OUT" | grep -qE -- "$1" && ok "$2" || { bad "$2 — output did not match /$1/"; printf '%s\n' "$OUT" | sed 's/^/        /'; }
}

echo "check-deleted-tests fixture"

# --- 1. THE INCIDENT: a case leaves a file that stays -----------------------------
repo incident
perl -0pi -e "s/  it\('a writer can post for a teammate'.*?\n  \}\);\n//s" "$R/src/desk.test.ts"
grep -q 'teammate' "$R/src/desk.test.ts" && bad "fixture: the plant did not remove the case"
commit "rebuild the desk"
check
expect_rc 1 "a deleted it( case with no accounting stops the gate"
expect_out 'src/desk.test.ts.*lost 1 case' "it names the file and says a case was lost"
expect_out 'src/desk.test.ts: a writer can post for a teammate' "and it names the case that was lost"
expect_out '^- `src/desk.test.ts` → covered by' "and hands back a line ready to paste"

# --- 2. A whole test file deleted, nothing said -----------------------------------
repo wholefile
git -C "$R" rm -q src/desk.test.ts; commit
check
expect_rc 1 "a deleted test file with no body stops the gate"
expect_out 'src/desk.test.ts — deleted \(3 cases\)' "it names the file and how many cases went with it"

# --- 3. Covered by a test that exists: accounted ----------------------------------
repo covered
git -C "$R" rm -q src/desk.test.ts
cat > "$R/src/one-desk.test.ts" <<'TS'
it('a writer can post for a teammate', () => {});
TS
commit
check '## Summary
rebuilt

## Deleted tests
- `src/desk.test.ts` → covered by `src/one-desk.test.ts`'
expect_rc 0 "'covered by' a test file that exists at head passes"

# --- 4. Covered by a file that does not exist -------------------------------------
repo covered-missing
git -C "$R" rm -q src/desk.test.ts; commit
check '## Deleted tests
- `src/desk.test.ts` → covered by `src/imaginary.test.ts`'
expect_rc 1 "'covered by' a path that is not at head fails"
expect_out 'does not exist at head' "and says why"

# --- 5. Covered by the source file, not a test ------------------------------------
repo covered-source
git -C "$R" rm -q src/desk.test.ts; commit
check '## Deleted tests
- `src/desk.test.ts` → covered by `src/desk.ts`'
expect_rc 1 "'covered by' a file that is not a test fails"
expect_out 'not a test file' "and says why"

# --- 6. Covered by a test file with every case skipped ----------------------------
repo covered-skipped
git -C "$R" rm -q src/desk.test.ts
printf "it.skip('a writer can post for a teammate', () => {});\n" > "$R/src/one-desk.test.ts"
commit
check '## Deleted tests
- `src/desk.test.ts` → covered by `src/one-desk.test.ts`'
expect_rc 1 "'covered by' a test file with no live case fails"
expect_out 'no live it\(/test\( case' "and says why"

# --- 7. Removed on purpose, with and without a reason -----------------------------
repo purpose
git -C "$R" rm -q src/desk.test.ts; commit
check '## Deleted tests
- src/desk.test.ts -> removed on purpose: the desk is retired, nothing replaces it'
expect_rc 0 "'removed on purpose: <reason>' passes (-> and no backticks accepted)"
check '## Deleted tests
- `src/desk.test.ts` → removed on purpose: <reason>'
expect_rc 1 "the placeholder '<reason>' is not a reason"
check '## Deleted tests
- `src/desk.test.ts` → removed on purpose:'
expect_rc 1 "an empty reason is not a reason"
check '## Deleted tests
- `src/desk.test.ts` → gone'
expect_rc 1 "a line that says neither form fails"

# --- 8. The line must be IN the section -------------------------------------------
repo wrong-section
git -C "$R" rm -q src/desk.test.ts; commit
check '## Summary
- `src/desk.test.ts` → removed on purpose: the desk is retired

## Deleted tests
nothing to see'
expect_rc 1 "an accounting line under another heading does not count"

# --- 9. A rename is not a deletion ------------------------------------------------
repo rename
mkdir -p "$R/src/desk"; git -C "$R" mv src/desk.test.ts src/desk/desk.test.ts; commit
check
expect_rc 0 "a renamed test file with its cases intact passes with no body"

# --- 10. A rename that drops a case on the way is still caught --------------------
repo rename-lossy
mkdir -p "$R/src/desk"; git -C "$R" mv src/desk.test.ts src/desk/desk.test.ts
perl -pi -e 's/  test\("shows the queue", \(\) => \{\}\);\n//' "$R/src/desk/desk.test.ts"
grep -q 'shows the queue' "$R/src/desk/desk.test.ts" && bad "fixture: the plant did not remove the case"
commit
check
expect_rc 1 "a rename that loses a case stops the gate"
expect_out 'renamed to src/desk/desk.test.ts and lost 1 case' "naming the rename and the loss"
expect_out 'shows the queue' "and the case"

# --- 11. Renamed out of the test patterns is a deletion ---------------------------
repo rename-out
git -C "$R" mv src/inbox.test.tsx src/inbox.fixture.tsx; commit
check
expect_rc 1 "a test renamed to a non-test path is a deletion"
expect_out 'which is not a test file' "and says so"

# --- 12. Skipping a case is losing it ---------------------------------------------
repo skip
perl -pi -e "s/it\('opens the desk'/it.skip('opens the desk'/" "$R/src/desk.test.ts"
grep -q "it.skip('opens the desk'" "$R/src/desk.test.ts" || bad "fixture: the skip plant did not land"
commit
check
expect_rc 1 "turning it( into it.skip( counts as a lost case"
expect_out 'opens the desk' "naming it"

# --- 13. Adding, editing and non-test changes are none of its business -------------
repo additive
printf "  it('a new case', () => {});\n" >> "$R/src/inbox.test.tsx"
perl -pi -e 's/toBe\(true\)/toBe(!!true)/' "$R/src/desk.test.ts"
git -C "$R" rm -q src/desk.ts
commit
check
expect_rc 0 "added cases, edited bodies and a deleted source file pass"

# --- 14. x.test( is a method call, not a case -------------------------------------
repo regex-test
printf "it('matches', () => { expect(/a/.test('a')).toBe(true); });\n" > "$R/src/re.test.ts"
git -C "$R" checkout -q main; commit "trunk adds re"; git -C "$R" checkout -q work
git -C "$R" merge -q --ff-only main
printf "it('matches', () => { expect(true).toBe(true); });\n" > "$R/src/re.test.ts"
commit
check
expect_rc 0 "removing a /re/.test( call is not removing a case"

# --- 15. Something the TRUNK added after the cut is not this branch's deletion ------
repo trunk-added
git -C "$R" checkout -q main
printf "it('trunk only', () => {});\n" > "$R/src/later.test.ts"
printf "it('another trunk case', () => {});\n" >> "$R/src/inbox.test.tsx"
commit "trunk moves on"
git -C "$R" checkout -q work
printf 'x\n' > "$R/notes.txt"; commit
check
expect_rc 0 "a test file and a case added on the trunk after the cut are not deletions"
expect_out 'test files deleted or losing cases   : 0' "and the count says zero"

# --- 16. It reads commits, never the working tree ----------------------------------
repo worktree-only
rm "$R/src/desk.test.ts"
printf 'x\n' > "$R/notes.txt"; git -C "$R" add notes.txt; git -C "$R" commit -qm notes
check
expect_rc 0 "an uncommitted deletion in the working tree is not read"
git -C "$R" add -A; git -C "$R" commit -qm "now it is committed"
check
expect_rc 1 "and the same deletion, committed, is"

# --- 17. Patterns come from harness.json -------------------------------------------
repo cfg
mkdir -p "$R/.claude" "$R/t"
printf '{"tests":{"patterns":["*.test.sh"]}}\n' > "$R/.claude/harness.json"
printf 'echo ok\n' > "$R/t/gate.test.sh"
git -C "$R" checkout -q main; commit "trunk config"; git -C "$R" checkout -q work
git -C "$R" merge -q --ff-only main
git -C "$R" rm -q t/gate.test.sh src/desk.test.ts; commit
check
expect_rc 1 "a pattern from harness.json is what counts as a test"
expect_out 't/gate.test.sh' "the configured file is named"
printf '%s' "$OUT" | grep -q 'src/desk.test.ts' && bad "a file outside the configured patterns was flagged" \
  || ok "and a file outside the configured patterns is not"
HARNESS_TEST_PATTERNS='*.test.ts' check
expect_out 'src/desk.test.ts' "HARNESS_TEST_PATTERNS overrides the config"
printf '{"tests":{"patterns":"*.test.sh"}}\n' > "$R/.claude/harness.json"
check
expect_rc 2 "tests.patterns that is not a list is a refusal, not a default"

# --- 18. It refuses rather than reporting clean when it cannot measure ------------
repo badref
OUT=$(bash "$SUT" --repo "$R" --base no-such-branch --head work 2>&1); RC=$?
expect_rc 2 "a base that does not resolve is a refusal"
OUT=$(bash "$SUT" --repo "$SB/not-a-repo" --base main 2>&1); RC=$?
expect_rc 2 "a directory that is not a repo is a refusal"

# --- 19. A case renamed where it stands is not a lost test --------------------------
# Measured on the origin project: 74 of 85 files this check flagged kept or grew their
# case count. The commonest shape was one title reworded in place.
repo rename-in-place
perl -pi -e "s/it\('opens the desk'/it('opens the desk on the queue tab'/" "$R/src/desk.test.ts"
grep -q "opens the desk on the queue tab" "$R/src/desk.test.ts" || bad "fixture: the rename plant did not land"
commit
check
expect_rc 0 "a case renamed in place passes with no body"
expect_out 'cases renamed, rewritten or moved    : 1' "and is counted as renamed"

# --- 20. A case rewritten in place, new words, same count --------------------------
repo rewrite-in-place
perl -pi -e 's/test\("shows the queue"/test("lists every waiting post, oldest first"/' "$R/src/desk.test.ts"
grep -q "oldest first" "$R/src/desk.test.ts" || bad "fixture: the rewrite plant did not land"
commit
check
expect_rc 0 "a case rewritten in place, the file keeping its count, passes"

# --- 21. A case moved to a new file ------------------------------------------------
repo move-new-file
perl -pi -e 's/  test\("shows the queue", \(\) => \{\}\);\n//' "$R/src/desk.test.ts"
grep -q 'shows the queue' "$R/src/desk.test.ts" && bad "fixture: the plant did not remove the case"
printf "test('shows the queue', () => {});\n" > "$R/src/queue.test.ts"
commit
check
expect_rc 0 "a case moved word for word into a new test file passes"

# --- 22. A case moved to another file with a reword --------------------------------
repo move-reword
perl -0pi -e "s/  it\('a writer can post for a teammate'.*?\n  \}\);\n//s" "$R/src/desk.test.ts"
grep -q 'teammate' "$R/src/desk.test.ts" && bad "fixture: the plant did not remove the case"
printf "it('a writer can post for a teammate from the inbox', () => {});\n" >> "$R/src/inbox.test.tsx"
commit
check
expect_rc 0 "a case moved to another file with most of its words passes"

# --- 23. Same count, but a named test is gone with nothing like it -------------------
repo swapped
perl -0pi -e "s/  it\('a writer can post for a teammate'.*?\n  \}\);\n//s" "$R/src/desk.test.ts"
grep -q 'teammate' "$R/src/desk.test.ts" && bad "fixture: the plant did not remove the case"
printf "it('sorts messages by sender', () => {});\n" >> "$R/src/inbox.test.tsx"
commit
check
expect_rc 1 "a case gone with nothing like it stops the gate, even when the total holds"
expect_out 'src/desk.test.ts.*lost 1 case' "naming the file"
expect_out 'src/desk.test.ts: a writer can post for a teammate' "and the case"
expect_out 'cases in them, base -> head          : 4 -> 4' "while the total says nothing dropped"

# --- 24. A file deleted whose cases all moved ---------------------------------------
repo split
git -C "$R" rm -q src/desk.test.ts
cat > "$R/src/desk-open.test.ts" <<'TS'
it('opens the desk', () => {});
it('a writer can post for a teammate', () => {});
TS
printf "test('shows the queue', () => {});\n" > "$R/src/desk-queue.test.ts"
commit
check
expect_rc 0 "a test file split into two, every case kept, passes with no body"

# --- 25. Two cases become one: the count drops ---------------------------------------
repo merge-two
perl -pi -e "s/it\('opens the desk'/it('opens the desk and shows the queue'/; s/  test\(\"shows the queue\", \(\) => \{\}\);\n//" "$R/src/desk.test.ts"
grep -q 'test("shows the queue"' "$R/src/desk.test.ts" && bad "fixture: the plant did not remove the case"
commit
check
expect_rc 1 "two cases folded into one is a lost case"
expect_out 'src/desk.test.ts.*lost 1 case' "naming one loss"
expect_out 'cases in them, base -> head          : 3 -> 2' "and the drop"

# --- 26. Filler words alone do not make a case "like" another -----------------------
repo filler
perl -pi -e "s/  it\('opens the desk', \(\) => \{\}\);\n//" "$R/src/desk.test.ts"
grep -q 'opens the desk' "$R/src/desk.test.ts" && bad "fixture: the plant did not remove the case"
printf "it('closes the desk', () => {});\n" >> "$R/src/inbox.test.tsx"
commit
check
expect_rc 1 "a case moved to another file sharing only 'the desk' is not a match"
expect_out 'src/desk.test.ts: opens the desk' "naming the case"

# --- 27. A case the trunk retired, still on a stale branch, is not a new case --------
repo stale
git -C "$R" checkout -q main
perl -pi -e 's/  test\("shows the queue", \(\) => \{\}\);\n//' "$R/src/desk.test.ts"
grep -q 'shows the queue' "$R/src/desk.test.ts" && bad "fixture: the trunk plant did not land"
commit "trunk retires the queue case"
git -C "$R" checkout -q work
perl -0pi -e "s/  it\('a writer can post for a teammate'.*?\n  \}\);\n//s" "$R/src/desk.test.ts"
grep -q 'teammate' "$R/src/desk.test.ts" && bad "fixture: the plant did not remove the case"
grep -q 'shows the queue' "$R/src/desk.test.ts" || bad "fixture: the branch should still carry the retired case"
commit
check
expect_rc 1 "a case the trunk retired does not absorb a case the branch dropped"
expect_out 'src/desk.test.ts: a writer can post for a teammate' "naming the dropped case"

# A case turned off still has a title, so a new case in the same file must not
# absorb it as a rewrite. Each plant below turns one case off and adds one.
add_case() { printf "it('sorts the queue by age', () => {});\n" >> "$R/src/desk.test.ts"; }
TEAMMATE_CASE="  it\('a writer can post for a teammate'.*?\n  \}\);\n"

# --- 28. it.skip plus a new case: turned off, not rewritten --------------------------
repo skip-plus-new
perl -pi -e "s/it\('a writer can post for a teammate'/it.skip('a writer can post for a teammate'/" "$R/src/desk.test.ts"
add_case
grep -q "it.skip('a writer can post for a teammate'" "$R/src/desk.test.ts" || bad "fixture: the skip plant did not land"
grep -q "sorts the queue by age" "$R/src/desk.test.ts" || bad "fixture: the new case did not land"
commit
check
expect_rc 1 "a case skipped while another is added is not a rewrite"
expect_out 'src/desk.test.ts.*turned off 1 case' "it says the case was turned off"
expect_out 'src/desk.test.ts: a writer can post for a teammate' "and names it"
check '## Deleted tests
- `src/desk.test.ts` → removed on purpose: retired with the old desk'
expect_rc 0 "and a reason in the body accounts for it"

# --- 29. test.todo plus a new case ------------------------------------------------------
repo todo-plus-new
perl -0pi -e "s/$TEAMMATE_CASE/  test.todo('a writer can post for a teammate');\n/s" "$R/src/desk.test.ts"
add_case
grep -q "test.todo('a writer can post for a teammate')" "$R/src/desk.test.ts" || bad "fixture: the todo plant did not land"
commit
check
expect_rc 1 "a case turned into test.todo while another is added is lost"
expect_out 'src/desk.test.ts: a writer can post for a teammate' "naming it"

# --- 30. xit plus a new case ------------------------------------------------------------
repo xit-plus-new
perl -pi -e "s/it\('opens the desk'/xit('opens the desk'/" "$R/src/desk.test.ts"
add_case
grep -q "xit('opens the desk'" "$R/src/desk.test.ts" || bad "fixture: the xit plant did not land"
commit
check
expect_rc 1 "a case turned into xit while another is added is lost"
expect_out 'src/desk.test.ts: opens the desk' "naming it"

# --- 31. A case wrapped in describe.skip plus a new case --------------------------------
repo describe-skip
perl -0pi -e "s/($TEAMMATE_CASE)/  describe.skip('legacy', () => {\n\$1  });\n/s" "$R/src/desk.test.ts"
add_case
grep -q "describe.skip('legacy'" "$R/src/desk.test.ts" || bad "fixture: the describe.skip plant did not land"
grep -q "a writer can post for a teammate" "$R/src/desk.test.ts" || bad "fixture: the wrapped case should still be in the file"
commit
check
expect_rc 1 "a case inside a skipped describe is off"
expect_out 'src/desk.test.ts: a writer can post for a teammate' "naming it"

# --- 32. A case wrapped in xdescribe plus a new case ------------------------------------
repo xdescribe
perl -0pi -e "s/($TEAMMATE_CASE)/  xdescribe('legacy', () => {\n\$1  });\n/s" "$R/src/desk.test.ts"
add_case
grep -q "xdescribe('legacy'" "$R/src/desk.test.ts" || bad "fixture: the xdescribe plant did not land"
commit
check
expect_rc 1 "a case inside an xdescribe is off"
expect_out 'src/desk.test.ts: a writer can post for a teammate' "naming it"

# --- 33. it.only turns its siblings off -------------------------------------------------
repo only-case
perl -pi -e "s/it\('opens the desk'/it.only('opens the desk'/" "$R/src/desk.test.ts"
grep -q "it.only('opens the desk'" "$R/src/desk.test.ts" || bad "fixture: the .only plant did not land"
commit
check
expect_rc 1 "an it.only left in a file turns the other cases off"
expect_out 'src/desk.test.ts: a writer can post for a teammate' "naming one sibling"
expect_out 'src/desk.test.ts: shows the queue' "and the other"
expect_out 'cases in them, base -> head          : 3 -> 1' "and only one case still runs"

# --- 34. describe.only over the whole file excludes nothing -----------------------------
repo only-describe
perl -pi -e "s/describe\('desk'/describe.only('desk'/" "$R/src/desk.test.ts"
grep -q "describe.only('desk'" "$R/src/desk.test.ts" || bad "fixture: the describe.only plant did not land"
commit
check
expect_rc 0 "a describe.only around every case in the file excludes nothing"

# --- 35. Skipped and reworded at once is still off --------------------------------------
repo skip-reword
perl -pi -e "s/it\('a writer can post for a teammate'/it.skip('writer posts for teammate'/" "$R/src/desk.test.ts"
printf "it('opens the queue tab', () => {});\n" >> "$R/src/desk.test.ts"
grep -q "it.skip('writer posts for teammate'" "$R/src/desk.test.ts" || bad "fixture: the skip-reword plant did not land"
commit
check
expect_rc 1 "a case skipped and reworded while another is added is lost"
expect_out 'src/desk.test.ts: a writer can post for a teammate' "naming it"

# --- 36. Turning a skipped case back on is not a loss -----------------------------------
repo unskip
git -C "$R" checkout -q main
perl -pi -e "s/it\('opens the desk'/it.skip('opens the desk'/" "$R/src/desk.test.ts"
grep -q "it.skip('opens the desk'" "$R/src/desk.test.ts" || bad "fixture: the trunk skip plant did not land"
commit "trunk skips a case"
git -C "$R" checkout -q work; git -C "$R" merge -q --ff-only main
perl -pi -e "s/it\.skip\('opens the desk'/it('opens the desk'/" "$R/src/desk.test.ts"
grep -q "it.skip(" "$R/src/desk.test.ts" && bad "fixture: the un-skip plant did not land"
commit
check
expect_rc 0 "a skipped case turned back on is not a loss"

# --- 37. A new placeholder never claims a reworded case -----------------------------------
repo reword-plus-todo
perl -pi -e "s/it\('opens the desk'/it('the desk opens on load'/" "$R/src/desk.test.ts"
printf "%s\n" "it.todo('sorts the queue by age');" >> "$R/src/desk.test.ts"
grep -q "it('the desk opens on load'" "$R/src/desk.test.ts" || bad "fixture: the reword plant did not land"
grep -q "it.todo('sorts the queue by age')" "$R/src/desk.test.ts" || bad "fixture: the todo plant did not land"
commit
check
expect_rc 0 "a new placeholder beside a reworded case is not a loss"

# --- 38–43. A read that fails refuses; it never reports clean ----------------------------
# Each case puts a `git` on PATH for the gate alone that fails one kind of read and
# hands everything else to the real git. The fixture's own git never sees it.
REAL_GIT=$(command -v git)
shim() { # <name> <bash body run before the real git; "$@" is git's argv>
  mkdir -p "$SB/shim-$1"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$2"; printf 'exec "%s" "$@"\n' "$REAL_GIT"; } > "$SB/shim-$1/git"
  chmod +x "$SB/shim-$1/git"
}
check_shim() { # <name> [body]
  printf '%s\n' "${2:-}" > "$SB/body.md"
  OUT=$(PATH="$SB/shim-$1:$PATH" bash "$SUT" --repo "$R" --base main --head work --body-file "$SB/body.md" 2>&1); RC=$?
}
expect_not_out() { # <regex> <label>
  printf '%s' "$OUT" | grep -qE -- "$1" && { bad "$2 — output matched /$1/"; printf '%s\n' "$OUT" | sed 's/^/        /'; } || ok "$2"
}

# 38. The diff itself fails.
shim diff-fails 'for a in "$@"; do [ "$a" = diff ] && { echo "fatal: forced" >&2; exit 128; }; done'
repo diff-fails
git -C "$R" rm -q src/inbox.test.tsx; commit
check_shim diff-fails
expect_rc 2 "a diff git could not produce refuses"
expect_out 'could not read the diff' "saying the diff could not be read"
expect_not_out 'test files deleted or losing cases   : 0' "and never reports nothing found"

# 39. A test file cannot be read at one commit.
shim show-fails 'for a in "$@"; do case "$a" in *:*.test.ts) for b in "$@"; do [ "$b" = show ] && { echo "fatal: forced" >&2; exit 128; }; done ;; esac; done'
repo show-fails
add_case; commit
check_shim show-fails
expect_rc 2 "a test file git could not read refuses"
expect_out "could not read src/desk.test.ts at [0-9a-f]{7,}" "naming the file and the commit"

# 40. The control count cannot list the tree.
shim ls-tree-fails 'for a in "$@"; do [ "$a" = ls-tree ] && { echo "fatal: forced" >&2; exit 128; }; done'
repo ls-tree-fails
add_case; commit
check_shim ls-tree-fails
expect_rc 2 "a control count git could not take refuses"
expect_out 'could not list the files at base' "naming the control step"

# 41. The diff succeeds but a record is cut short: a status with no path.
shim diff-truncated 'for a in "$@"; do [ "$a" = diff ] && { printf "M\0"; exit 0; }; done'
repo diff-truncated
add_case; commit
check_shim diff-truncated
expect_rc 2 "a diff record with no path refuses"
expect_out 'could not parse the diff' "saying the diff could not be parsed"

# 42. The file named as "covered by" cannot be read at head.
shim show-tsx-fails 'for a in "$@"; do case "$a" in *:*.test.tsx) for b in "$@"; do [ "$b" = show ] && { echo "fatal: forced" >&2; exit 128; }; done ;; esac; done'
repo covered-unreadable
git -C "$R" rm -q src/desk.test.ts; commit
check_shim show-tsx-fails "$(printf '## Deleted tests\n- `src/desk.test.ts` → covered by `src/inbox.test.tsx`')"
expect_rc 2 "a covering file git could not read refuses"
expect_out 'could not read src/inbox.test.tsx at' "naming the covering file"

# 43. Whether a deleted file was at the merge-base cannot be read.
shim mb-tree-fails 'r=0; for a in "$@"; do [ "$a" = -r ] && r=1; done; for a in "$@"; do [ "$a" = ls-tree ] && [ $r -eq 0 ] && { echo "fatal: forced" >&2; exit 128; }; done'
repo mb-unreadable
git -C "$R" rm -q src/desk.test.ts; commit
check_shim mb-tree-fails
expect_rc 2 "a merge-base tree git could not read refuses"
expect_out 'could not read the tree at the merge-base' "saying so"

# 44. A deleted file read fine for its cases, then fails when the gate counts its total.
# The gate reads it at base and at the merge-base first; the third read is the total.
shim third-show-fails 'for a in "$@"; do case "$a" in *:src/desk.test.ts) for b in "$@"; do [ "$b" = show ] || continue; n=$(( $(cat "$SHOW_COUNT" 2>/dev/null || echo 0) + 1 )); echo $n > "$SHOW_COUNT"; [ $n -ge 3 ] && { echo "fatal: forced" >&2; exit 128; }; done ;; esac; done'
repo total-unreadable
git -C "$R" rm -q src/desk.test.ts; commit
export SHOW_COUNT="$SB/show-count"; rm -f "$SHOW_COUNT"
check_shim third-show-fails
unset SHOW_COUNT
expect_rc 2 "a deleted file git could not read for its total refuses"
expect_out 'could not read src/desk.test.ts at' "naming the file"
expect_not_out 'deleted \(0 cases\)' "and never counts it as empty"

# 45. A test file new at head cannot be read there.
shim new-file-fails 'for a in "$@"; do case "$a" in *:src/new.test.ts) for b in "$@"; do [ "$b" = show ] && { echo "fatal: forced" >&2; exit 128; }; done ;; esac; done'
repo head-unreadable
printf "it('opens a new desk', () => {});\n" > "$R/src/new.test.ts"; commit
check_shim new-file-fails
expect_rc 2 "a test file new at head git could not read refuses"
expect_out 'could not read src/new.test.ts at' "naming it"

# 46. A test file reads at base and head but not at the merge-base.
shim mb-show-fails 'for a in "$@"; do case "$a" in "$FAIL_REV":*) for b in "$@"; do [ "$b" = show ] && { echo "fatal: forced" >&2; exit 128; }; done ;; esac; done'
repo mb-show-unreadable
git -C "$R" checkout -q main; printf 'export const other = 1;\n' > "$R/src/other.ts"; commit "trunk moves on"
git -C "$R" checkout -q work; add_case; commit
export FAIL_REV=$(git -C "$R" merge-base main work)
[ "$FAIL_REV" != "$(git -C "$R" rev-parse main)" ] || bad "fixture: the merge-base should not be base"
check_shim mb-show-fails
unset FAIL_REV
expect_rc 2 "a test file git could not read at the merge-base refuses"
expect_out 'could not read src/desk.test.ts at' "naming it"

# 47. A test file reads at head and the merge-base but not at base.
repo base-show-unreadable
git -C "$R" checkout -q main; printf 'export const other = 1;\n' > "$R/src/other.ts"; commit "trunk moves on"
git -C "$R" checkout -q work; add_case; commit
export FAIL_REV=$(git -C "$R" rev-parse main)
[ "$FAIL_REV" != "$(git -C "$R" merge-base main work)" ] || bad "fixture: base should not be the merge-base"
check_shim mb-show-fails
unset FAIL_REV
expect_rc 2 "a test file git could not read at base refuses"
expect_out 'could not read src/desk.test.ts at' "naming it"

# --- 48. A .only quoted in a string excludes nothing ----------------------------------
repo only-in-string
printf "const sample = \"it.only('x', () => {})\";\n" >> "$R/src/desk.test.ts"
grep -q 'const sample = "it.only' "$R/src/desk.test.ts" || bad "fixture: the quoted .only plant did not land"
commit
check
expect_rc 0 "a .only inside a string does not turn the file's cases off"
expect_not_out 'turned off' "and nothing is reported as turned off"

echo
[ "$fail" -eq 0 ] && echo "check-deleted-tests: all cases pass" || echo "check-deleted-tests: FAILURES above"
exit $fail
