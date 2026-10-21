#!/usr/bin/env bash
# polish-list.test.sh — a Minor finding lands on its screen's one open list, never
# a ticket of its own: the list is found by its labels or opened once, an item is
# appended under "## Items" once however often it is added, and the free items are
# what a builder and the coordinator read. An item is ticked only when the PR that
# fixed it merges; a PR closed unmerged frees it; a list closes when nothing is left.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
P="$HERE/polish-list.sh"

# A gh whose issues are files that create, edit and list really change.
mkdir -p "$FIX/store"; echo 900 > "$FIX/store/next"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
S="$FIX/store"; labels=(); title=""; body=""; bodyfile=""; prev=""
for a in "$@"; do
  case "$prev" in --label) labels+=("$a") ;; --title) title="$a" ;; --body) body="$a" ;; --body-file) bodyfile="$a" ;; esac
  prev="$a"
done
case "$1 $2" in
  "label create") exit 0 ;;
  "issue create")
    n=$(cat "$S/next"); echo $((n+1)) > "$S/next"
    printf '%s\n' "${labels[@]}" | jq -R . | jq -s --argjson n "$n" --arg t "$title" --arg b "$body" \
      '{number:$n, state:"OPEN", title:$t, body:$b, labels:map({name:.})}' > "$S/issue-$n.json"
    echo "https://github.com/acme/widgets/issues/$n" ;;
  "issue view") f="$S/issue-$3.json"; [ -f "$f" ] || exit 1; cat "$f" ;;
  "issue edit")
    f="$S/issue-$3.json"; [ -f "$f" ] || exit 1
    [ "$bodyfile" = - ] && body=$(cat) || body=$(cat "$bodyfile")
    jq --arg b "$body" '.body = $b' "$f" > "$f.t" && mv "$f.t" "$f" ;;
  "issue list")
    # $S/stale-list: the list read answers with bodies an edit has since changed.
    [ -f "$S/stale-list" ] && { cat "$S/stale-list"; exit 0; }
    want=$(printf '%s\n' "${labels[@]}" | jq -R . | jq -sc .)
    for f in "$S"/issue-*.json; do [ -f "$f" ] && cat "$f"; done \
      | jq -s --argjson w "$want" '[.[] | select(.state == "OPEN") | select([.labels[].name] as $l | all($w[]; . as $x | $l | index($x))) | {number, body}]' ;;
  "api repos/"*)
    # The issues endpoint by label. $S/lag: GitHub has not listed a new issue yet.
    [ -f "$S/lag" ] && { echo '[]'; exit 0; }
    want=$(printf '%s' "$2" | sed -n 's/.*[?&]labels=\([^&]*\).*/\1/p' | tr ',' '\n' | jq -Rr '@text' | while IFS= read -r l; do printf '%b\n' "${l//%/\\x}"; done | jq -R . | jq -sc .)
    for f in "$S"/issue-*.json; do [ -f "$f" ] && cat "$f"; done \
      | jq -s --argjson w "$want" '[.[] | select(.state == "OPEN") | select([.labels[].name] as $l | all($w[]; . as $x | $l | index($x))) | {number, title, body}]' ;;
  "issue close") f="$S/issue-$3.json"; jq '.state = "CLOSED"' "$f" > "$f.t" && mv "$f.t" "$f" ;;
  "api graphql")
    # A batched read of pull requests: each iN answered from $S/pr-N (its state).
    q=""; for a in "$@"; do case "$a" in query=*) q="${a#query=}" ;; esac; done
    out='{}'
    for n in $(printf '%s' "$q" | grep -oE 'i[0-9]+:issueOrPullRequest' | sed 's/^i//; s/:.*//'); do
      st=$(cat "$S/pr-$n" 2>/dev/null || echo OPEN)
      # $S/lbl-N: its labels, comma-joined; $S/upd-N: when it last changed (default now).
      out=$(jq -c --arg k "i$n" --argjson n "$n" --arg s "$st" --arg l "$(cat "$S/lbl-$n" 2>/dev/null)" \
              --arg u "$(cat "$S/upd-$n" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + {($k): {number:$n, state:$s, title:"", updatedAt:$u, labels:{nodes:($l | split(",") | map(select(length > 0) | {name:.}))}}}' <<<"$out")
    done
    jq -c '{data:{repository:.}}' <<<"$out" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"
body() { jq -r .body "$FIX/store/issue-$1.json"; }
lines() { body "$1" | grep -c '^- \[ \] '; }

echo "--- the first item opens the screen's list ---"
out=$(bash "$P" add inbox-thread "The row gap is 12px, the kit says 16px" 2>&1)
want "it names the list and the item"      "#900: added The row gap is 12px, the kit says 16px" "$out"
want "titled for the screen"               "Polish list: Inbox Thread" "$(jq -r .title "$FIX/store/issue-900.json")"
want "labelled as a list, for the screen, P3, ready, a bug" \
  "P3,polish-list,screen:inbox-thread,status:ready,type:bug" "$(jq -r '[.labels[].name] | sort | join(",")' "$FIX/store/issue-900.json")"
want "the item is a task line under ## Items" "- [ ] The row gap is 12px, the kit says 16px" "$(body 900 | sed -n '/^## Items/,$p' | sed -n 2p)"

echo "--- the same text twice adds one line ---"
out=$(bash "$P" add inbox-thread "The row gap is 12px, the kit says 16px" 2>&1)
want "one line, not two"                   "1" "$(lines 900)"
want_in "and it says it is already there"  'already lists' "$out"
want "no second list was opened"           "901" "$(cat "$FIX/store/next")"

echo "--- a second item goes on the same list, under the first ---"
bash "$P" add inbox-thread "Send button label wraps on a phone" >/dev/null
want "two items"                           "2" "$(lines 900)"
want "in the order they came"              "Send button label wraps on a phone" "$(body 900 | grep '^- \[ \] ' | sed -n '2s/^- \[ \] //p')"

echo "--- another screen gets its own list ---"
bash "$P" add calendar "Week header is one weight too heavy" >/dev/null
want "a second list"                       "901" "$(bash "$P" for-screen calendar)"
want "for-screen finds the first"          "900" "$(bash "$P" for-screen inbox-thread)"
want "a screen with no list prints nothing" "" "$(bash "$P" for-screen settings)"

echo "--- items and count read only the free ones ---"
bash "$P" add inbox-thread "Empty state icon is off-kit" >/dev/null
want "items prints all three while none is taken" "3" "$(bash "$P" count 900)"
want "count reads a body from stdin: unticked, unreserved, under ## Items" "1" \
  "$(printf '## Items\n- [ ] a\n- [x] b\n- [ ] c (in PR #7)\n\n## Notes\n- [ ] not an item\n' | bash "$P" count -)"
want "an empty list counts 0"              "0" "$(printf 'no items yet\n' | bash "$P" count -)"

echo "--- a run takes an item: marked at once, never ticked during the build ---"
out=$(bash "$P" take 900 501 "Send button label wraps on a phone")
want_in "it says it is ticked when the PR merges" 'ticked when its pull request merges' "$out"
want "nothing is ticked"                   "3" "$(lines 900)"
want "the line says who took it"           "- [ ] Send button label wraps on a phone (taken by #501)" "$(body 900 | grep 'Send button')"
want "the run's record names it"           "900	Send button label wraps on a phone" "$(bash "$P" taken 501)"
bash "$P" take 900 502 "Send button label wraps on a phone" 2>/dev/null; want "a second run cannot take it" "1" "$?"
want_in "taking it again for the same run is fine" 'taken for #501' "$(bash "$P" take 900 501 "Send button label wraps on a phone")"
bash "$P" take 900 501 "Not on the list" 2>/dev/null; want "taking an item not there fails" "1" "$?"
bash "$P" reserve 900 41 "Send button label wraps on a phone" 2>/dev/null; want "a PR cannot reserve another run's take" "1" "$?"
bash "$P" reserve --ticket 502 900 41 "Send button label wraps on a phone" 2>/dev/null; want "nor can another ticket's ship" "1" "$?"

echo "--- ship reserves it for its PR: other runs skip it ---"
out=$(bash "$P" reserve --ticket 501 900 41 "Send button label wraps on a phone")
want "the line carries the PR"             "- [ ] Send button label wraps on a phone (in PR #41)" "$(body 900 | grep 'Send button')"
want "a reserved item is not free"         "The row gap is 12px, the kit says 16px|Empty state icon is off-kit" "$(bash "$P" items 900 | tr '\n' '|' | sed 's/|$//')"
bash "$P" take 900 502 "Send button label wraps on a phone" 2>/dev/null; want "another run cannot take it" "1" "$?"
bash "$P" reserve 900 42 "Send button label wraps on a phone" 2>/dev/null; want "nor another PR reserve it" "1" "$?"
want_in "reserving it again for the same PR is fine" 'already reserved' "$(bash "$P" reserve 900 41 "Send button label wraps on a phone")"
want "a reserved item is still never added again" "#900 already lists: Send button label wraps on a phone" "$(bash "$P" add inbox-thread "Send button label wraps on a phone")"

echo "--- a fresh run lets go of what an earlier run took and never reserved ---"
bash "$P" take 900 503 "Empty state icon is off-kit" >/dev/null
want "taken"                               "- [ ] Empty state icon is off-kit (taken by #503)" "$(body 900 | grep 'Empty state')"
bash "$P" forget 503 >/dev/null
want "free again"                          "- [ ] Empty state icon is off-kit" "$(body 900 | grep 'Empty state')"
want "and the record is gone"              "" "$(bash "$P" taken 503)"
bash "$P" take 900 503 "Empty state icon is off-kit" >/dev/null
bash "$P" forget 503 900 "Empty state icon is off-kit" >/dev/null
want "forgetting one item leaves the list's mark (ship, once reserved)" "- [ ] Empty state icon is off-kit (taken by #503)" "$(body 900 | grep 'Empty state')"
want "and drops it from the record"        "" "$(bash "$P" taken 503)"
echo CLOSED > "$FIX/store/pr-503"; bash "$P" sweep >/dev/null
want "the sweep frees what a closed ticket took" "- [ ] Empty state icon is off-kit" "$(body 900 | grep 'Empty state')"

echo "--- a take is released when its run is parked, waits on the owner, or has stopped ---"
bash "$P" take 900 510 "Empty state icon is off-kit" >/dev/null
echo "status:parked" > "$FIX/store/lbl-510"; bash "$P" sweep >/dev/null
want "a parked run's take is free again"   "- [ ] Empty state icon is off-kit" "$(body 900 | grep 'Empty state')"
bash "$P" take 900 511 "Empty state icon is off-kit" >/dev/null
echo "needs:owner-decision" > "$FIX/store/lbl-511"; bash "$P" sweep >/dev/null
want "so is one waiting on the owner"      "- [ ] Empty state icon is off-kit" "$(body 900 | grep 'Empty state')"
bash "$P" take 900 512 "Empty state icon is off-kit" >/dev/null
echo "2026-01-01T00:00:00Z" > "$FIX/store/upd-512"; out=$(bash "$P" sweep)
want "and one with no live run, untouched for a day" "- [ ] Empty state icon is off-kit" "$(body 900 | grep 'Empty state')"
want_in "named"                            'no live run and no change in 24h' "$out"
bash "$P" take 900 513 "Empty state icon is off-kit" >/dev/null; bash "$P" sweep >/dev/null
want "a take touched today stays"          "- [ ] Empty state icon is off-kit (taken by #513)" "$(body 900 | grep 'Empty state')"
bash "$P" forget 513 >/dev/null
bash "$P" take 900 514 "Empty state icon is off-kit" >/dev/null
echo "2026-01-01T00:00:00Z" > "$FIX/store/upd-514"; fix_running 514; bash "$P" sweep >/dev/null
want "an old take whose run is still live stays" "- [ ] Empty state icon is off-kit (taken by #514)" "$(body 900 | grep 'Empty state')"
rm -f "$STATE/runs/claim-514-t.json"; bash "$P" forget 514 >/dev/null

echo "--- housekeeping settles it: merged ticks, closed unmerged frees ---"
bash "$P" reserve 900 43 "Empty state icon is off-kit" >/dev/null
echo MERGED > "$FIX/store/pr-41"; echo CLOSED > "$FIX/store/pr-43"
out=$(bash "$P" sweep --dry-run)
want_in "a dry run says what it would do"  'would be ticked — PR #41 merged' "$out"
want "and changes nothing"                 "- [ ] Send button label wraps on a phone (in PR #41)" "$(body 900 | grep 'Send button')"
out=$(bash "$P" sweep)
want "the merged PR's item is ticked"      "- [x] Send button label wraps on a phone (in PR #41)" "$(body 900 | grep 'Send button')"
want "the closed PR's item is free again"  "- [ ] Empty state icon is off-kit" "$(body 900 | grep 'Empty state')"
want "an open PR's item stays reserved, nothing else moves" "OPEN" "$(jq -r .state "$FIX/store/issue-900.json")"

echo "--- the sweep writes over the body as it is now, not as the list read found it ---"
bash "$P" add calendar "Stale read item" >/dev/null
bash "$P" reserve 901 61 "Stale read item" >/dev/null
"$BIN/gh" issue list --repo acme/widgets --state open --label polish-list --json number,body > "$FIX/stale.json"
mv "$FIX/stale.json" "$FIX/store/stale-list"
# Someone adds an item on the web between the sweep's list read and its write.
jq '.body += "\n- [ ] Added after the read"' "$FIX/store/issue-901.json" > "$FIX/t" && mv "$FIX/t" "$FIX/store/issue-901.json"
echo MERGED > "$FIX/store/pr-61"; bash "$P" sweep >/dev/null; rm -f "$FIX/store/stale-list"
want "the merged item is ticked"           "- [x] Stale read item (in PR #61)" "$(body 901 | grep 'Stale read')"
want "and an item added since is not lost" "- [ ] Added after the read" "$(body 901 | grep 'Added after')"

echo "--- a list closes only when nothing is left on it ---"
bash "$P" reserve 900 44 "The row gap is 12px, the kit says 16px" >/dev/null
bash "$P" reserve 900 45 "Empty state icon is off-kit" >/dev/null
echo MERGED > "$FIX/store/pr-44"; bash "$P" sweep >/dev/null
want "one item still reserved: the list stays open" "OPEN" "$(jq -r .state "$FIX/store/issue-900.json")"
echo MERGED > "$FIX/store/pr-45"; out=$(bash "$P" sweep)
want "every item merged: the list closes"  "CLOSED" "$(jq -r .state "$FIX/store/issue-900.json")"
want_in "and says so"                      '#900: closed — every item is done' "$out"
want "a new item for the screen opens a new list" "#902: added Header weight" "$(bash "$P" add inbox-thread "Header weight")"

echo "--- the lock: a dead holder's lock is broken; only its owner removes it ---"
L="$STATE/swarm/polish-list.lock"; mkdir -p "$L"; echo dead > "$L/owner"; touch -t 202601010000 "$L"
out=$(bash "$P" add calendar "Stale lock item" 2>&1)
want_in "a lock older than the stale age is broken, not waited out" 'added Stale lock item' "$out"
want "and the waiter removed only its own lock on exit" "" "$(ls -d "$L" 2>/dev/null)"
mkdir -p "$L"; echo someone-else > "$L/owner"
( . "$P" --help >/dev/null; unlock )
want "an exit never removes a lock another process owns" "someone-else" "$(cat "$L/owner" 2>/dev/null)"
rm -rf "$L"
want "the waiter outlasts the stale age"   "yes" "$( . "$P" --help >/dev/null; [ "$LOCK_WAIT_SEC" -gt "$LOCK_STALE_SEC" ] && echo yes )"

echo "--- a body edited on the web keeps working ---"
jq '.body = "Hand-written intro\r\n\r\n## Items\r\n- [ ] One\r\n\r\n## Notes\r\nkeep me\r\n"' "$FIX/store/issue-901.json" > "$FIX/t" && mv "$FIX/t" "$FIX/store/issue-901.json"
bash "$P" add calendar "Two" >/dev/null
want "the new item lands inside ## Items, before the next heading" "- [ ] One|- [ ] Two||" "$(body 901 | sed -n '/^## Items/,/^## Notes/p' | sed '1d;$d' | tr '\n' '|')"
want "the rest of the body is kept"        "keep me" "$(body 901 | tail -1)"

echo "--- a read that fails adds nothing ---"
mv "$FIX/store/issue-900.json" "$FIX/store/gone.json"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh-down"; chmod +x "$BIN/gh-down"
out=$(SWARM_GH="$BIN/gh-down" bash "$P" add inbox-thread "Something" 2>&1); rc=$?
want "refused"                             "2" "$rc"
want_in "and says so"                      'could not be read — nothing added' "$out"
want "nothing was opened"                  "903" "$(cat "$FIX/store/next")"
want "a bad slug is refused"               "2" "$(bash "$P" add "Inbox Thread" x >/dev/null 2>&1; echo $?)"

echo "--- two quick adds land on one list while GitHub has not listed it yet ---"
touch "$FIX/store/lag"
bash "$P" add lag-screen "first finding" >/dev/null
first=$(($(cat "$FIX/store/next") - 1))
bash "$P" add lag-screen "second finding" >/dev/null
want "no second list was opened"           "$((first + 1))" "$(cat "$FIX/store/next")"
want "both items are on the one list"      "2" "$(lines "$first")"
rm -f "$FIX/store/lag"
want "for-screen finds it once GitHub lists it" "$first" "$(bash "$P" for-screen lag-screen)"
jq '.state = "CLOSED"' "$FIX/store/issue-$first.json" > "$FIX/store/c.json" && mv "$FIX/store/c.json" "$FIX/store/issue-$first.json"
touch "$FIX/store/lag"
want "a closed list on record is not used" "" "$(bash "$P" for-screen lag-screen)"
rm -f "$FIX/store/lag"


echo "--- polish is Minor by definition: a Major or Critical is its own ticket, never an item ---"
rm -f "$FIX/store/lag"
bash "$P" add grade-screen "the gap is 4px off" >/dev/null
gl=$(bash "$P" for-screen grade-screen)
before=$(lines "$gl")
out=$(bash "$P" add grade-screen "Major · the masthead clips the primary verb off screen" 2>&1); rc=$?
want "handled, not an error"               "0" "$rc"
want_not_in "the Major is not on the list" 'masthead clips' "$(body "$gl")"
want "the list keeps its Minor only"       "$before" "$(lines "$gl")"
mj=$(printf '%s' "$out" | grep -oE '^#[0-9]+' | tr -d '#')
want_in "add says where it went"           '^#[0-9]+: graded major, so not polish — its own ticket \(P1\)' "$out"
want "a ticket of its own, P1, for the screen, a bug" "P1,screen:grade-screen,status:drafting,type:bug" \
  "$(jq -r '[.labels[].name] | sort | join(",")' "$FIX/store/issue-$mj.json" 2>/dev/null)"
want "titled for the screen, grade dropped" "Grade Screen: the masthead clips the primary verb off screen" "$(jq -r .title "$FIX/store/issue-$mj.json" 2>/dev/null)"
n0=$(cat "$FIX/store/next")
out=$(bash "$P" add grade-screen "Major · the masthead clips the primary verb off screen" 2>&1)
want "the same Major twice opens one ticket" "$n0" "$(cat "$FIX/store/next")"
want_in "and names it again"               "^#$mj: graded major" "$out"
out=$(bash "$P" add grade-screen "[Critical] the save loses the draft" 2>&1)
cr=$(printf '%s' "$out" | grep -oE '^#[0-9]+' | tr -d '#')
want_in "a Critical is P0"                 'P0' "$(jq -r '[.labels[].name] | join(",")' "$FIX/store/issue-$cr.json" 2>/dev/null)"
bash "$P" add grade-screen "Minor · the label wraps at 390" >/dev/null
want "a Minor still lands on the list"     "$((before + 1))" "$(lines "$gl")"

echo "--- a list that ships alone lends none ---"
for i in 1 2 3 4 5 6 7; do bash "$P" add full-screen "full item $i" >/dev/null; done
fl=$(bash "$P" for-screen full-screen)
rc=0; bash "$P" lends "$fl" 42 >/dev/null || rc=$?
want "7 free items: it lends"              "0" "$rc"
bash "$P" add full-screen "full item 8" >/dev/null
rc=0; out=$(bash "$P" lends "$fl" 42) || rc=$?
want "8 free items: full, it lends none"   "1" "$rc"
want_in "and says why"                     'ships alone: 8 free items, full at 8' "$out"
rc=0; bash "$P" lends "$fl" "$fl" >/dev/null || rc=$?
want "the list's own run takes its own"    "0" "$rc"
rc=0; COORDINATOR_POLISH_LIST_FULL=20 bash "$P" lends "$fl" 42 >/dev/null || rc=$?
want "full follows coordinator.polishListFull" "0" "$rc"
jq '.labels += [{name:"status:claimed"}]' "$FIX/store/issue-$gl.json" > "$FIX/store/c.json" && mv "$FIX/store/c.json" "$FIX/store/issue-$gl.json"
rc=0; out=$(bash "$P" lends "$gl" 42) || rc=$?
want "claimed by its own run: it lends none" "1" "$rc"
want_in "and says so"                      'its own run holds it' "$out"
rc=0; SWARM_GH="$BIN/gh-down" bash "$P" lends "$gl" 42 >/dev/null 2>&1 || rc=$?
want "unreadable is not 'lends'"           "2" "$rc"

exit "$FAILED"
