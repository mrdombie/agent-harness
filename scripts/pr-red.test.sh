#!/usr/bin/env bash
# pr-red.test.sh — a repair starts only on a PR that is really red: a check the base
# branch's LIVE rules require concluded failure, or GitHub says it clashes. A check
# still running, a cancelled one, or a red the base does not require starts nothing.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/pr-red.sh"

FAILED=0
ok()   { printf 'OK       %s\n' "$1"; }
bad()  { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }

pr() { # <mergeState> <mergeable> <draft> <name:status:conclusion>…
  local ms="$1" m="$2" d="$3" rows="[]" c n st co; shift 3
  for c in "$@"; do
    IFS=: read -r n st co <<<"$c"
    rows=$(jq -c --arg n "$n" --arg s "$st" --arg c "$co" \
      '. + [{__typename: "CheckRun", name: $n, status: $s, conclusion: (if $c == "-" then null else $c end), completedAt: "2026-10-23T10:00:00Z"}]' <<<"$rows")
  done
  jq -cn --arg ms "$ms" --arg m "$m" --argjson d "$d" --argjson r "$rows" \
    '{number: 7, baseRefName: "develop", isDraft: $d, mergeable: $m, mergeStateStatus: $ms, statusCheckRollup: $r}'
}
REQ='["typecheck + unit tests","schema drift"]'
verdict() { pr_red_classify "$1" "$REQ" approval '[]' | cut -f1; }
rc()      { pr_red_classify "$1" "$REQ" approval '[]' >/dev/null; echo $?; }

echo "--- a settled red on a required check, or a clash, is a repair ---"
p=$(pr BLOCKED MERGEABLE false "Typecheck + Unit tests:COMPLETED:FAILURE" "Schema drift:COMPLETED:SUCCESS")
want "a required check failed"             red "$(verdict "$p")"
want "  and a repair may start"            0   "$(rc "$p")"
p=$(pr DIRTY CONFLICTING false "Typecheck + Unit tests:COMPLETED:SUCCESS")
want "a clash"                             clash "$(verdict "$p")"
want "  and a repair may start"            0   "$(rc "$p")"

echo "--- CI still running is not red, even beside a failure ---"
p=$(pr BLOCKED MERGEABLE false "Typecheck + Unit tests:IN_PROGRESS:-" "Schema drift:COMPLETED:FAILURE")
want "a required check still running"      pending "$(verdict "$p")"
want "  starts nothing"                    1   "$(rc "$p")"
p=$(pr BLOCKED MERGEABLE false "Typecheck + Unit tests:QUEUED:-")
want "a required check queued, no runner"  pending "$(verdict "$p")"

echo "--- a red the base does not require starts nothing ---"
p=$(pr BLOCKED MERGEABLE false "Typecheck + Unit tests:COMPLETED:SUCCESS" "Capture and pin the evidence:COMPLETED:FAILURE")
want "only a non-required check is red"    green "$(verdict "$p")"
want "  starts nothing"                    1   "$(rc "$p")"
p=$(pr BLOCKED MERGEABLE false "Capture and pin the evidence:IN_PROGRESS:-" "Schema drift:COMPLETED:FAILURE")
want "a non-required check running is no wait" red "$(verdict "$p")"

echo "--- cancelled, timed out or never started is a re-run, not a repair ---"
for k in CANCELLED TIMED_OUT STARTUP_FAILURE; do
  p=$(pr BLOCKED MERGEABLE false "Typecheck + Unit tests:COMPLETED:$k")
  want "$k"                                rerun "$(verdict "$p")"
  want "  starts nothing"                  1   "$(rc "$p")"
done

