#!/usr/bin/env bash
# pr-watch.sh — the shell waits on a PR so the model does not. Each event once,
# an empty rollup never reads green, and a watch with nothing to report gives up
# with TIMEOUT instead of running for ever. Then the plants.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/pr-watch-XXXXXX"); on_exit_keep_status 'rm -rf "$SB"'
mkdir -p "$SB/bin" "$SB/pr"
cat > "$SB/bin/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "pr view" ] && cat "$PRW_DIR/$3.json"
SH
chmod +x "$SB/bin/gh"
export PATH="$SB/bin:$PATH" PRW_DIR="$SB/pr" PR_WATCH_EVERY=0 PR_WATCH_MAX=1
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

pr() { printf '%s' "$2" > "$SB/pr/$1.json"; }
pr 1 '{"state":"OPEN","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"SKIPPED"}]}'
pr 2 '{"state":"OPEN","mergeable":"MERGEABLE","statusCheckRollup":[]}'
pr 3 '{"state":"OPEN","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"FAILURE"}]}'
pr 4 '{"state":"MERGED","mergeable":"UNKNOWN","statusCheckRollup":[]}'
pr 5 '{"state":"OPEN","mergeable":"CONFLICTING","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
pr 6 '{"state":"OPEN","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"},{"status":"IN_PROGRESS"}]}'

# A watch that never gives up would hang the suite: each run gets 5 seconds.
w5() { perl -e 'alarm shift; exec @ARGV' 5 bash "$@" 2>/dev/null; }
core() { # <script> → failed cases, one per line
  local s=$1 o
  o=$(w5 "$s" 1); [ "$o" = "PR #1 GREEN" ] || echo "all checks passed is not GREEN ($o)"
  o=$(w5 "$s" 2); case "$o" in TIMEOUT*) ;; *) echo "an empty rollup reported $o" ;; esac
  o=$(w5 "$s" 3); [ "$o" = "PR #3 RED" ] || echo "a failed check is not RED ($o)"
  o=$(w5 "$s" 4); [ "$o" = "PR #4 MERGED" ] || echo "a merge is not MERGED ($o)"
  o=$(w5 "$s" 5); [ "$o" = "PR #5 CONFLICT" ] || echo "a clash is not CONFLICT ($o)"
  o=$(w5 "$s" 6); case "$o" in TIMEOUT*) ;; *) echo "a check still running reported $o" ;; esac
  o=$(w5 "$s" 2 3); [ "$o" = "PR #3 RED" ] || echo "two PRs: the one with news is not reported alone ($o)"
}
echo "pr-watch"
r=$(core "$HERE/pr-watch.sh"); [ -z "$r" ] && ok "every event reads right" || { bad "cases failed:"; printf '         %s\n' "$r"; }

plant() { # <desc> <old> <new> <the case that must go red>
  cp "$HERE/pr-watch.sh" "$SB/p.sh"
  python3 - "$SB/p.sh" "$2" "$3" <<'PY' || { bad "plant did not land: $1"; return; }
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
  local r; r=$(core "$SB/p.sh")
  grep -qF -- "$4" <<<"$r" && ok "planted: $1 → red" || bad "planted: $1 → not red on its case ($4)"
}
echo "plants"
plant "an empty rollup reads green" 'elif ($c | length) > 0 and ($c' 'elif ($c' 'an empty rollup reported'
plant "a running check reads green" '(SUCCESS|NEUTRAL|SKIPPED)' '(SUCCESS|NEUTRAL|SKIPPED|IN_PROGRESS|)' 'a check still running reported'
plant "the watch never gives up" '-ge "$MAX" ]' '-ge 999999999 ]' 'an empty rollup reported'
suite_end "$fail"
