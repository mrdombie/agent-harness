#!/usr/bin/env bash
# follow-up.test.sh — merge first, fix after: each review finding that does not hold the
# change is one ticket, naming the PR, the file:line and the finding; a Major at P1, a
# Minor at P3; status ready and at the front of the queue; filed once per PR and
# finding, whether this host or the forge remembers it; a Critical or a Nit never.
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
       merged_at: (if $s == "merged" then "2026-10-23T10:00:00Z" else null end), head: {sha: "abc123def"}}'; exit 0 ;;
  *"/comments -X POST"*)
     a="$*"; n="${a#*repos/acme/widgets/issues/}"; n="${n%%/*}"
     k=$(ls "$FIX"/fgh.comment.$n.* 2>/dev/null | grep -c .)
     printf '%s\0' "$@" > "$FIX/fgh.comment.$n.$k"; exit 0 ;;
  *"/comments?per_page=100"*)
     a="$*"; n="${a#*repos/acme/widgets/issues/}"; n="${n%%/*}"
     if [ -f "$FIX/fgh.comments.$n" ]; then cat "$FIX/fgh.comments.$n"; else echo '[]'; fi; exit 0 ;;
  *"issues?state=open&labels=fix-after-merge"*) if [ -f "$FIX/fgh.kids" ]; then cat "$FIX/fgh.kids"; else echo '[]'; fi; exit 0 ;;
  *"issues?state=all&labels=follow-ups-held"*) if [ -f "$FIX/fgh.heldprs" ]; then cat "$FIX/fgh.heldprs"; else echo '[]'; fi; exit 0 ;;
  *"/labels -X POST"*|*"/labels/follow-ups-held -X DELETE"*) exit 0 ;;
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
  *"repos/acme/widgets/issues/"*) printf 'screen:home\narea:feed\nP2\n'; exit 0 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FIX/queue.log"\n' > "$FIX/queue"
chmod +x "$FIX/fgh" "$FIX/queue"
export FOLLOW_UP_GH="$FIX/fgh" FOLLOW_UP_QUEUE_CMD="$FIX/queue" FOLLOW_UP_LEDGER="$FIX/ledger.tsv"
export FOLLOW_UP_HELD_DIR="$FIX/held" FOLLOW_UP_BLOCKED_LEDGER="$FIX/blocked.tsv" FOLLOW_UP_PARENTS="$FIX/parents.tsv"
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
    "$FIX/fgh.next" "$FIX/fgh.found" "$FIX/ledger.tsv" "$FIX/held" "$FIX/blocked.tsv" "$FIX/parents.tsv" "$GH_BACKOFF_FILE"
  echo merged > "$FIX/fgh.pr.42"; : > "$FIX/fgh.log"; : > "$FIX/queue.log"; : > "$GH_LOG"; }
case_settle() { OUT=$(bash "$SUT" settle 2>&1); RC=$?; R="created=$(created)"; }
held_n() { grep -c . "$FIX/held/42.jsonl" 2>/dev/null || echo 0; }
comment_of() { tr '\0' '\n' < "$FIX/fgh.comment.$1.${2:-0}" 2>/dev/null; }
kid() { # <n> <labels csv> <parent pr> — one open follow-up ticket of that parent
  jq -n --argjson n "$1" --arg l "$2" --arg p "$3" '{number: $n, labels: ($l | split(",") | map({name: .})),
    body: "A review finding on PR #\($p) (ticket #701).\n\n<!-- follow-up: pr=\($p) finding=m1 -->"}'; }
case_file() { OUT=$(bash "$SUT" file 701 42 "$F" 2>&1); RC=$?; R="created=$(created)"; }

echo "--- a Major and a Minor are filed; a Critical and a Nit are not ---"
reset; case_file
want "it exits clean"                          "0" "$RC"
want "two tickets"                             "created=2" "$R"
want_in "the Major at P1"                      '^labels\[\]=P1$' "$(args_of 777)"
want_in "the Minor at P3"                      '^labels\[\]=P3$' "$(args_of 778)"
want_in "every follow-up wears fix-after-merge" '^labels\[\]=fix-after-merge$' "$(args_of 777)"
want_in "the Minor too"                        '^labels\[\]=fix-after-merge$' "$(args_of 778)"
want "the label was missing, so it was created once" "1" "$(grep -c 'labels -X POST -f name=fix-after-merge' "$FIX/fgh.log")"
want_in "the parent's screen rides along"      '^labels\[\]=screen:home$' "$(args_of 777)"
want_not_in "the parent's priority does not"   '^labels\[\]=P2$' "$(args_of 777)"
want_in "the body names the PR"                'A review finding on PR #42 \(ticket #701\)' "$(args_of 777)"
want_in "the file:line"                        'apps/web/a.tsx:3' "$(args_of 777)"
want_in "the finding"                          'the save is dropped' "$(args_of 777)"
want_in "and carries its dedupe key"           'follow-up: pr=42 finding=m1' "$(args_of 777)"
want_in "it is made ready"                     'issue edit 777 .*--add-label.status:ready' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "and put at the front of the queue"    '^add 777 --front --note follow-up of PR #42: major at apps/web/a.tsx:3$' "$(cat "$FIX/queue.log")"
want_in "a Critical is never filed"            "c3 is graded 'critical', which is never filed" "$OUT"

