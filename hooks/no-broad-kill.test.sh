#!/usr/bin/env bash
# Self-test for no-broad-kill.sh, driven by no-broad-kill.cases.tsv.
#
# Each row is `block<TAB><command>` or `allow<TAB><command>`; a row whose command
# spans lines (a heredoc) continues until the next row keyword. The table is the
# spec — a new false positive is one line, not one function.
D="$(cd "$(dirname "$0")" && pwd)"; H="$D/no-broad-kill.sh"; CASES="$D/no-broad-kill.cases.tsv"
fail=0
export HARNESS_BRANCH_PREFIX=sh- HARNESS_WORKTREE_ROOT=/Users/me/wt

run(){ printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" \
         | bash "$H" >/dev/null 2>&1; echo $?; }

check(){ want=$1; cmd=$2
  rc=$(run "$cmd"); got=block; [ "$rc" -eq 0 ] && got=allow
  one=$(printf '%s' "$cmd" | head -1)
  if [ "$got" = "$want" ]; then printf 'ok   %-5s %s\n' "$want" "$one"
  else printf 'FAIL %-5s got %s: %s\n' "$want" "$got" "$one"; fail=1; fi; }

want=""; buf=""
flush(){ [ -n "$want" ] && check "$want" "$buf"; }
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    block$'\t'*|allow$'\t'*) flush; want="${line%%$'\t'*}"; buf="${line#*$'\t'}" ;;
    *) buf="$buf
$line" ;;
  esac
done < "$CASES"
flush

# The config-driven half. Without the worktree root in the environment the same
# command is BLOCKED — that is what proves the row above is not passing for
# some other reason.
rc=$(env -u HARNESS_WORKTREE_ROOT -u HARNESS_BRANCH_PREFIX bash -c \
  'printf "{\"tool_input\":{\"command\":\"pkill -f /Users/me/wt/a/next\"}}" | bash "$0" >/dev/null 2>&1; echo $?' "$H")
if [ "$rc" -eq 2 ]; then echo "ok   block unconfigured — a bare worktree root is not scoped"
else echo "FAIL the worktree-root allowance fires without the config"; fail=1; fi

[ "$fail" -eq 0 ] && echo "no-broad-kill: all cases pass"
exit $fail
