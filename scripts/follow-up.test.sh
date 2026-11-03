#!/usr/bin/env bash
# follow-up.test.sh — finding tickets are switched off (the owner, 2026-11-02: the 3-voter
# review replaces them). `file` files nothing and holds nothing; `settle` drops findings held
# from before, whether their PR merged, closed or was rebuilt, and files none. A follow-up
# filed earlier still waits for an open parent and goes back to ready when it merges.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../driver/tests/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
SUT="$HERE/follow-up.sh"

# The forge, for this script's REST calls: the parent's labels, the search, the create.
cat > "$FIX/fgh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/fgh.log"
case "$*" in
  # A PR's state: $FIX/fgh.pr.<n> holds merged|open|closed; none is a 404.
  *"repos/acme/widgets/pulls/"*)
     a="$*"; n="${a#*repos/acme/widgets/pulls/}"; n="${n%% *}"
     [ -f "$FIX/fgh.pr.$n" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
     jq -n --arg s "$(cat "$FIX/fgh.pr.$n")" '{state: (if $s == "open" then "open" else "closed" end),
       merged_at: (if $s == "merged" then "2026-10-23T10:00:00Z" else null end), closed_at: (if $s == "open" then null else "2026-10-23T10:00:00Z" end), head: {sha: "abc123def"}}'; exit 0 ;;
  *"/comments -X POST"*)
     a="$*"; n="${a#*repos/acme/widgets/issues/}"; n="${n%%/*}"
     k=$(ls "$FIX"/fgh.comment.$n.* 2>/dev/null | grep -c .)
     printf '%s\0' "$@" > "$FIX/fgh.comment.$n.$k"; exit 0 ;;
  *"/comments?per_page=100"*)
     a="$*"; n="${a#*repos/acme/widgets/issues/}"; n="${n%%/*}"
     if [ -f "$FIX/fgh.comments.$n" ]; then cat "$FIX/fgh.comments.$n"; else echo '[]'; fi; exit 0 ;;
  # The settle pass's one read: the held PRs and the open follow-ups, as GraphQL search answers.
  *"api graphql"*"follow-ups-held"*)
     jq -n --slurpfile h <(cat "$FIX/fgh.heldprs" 2>/dev/null || echo '[]') --slurpfile k <(cat "$FIX/fgh.kids" 2>/dev/null || echo '[]') \
       '{data: {held: {nodes: [$h[0][] | {number}]},
                kids: {pageInfo: {hasNextPage: false, endCursor: null},
                       nodes: [$k[0][] | {number, body, labels: {nodes: (.labels // [])}}]}}}'; exit 0 ;;
  *"/labels -X POST"*|*"/labels/follow-ups-held -X DELETE"*) exit 0 ;;
  *"git/matching-refs/stale/"*)
     a="$*"; t="${a#*matching-refs/stale/}"; t="${t%%/*}"
     if [ -f "$FIX/fgh.stale.$t" ]; then echo "[{\"ref\":\"refs/stale/$t/20261023\"}]"; else echo '[]'; fi; exit 0 ;;
  *"is:pr is:merged"*) if [ -f "$FIX/fgh.merged" ]; then cat "$FIX/fgh.merged"; else echo '{"total_count":0,"items":[]}'; fi; exit 0 ;;
  # The search answers as GitHub does (the caller's -q applies to it); fgh.search-fails refuses it once.
  *"-X GET search/issues"*)
     if [ -f "$FIX/fgh.search-fails" ]; then rm -f "$FIX/fgh.search-fails"; echo 'gh: HTTP 502: Bad Gateway' >&2; exit 1; fi
     if [ -f "$FIX/fgh.found" ]; then printf '{"total_count":1,"items":[{"number":%s}]}\n' "$(cat "$FIX/fgh.found")"
     else echo '{"total_count":0,"items":[]}'; fi; exit 0 ;;
  *"repos/acme/widgets/issues -X POST"*)
     n=$(( $(cat "$FIX/fgh.next" 2>/dev/null || echo 776) + 1 )); echo "$n" > "$FIX/fgh.next"
     printf '%s\0' "$@" > "$FIX/fgh.create.$n"; echo "$n"; exit 0 ;;
  *"repos/acme/widgets/labels -X POST"*) : > "$FIX/fgh.label"; exit 0 ;;
  *"repos/acme/widgets/labels/"*) [ -f "$FIX/fgh.label" ] || exit 1; echo fix-after-merge; exit 0 ;;
  *"repos/acme/widgets/issues/"*) if [ -f "$FIX/fgh.parent" ]; then cat "$FIX/fgh.parent"; else printf 'screen:home\narea:feed\nP2\n'; fi; exit 0 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FIX/queue.log"\n' > "$FIX/queue"
