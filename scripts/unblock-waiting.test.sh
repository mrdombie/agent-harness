#!/usr/bin/env bash
# unblock-waiting.test.sh — a ticket waiting on others ("Blocked until #…", gated or blocked)
# goes back to ready once every one of them has landed, and not while one is still open.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
U="$HERE/unblock-waiting.sh"
cat > "$BIN/queue" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FIX/queue.log"
SH
chmod +x "$BIN/queue"; export UNBLOCK_QUEUE="$BIN/queue"
waiting() { # <n> <label> <body> <comment…> — an open ticket waiting, as the list read returns it
  local n="$1" l="$2" b="$3"; shift 3
  jq -n --argjson n "$n" --arg l "$l" --arg b "$b" '{number:$n, state:"OPEN", title:"Ticket \($n)", labels:[{name:$l},{name:"P0"}], body:$b,
    comments:[$ARGS.positional[] | {body:.}]}' --args "$@" > "$FIX/gh/issue-$n.json"
}
listing() { # <label> <n…>
  local l="$1"; shift
  local f; for f in "$@"; do cat "$FIX/gh/issue-$f.json"; done | jq -s '[.[] | {number, body, comments}]' > "$FIX/gh/issue-list-$l.json"
}
closed() { jq -n --argjson n "$1" --arg r "${2:-COMPLETED}" '{number:$n, state:"CLOSED", stateReason:$r, title:"t", labels:[]}' > "$FIX/gh/issue-$1.json"; }
opened() { fix_issue "$1" OPEN "status:ready"; }
run() { : > "$FIX/queue.log"; : > "$GH_LOG"; bash "$U" "$@" 2>&1; }

echo "--- the PM's hand-gated tickets, read from their own comments ---"
waiting 14276 status:gated "spec" "**PM answer:** Yes, it waits. Blocked until #14273 merge. It goes back to ready when they have."
waiting 13573 status:gated "spec" "Blocked until #13572" "**PM answer:** Yes, it waits. Blocked until #14268, #14269, #14270 and #14271 merge. It goes back to ready when they have."
listing status:gated 14276 13573
closed 14273; closed 14268; closed 14269; closed 14270; opened 14271; closed 13572 NOT_PLANNED
out=$(run)
want_in "#14276's blocker merged: back to ready"  '^unblocked #14276$' "$out"
want_in "  relabelled"                            'issue edit 14276 .*--remove-label status:gated --add-label status:ready' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "  told"                                  'issue comment 14276 .*Unblocked' "$(tr '\n' ' ' < "$GH_LOG")"
want "  queued first at its priority"            "add 14276 --first" "$(cat "$FIX/queue.log")"
want_in "#13573 waits while one part is still open" '^waits: #13573 — still open: #14271$' "$out"
want_not_in "  the newest Blocked-until line decides, not the split parent" '#13572' "$out"
closed 14271
out=$(run)
want_in "the last part merged: #13573 is released"  '^unblocked #13573$' "$out"

echo "--- a split part says it in its body; a blocker closed as not planned has not landed ---"
waiting 801 status:gated "Part 2 of 3, split from #800.
Blocked until #799 merges: the parts build in order."
listing status:gated 801; closed 799 NOT_PLANNED
want_in "not planned, not a split: not landed, the PM's" '^waits: #801 — closed unmerged, not as split: #799 \(the PM decides\)$' "$(run)"
closed 799
want_in "closed as completed: released"          '^unblocked #801$' "$(run)"

echo "--- the blocked status too (a follow-up waiting on its parent) ---"
waiting 702 status:blocked "spec" "Blocked until #13772 merges: this ticket waits for it."
listing status:blocked 702; printf '[]\n' > "$FIX/gh/issue-list-status:gated.json"
jq -n '{number:13772, state:"MERGED", title:"PR", labels:[]}' > "$FIX/gh/issue-13772.json"
want_in "a merged pull request has landed"       '^unblocked #702$' "$(run)"

echo "--- a blocker closed as split stands for its parts ---"
# #13581 was requeued when #13578 closed as split into #14263–#14266, none merged, and it parked asking.
printf '[]\n' > "$FIX/gh/issue-list-status:blocked.json"
waiting 13581 status:gated "spec" "Blocked until #13578 merges."
listing status:gated 13581
jq -n '{number:13578, state:"CLOSED", stateReason:"NOT_PLANNED", title:"t", labels:[],
  comments:[{body:"**Split** into #14263 #14264 #14265 #14266 — one change each, in this order. Closed as split."}]}' > "$FIX/gh/issue-13578.json"
closed 14263; closed 14264; opened 14265; opened 14266
want_in "its parts still open: it waits"          '^waits: #13581 — still open: #13578$' "$(run)"
closed 14265; closed 14266
want_in "every part landed: released"             '^unblocked #13581$' "$(run)"
echo "--- a blocker closed unmerged, not as split: it waits, with one note for the PM ---"
waiting 13590 status:gated "spec" "Blocked until #13589 merges."
listing status:gated 13590
jq -n '{number:13589, state:"CLOSED", stateReason:"NOT_PLANNED", title:"t", labels:[], comments:[{body:"Closed: not needed."}]}' > "$FIX/gh/issue-13589.json"
out=$(run)
want_in "  it waits, for the PM"                   '^waits: #13590 — closed unmerged, not as split: #13589 \(the PM decides\)$' "$out"
want_in "  with a note on the ticket"             'issue comment 13590 .*Still waiting' "$(tr '\n' ' ' < "$GH_LOG")"
listing status:blocked 702

echo "--- dry: says it, changes nothing ---"
out=$(run --dry-run)
want_in "  says what it would do"                '^would unblock #702' "$out"
want "  writes nothing"                          "0" "$(grep -c -E '^issue (edit|comment)' "$GH_LOG")"
want "  queues nothing"                          "" "$(cat "$FIX/queue.log")"

suite_end "$FAILED"
