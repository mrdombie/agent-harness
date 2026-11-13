#!/usr/bin/env bash
# Fixture test for check-deleted-tests.sh on a branch the trunk has moved past.
#
# WHY THIS EXISTS
#   The gate read the diff base..head, so a test file the trunk renamed after the
#   branch was cut entered the diff under a name the merge-base never had. The gate
#   then could not read it there and refused to ship changes that deleted no test.
#   Every case below cuts a branch, moves the trunk on, and asserts the gate judges
#   only what the branch itself changed — and still catches what the branch deletes.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1

SUT="${SUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-deleted-tests.sh}"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

# Inherited from a git hook, GIT_* aims every `git` below at the real repo. Drop them all.
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@test.local
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@test.local
export GIT_CONFIG_NOSYSTEM=1 HOME="${TMPDIR:-/tmp}/dtmb-home-$$"
unset HARNESS_CFG_PATH
export HARNESS_TEST_PATTERNS='*.test.ts *.test.tsx *.spec.ts *.test.sh'
mkdir -p "$HOME"

SB="${TMPDIR:-/tmp}/dtmb-fixture-$$"
mkdir -p "$SB"
on_exit_keep_status 'rm -rf "$SB" "$HOME"'
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# A throwaway repo: the trunk carries two test files and src/checks.sh, which holds
# cases but is not a test file by name. A branch `work` is cut from it.
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
  printf "it('lists messages', () => {});\n" > "$R/src/inbox.test.tsx"
  printf "it('checks the desk', () => {});\nit('checks the inbox', () => {});\n" > "$R/src/checks.sh"
  git -C "$R" add -A && git -C "$R" commit -qm trunk
  git -C "$R" checkout -q -b work
}
commit() { git -C "$R" add -A && git -C "$R" commit -qm "${1:-change}"; }
# The trunk moves on after the cut: the file that was not a test takes a test name.
trunk_renames() {
  git -C "$R" checkout -q main
  git -C "$R" mv src/checks.sh src/checks.test.sh; commit "trunk gives the checks a test name"
  git -C "$R" checkout -q work
  [ -z "$(git -C "$R" ls-tree --name-only "$(git -C "$R" merge-base main work)" -- src/checks.test.sh)" ] \
    || bad "fixture: the test name should not be at the merge-base"
  [ -n "$(git -C "$R" ls-tree --name-only main -- src/checks.test.sh)" ] || bad "fixture: the trunk rename did not land"
}
check() {
  OUT=$(bash "$SUT" --repo "$R" --base main --head work 2>&1); RC=$?
}
expect_rc() { # <want> <label>
  [ "$RC" -eq "$1" ] && ok "$2" || { bad "$2 (rc $RC, want $1)"; printf '%s\n' "$OUT" | sed 's/^/        /'; }
}
expect_out() { # <regex> <label>
  printf '%s' "$OUT" | grep -qE -- "$1" && ok "$2" || { bad "$2 — output did not match /$1/"; printf '%s\n' "$OUT" | sed 's/^/        /'; }
}
expect_not_out() { # <regex> <label>
  printf '%s' "$OUT" | grep -qE -- "$1" && { bad "$2 — output matched /$1/"; printf '%s\n' "$OUT" | sed 's/^/        /'; } || ok "$2"
}
TEAMMATE_CASE="  it\('a writer can post for a teammate'.*?\n  \}\);\n"
drop_teammate() {
  perl -0pi -e "s/$TEAMMATE_CASE//s" "$R/src/desk.test.ts"
  grep -q 'teammate' "$R/src/desk.test.ts" && bad "fixture: the plant did not remove the case"
}

echo "check-deleted-tests on a branch the trunk has moved past"

# --- 1. THE INCIDENT: the trunk renames a file to a test name; the branch deletes nothing --
repo trunk-renamed
trunk_renames
printf 'x\n' > "$R/notes.txt"; commit
check
expect_rc 0 "a file the trunk renamed to a test name after the cut is not this branch's change"
expect_not_out 'refusing to report clean' "and nothing is refused"
expect_out 'test files the diff touches          : 0' "and the diff touches no test file"
expect_out 'control, test files at base          : 3' "while the control still sees the test files at base"