chmod +x "$FIX/fgh" "$FIX/queue"
export FOLLOW_UP_GH="$FIX/fgh" FOLLOW_UP_QUEUE_CMD="$FIX/queue" FOLLOW_UP_LEDGER="$FIX/ledger.tsv"
export GH_PRS_FILE="$FIX/prs.json" FOLLOW_UP_HELD_DIR="$FIX/held" FOLLOW_UP_BLOCKED_LEDGER="$FIX/blocked.tsv" FOLLOW_UP_PARENTS="$FIX/parents.tsv"
for n in 777 778 779 780 781; do fix_issue "$n" OPEN ""; done

F="$FIX/findings.jsonl"
cat > "$F" <<'J'
{"id":"m1","grade":"major","file":"apps/web/a.tsx","line":3,"summary":"the save is dropped","reason":"a failure shows as success","fix":"keep the error","round":1}
{"id":"n2","grade":"minor","file":"lib/x.ts","line":2,"summary":"the log line is vague","round":1}
{"id":"c3","grade":"critical","file":"lib/y.ts","line":1,"summary":"another workspace sees the rows","round":1}
{"id":"z4","grade":"nit","file":"lib/z.ts","line":1,"summary":"taste","round":1}
J
created() { ls "$FIX"/fgh.create.* 2>/dev/null | grep -c .; }
args_of() { tr '\0' '\n' < "$FIX/fgh.create.$1"; }
export GH_BACKOFF_FILE="$FIX/gh-backoff"
reset() { rm -rf "$FIX"/fgh.create.* "$FIX"/fgh.comment.* "$FIX"/fgh.comments.* "$FIX"/fgh.pr.* "$FIX/fgh.kids" "$FIX/fgh.heldprs" \
    "$FIX/fgh.next" "$FIX/fgh.found" "$FIX"/fgh.stale.* "$FIX/fgh.merged" "$FIX/prs.json" "$FIX/ledger.tsv" "$FIX/held" "$FIX/blocked.tsv" "$FIX/parents.tsv" "$GH_BACKOFF_FILE"
  echo merged > "$FIX/fgh.pr.42"; : > "$FIX/fgh.log"; : > "$FIX/queue.log"; : > "$GH_LOG"; }
# The two cases, as a plant that measured something else leaves them: std_cases puts them back.
std_cases() {
  case_file() { OUT=$(bash "$SUT" file 701 42 "$F" 2>&1); RC=$?; R="created=$(created)"; }
  case_settle() { OUT=$(bash "$SUT" settle 2>&1); RC=$?; R="created=$(created)"; }
}
std_cases
held_n() { grep -c . "$FIX/held/42.jsonl" 2>/dev/null || echo 0; }
comment_of() { tr '\0' '\n' < "$FIX/fgh.comment.$1.${2:-0}" 2>/dev/null; }
kid() { # <n> <labels csv> <parent pr> [parent ticket] — one open follow-up ticket of that parent
  jq -n --argjson n "$1" --arg l "$2" --arg p "$3" --arg t "${4:-701}" '{number: $n, labels: ($l | split(",") | map({name: .})),
    body: "A review finding on PR #\($p) (ticket #\($t)).\n\n<!-- follow-up: pr=\($p) finding=m1 -->"}'; }

