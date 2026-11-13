#!/usr/bin/env bash
# feature-close.test.sh — an item of a split feature passes only when its part has merged
# with its test steps on the integration branch, and the feature is done only when every
# item passes and its clean-up part has merged.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../driver/feature-list.sh" || exit 1
FC="$HERE/feature-close.sh"
# A file not on the trunk answers as GitHub does: 404 on stderr, exit 1. Anything else unknown fails plainly.
mv "$BIN/gh" "$BIN/gh-base"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in "api repos/acme/widgets/contents/"*)
  [ -f "$FIX/gh/api-$(printf '%s' "$2" | tr '/?&=' '____').json" ] || { printf '%s\n' "$*" >> "$GH_LOG"; echo 'gh: Not Found (HTTP 404)' >&2; exit 1; } ;;
esac
exec "$FIX/bin/gh-base" "$@"
SH
chmod +x "$BIN/gh"

list_json() { # <F2 passes> — the list as the split posted it: F1 on #901, F2 on #902, clean-up #903
  jq -nc --argjson p2 "${1:-false}" '{ticket:900, items:[
    {id:"F1", behaviour:"saves a filter", steps:["save it","it is listed"], test:"src/a.test.ts", needsFoundation:false, passes:false, part:901},
    {id:"F2", behaviour:"says how to save one", steps:["open it empty","it says how"], test:"src/b.test.ts", needsFoundation:false, passes:$p2, part:902}],
    foundation:null, cleanup:{part:903}}'
}
comment_of() { printf '%s' "$1" > "$FIX/l.json"; feature_list_comment "$FIX/l.json"; }
parent() { # <stateReason> <list comment bodies…> — #900, closed as split, carrying its lists
  local r="$1"; shift
  jq -n --arg r "$r" '{number:900, state:"CLOSED", stateReason:$r, title:"Saved filters",
    comments:([{body:"**Split by behaviour** into #901 #902 #903 — one part per item."}] + [$ARGS.positional[] | {body:.}])}' --args "$@" > "$FIX/gh/issue-900.json"
}
part() { jq -n --argjson n "$1" --arg s "$2" --arg r "${3:-}" '{number:$n, state:$s, stateReason:(if $r == "" then null else $r end), title:"part"}' > "$FIX/gh/issue-$1.json"; }
on_trunk() { printf '{"path":"%s"}\n' "$1" > "$FIX/gh/api-repos_acme_widgets_contents_$(printf '%s' "$1" | tr '/?&=' '____')_ref_develop.json"; }
run() { : > "$GH_LOG"; bash "$FC" "$@" 2>&1; }
posted() { grep -c "^issue comment 900" "$GH_LOG"; }

echo "--- an item passes once its part merged with its steps on the trunk ---"
parent NOT_PLANNED "$(comment_of "$(list_json)")"
part 901 CLOSED COMPLETED; on_trunk src/a.test.ts
part 902 OPEN; part 903 OPEN
out=$(run 900); rc=$?
want "it reads"                                        "0" "$rc"
want_in "F1 passes"                                    'F1 passes' "$out"
want_in "F2 is still failing, and why"                 'F2 failing: #902 is still open' "$out"
want "the parent's list is posted again, F1 ticked"   "1" "$(posted)"
want_in "  with F1 passing and F2 not"                 'F1\*\* saves a filter — #901 \(passes\).*F2\*\* says how to save one — #902 \(failing\)' "$(tr '\n' ' ' < "$GH_LOG")"
want_not_in "the feature is not done"                  'state_reason=completed' "$(cat "$GH_LOG")"

echo "--- nothing changed: nothing posted ---"
parent NOT_PLANNED "$(comment_of "$(list_json)")" "$(comment_of "$(list_json | jq -c '.items[0].passes = true')")"
out=$(run 900)
want "no new comment when the list reads the same"    "0" "$(posted)"

echo "--- a part merged without its steps on the trunk does not pass ---"
part 902 CLOSED COMPLETED
out=$(run 900)
want_in "F2 does not pass"                             'F2 failing: #902 merged, and its steps.s test src/b.test.ts is not on develop' "$out"
want_in "  the parent is told"                         'issue comment 900 .*F2 does not pass:.*src/b.test.ts.*is not on .develop' "$(tr '\n' ' ' < "$GH_LOG")"

echo "--- a part closed without merging does not pass ---"
part 902 CLOSED NOT_PLANNED; on_trunk src/b.test.ts
want_in "closed as not planned: failing"               'F2 failing: #902 closed without merging' "$(run 900)"