echo "--- filed once: a second ship files nothing ---"
case_file
want "nothing new"                             "created=2" "$R"
want_in "and says they were filed"             '2 finding\(s\) on PR #42 were already filed' "$OUT"

echo "--- filed once even when this host forgot: the forge's marker is found ---"
reset; echo 900 > "$FIX/fgh.found"; case_file
want "nothing created"                         "created=0" "$R"
want_in "the key is searched for"              'follow-up: pr=42 finding=m1' "$(cat "$FIX/fgh.log")"

echo "--- a search that fails is unknown: nothing is filed, and it says so ---"
reset; : > "$FIX/fgh.search-fails"; case_file
want "nothing created on the failed search"    "created=1" "$R"
want_in "it logs unknown"                      'unknown — whether finding .* was filed could not be read' "$OUT"
want "and exits non-zero"                      "1" "$RC"

echo "--- a review on an open PR files no ticket: the findings are held on its fix list ---"
reset; echo open > "$FIX/fgh.pr.42"; case_file
want "it exits clean"                          "0" "$RC"
want "no ticket is filed"                      "created=0" "$R"
want "the Major and the Minor are held"        "2" "$(held_n)"
want_in "keyed by PR and head"                 '"pr":"42","head":"abc123def"' "$(head -1 "$FIX/held/42.jsonl")"
want_in "the PR wears the held label"          'issues/42/labels -X POST -f labels\[\]=follow-ups-held' "$(cat "$FIX/fgh.log")"
want_in "its fix list names the finding"       'the save is dropped' "$(comment_of 42)"
want_in "and the comment is the harness's"     '<!-- harness:machine -->' "$(comment_of 42)"
want_in "it says they wait for the merge"      'PR #42 has not merged: 2 finding\(s\) held' "$OUT"
case_file
want "a second review holds nothing twice"     "2" "$(held_n)"

echo "--- the merge files them, each with the fix-after-merge label ---"
echo merged > "$FIX/fgh.pr.42"; case_settle
want "settle exits clean"                      "0" "$RC"
want "two tickets on the merge"                "created=2" "$R"
want_in "the Major wears fix-after-merge"      '^labels\[\]=fix-after-merge$' "$(args_of 777)"
want_in "the Minor too"                        '^labels\[\]=fix-after-merge$' "$(args_of 778)"
want_in "the ticket names the PR"              'A review finding on PR #42 \(ticket #701\)' "$(args_of 777)"
want "nothing is held any more"                "0" "$(held_n)"
case_settle
want "a second pass files nothing"             "created=2" "$R"

echo "--- a PR closed unmerged files none: its held findings are dropped ---"
reset; echo open > "$FIX/fgh.pr.42"; case_file
echo closed > "$FIX/fgh.pr.42"; case_settle
want "no ticket for a closed PR"               "created=0" "$R"
want "nothing is held"                         "0" "$(held_n)"
want_in "and it says they were dropped"        'PR #42 closed without merging: its held findings are dropped' "$OUT"
reset; echo closed > "$FIX/fgh.pr.42"; case_file
want "a review of a closed PR files none"      "created=0" "$R"

echo "--- held on another host: the merge pass reads them off the PR's fix list ---"
reset; echo open > "$FIX/fgh.pr.42"; case_file
jq -n --arg b "$(comment_of 42 | sed -n '/^body=/,$p' | sed '1s/^body=//')" '[{body: "a person"}, {body: $b}]' > "$FIX/fgh.comments.42"
rm -rf "$FIX/held"; echo '[{"number":42,"pull_request":{}}]' > "$FIX/fgh.heldprs"; echo merged > "$FIX/fgh.pr.42"; case_settle
want "both filed from the comment's data"      "created=2" "$R"
want_in "and the label comes off"              'issues/42/labels/follow-ups-held -X DELETE' "$(cat "$FIX/fgh.log")"

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
want_in "and at the front of the queue"        '^add 950 --front' "$(cat "$FIX/queue.log")"

echo "--- one a person blocked on its parent is unblocked too; one blocked on something else is not ---"
reset; fix_issue 951 OPEN "status:blocked,fix-after-merge"; fix_issue 952 OPEN "status:blocked,fix-after-merge"
jq -n --argjson a "$(kid 951 status:blocked,fix-after-merge 56)" --argjson b "$(kid 952 status:blocked,fix-after-merge 56)" '[$a, $b]' > "$FIX/fgh.kids"
echo '[{"body":"## PM answer\nWait for PR #56 to merge, then build this. Blocked on #56."}]' > "$FIX/fgh.comments.951"
echo '[{"body":"Blocked on the vendor answering."}]' > "$FIX/fgh.comments.952"
echo merged > "$FIX/fgh.pr.56"; case_settle
want_in "the PM's block on the parent lifts"   'issue edit 951 .*--add-label status:ready' "$(tr '\n' ' ' < "$GH_LOG")"
want_not_in "another block stays"              'issue edit 952' "$(cat "$GH_LOG")"

