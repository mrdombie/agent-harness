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
# A wait's times: the body is filed at BODY_AT, every comment at NOTE_AT.
BODY_AT=2026-11-01T09:00:00Z NOTE_AT=2026-11-01T10:00:00Z
# No live claim unless a case plants one in $FIX/claims.
printf '#!/usr/bin/env bash\ncat "$FIX/claims" 2>/dev/null; exit 0\n' > "$BIN/claims"; chmod +x "$BIN/claims"; export UNBLOCK_CLAIMS="$BIN/claims"
labeled() { # <n> <login> <at> — the newest status:blocked labeled event on its timeline
  jq -n --arg u "$2" --arg at "$3" '[{event:"labeled", label:{name:"status:blocked"}, actor:{login:$u}, created_at:$at}]' \
    > "$FIX/gh/api-repos_acme_widgets_issues_$1_timeline_per_page_100.json"
}
waiting() { # <n> <label> <body> <comment…> — an open ticket waiting, as the list read returns it
  local n="$1" l="$2" b="$3"; shift 3
  jq -n --argjson n "$n" --arg l "$l" --arg b "$b" --arg ba "$BODY_AT" --arg na "$NOTE_AT" '{number:$n, state:"OPEN", title:"Ticket \($n)", labels:[{name:$l},{name:"P0"}], body:$b, createdAt:$ba,
    comments:[$ARGS.positional[] | {body:., createdAt:$na}]}' --args "$@" > "$FIX/gh/issue-$n.json"
  # The machine's own wait: the label goes on 2 s after the line that names it.
  [ "$l" != status:blocked ] || if [ $# -gt 0 ]; then labeled "$n" harness-bot 2026-11-01T10:00:02Z; else labeled "$n" harness-bot 2026-11-01T09:00:02Z; fi
}
listing() { # <label> <n…>
  local l="$1"; shift
  local f; for f in "$@"; do cat "$FIX/gh/issue-$f.json"; done | jq -s '[.[] | {number, body, createdAt, labels, comments}]' > "$FIX/gh/issue-list-$l.json"
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
want_in "its parts still open: it waits"          '^waits: #13581 — still open: #13578 \(its parts #14265 #14266\)$' "$(run)"
closed 14265; closed 14266
want_in "every part landed: released"             '^unblocked #13581$' "$(run)"
echo "--- a range is every ticket in it, en dash or hyphen ---"
# #14315 was released at 06:17Z with #14311 and #14312 open: "#14310–#14314" was read as its two ends.
printf '[]\n' > "$FIX/gh/issue-list-status:blocked.json"
waiting 14315 status:gated "spec" "**PM answer:** Yes, it waits. Blocked until #14310–#14314 merge."
listing status:gated 14315
closed 14310; opened 14311; opened 14312; closed 14313; closed 14314
want_in "the middle of an en-dash range still open: it waits" '^waits: #14315 — still open: #14311 #14312$' "$(run)"
closed 14311; closed 14312
want_in "  every one landed: released"            '^unblocked #14315$' "$(run)"
waiting 14316 status:gated "spec" "Blocked until #14310-14312 merge."
listing status:gated 14316
opened 14311
want_in "a hyphen range with a bare end counts its middle" '^waits: #14316 — still open: #14311$' "$(run)"
closed 14311
jq -n '{number:13579, state:"CLOSED", stateReason:"NOT_PLANNED", title:"t", labels:[],
  comments:[{body:"**Split** into #14280–#14282 — one change each. Closed as split."}]}' > "$FIX/gh/issue-13579.json"
waiting 14317 status:gated "spec" "Blocked until #13579 merges."
listing status:gated 14317
closed 14280; opened 14281; closed 14282
want_in "a split comment's range counts its middle too" '^waits: #14317 — still open: #13579 \(its part #14281\)$' "$(run)"

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

# A wait no pass can ever release must be said, never held in silence. 2026-10-29: the
# Holly 2.0 chain stood still ~12 hours: #16130 waited on #16140 (split), whose last part
# #16152 waited on #16130; 11 tickets waited behind them, and every pass said "still open".
cat > "$BIN/notify" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FIX/notify.log"
SH
chmod +x "$BIN/notify"; export UNBLOCK_NOTIFY="$BIN/notify"
fresh() { printf '[]\n' > "$FIX/gh/issue-list-status:blocked.json"; printf '[]\n' > "$FIX/gh/issue-list-status:gated.json"; : > "$FIX/notify.log"; }
split_as() { # <n> <part…> — closed as not planned, with the driver's split comment
  local n="$1"; shift
  jq -n --argjson n "$n" --arg k "$(printf '#%s ' "$@")" '{number:$n, state:"CLOSED", stateReason:"NOT_PLANNED", title:"t", labels:[],
    comments:[{body:"**Split** into \($k)— one change each, in this order. Closed as split."}]}' > "$FIX/gh/issue-$n.json"
}

