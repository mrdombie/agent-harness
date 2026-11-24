#!/usr/bin/env bash
# Plant tests for no-close-unshipped-pr.sh, against a fake gh. Exit 1 on any mismatch.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
H="$(dirname "$0")/no-close-unshipped-pr.sh"; fail=0
d=$(mktemp -d); on_exit_keep_status 'rm -rf "$d"'
# Fake gh: PR 10 open, 11 merged, 12 closed, 13 open; anything else is unreadable.
cat >"$d/gh" <<'SH'
#!/usr/bin/env bash
n=$3
case "$n" in
  10 | 13) s=OPEN ;; 11) s=MERGED ;; 12) s=CLOSED ;; *) exit 1 ;;
esac
case "$*" in *state,number*) echo "$s $n" ;; *) echo "$s" ;; esac
SH
chmod +x "$d/gh"; export NO_CLOSE_GH="$d/gh"
t(){ want=$1; shift; out=$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$H"); r=allow; [ -n "$out" ] && r=deny; mark=OK; [ "$r" = "$want" ] || { mark=MISMATCH; fail=1; }; printf '%-8s want=%-5s got=%-5s %s\n' "$mark" "$want" "$r" "$1"; }
t deny  'gh pr close 10 --comment "PM: closing to rebuild fresh from develop"'
t deny  'cd /x && gh pr close 10 --repo o/r --delete-branch'
t deny  'gh pr close 10 -c "Duplicate of #13"'
t deny  'gh pr close 10 -c "see #10"'
t deny  'gh pr close 10 -c "Duplicate of #99"'
t deny  'X=1 gh pr close 10'
t deny  'gh pr close 99'
t deny  'gh pr close'
t allow 'gh pr close 10 --comment "Duplicate of #11, which merged first"'
t allow 'gh pr close 10 --repo o/r --comment="superseded by #11"'
t allow 'gh pr close 12'
t allow 'gh pr close 11'
t allow 'gh pr view 10'
t allow 'gh issue close 10'
t allow 'echo "gh pr close 10"'
suite_end "$fail"