hold() { # <pr> <ticket> — findings held on a PR before finding tickets were switched off
  mkdir -p "$FIX/held"
  jq -c --arg p "$1" --arg t "$2" 'select(.grade == "major" or .grade == "minor") | . + {ticket: $t, pr: $p, head: "abc123def"}' "$F" > "$FIX/held/$1.jsonl"
}

echo "--- file files nothing and holds nothing, merged, open or closed ---"
for st in merged open closed; do
  reset; echo "$st" > "$FIX/fgh.pr.42"; case_file
  want "$st: it exits clean"                   "0" "$RC"
  want "$st: no ticket"                        "created=0" "$R"
  want "$st: nothing held"                     "0" "$(held_n)"
  want_in "$st: and it says so"                '4 finding\(s\) of PR #42 dropped, not filed: finding tickets are switched off' "$OUT"
done
want "no label is made or put on"              "0" "$(grep -c 'labels' "$FIX/fgh.log")"
want "and nothing is queued"                   "" "$(cat "$FIX/queue.log")"

echo "--- findings held from before are dropped when their PR merges, never filed ---"
reset; hold 42 701; echo merged > "$FIX/fgh.pr.42"; case_settle
want "settle exits clean"                      "0" "$RC"
want "no ticket on the merge"                  "created=0" "$R"
want "nothing is held any more"                "0" "$(held_n)"
want_in "and it says they were dropped"        'PR #42 merged: its held findings are dropped, not filed' "$OUT"

echo "--- a PR closed unmerged: its held findings are dropped ---"
reset; hold 42 701; echo closed > "$FIX/fgh.pr.42"; case_settle
want "no ticket for a closed PR"               "created=0" "$R"
want "nothing is held"                         "0" "$(held_n)"
want_in "and it says they were dropped"        'PR #42 closed without merging: its held findings are dropped' "$OUT"

echo "--- an open PR's held findings wait, and are dropped once it merges ---"
reset; hold 42 701; echo open > "$FIX/fgh.pr.42"; case_settle
want "still open: still held"                  "2" "$(held_n)"
echo merged > "$FIX/fgh.pr.42"; case_settle
want "merged: dropped, none filed"             "created=0 0" "$R $(held_n)"

echo "--- held on another host: read off the PR's fix list, dropped, and the label comes off ---"
reset; hold 42 701
data=$(base64 < "$FIX/held/42.jsonl" | tr -d '\n'); rm -rf "$FIX/held"
jq -n --arg d "$data" '[{body: "a person"}, {body: ("held\n<!-- follow-up-held: pr=42 head=abc123def data=" + $d + " -->")}]' > "$FIX/fgh.comments.42"
echo '[{"number":42,"pull_request":{}}]' > "$FIX/fgh.heldprs"; echo merged > "$FIX/fgh.pr.42"; case_settle
want "none filed from the comment's data"      "created=0" "$R"
want_in "they are dropped"                     'PR #42 merged: its held findings are dropped' "$OUT"
want_in "and the label comes off"              'issues/42/labels/follow-ups-held -X DELETE' "$(cat "$FIX/fgh.log")"

echo "--- closed to rebuild fresh: they wait for the ticket's next PR, and are dropped when it merges ---"
reset; hold 42 701; echo closed > "$FIX/fgh.pr.42"; : > "$FIX/fgh.stale.701"; case_settle
want "nothing filed while the rebuild is unmerged" "created=0" "$R"
want "and nothing is dropped yet"              "2" "$(held_n)"
echo '{"total_count":2,"items":[{"number":42,"title":"#701: old"},{"number":61,"title":"#701: the rebuild","body":"Closes #701"}]}' > "$FIX/fgh.merged"; case_settle
want "the rebuild's merge files none"          "created=0" "$R"
want "and nothing is held"                     "0" "$(held_n)"