echo "--- A split into A1 and A2: B waits while A2 is open, and goes once both are done ---"
fresh; split_as 900 901 902
waiting 903 status:gated "spec" "Blocked until #900 merge."
listing status:gated 903
closed 901; opened 902
out=$(run)
want_in "A2 open: B waits, naming the part it waits on" '^waits: #903 — still open: #900 \(its part #902\)$' "$out"
closed 902
want_in "both parts done: B is released"           '^unblocked #903$' "$(run)"

echo "--- two tickets that each wait on the other: a deadlock, said once on each ---"
fresh
waiting 910 status:gated "spec" "Blocked until #911 merges."
waiting 911 status:gated "spec" "Blocked until #910 merges."
listing status:gated 910 911
out=$(run)
want_in "the deadlock is reported"                 '^deadlock: #910 #911 — each waits on another, so none can start \(the PM breaks it\)$' "$out"
want_in "  on each ticket in it"                   'issue comment 910 .*Deadlocked.*unblock: deadlock #910 #911' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "  both of them"                           'issue comment 911 .*Deadlocked' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "  and to the PM's channel"                '^--class agent wait-deadlock:910,911 ' "$(cat "$FIX/notify.log")"
waiting 910 status:gated "spec" "Blocked until #911 merges." "**Deadlocked:** … <!-- unblock: deadlock #910 #911 -->"
listing status:gated 910 911
run >/dev/null
want "  a second pass writes no second note on #910" "0" "$(grep -c '^issue comment 910' "$GH_LOG")"
want_not_in "  nobody is released"                 'unblocked' "$out"

echo "--- a deadlock through a split: the Holly 2.0 shape ---"
fresh; split_as 921 922 923
waiting 920 status:gated "spec" "Blocked until #921 merges."
waiting 923 status:gated "Part 2 of 2, split from #921.
Blocked until #922 merges." "Blocked until #920 merges."
listing status:gated 920 923
opened 922
out=$(run)
want_in "the part waiting on the waiter is found"  '^deadlock: #920 #923 — each waits on another' "$out"

echo "--- a closed pull request that never merged has not landed ---"
fresh
waiting 940 status:blocked "spec" "Blocked until #941 merges."
listing status:blocked 940
jq -n '{number:941, state:"CLOSED", title:"PR", labels:[]}' > "$FIX/gh/issue-941.json"
printf '{"merged_at":null}\n' > "$FIX/gh/api-repos_acme_widgets_pulls_941.json"
out=$(run)
want_in "a PR closed unmerged: it waits, the PM's" '^waits: #940 — closed unmerged, not as split: #941 \(the PM decides\)$' "$out"
want_in "  said on the PM's channel too"           '^--class agent wait-unmerged:940:941 ' "$(cat "$FIX/notify.log")"

echo "--- a blocked ticket names its wait as the machine and the PM wrote it before ---"
fresh
waiting 930 status:blocked "spec" "Blocked on #931: this ticket waits for #931 to merge, then builds on develop (standard answer (b), release.mergeFirst)."
waiting 932 status:blocked "spec" "PM answer: this ticket is blocked by #16009 (the loop work) and resumes from its draft PR #934 once #933 merges." "Blocked by #933"
waiting 935 status:gated "spec" "Blocked on #936 (partner approval). Separation: #937."
listing status:blocked 930 932; listing status:gated 935
closed 931; opened 933; closed 936; opened 934
out=$(run)
want_in "\"Blocked on #N\" on a blocked ticket is read" '^unblocked #930$' "$out"
want_in "\"Blocked by #N\", the newest line, is read" '^waits: #932 — still open: #933$' "$out"
want_not_in "a gated ticket reads \"Blocked until\" alone" '#935' "$out"

echo "--- a blocked ticket with no line naming its wait is said, not held in silence ---"
fresh
waiting 950 status:blocked "spec" "Blocked for now."
waiting 951 status:blocked "spec" "Blocked: waits for #952 to merge. The merge pass sets it back to ready when #952 merges."
listing status:blocked 950 951
out=$(run)
want_in "no wait named: said"                      '^waits: #950 — blocked, but no "Blocked until #…" line names what on \(the PM decides\)$' "$out"
want_in "  on the PM's channel"                    '^--class agent wait-unnamed:950 ' "$(cat "$FIX/notify.log")"
want_not_in "  a follow-up's wait is follow-up.sh's" '#951' "$out"

