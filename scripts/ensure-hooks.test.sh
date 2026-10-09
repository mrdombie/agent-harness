#!/usr/bin/env bash
# ensure-hooks.test.sh — a worktree runs ITS OWN .husky/pre-push, whatever happened
# to the main clone's shims or its shared core.hooksPath, and a worktree whose hook
# would not run is refused.
#
# Real repos on disk, real `git push` to a real bare remote: the defect was git
# finding no hook and pushing anyway, so only git can say whether it is fixed.
#
# Run: bash "$0"
set -uo pipefail
# A hook environment exports GIT_DIR and friends; left set, every git call below
# would act on the repo the suite was launched from.
while IFS= read -r v; do unset "$v"; done < <(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p')
export GIT_CONFIG_NOSYSTEM=1 HOME
SCRIPT="${ENSURE_HOOKS:-$(cd "$(dirname "$0")" && pwd)/ensure-hooks.sh}"

FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
FIX=$(cd "$FIX" && pwd -P)
HOME="$FIX/home"; mkdir -p "$HOME"
git config --global user.email t@example.invalid
git config --global user.name Tester
git config --global init.defaultBranch develop
FAILED=0
ok()   { printf 'OK       %s\n' "$1"; }
bad()  { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }
want_in() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — '$2' not in: $3" ;; esac; }

# A main clone laid out as husky leaves it: tracked .husky/pre-push, the shared
# core.hooksPath RELATIVE (.husky/_), and — the defect — no .husky/_ shims.
# $1 = dir, $2 = what the tracked pre-push does ("pass" | "fail" | "slow").
make_repo() {
  local r="$1"
  git init -q "$r"
  mkdir -p "$r/.husky" "$r/sub"
  printf '.husky/_\n' > "$r/.gitignore"
  : > "$r/sub/.keep"
  case "$2" in
    pass) printf '#!/usr/bin/env sh\necho "ran $(basename "$PWD") v2" >> "%s/ran"\nexit 0\n' "$FIX" > "$r/.husky/pre-push" ;;
    fail) printf '#!/usr/bin/env sh\necho "ran $(basename "$PWD") v2" >> "%s/ran"\necho "✗ check:ui-gate-attested" >&2\nexit 1\n' "$FIX" > "$r/.husky/pre-push" ;;
    slow) printf '#!/usr/bin/env sh\necho $$ > "%s/hook.pid"\nsleep 30\nexit 0\n' "$FIX" > "$r/.husky/pre-push" ;;
  esac
  chmod +x "$r/.husky/pre-push"
  git -C "$r" add -A && git -C "$r" commit -qm "gate"
  git -C "$r" config core.hooksPath .husky/_
  git init -q --bare "$r.origin"
  git -C "$r" remote add origin "$r.origin"
  git -C "$r" push -q --no-verify origin develop 2>/dev/null
  # The main clone's CHECKOUT is stale, as the real one is: its pre-push is an
  # older version. A worktree must run its own, never this one.
  printf '#!/usr/bin/env sh\necho "ran main-clone v1" >> "%s/ran"\nexit 0\n' "$FIX" > "$r/.husky/pre-push"
}
# A worktree on a branch with one commit to push.
make_wt() { # <repo> <wt> <branch>
  git -C "$1" worktree add -q "$2" -b "$3" develop
  echo change > "$2/file.txt"; git -C "$2" add file.txt; git -C "$2" commit -qm change --no-verify
}
pushed() { # <repo> <branch> — 1 if the branch reached the remote
  git --git-dir="$1.origin" rev-parse --verify -q "refs/heads/$2" >/dev/null && echo 1 || echo 0
}

echo "--- a worktree whose .husky/_ was never copied runs its own pre-push ---"
R="$FIX/a"; make_repo "$R" fail; WT="$FIX/a-wt"; make_wt "$R" "$WT" t-1
want "precondition: the main clone has no shims" "0" "$([ -d "$R/.husky/_" ] && echo 1 || echo 0)"
want "precondition: the worktree has no shims" "0" "$([ -d "$WT/.husky/_" ] && echo 1 || echo 0)"
out=$(bash "$SCRIPT" "$R" "$WT" 2>&1); rc=$?
want "ensure-hooks exits 0" "0" "$rc"
: > "$FIX/ran"
git -C "$WT" hook run pre-push -- origin x </dev/null >/dev/null 2>&1; rc=$?
want "git hook run pre-push runs and fails as the hook does" "1" "$rc"
want "it ran the WORKTREE's pre-push, not the main clone's stale one" "ran a-wt v2" "$(cat "$FIX/ran")"

echo "--- a pre-push that exits 1 blocks git push to a bare remote ---"
: > "$FIX/ran"
out=$(git -C "$WT" push origin t-1 2>&1); rc=$?
want "the push exits non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
want "the branch did not reach the remote" "0" "$(pushed "$R" t-1)"
want_in "the hook's own failure is what stopped it" "check:ui-gate-attested" "$out"

echo "--- and from a subdirectory of the worktree, too ---"
: > "$FIX/ran"
git -C "$WT/sub" push origin t-1 >/dev/null 2>&1
want "still not pushed" "0" "$(pushed "$R" t-1)"
want "the worktree's hook ran" "ran a-wt v2" "$(cat "$FIX/ran")"

