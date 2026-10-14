#!/usr/bin/env bash
# clear-hold.test.sh — the hold label and the branch prefix come from harness.json,
# and a reason given is the reason recorded.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
jq '.labels.hold = "hold:pixels" | .branchPrefix = "wk-"' "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"

cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view") case "$*" in *author*) echo "${PR_AUTHOR:-tester}" ;; *headRefName*) echo "wk-417/do-thing" ;; esac ;;
  "variable get") exit 1 ;;
esac
exit 0
GH
chmod +x "$BIN/gh"

echo "--- the operator's own PR: comment, then the configured label off the issue and the PR ---"
: > "$GH_LOG"
out=$(bash "$HERE/clear-hold.sh" 88 2>&1); rc=$?
want "it succeeds"                          "0" "$rc"
want_in "the configured label leaves the PR" '^pr edit 88 .*--remove-label hold:pixels' "$(cat "$GH_LOG")"
want_in "the issue is found by the configured prefix" '^issue edit 417 .*--remove-label hold:pixels' "$(cat "$GH_LOG")"
want_not_in "no literal label from another project" 'needs:human-approval' "$(cat "$GH_LOG")"
want_in "the comment names the label it cleared" 'pr comment 88 .*`hold:pixels` cleared' "$(cat "$GH_LOG")"

echo "--- a reason given is the reason recorded ---"
: > "$GH_LOG"
bash "$HERE/clear-hold.sh" 88 --reason "develop-only update, screens unchanged" >/dev/null 2>&1
want_in "the comment carries the reason"    'pr comment 88 .*develop-only update, screens unchanged' "$(cat "$GH_LOG")"
want_not_in "and does not claim an instruction it did not get" 'pr comment 88 .*on their instruction' "$(cat "$GH_LOG")"

echo "--- a peer's PR and an approver: an approving review carries the reason ---"
: > "$GH_LOG"
PR_AUTHOR=peer HUMAN_APPROVERS=tester bash "$HERE/clear-hold.sh" 88 --reason "develop-only update" >/dev/null 2>&1
want_in "an approving review"               '^pr review 88 .*--approve.*develop-only update' "$(cat "$GH_LOG")"

exit $FAILED