echo "--- at the split, every wait naming the parent is re-pointed at its parts ---"
fresh; split_as 960 961 962
waiting 963 status:gated "spec" "Blocked until #960, #964 merge."
waiting 965 status:blocked "spec" "Blocked until #964 merges."
listing status:gated 963; listing status:blocked 965
: > "$GH_LOG"
out=$(bash "$U" --repoint 960 961 962 2>&1)
want_in "the waiter is re-pointed"                 'issue comment 963 .*Blocked until #961, #962, #964 merge' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "  and says so"                            '^repointed #963 — #960 is now #961 #962$' "$out"
want "  one waiting on something else is left"     "0" "$(grep -c '^issue comment 965' "$GH_LOG")"
: > "$GH_LOG"
out=$(bash "$U" --repoint 960 961 962 --dry-run 2>&1)
want_in "  dry: says it"                           '^would repoint #963' "$out"
want "  dry: writes nothing"                       "0" "$(grep -c '^issue comment' "$GH_LOG")"

echo "--- a person's block after the wait is theirs: no landed blocker lifts it ---"
# #20022: filed "Blocked until #19700"; a person put status:blocked on an hour later; #19700 landed and released it.
fresh
waiting 20022 status:blocked "Blocked until #19700 merges."
labeled 20022 dom 2026-11-01T10:00:00Z
listing status:blocked 20022; closed 19700
out=$(run)
want_not_in "the person's block is not released"   '^unblocked #20022$' "$out"
want_in "  it says a person blocked it after the wait" '^held: #20022 — @dom put status:blocked on at 2026-11-01T10:00:00Z, after its wait line \(theirs to lift\)$' "$out"
want "  not set ready"                             "0" "$(grep -c '^issue edit 20022' "$GH_LOG")"
want "  no Unblocked note"                         "0" "$(grep -c '^issue comment 20022.*Unblocked' "$GH_LOG")"
waiting 20022 status:blocked "spec" "Blocked until #19700 merges."
jq '.labels += [{name:"needs:owner-decision"}]' "$FIX/gh/issue-20022.json" > "$FIX/t" && mv "$FIX/t" "$FIX/gh/issue-20022.json"
listing status:blocked 20022
out=$(run)
want_not_in "a fresh wait beside the owner's hold: not released" '^unblocked #20022$' "$out"
want_in "  it says whose hold"                     '^held: #20022 — it wears needs:owner-decision \(a person.s hold\)$' "$out"
waiting 20022 status:blocked "spec" "Blocked until #19700 merges."
listing status:blocked 20022; echo 20022 > "$FIX/claims"
out=$(run)
want_not_in "a live claim: not released"           '^unblocked #20022$' "$out"
want_in "  it says the claim holds it"             '^held: #20022 — a live claim holds it$' "$out"
want "  not set ready"                             "0" "$(grep -c '^issue edit 20022' "$GH_LOG")"
rm -f "$FIX/claims"
out=$(run)
want_in "the machine's wait (label 2 s after the line) is released" '^unblocked #20022$' "$out"
rm -f "$FIX/gh/api-repos_acme_widgets_issues_20022_timeline_per_page_100.json"
out=$(run); rc=$?
want_not_in "an unread timeline releases nothing"  '^unblocked #20022$' "$out"
want "  and is a failed read"                      "1" "$rc"

echo "--- tickets in another repo's queue (issueRepo): the block's timeline is read there ---"
fresh
waiting 20023 status:blocked "Blocked until #19700 merges."
jq -n '[{event:"labeled", label:{name:"status:blocked"}, actor:{login:"dom"}, created_at:"2026-11-01T10:00:00Z"}]' \
  > "$FIX/gh/api-repos_acme_queue_issues_20023_timeline_per_page_100.json"
listing status:blocked 20023; closed 19700
jq '.issueRepo = "acme/queue"' "$HARNESS_CFG_PATH" > "$FIX/cfg-queue.json"
out=$(HARNESS_CFG_PATH="$FIX/cfg-queue.json" run)
want_not_in "the person's block in the queue's repo is not released" '^unblocked #20023$' "$out"
want_in "  it names who put it on there" '^held: #20023 — @dom put status:blocked on at 2026-11-01T10:00:00Z' "$out"

suite_end "$FAILED"