echo "--- husky resetting the shared core.hooksPath does not unhook the worktree ---"
git -C "$R" config core.hooksPath .husky/_          # npm install at the main clone
git -C "$WT" config core.hooksPath .husky/_         # npm install inside the worktree (still writes the shared file)
: > "$FIX/ran"
git -C "$WT" push origin t-1 >/dev/null 2>&1
want "still refused after both resets" "0" "$(pushed "$R" t-1)"
want "the worktree's hook ran" "ran a-wt v2" "$(cat "$FIX/ran")"
want "the main clone's shared value is husky's, untouched" ".husky/_" "$(git -C "$R" config --local --get core.hooksPath)"
out=$(bash "$SCRIPT" --check "$R" "$WT" 2>&1); rc=$?
want "--check passes" "0" "$rc"

echo "--- a passing pre-push lets the push through ---"
R2="$FIX/b"; make_repo "$R2" pass; WT2="$FIX/b-wt"; make_wt "$R2" "$WT2" t-2
bash "$SCRIPT" "$R2" "$WT2" >/dev/null 2>&1
: > "$FIX/ran"
git -C "$WT2" push -q origin t-2 >/dev/null 2>&1
want "pushed" "1" "$(pushed "$R2" t-2)"
want "after running the hook" "ran b-wt v2" "$(cat "$FIX/ran")"

echo "--- running it twice changes nothing ---"
before=$(git -C "$WT2" config --worktree --get core.hooksPath)
bash "$SCRIPT" "$R2" "$WT2" >/dev/null 2>&1; rc=$?
want "second run exits 0" "0" "$rc"
want "same hooksPath" "$before" "$(git -C "$WT2" config --worktree --get core.hooksPath)"

echo "--- the main repo may be named by its git common dir (the form /finish uses) ---"
WT8="$FIX/b-wt8"; make_wt "$R2" "$WT8" t-8
out=$(cd "$WT8" && bash "$SCRIPT" "$(git rev-parse --path-format=absolute --git-common-dir)" "$(pwd -P)" 2>&1); rc=$?
want "exits 0" "0" "$rc"
want "the worktree resolves to its dispatcher" "$(git -C "$WT8" rev-parse --absolute-git-dir)/harness-hooks" "$(git -C "$WT8" rev-parse --path-format=absolute --git-path hooks)"

echo "--- a worktree with no pre-push is refused ---"
R3="$FIX/c"; make_repo "$R3" pass; WT3="$FIX/c-wt"; make_wt "$R3" "$WT3" t-3
git -C "$WT3" rm -q .husky/pre-push && git -C "$WT3" commit -qm "drop gate" --no-verify
out=$(bash "$SCRIPT" "$R3" "$WT3" 2>&1); rc=$?
want "exits non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
want_in "says why" "🛑" "$out"

echo "--- a dispatcher that is not executable fails --check ---"
WT4="$FIX/b-wt4"; make_wt "$R2" "$WT4" t-4
bash "$SCRIPT" "$R2" "$WT4" >/dev/null 2>&1
chmod -x "$(git -C "$WT4" config --worktree --get core.hooksPath)/pre-push"
out=$(bash "$SCRIPT" --check "$R2" "$WT4" 2>&1); rc=$?
want "--check exits non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
want_in "says why" "🛑" "$out"

echo "--- a worktree resolving to the old relative path with no shims fails --check ---"
WT5="$FIX/b-wt5"; make_wt "$R2" "$WT5" t-5
out=$(bash "$SCRIPT" --check "$R2" "$WT5" 2>&1); rc=$?
want "--check exits non-zero for an unprepared worktree" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
want_in "names the hooks dir it found" ".husky/_" "$out"

echo "--- a worktree of a different repo is refused ---"
out=$(bash "$SCRIPT" "$R" "$WT2" 2>&1); rc=$?
want "exits non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

echo "--- a main clone with core.bare=true keeps every worktree a work tree ---"
R6="$FIX/d"; make_repo "$R6" fail
git -C "$R6" config core.bare true
OLD="$FIX/d-old"; git -C "$R6" worktree add -q --detach "$OLD" develop
NEW="$FIX/d-new"; make_wt "$R6" "$NEW" t-6
out=$(bash "$SCRIPT" "$R6" "$NEW" 2>&1); rc=$?
want "ensure-hooks exits 0" "0" "$rc"
want "the new worktree is not bare" "false" "$(git -C "$NEW" rev-parse --is-bare-repository 2>&1)"
want "an older worktree is not bare" "false" "$(git -C "$OLD" rev-parse --is-bare-repository 2>&1)"
want "an older worktree still answers git status" "0" "$(git -C "$OLD" status --short >/dev/null 2>&1; echo $?)"
want "the main clone is still bare" "true" "$(git -C "$R6" rev-parse --is-bare-repository 2>&1)"
git -C "$NEW" push origin t-6 >/dev/null 2>&1
want "and the new worktree's push is refused by its hook" "0" "$(pushed "$R6" t-6)"

echo "--- a pre-push killed partway does not let the push through (POSIX) ---"
R7="$FIX/e"; make_repo "$R7" slow; WT7="$FIX/e-wt"; make_wt "$R7" "$WT7" t-7
bash "$SCRIPT" "$R7" "$WT7" >/dev/null 2>&1
rm -f "$FIX/hook.pid"
git -C "$WT7" push origin t-7 >/dev/null 2>&1 &
pushpid=$!
n=0; while [ ! -s "$FIX/hook.pid" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
kill "$(cat "$FIX/hook.pid" 2>/dev/null)" 2>/dev/null
wait "$pushpid"; rc=$?
want "the push exits non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
want "the branch did not reach the remote" "0" "$(pushed "$R7" t-7)"

exit $FAILED