echo "--- plants: each guard out, its case fails ---"
KIT="$FIX/kit"
plant() { # <label> <exact text to delete> <setup> <the result the guard prevents> [case]
  rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$HERE" "$KIT/scripts"; cp -R "$HERE/../swarm" "$HERE/../driver" "$KIT/"
  python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' "$KIT/scripts/follow-up.sh" "$2" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  reset; eval "$3"; SUT="$KIT/scripts/follow-up.sh" "${5:-case_file}"; want "planted ($1): the case now fails" "$4" "$R"
}
plant "the ledger" '    if n=$(awk -F'"'"'\t'"'"' -v p="$PR" -v i="$id" '"'"'$1 == p && $2 == i { print $3; exit }'"'"' "$LEDGER" 2>/dev/null) && [ -n "$n" ]; then
      had=$((had + 1)); continue
    fi' 'SUT="$KIT/scripts/follow-up.sh" case_file' "created=4"
plant "the forge search" '  if [ -n "$n" ]; then printf '"'"'%s\t%s\n'"'"' "$key" "$n" >> "$LEDGER"; had=$((had + 1)); continue; fi' 'echo 900 > "$FIX/fgh.found"' "created=2"
plant "the grade map" '    major) pri="$P_MAJOR" ;; minor) pri="$P_MINOR" ;;' ':' "created=0"
plant "the follow-up label" ' -f "labels[]=$FU_LABEL"' 'case_file() { OUT=$(bash "$SUT" file 701 42 "$F" 2>&1); RC=$?; R="label=$(args_of 777 | grep -c "^labels\[\]=fix-after-merge$")"; }' "label=0"
plant "the label's creation" '  ensure_fu_label
' 'rm -f "$FIX/fgh.label"; case_file() { OUT=$(bash "$SUT" file 701 42 "$F" 2>&1); RC=$?; R="made=$(grep -c "labels -X POST" "$FIX/fgh.log")"; }' "made=0"
case_file() { OUT=$(bash "$SUT" file 701 42 "$F" 2>&1); RC=$?; R="created=$(created)"; }
case_settle() { OUT=$(bash "$SUT" settle 2>&1); RC=$?; R="created=$(created)"; }
plant "the hold on an open PR" '    *) hold_findings "$T" "$PR" "$head" "$F"; exit "$failed" ;;' 'echo open > "$FIX/fgh.pr.42"' "created=2"
plant "the filing on merge" '        file_findings "$(jq -r '"'"'.ticket // empty'"'"' "$hf" | head -1)" "$pr" "$hf"' \
  'echo open > "$FIX/fgh.pr.42"; case_file; echo merged > "$FIX/fgh.pr.42"' "created=0" case_settle
plant "the drop on a closed PR" '  rm -f "$hf"
' 'echo open > "$FIX/fgh.pr.42"; case_file; echo closed > "$FIX/fgh.pr.42"; case_settle() { bash "$SUT" settle >/dev/null 2>&1; R="held=$(held_n)"; }' "held=2" case_settle
plant "the block of a child" '      issue_status_set "$n" "$LBL_BLOCKED" >/dev/null 2>&1 || { echo "#$n could not be set $LBL_BLOCKED"; rc=1; continue; }' \
  'fix_issue 950 OPEN "status:ready,fix-after-merge"; jq -n --argjson k "$(kid 950 status:ready,fix-after-merge 55)" "[\$k]" > "$FIX/fgh.kids"; echo open > "$FIX/fgh.pr.55"
   case_settle() { bash "$SUT" settle >/dev/null 2>&1; R="blocked=$(grep -c "issue edit 950 .*status:blocked" "$GH_LOG")"; }' "blocked=0" case_settle
plant "the unblock on merge" '      issue_status_set "$n" "$LBL_READY" >/dev/null 2>&1 || { echo "#$n could not be set $LBL_READY"; rc=1; continue; }' \
  'fix_issue 950 OPEN "status:blocked,fix-after-merge"; jq -n --argjson k "$(kid 950 status:blocked,fix-after-merge 55)" "[\$k]" > "$FIX/fgh.kids"; echo "950 55" > "$FIX/blocked.tsv"; echo merged > "$FIX/fgh.pr.55"
   case_settle() { bash "$SUT" settle >/dev/null 2>&1; R="ready=$(grep -c "issue edit 950 .*status:ready" "$GH_LOG")"; }' "ready=0" case_settle

suite_end "$FAILED"
