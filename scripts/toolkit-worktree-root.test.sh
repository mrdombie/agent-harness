#!/usr/bin/env bash
# toolkit_worktree_root — where every claim's worktree lives.
#
# WHY: macOS's dirhelper deletes files under $TMPDIR (/var/folders/…/T) that are
# three days untouched, file by file, so a worktree there rots in place while
# keeping its name. The origin project measured 54 of 103 claim worktrees with
# no .git on 2026-09-27 and fixed it with this resolver — but the fix landed in
# the project's own copy of /claim the day before that copy was retired in
# favour of the kit's (#33), and the kit's copy never had it. A claim on
# 2026-10-02 put its worktree back in $TMPDIR, and the project's dev server
# refused to start there.
#
# The function is read out of toolkit-env.sh itself, so this tests the shipped
# text, with toolkit_cfg stubbed to the config each case needs.
set -uo pipefail
ENV_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }

FN=$(sed -n '/^toolkit_worktree_root() {/,/^}/p' "$ENV_SH")
[ -n "$FN" ] || { echo "  FAIL — toolkit-env.sh defines no toolkit_worktree_root"; exit 1; }
eval "$FN"

CFG_ROOT=""
toolkit_cfg() { [ "$1" = worktreeRoot ] && [ -n "$CFG_ROOT" ] && { printf '%s\n' "$CFG_ROOT"; return 0; }; return 1; }

NAME="wtroot-test-$$"
REPO_SLUG="owner/$NAME"
DEFAULT="$HOME/.harness-worktrees/$NAME"
cleanup() { rmdir "$DEFAULT" 2>/dev/null; rmdir "$HOME/.harness-worktrees" 2>/dev/null; true; }
trap cleanup EXIT

echo "--- the default is under HOME, keyed by the repo's name, and exists ---"
unset HARNESS_WORKTREE_ROOT
out=$(toolkit_worktree_root 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "$DEFAULT" ] && ok "default → $out" || fail "default gave rc=$rc '$out', wanted $DEFAULT"
[ -d "$DEFAULT" ] && ok "the default directory is created" || fail "the default directory was not created"

echo "--- a configured root under HOME wins over the default ---"
CFG_ROOT="~/.harness-worktrees/$NAME"
out=$(toolkit_worktree_root 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "$DEFAULT" ] && ok "worktreeRoot with ~ expands to $out" || fail "configured root gave rc=$rc '$out'"
CFG_ROOT=""

echo "--- every temp location is refused, whoever asks for it ---"
for bad in "${TMPDIR:-/tmp}/wt" /tmp/wt /private/tmp/wt /var/folders/ab/cd/T/wt /private/var/folders/ab/cd/T/wt; do
  out=$(HARNESS_WORKTREE_ROOT="$bad" toolkit_worktree_root 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] && [ -z "$out" ] && ok "env root refused: $bad" || fail "env root accepted: $bad → '$out'"
  CFG_ROOT="$bad"
  out=$(toolkit_worktree_root 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] && [ -z "$out" ] && ok "config root refused: $bad" || fail "config root accepted: $bad → '$out'"
  CFG_ROOT=""
done

echo "--- the refusal says what to do ---"
msg=$(HARNESS_WORKTREE_ROOT=/tmp/wt toolkit_worktree_root 2>&1 >/dev/null)
printf '%s' "$msg" | grep -q 'worktreeRoot' && ok "names the setting to change" || fail "refusal does not name worktreeRoot: $msg"

echo "--- /claim takes its worktree from the resolver, never from TMPDIR ---"
CLAIM="$(dirname "$ENV_SH")/../skills/claim/SKILL.md"
grep -q 'WT_ROOT=$(toolkit_worktree_root)' "$CLAIM" && ok "claim Step 5 calls the resolver" || fail "claim Step 5 does not call toolkit_worktree_root"
grep -nE 'WORKTREE=.*TMPDIR|TMP_BASE=' "$CLAIM" >/dev/null && fail "claim still builds a worktree path from TMPDIR" || ok "claim builds no worktree path from TMPDIR"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