echo "--- a ticket already filed for an open parent is blocked, then unblocked on merge ---"
reset; fix_issue 950 OPEN "status:ready,fix-after-merge"
jq -n --argjson k "$(kid 950 status:ready,fix-after-merge 55)" '[$k]' > "$FIX/fgh.kids"; echo open > "$FIX/fgh.pr.55"; case_settle
want_in "it is set blocked"                    'issue edit 950 .*--add-label status:blocked' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "it says what it waits for"            'waits for #55 to merge' "$(cat "$FIX/fgh.log")"
want_in "and the comment is the harness's"     'issue comment 950 .*harness:machine' "$(tr '\n' ' ' < "$FIX/fgh.log")"
want_in "it leaves the queue"                  '^remove 950$' "$(cat "$FIX/queue.log")"
: > "$GH_LOG"; case_settle
want_not_in "an open parent: blocked once"     'issue edit 950' "$(cat "$GH_LOG")"
fix_issue 950 OPEN "status:blocked,fix-after-merge"
jq -n --argjson k "$(kid 950 status:blocked,fix-after-merge 55)" '[$k]' > "$FIX/fgh.kids"; : > "$GH_LOG"; case_settle
want_not_in "still open: it stays blocked"     'status:ready' "$(cat "$GH_LOG")"
echo merged > "$FIX/fgh.pr.55"; case_settle
want_in "the merge sets it ready"              'issue edit 950 .*--add-label status:ready' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "and back on the queue at its priority" '^add 950 --note' "$(cat "$FIX/queue.log")"
want_not_in "never on top"                     '^add 950 --(front|first)' "$(cat "$FIX/queue.log")"

echo "--- one a person blocked on its parent is unblocked too; one blocked on something else is not ---"
reset; fix_issue 951 OPEN "status:blocked,fix-after-merge"; fix_issue 952 OPEN "status:blocked,fix-after-merge"
jq -n --argjson a "$(kid 951 status:blocked,fix-after-merge 56)" --argjson b "$(kid 952 status:blocked,fix-after-merge 56)" '[$a, $b]' > "$FIX/fgh.kids"
echo '[{"body":"## PM answer\nWait for PR #56 to merge, then build this. Blocked on #56."}]' > "$FIX/fgh.comments.951"
echo '[{"body":"Blocked on the vendor answering."}]' > "$FIX/fgh.comments.952"
echo merged > "$FIX/fgh.pr.56"; case_settle
want_in "the PM's block on the parent lifts"   'issue edit 951 .*--add-label status:ready' "$(tr '\n' ' ' < "$GH_LOG")"
want_not_in "another block stays"              'issue edit 952' "$(cat "$GH_LOG")"

echo "--- a child of a PR closed to rebuild is blocked on the ticket, then unblocked by its rebuild ---"
reset; fix_issue 960 OPEN "status:ready,fix-after-merge"
jq -n --argjson k "$(kid 960 status:ready,fix-after-merge 73 706)" '[$k]' > "$FIX/fgh.kids"; echo closed > "$FIX/fgh.pr.73"; : > "$FIX/fgh.stale.706"; case_settle
want_in "it is set blocked"                    'issue edit 960 .*--add-label status:blocked' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "on the ticket's next PR"              "waits for ticket #706's next PR to merge" "$(cat "$FIX/fgh.log")"
fix_issue 960 OPEN "status:blocked,fix-after-merge"; jq -n --argjson k "$(kid 960 status:blocked,fix-after-merge 73 706)" '[$k]' > "$FIX/fgh.kids"
: > "$GH_LOG"; case_settle
want_not_in "no rebuild merged: still blocked" 'status:ready' "$(cat "$GH_LOG")"
echo '{"total_count":1,"items":[{"number":88,"title":"#706: rebuild"}]}' > "$FIX/fgh.merged"; case_settle
want_in "the rebuild's merge sets it ready"    'issue edit 960 .*--add-label status:ready' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "naming the rebuild"                   'Unblocked: #88 merged' "$(cat "$FIX/fgh.log")"

echo "--- a follow-up that names no parent PR is skipped, not unknown ---"
reset; echo '[{"number":970,"labels":[{"name":"status:ready"}],"body":"Follow-up from the review of #13048."}]' > "$FIX/fgh.kids"; case_settle
want "it exits clean"                          "0" "$RC"
want_not_in "and says nothing unknown"         'unknown' "$OUT"