echo "--- the newest run of a check is the one read ---"
p=$(pr BLOCKED MERGEABLE false "Typecheck + Unit tests:COMPLETED:FAILURE")
p=$(jq -c '.statusCheckRollup += [{name: "Typecheck + Unit tests", status: "COMPLETED", conclusion: "SUCCESS", completedAt: "2026-10-23T11:00:00Z"}]' <<<"$p")
want "a re-run that passed clears the red" green "$(verdict "$p")"
p=$(jq -c '.statusCheckRollup += [{name: "Typecheck + Unit tests", status: "IN_PROGRESS", conclusion: null}]' <<<"$p")
want "a re-run in progress is a wait"      pending "$(verdict "$p")"

echo "--- the hold check and a release non-blocking check are never red ---"
REQ='["typecheck + unit tests","approval","lesson"]'
p=$(pr BLOCKED MERGEABLE false "Typecheck + Unit tests:COMPLETED:SUCCESS" "approval:COMPLETED:FAILURE")
want "the hold check"                      green "$(pr_red_classify "$p" "$REQ" approval '[]' | cut -f1)"
p=$(pr BLOCKED MERGEABLE false "Typecheck + Unit tests:COMPLETED:SUCCESS" "Lesson:COMPLETED:FAILURE")
want "a non-blocking check"                green "$(pr_red_classify "$p" "$REQ" approval '["lesson"]' | cut -f1)"
REQ='["typecheck + unit tests","schema drift"]'

echo "--- a draft with its checks settled is one to finish; green is nothing ---"
p=$(pr CLEAN MERGEABLE true "Typecheck + Unit tests:COMPLETED:SUCCESS")
want "a settled draft"                     finish "$(verdict "$p")"
p=$(pr CLEAN MERGEABLE false "Typecheck + Unit tests:COMPLETED:SUCCESS")
want "a green PR"                          green "$(verdict "$p")"
want "  starts nothing"                    1   "$(rc "$p")"

echo "--- unreadable is never red ---"
want "no PR"                               unread "$(pr_red_classify "" "$REQ" | cut -f1)"
want "no required list"                    unread "$(pr_red_classify "$p" "" | cut -f1)"

echo "--- the required list is the base branch's live rules, read once ---"
BIN=$(mktemp -d); on_exit_keep_status 'rm -rf "$BIN"'
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$BIN/calls"
case "$2" in
  repos/o/r/rules/branches/develop) echo '[{"type":"pull_request"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Typecheck + Unit tests"}]}}]' ;;
  repos/o/r/branches/develop/protection/required_status_checks) [ -f "$BIN/prot" ] && cat "$BIN/prot" && exit 0; echo '{"message":"Required status checks not enabled"}'; exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$BIN/gh"; export BIN
export REPO_SLUG=o/r; PR_RED_REQ_CACHE=""
want "a ruleset's required checks"         '["typecheck + unit tests"]' "$(PATH="$BIN:$PATH" pr_red_required develop)"
echo '{"contexts":["Build"]}' > "$BIN/prot"; : > "$BIN/calls"
PR_RED_REQ_FILE="$BIN/cache"; export PR_RED_REQ_FILE
want "plus classic protection's"           '["build","typecheck + unit tests"]' "$(PATH="$BIN:$PATH" pr_red_required develop)"
PATH="$BIN:$PATH" pr_red_required develop >/dev/null
want "the second read is the cached one"   2 "$(grep -c . "$BIN/calls")"
want "an unreadable ruleset is unread"     unread "$(PR_RED_REQ_FILE="" PR_RED_REQ_CACHE="" PATH="$BIN:$PATH" pr_red_verdict "$(jq -c '.baseRefName = "main"' <<<"$p")" | cut -f1)"
unset PR_RED_REQ_FILE; rm -f "$BIN/prot"; PR_RED_REQ_CACHE=""
p=$(pr BLOCKED MERGEABLE false "Typecheck + Unit tests:COMPLETED:SUCCESS" "Schema drift:COMPLETED:FAILURE")
want "a red the live rules do not require" green "$(PATH="$BIN:$PATH" pr_red_verdict "$p" | cut -f1)"

suite_end "$FAILED"