# --- 2. The trunk adds a test file after the cut and the branch adds one like it ----------
repo trunk-added-twin
git -C "$R" checkout -q main
printf "it('pins one', () => {});\nit('pins two', () => {});\nit('pins three', () => {});\nit('pins four', () => {});\n" > "$R/src/later.test.ts"
commit "trunk moves on"
git -C "$R" checkout -q work
printf "it('pins one', () => {});\nit('pins two', () => {});\nit('pins three', () => {});\nit('pins five', () => {});\n" > "$R/src/mine.test.ts"
commit
check
expect_rc 0 "a new test file is never read as a rename of one the trunk added"
expect_not_out 'refusing to report clean' "and nothing is refused"

# --- 3. A test file deleted on a stale branch is still reported ---------------------------
repo stale-deletes-file
trunk_renames
git -C "$R" rm -q src/desk.test.ts; commit
check
expect_rc 1 "a test file deleted on a stale branch stops the gate"
expect_out 'src/desk.test.ts — deleted \(3 cases\)' "naming the file and its cases"
expect_not_out 'checks\.test\.sh' "and never the file the trunk renamed"

# --- 4. And so is a case deleted inside a test file that stays ----------------------------
repo stale-deletes-case
trunk_renames
drop_teammate; commit
check
expect_rc 1 "a case deleted on a stale branch stops the gate"
expect_out 'src/desk.test.ts.*lost 1 case' "naming the file"
expect_out 'src/desk.test.ts: a writer can post for a teammate' "and the case"

# --- 5. A test file the trunk deleted too is not the branch's to account for ---------------
repo both-deleted
git -C "$R" checkout -q main; git -C "$R" rm -q src/inbox.test.tsx; commit "trunk retires the inbox"
git -C "$R" checkout -q work
git -C "$R" rm -q src/inbox.test.tsx; commit
check
expect_rc 0 "a test file gone from base too is not this branch's deletion"
expect_not_out 'refusing to report clean' "and nothing is refused"

# --- 6. A file the trunk deleted never stands in for a case the branch dropped -------------
# From base, the trunk's deletion reads as a test file new at head, and its case as a gain.
repo trunk-deleted-no-cover
git -C "$R" checkout -q main; git -C "$R" rm -q src/inbox.test.tsx; commit "trunk retires the inbox"
git -C "$R" checkout -q work
drop_teammate; commit
check
expect_rc 1 "a case dropped beside a file the trunk deleted stops the gate"
expect_out 'src/desk.test.ts: a writer can post for a teammate' "naming the case"
expect_out 'test files the diff touches          : 1' "and only the branch's own file is in the diff"

# --- 7. A commit the repo does not have refuses --------------------------------------------
repo missing-commit
trunk_renames
printf 'x\n' > "$R/notes.txt"; commit
GONE=1234567890abcdef1234567890abcdef12345678
OUT=$(bash "$SUT" --repo "$R" --base "$GONE" --head work 2>&1); RC=$?
expect_rc 2 "a base commit the repo does not have is a refusal"
expect_out 'does not resolve to a commit' "saying it does not resolve"
OUT=$(bash "$SUT" --repo "$R" --base main --head "$GONE" 2>&1); RC=$?
expect_rc 2 "and so is a head commit it does not have"

# --- 8. A tree git cannot read refuses, on a stale branch too ------------------------------
# A `git` on PATH for the gate alone that fails every read of one path's tree entry.
REAL_GIT=$(command -v git)
mkdir -p "$SB/shim"
{ printf '#!/usr/bin/env bash\n'
  printf '%s\n' 'r=0; for a in "$@"; do [ "$a" = -r ] && r=1; done; for a in "$@"; do [ "$a" = ls-tree ] && [ $r -eq 0 ] && { echo "fatal: forced" >&2; exit 128; }; done'
  printf 'exec "%s" "$@"\n' "$REAL_GIT"; } > "$SB/shim/git"
chmod +x "$SB/shim/git"
repo stale-tree-unreadable
trunk_renames
git -C "$R" rm -q src/desk.test.ts; commit
OUT=$(PATH="$SB/shim:$PATH" bash "$SUT" --repo "$R" --base main --head work 2>&1); RC=$?
expect_rc 2 "a tree git could not read refuses"
expect_out 'could not read the tree at base [0-9a-f]{7,}' "naming base"
expect_not_out 'test files deleted or losing cases' "and never reports a count"

echo
[ "$fail" -eq 0 ] && echo "check-deleted-tests-merge-base: all cases pass" || echo "check-deleted-tests-merge-base: FAILURES above"
suite_end "$fail"