echo "--- an open parent in the shared open-PR copy costs no read ---"
reset; fix_issue 950 OPEN "status:ready,fix-after-merge"; jq -n --argjson k "$(kid 950 status:ready,fix-after-merge 55)" '[$k]' > "$FIX/fgh.kids"
echo '[{"number":55}]' > "$FIX/prs.json"; case_settle
want_not_in "PR #55 is not read on its own"    'pulls/55' "$(cat "$FIX/fgh.log")"
want_in "and the child is blocked all the same" 'issue edit 950 .*--add-label status:blocked' "$(tr '\n' ' ' < "$GH_LOG")"

echo "--- plants: each guard out, its case fails ---"
KIT="$FIX/kit"
plant() { # <label> <exact text to delete> <setup> <the result the guard prevents> [case]
  rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$HERE" "$KIT/scripts"; cp -R "$HERE/../swarm" "$HERE/../driver" "$KIT/"
  python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' "$KIT/scripts/follow-up.sh" "$2" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  reset; eval "$3"; SUT="$KIT/scripts/follow-up.sh" "${5:-case_file}"; want "planted ($1): the case now fails" "$4" "$R"
}
plant "the drop of held findings" '  rm -f "$hf"
' 'hold 42 701; echo merged > "$FIX/fgh.pr.42"; case_settle() { bash "$SUT" settle >/dev/null 2>&1; R="held=$(held_n)"; }' "held=2" case_settle
plant "the block of a child" '      issue_status_set "$n" "$LBL_BLOCKED" >/dev/null 2>&1 || { echo "#$n could not be set $LBL_BLOCKED"; rc=1; continue; }' \
  'fix_issue 950 OPEN "status:ready,fix-after-merge"; jq -n --argjson k "$(kid 950 status:ready,fix-after-merge 55)" "[\$k]" > "$FIX/fgh.kids"; echo open > "$FIX/fgh.pr.55"
   case_settle() { bash "$SUT" settle >/dev/null 2>&1; R="blocked=$(grep -c "issue edit 950 .*status:blocked" "$GH_LOG")"; }' "blocked=0" case_settle
plant "the unblock on merge" '      issue_status_set "$n" "$LBL_READY" >/dev/null 2>&1 || { echo "#$n could not be set $LBL_READY"; rc=1; continue; }' \
  'fix_issue 950 OPEN "status:blocked,fix-after-merge"; jq -n --argjson k "$(kid 950 status:blocked,fix-after-merge 55)" "[\$k]" > "$FIX/fgh.kids"; echo "950 55" > "$FIX/blocked.tsv"; echo merged > "$FIX/fgh.pr.55"
   case_settle() { bash "$SUT" settle >/dev/null 2>&1; R="ready=$(grep -c "issue edit 950 .*status:ready" "$GH_LOG")"; }' "ready=0" case_settle

plant "the empty-parent skip" '  case "$p" in '"''"'|*[!0-9]*) continue ;; esac
' 'echo "[{\"number\":970,\"labels\":[],\"body\":\"Follow-up from the review of #13048.\"}]" > "$FIX/fgh.kids"; case_settle() { OUT=$(bash "$SUT" settle 2>&1); R="unknown=$(printf "%s" "$OUT" | grep -c unknown)"; }' "unknown=1" case_settle
plant "the shared open-PR copy" '  if [ "$OPEN_KNOWN" = 1 ] && printf '"'"'%s\n'"'"' "$open_prs" | grep -qx "$1"; then printf open; return 0; fi
' 'fix_issue 950 OPEN "status:ready,fix-after-merge"; jq -n --argjson k "$(kid 950 status:ready,fix-after-merge 55)" "[\$k]" > "$FIX/fgh.kids"; echo "[{\"number\":55}]" > "$FIX/prs.json"; echo open > "$FIX/fgh.pr.55"; case_settle() { bash "$SUT" settle >/dev/null 2>&1; R="reads=$(grep -c "pulls/55" "$FIX/fgh.log")"; }' "reads=1" case_settle

suite_end "$FAILED"