echo "--- every item passes: the clean-up part still has to merge ---"
part 902 CLOSED COMPLETED
out=$(run 900)
want_in "both pass"                                    'F2 passes' "$out"
want_in "  waiting on the clean-up"                    'every item passes; waiting for its clean-up part #903' "$out"
want_not_in "  not done yet"                           'state_reason=completed' "$(cat "$GH_LOG")"

echo "--- the clean-up merged: the feature is done ---"
part 903 CLOSED COMPLETED
out=$(run 900)
want_in "done"                                         'done: #900' "$out"
want_in "  the parent says so"                         'issue comment 900 .*\*\*Feature done:\*\*' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "  and is closed as completed"                 'api -X PATCH repos/acme/widgets/issues/900 -f state=closed -f state_reason=completed' "$(cat "$GH_LOG")"
parent COMPLETED "$(comment_of "$(list_json true | jq -c '.items[0].passes = true')")"
out=$(run 900)
want "a feature already done is left alone"           "0" "$(grep -c 'issue comment\|PATCH' "$GH_LOG")"

echo "--- no clean-up part: done once every item passes ---"
parent NOT_PLANNED "$(comment_of "$(list_json | jq -c '.cleanup = null')")"
want_in "done with no clean-up to wait for"           'done: #900' "$(run 900)"

echo "--- a list that built whole has no parts: left alone, its passes not rewound ---"
parent OPEN "$(comment_of "$(list_json | jq -c '.items |= map(.part = null) | .cleanup = null')")" "$(comment_of "$(list_json | jq -c '.items |= map(.part = null | .passes = true) | .cleanup = null')")"
out=$(run 900)
want_in "it says why"                                 'built whole: #900' "$out"
want "nothing posted, nothing closed"                 "0" "$(grep -c 'issue comment\|PATCH' "$GH_LOG")"

echo "--- an edited list is refused: the first list stands ---"
part 902 OPEN
parent NOT_PLANNED "$(comment_of "$(list_json)")" "$(comment_of "$(list_json | jq -c '.items[1].steps = ["anything"] | .items[1].passes = true')")"
out=$(run 900)
want_in "the edit is named"                            'F2 was edited' "$out"
want_in "  the parent is told"                         'issue comment 900 .*edited' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "  and F2 is read from its part, not the edit" 'F2 failing: #902 is still open' "$out"

echo "--- a failed read decides nothing ---"
rm -f "$FIX/gh/issue-900.json"
out=$(run 900); rc=$?
want "unread: exit 1"                                  "1" "$rc"
want "  and nothing written"                           "0" "$(grep -c 'issue comment\|PATCH' "$GH_LOG")"
parent NOT_PLANNED "$(comment_of "$(list_json)")"; rm -f "$FIX/gh/issue-902.json"
out=$(run 900); rc=$?
want "a part unread: exit 1, nothing written"          "1 0" "$rc $(grep -c 'issue comment\|PATCH' "$GH_LOG")"
part 902 OPEN

echo "--- a dry run writes nothing ---"
part 902 CLOSED COMPLETED; part 903 CLOSED COMPLETED
out=$(run 900 --dry-run)
want_in "it says what it would do"                    'done: #900' "$out"
want "  and writes nothing"                            "0" "$(grep -c 'issue comment\|PATCH' "$GH_LOG")"

echo "--- the coordinator's sweep finds features from their parts ---"
jq -n '[{number:901, body:"Part 2 of 4, split from #900.\n<!-- harness:feature-item parent=900 id=F1 test=src/a.test.ts -->"},
        {number:951, body:"Part 1 of 2, split from #950.\n<!-- harness:feature-item parent=950 id=F1 test=x.test.ts -->"},
        {number:902, body:"Part 3 of 4, split from #900.\n<!-- harness:feature-item parent=900 id=F2 test=src/b.test.ts -->"},
        {number:777, body:"an ordinary ticket"}]' > "$FIX/gh/issue-list.json"
out=$(run sweep --dry-run)
want "each feature is checked once"                    "1 1" "$(grep -c '^issue view 900 ' "$GH_LOG") $(grep -c '^issue view 950 ' "$GH_LOG")"
want_in "  found by the words every item part carries" 'issue list .*--search "of the feature list of" in:body' "$(cat "$GH_LOG")"
want_not_in "  an ordinary ticket is not a feature"    'issue view 777' "$(cat "$GH_LOG")"

suite_end "$FAILED"
