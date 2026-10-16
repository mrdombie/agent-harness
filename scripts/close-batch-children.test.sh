#!/usr/bin/env bash
# close-batch-children.test.sh — a merged batch PR closes every child its ticket
# lists, and nothing else; and /agent-harness:finish calls it after the close.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
S="$HERE/close-batch-children.sh"

# The stub answers `issue view <n> --json body|state -q …` from $FIX/gh/issue-<n>.json.
issue() { # <n> <state> [body]
  jq -n --arg s "$2" --arg b "${3:-}" '{state:$s, body:$b, labels:[]}' > "$FIX/gh/issue-$1.json"
}
closes() { grep -E '^issue close' "$GH_LOG" | awk '{print $3}' | tr '\n' ' ' | sed 's/ $//'; }

echo "--- a merged batch closes the children its ticket lists ---"
: > "$GH_LOG"
issue 300 OPEN $'Batch: one screen\n**Children (3):** #301, #302, #303\n\n- The PR body closes **this** ticket only (`Closes #300`). List the children as `Rolled in: #301, #302, #303`.\n\nSee also #399.'
issue 301 OPEN; issue 302 CLOSED; issue 303 OPEN; issue 399 OPEN
out=$(bash "$S" 300 4321 2>&1); rc=$?
want "every open child is closed, in the listed order" "301 303" "$(closes)"
want_in "each with a comment naming the PR" '^issue close 301 .*--comment Shipped in PR #4321 \(batch #300\)\.' "$(cat "$GH_LOG")"
want_in "an already-closed child is said, not closed again" 'already closed #302' "$out"
want "a ticket only mentioned in the body is left alone" "0" "$(grep -c 'issue close 399' "$GH_LOG")"
want "and the run succeeds"                "0" "$rc"

: > "$GH_LOG"; issue 310 OPEN $'Rolled in: #311\n'; issue 311 OPEN
bash "$S" 310 4322 >/dev/null 2>&1
want "the Rolled in: form is read too"     "311" "$(closes)"

echo "--- the guard flags nothing correct ---"
: > "$GH_LOG"; issue 200 OPEN $'One fix. Related to #201.\n'; issue 201 OPEN
out=$(bash "$S" 200 4323 2>&1); rc=$?
want "a ticket with no child list closes nothing" "" "$(closes)"
want "and succeeds quietly"                "0 " "$rc $out"

echo "--- /agent-harness:finish calls it, after the ticket's own close ---"
F="$HERE/../skills/finish/SKILL.md"
step=$(awk '/^\*\*7d\. Close the GitHub Issue/{on=1} on && /^```$/{n++; if (n == 2) exit} on' "$F")
want_in "Step 7d runs close-batch-children.sh with the ticket and the PR" \
  'bash "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/close-batch-children\.sh" "\$ISSUE_NUM" "\$PR_NUMBER"' "$step"
after=$(printf '%s\n' "$step" | awk '/gh issue close "\$ISSUE_NUM"/{c=NR} /close-batch-children\.sh/{b=NR} END{print (c && b > c) ? "after" : "before"}')
want "and only once the ticket itself is closed" "after" "$after"

exit $FAILED
