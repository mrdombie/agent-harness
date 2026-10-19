#!/usr/bin/env bash
# polish-list.test.sh — a Minor finding lands on its screen's one open list, never
# a ticket of its own: the list is found by its labels or opened once, an item is
# appended under "## Items" once however often it is added, and the unticked
# items are what a builder and the coordinator read.
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
    want=$(printf '%s\n' "${labels[@]}" | jq -R . | jq -sc .)
    for f in "$S"/issue-*.json; do [ -f "$f" ] && cat "$f"; done \
      | jq -s --argjson w "$want" '[.[] | select(.state == "OPEN") | select([.labels[].name] as $l | all($w[]; . as $x | $l | index($x))) | {number}]' ;;
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

echo "--- items and count read only the unticked ones ---"
bash "$P" add inbox-thread "Empty state icon is off-kit" >/dev/null
out=$(bash "$P" tick 900 "Send button label wraps on a phone")
want_in "tick marks it done"               'ticked Send button' "$out"
want "items prints what is left"           "The row gap is 12px, the kit says 16px|Empty state icon is off-kit" "$(bash "$P" items 900 | tr '\n' '|' | sed 's/|$//')"
want "count agrees"                        "2" "$(bash "$P" count 900)"
want "a ticked item is still never added again" "#900 already lists: Send button label wraps on a phone" "$(bash "$P" add inbox-thread "Send button label wraps on a phone")"
bash "$P" tick 900 "Not on the list" 2>/dev/null; want "ticking an item not there fails" "1" "$?"
want "count reads a body from stdin"       "1" "$(printf '## Items\n- [ ] a\n- [x] b\n\n## Notes\n- [ ] not an item\n' | bash "$P" count -)"
want "an empty list counts 0"              "0" "$(printf 'no items yet\n' | bash "$P" count -)"

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
want "nothing was opened"                  "902" "$(cat "$FIX/store/next")"
want "a bad slug is refused"               "2" "$(bash "$P" add "Inbox Thread" x >/dev/null 2>&1; echo $?)"

exit "$FAILED"
