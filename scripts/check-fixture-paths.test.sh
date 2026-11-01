#!/usr/bin/env bash
# check-fixture-paths.test.sh — the check finds a read-back path handed to git -C unheld, and passes a held one.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-fixture-paths.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/check-fixture-paths-test.XXXXXX")
on_exit_keep_status 'rm -rf "$SB"'
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# judged <name> <body…> — writes a suite and prints the check's exit code on it.
# Plants spell it GIT so this file is not itself a suite the check judges; written out, they are.
judged() {
  local n=$1; shift
  printf '%s\n' "$@" | sed 's/GIT -C/git -C/' > "$SB/$n.test.sh"
  bash "$CHECK" "$SB/$n.test.sh" > "$SB/$n.out" 2>&1; echo $?
}

echo "--- a read-back path handed to git -C with nothing holding it is caught ---"
r=$(judged bare 'PWT=$(driver_state_get 407 worktree)' 'GIT -C "$PWT" add -A')
[ "$r" = 1 ] && grep -q 'bare.test.sh:1: \$PWT' "$SB/bare.out" && ok "named with its line" || bad "not caught (rc $r): $(cat "$SB/bare.out")"
r=$(judged brace 'WT=$(get_tree)' 'GIT -C "${WT}" commit -qm x')
[ "$r" = 1 ] && ok "the \${VAR} spelling too" || bad "\${WT} slipped through: $(cat "$SB/brace.out")"
r=$(judged quoted 'WT="$(get_tree)"' 'GIT -C "$WT/sub" status')
[ "$r" = 1 ] && ok "a quoted assignment and a path under it too" || bad "a quoted read-back slipped through"
r=$(judged local 'f() {' '  local wt=$(fresh_tree 1)' '  GIT -C "$wt" config core.hooksPath x' '}')
[ "$r" = 1 ] && ok "a local one inside a function too" || bad "a local read-back slipped through"
r=$(judged other 'WT=$(get_tree); fixture_path OTHER "$FIX"' 'GIT -C "$WT" add -A')
[ "$r" = 1 ] && ok "holding a different variable does not hold this one" || bad "fixture_path OTHER passed for WT"
r=$(judged far 'WT=$(get_tree)' 'echo' 'fixture_path WT "$FIX"' 'GIT -C "$WT" add -A')
[ "$r" = 1 ] && ok "a guard two lines later is too late to count" || bad "a late guard passed"

echo "--- a held path, a root and a comment pass ---"
r=$(judged same 'WT=$(get_tree); fixture_path WT "$FIX"' 'GIT -C "$WT" add -A')
[ "$r" = 0 ] && ok "held on the same line" || bad "a held path failed: $(cat "$SB/same.out")"
r=$(judged next 'WT=$(get_tree)' 'fixture_path WT "$FIX"' 'GIT -C "$WT" add -A')
[ "$r" = 0 ] && ok "held on the next line" || bad "held on the next line failed: $(cat "$SB/next.out")"
r=$(judged skip 'P=$(git -C "$HERE" rev-parse --show-toplevel)' '[ -n "$P" ] || suite_skip "none"' 'GIT -C "$P" log')
[ "$r" = 0 ] && ok "an empty path that skips the suite" || bad "the skip form failed: $(cat "$SB/skip.out")"
r=$(judged roots 'SB=$(mktemp -d)' 'R=$(cd "$SB" && pwd -P)' 'GIT -C "$SB" init -q' 'GIT -C "$R" status')
[ "$r" = 0 ] && ok "a fresh mktemp or cd-pwd root is not a read-back path" || bad "a root was flagged: $(cat "$SB/roots.out")"
r=$(judged comment 'WT=$(get_tree)' '# GIT -C "$WT" add -A')
[ "$r" = 0 ] && ok "a commented-out git -C is not a use" || bad "a comment was flagged"

echo "--- every suite in the kit passes as it stands ---"
bash "$CHECK" > "$SB/kit.out" 2>&1; r=$?
[ "$r" = 0 ] && ok "$(tail -1 "$SB/kit.out")" || bad "the kit's own suites fail: $(cat "$SB/kit.out")"

suite_end "$fail"
