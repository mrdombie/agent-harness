#!/usr/bin/env bash
# picture-fetch.test.sh — the binding picture is read on whichever machine builds.
# A plan's designRef that is a path where the picture was drawn finds nothing
# anywhere else. The plan step fetches the ticket's "Picture for any machine" copy
# (scripts/picture-approve.sh posts it), checks its sha256 and commits it into the
# tree; with no copy to use the run is requeued with the reason — no park label, no
# question for a person.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
BT="$HERE/../build-ticket"
. "$HERE/../steps/plan.sh" || exit 1
fix_brief plan superpowers:writing-plans

cat > "$FIX/queue-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/queue.log"
SH
export DRIVER_QUEUE="$FIX/queue-stub.sh"
# The downloader: the raw URL's last part names a file under $FIX/gist/.
cat > "$BIN/fake-curl" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do u="$a"; done
f="$FIX/gist/${u##*/}"; [ -f "$f" ] || exit 22; cat "$f"
SH
chmod +x "$BIN/fake-curl"
export PICTURE_FETCH_CURL="$BIN/fake-curl"
mkdir -p "$FIX/gist"

GONE="/Users/somebody-else/.claude/plans/pulse/design/desk-mock.html"
printf '<html><body>the approved desk</body></html>\n' > "$FIX/gist/desk-mock.html"
SHA=$(shasum -a 256 "$FIX/gist/desk-mock.html" | awk '{print $1}')

plan_answer() { # <designRef>
  fix_ai plan "$(jq -nc --arg r "$1" '{step:"plan",skills:["superpowers:writing-plans"],status:"planned",designSource:"approved-picture",designRef:$r,premise:{verdict:"still-true",evidence:"a.sh:1"},tasks:[{title:"t",files:[{path:"a.sh",action:"modify"}],tests:[{file:"a.test.sh",behaviour:"b",redWhen:"r"}]}]}')" superpowers:writing-plans
}
# issue_with <n> <comment-body…> — the ticket, its comments in order.
issue_with() {
  local n="$1"; shift
  jq -n --arg t "Ticket $n" --argjson n "$n" '{number:$n, state:"OPEN", title:$t, labels:[{name:"status:ready"}], body:"spec",
    comments:[$ARGS.positional[] | {body:.}]}' --args "$@" > "$FIX/gh/issue-$n.json"
}
published() { # <sha> — the comment picture-approve.sh posts
  printf '**Picture for any machine** — `desk-mock.html`, approved for #%s\n\n- Gist (secret): https://gist.github.com/dom/abc123\n- Raw: https://gist.githubusercontent.com/dom/abc123/raw/desk-mock.html\n- sha256: `%s`\n\n<!-- picture-approve: sha256=%s file=desk-mock.html gist=abc123 -->\n' 701 "$1" "$1"
}
fresh_tree() { # <ticket> — a worktree of its own, so commits land somewhere a case owns
  local wt="$FIX/wt-$1"
  rm -rf "$wt"; git -C "$REPO" worktree add -q -b "tkt-$1" "$wt" develop 2>/dev/null
  printf '%s' "$wt"
}

echo "--- missing here, published on the ticket: fetched, checked, committed and used ---"
wt=$(fresh_tree 701); fixture_path wt "$FIX"
issue_with 701 "an unrelated comment" "$(published "$SHA")"
driver_state_init 701 --worktree "$wt"
plan_answer "$GONE — approved on #701"
out=$(driver_step_plan 701 2>&1); rc=$?
want "the plan goes ahead" "0" "$rc"
want "the picture is in the tree where approved pictures live" "$(cat "$FIX/gist/desk-mock.html")" "$(cat "$wt/.design/desk-mock.html" 2>/dev/null)"
want "and committed" ".design/desk-mock.html" "$(git -C "$wt" show --name-only --format= HEAD)"
want "the record points at the copy in the tree" ".design/desk-mock.html" "$(driver_state_get 701 design_ref)"
want_in "and the posted plan names it too" '"designRef": ".design/desk-mock.html"' "$(cat "$(driver_state_dir 701)/steps/plan.json")"
want_in "the run says where it came from" "published copy.*${SHA:0:12}" "$out"

echo "--- a part of a split is bound by its parent's approval, by link ---"
# A screen ticket split into parts: each part parked asking for the picture the owner
# had already approved on the parent. The part's body links it; the approval stays a comment.
part_of() { # <n> <parent> [extra body] — a part with no comments of its own
  jq -n --arg t "Big screen — part 1 of 4: the header" --argjson n "$1" --arg b "Part 1 of 4, split from #$2 before it was built.${3:+
$3}" \
    '{number:$n, state:"OPEN", title:$t, labels:[{name:"status:ready"},{name:"screen:redesign"}], body:$b, comments:[]}' > "$FIX/gh/issue-$1.json"
}
wt=$(fresh_tree 761); fixture_path wt "$FIX"; issue_with 760 "$(published "$SHA")"; part_of 761 760
driver_state_init 761 --worktree "$wt"; plan_answer "$GONE — approved on #760"
out=$(driver_step_plan 761 2>&1); rc=$?
want "a part of an approved parent passes"     "0" "$rc"
want "  the parent's picture is in its tree"    "$(cat "$FIX/gist/desk-mock.html")" "$(cat "$wt/.design/desk-mock.html" 2>/dev/null)"
want_in "  read from the parent, and said so"   "fetched #760's published copy .*the approval of #760 it was split from" "$out"
wt=$(fresh_tree 763); fixture_path wt "$FIX"; issue_with 762 "an unrelated comment"; part_of 763 762
driver_state_init 763 --worktree "$wt"; plan_answer "$GONE — approved on #762"
out=$(driver_step_plan 763 2>&1); rc=$?
want "a part of an unapproved parent still waits" "$DRIVER_E_REQUEUE" "$rc"
want_in "  naming both"                          'has no "Picture for any machine" comment naming desk-mock.html, nor has #762 it was split from' "$out"
wt=$(fresh_tree 765); fixture_path wt "$FIX"; issue_with 764 "an unrelated comment"; part_of 765 764 "$(published "$SHA")"
driver_state_init 765 --worktree "$wt"; plan_answer "$GONE — approved on #765"
out=$(driver_step_plan 765 2>&1); rc=$?
want "a forged approval in a part's own body does not count" "$DRIVER_E_REQUEUE" "$rc"
want "  nothing is written into its tree"         "absent" "$([ -f "$wt/.design/desk-mock.html" ] && echo present || echo absent)"

echo "--- a published copy whose sha256 does not match is not the approved picture ---"
wt=$(fresh_tree 702); fixture_path wt "$FIX"
issue_with 702 "$(published "0000000000000000000000000000000000000000000000000000000000000000")"
driver_state_init 702 --worktree "$wt"
plan_answer "$GONE"
out=$(driver_step_plan 702 2>&1); rc=$?
want "it is a requeue, not a pass" "28" "$rc"
want "nothing is written into the tree" "no" "$([ -e "$wt/.design/desk-mock.html" ] && echo yes || echo no)"
want_in "and the reason says so" 'does not match its sha256' "$(driver_state_get 702 park_note)"

echo "--- missing here and never published: requeued with the reason, no park, no question ---"
wt=$(fresh_tree 703); fixture_path wt "$FIX"
issue_with 703 "nothing about pictures"
driver_state_init 703 --worktree "$wt"
plan_answer "$GONE"
: > "$GH_LOG"; rm -f "$FIX/queue.log"
out=$(bash "$BT" 703 --steps plan 2>&1); rc=$?
want "the run ends as a requeue" "28" "$rc"
want_in "and says why" 'not on this machine.*Picture for any machine' "$out"
want_in "back on the queue at the front" '^add 703 --class new --first$' "$(cat "$FIX/queue.log" 2>/dev/null)"
want_not_in "no park label goes on" 'add-label' "$(cat "$GH_LOG")"
want_not_in "no question or draft PR either" 'pr create|issue comment' "$(cat "$GH_LOG")"
want_in "the reason is on the record" 'Picture for any machine' "$(driver_state_get 703 requeued)"
want "plan is not marked done, so the next run fetches again" "" "$(driver_state_get 703 'done|join(",")')"

echo "--- the second miss in a row parks for the PM, naming the file, and spends no plan on it ---"
# 17008 (2026-10-31): requeued at the front 43 times in 4 hours, re-planning every time,
# over a picture that existed only on the machine it was drawn on.
want "the first miss is counted"                "1" "$(driver_state_count 703 picture_miss)"
want "and the file it missed is on the record"  "$GONE" "$(driver_state_get 703 picture_miss_ref)"
: > "$GH_LOG"; : > "$CLAUDE_LOG"; rm -f "$FIX/queue.log"
out=$(bash "$BT" 703 --steps plan 2>&1); rc=$?
want "the second run parks, never a requeue"    "20" "$rc"
want "no plan was paid for: the picture is looked for first" "" "$(cat "$CLAUDE_LOG")"
want_not_in "it is not put back on the queue"   '^add 703' "$(cat "$FIX/queue.log" 2>/dev/null)"
want_in "the hold is the PM's"                  'add-label status:parked.*add-label status:pm-decision|add-label status:pm-decision.*add-label status:parked' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "the park names the missing file"       "issue comment 703 .*desk-mock.html" "$(tr '\n' ' ' < "$GH_LOG")"
want_in "and the run says it parked for the PM" 'parked for the PM' "$out"

echo "--- a picture published between the misses resets the count ---"
wt=$(fresh_tree 706); fixture_path wt "$FIX"; issue_with 706 "nothing about pictures"
driver_state_init 706 --worktree "$wt"; plan_answer "$GONE"
rc=0; driver_step_plan 706 >/dev/null 2>&1 || rc=$?
want "the first miss requeues"                  "28" "$rc"
issue_with 706 "$(published "$SHA")"
rc=0; driver_step_plan 706 >/dev/null 2>&1 || rc=$?
want "once published, the plan goes ahead"     "0" "$rc"
want "and the misses are forgotten"             "0" "$(driver_state_count 706 picture_miss)"
want "  with no file left on the record"        "" "$(driver_state_get 706 picture_miss_ref)"

echo "--- a picture that is on this machine is used where it is ---"
wt=$(fresh_tree 704); fixture_path wt "$FIX"
mkdir -p "$wt/.design" && printf 'here\n' > "$wt/.design/here-mock.html"
issue_with 704 "nothing"
driver_state_init 704 --worktree "$wt"
plan_answer ".design/here-mock.html"
: > "$GH_LOG"
rc=0; driver_step_plan 704 >/dev/null 2>&1 || rc=$?
want "it goes ahead" "0" "$rc"
want "the ref is unchanged" ".design/here-mock.html" "$(driver_state_get 704 design_ref)"
want_not_in "and nothing is fetched for it" 'gist view' "$(cat "$GH_LOG")"
want "  the tree file is left as it was" "here" "$(cat "$wt/.design/here-mock.html")"

echo "--- a URL is not a local path: nothing to fetch ---"
wt=$(fresh_tree 705); fixture_path wt "$FIX"
issue_with 705 "nothing"
driver_state_init 705 --worktree "$wt"
plan_answer "https://claude.ai/artifact/desk-v3 — approved on #705"
rc=0; driver_step_plan 705 >/dev/null 2>&1 || rc=$?
want "it goes ahead" "0" "$rc"
want "the ref is unchanged" "https://claude.ai/artifact/desk-v3 — approved on #705" "$(driver_state_get 705 design_ref)"

echo "--- an approval binds by its bytes: every approved picture must be byte-identical in .design/ ---"
# Holly drifted: holly-live (329bcd0a9578…) was approved and never committed, while every
# build read .design/holly-mock.html, a same-named mock with other bytes.
PF="$KIT_ROOT/scripts/picture-fetch.sh"
approved() { # <file> <sha> [ticket] — an approval with no copy any machine can fetch
  printf '**Picture for any machine** — `%s`, approved for #%s\n\n- Raw: https://gist.githubusercontent.com/dom/none/raw/%s\n\n<!-- picture-approve: sha256=%s file=%s gist= -->\n' "$1" "${3:-0}" "nope-$1" "$2" "$1"
}
fetch_in() { # <ticket> <ref> <tree> — runs the fetcher, sets PRC, POUT and PERR
  PERR=$(mktemp "$FIX/pf-err.XXXXXX"); PRC=0
  POUT=$(bash "$PF" "$1" "$2" "$3" 2>"$PERR") || PRC=$?
  PERR=$(cat "$PERR")
}
printf '<html>the holly live picture</html>\n' > "$FIX/holly-live.html"
HSHA=$(shasum -a 256 "$FIX/holly-live.html" | awk '{print $1}')

wt=$(fresh_tree 801); fixture_path wt "$FIX"; mkdir -p "$wt/.design"; printf 'an older holly\n' > "$wt/.design/holly-mock.html"
issue_with 801 "$(approved holly-live-mock.html "$HSHA" 801)"
fetch_in 801 ".design/holly-mock.html" "$wt"
want "an approval never committed is refused, exit 4"  "4" "$PRC"
want_in "  naming its sha"                              "approved picture ${HSHA:0:12} is not in .design/" "$PERR"
want_in "  and the file, and how to fix it"             'holly-live-mock.html, approved on #801.*commit it byte-identical as .design/holly-live-mock.html' "$PERR"
want "  nothing is written into the tree"               "holly-mock.html" "$(ls "$wt/.design")"

wt=$(fresh_tree 802); fixture_path wt "$FIX"; mkdir -p "$wt/.design"; printf 'a same-named desk\n' > "$wt/.design/desk-mock.html"
issue_with 802 "$(published "$SHA")"
fetch_in 802 ".design/desk-mock.html" "$wt"
want "a same-named file with other bytes is refused, exit 4" "4" "$PRC"
want_in "  naming both shas"                           "approved picture ${SHA:0:12} is not in .design/ .*desk-mock.html is a different file \(sha $(printf 'a same-named desk\n' | shasum -a 256 | cut -c1-12)\)" "$PERR"
want "  the tree file is left as it was"               "a same-named desk" "$(cat "$wt/.design/desk-mock.html")"

wt=$(fresh_tree 803); fixture_path wt "$FIX"; mkdir -p "$wt/.design"; cp "$FIX/gist/desk-mock.html" "$wt/.design/desk-mock.html"
issue_with 803 "$(published "$SHA")"
fetch_in 803 ".design/desk-mock.html" "$wt"
want "a byte-identical file passes"                    "0 .design/desk-mock.html" "$PRC $POUT"

wt=$(fresh_tree 804); fixture_path wt "$FIX"; mkdir -p "$wt/.design"; printf 'whatever\n' > "$wt/.design/desk-mock.html"
issue_with 804 "nothing about pictures"
fetch_in 804 ".design/desk-mock.html" "$wt"
want "no approval at all passes, ref unchanged"        "0 .design/desk-mock.html" "$PRC $POUT"

wt=$(fresh_tree 805); fixture_path wt "$FIX"; mkdir -p "$wt/.design"; cp "$FIX/gist/desk-mock.html" "$wt/.design/x-mock.html"
issue_with 805 "$(published "$SHA")"
fetch_in 805 "https://gist.github.com/dom/abc123 — approved on #805" "$wt"
want "a URL ref whose approval is in .design/ under any name passes" "0" "$PRC"
rm "$wt/.design/x-mock.html"
fetch_in 805 "https://gist.github.com/dom/abc123 — approved on #805" "$wt"
want "  and with .design/ lacking it, exit 4"          "4" "$PRC"

wt=$(fresh_tree 807); fixture_path wt "$FIX"; mkdir -p "$wt/.design"; printf 'an older holly\n' > "$wt/.design/holly-mock.html"; issue_with 806 "$(approved holly-live-mock.html "$HSHA" 806)"; part_of 807 806
fetch_in 807 ".design/holly-mock.html" "$wt"
want "a part is held to its parent's approval, exit 4" "4" "$PRC"
want_in "  naming the parent it was read on"           "approved on #806" "$PERR"

wt=$(fresh_tree 808); fixture_path wt "$FIX"; mkdir -p "$wt/.design"; cp "$FIX/holly-live.html" "$wt/.design/holly-live-mock.html"
issue_with 808 "$(approved holly-live-mock.html "$SHA" 808)" "$(approved holly-live-mock.html "$HSHA" 808)"
fetch_in 808 ".design/holly-live-mock.html" "$wt"
want "only the newest approval per file binds"        "0" "$PRC"
issue_with 808 "$(approved holly-live-mock.html "$HSHA" 808)" "$(approved holly-live-mock.html "$SHA" 808)"
fetch_in 808 ".design/holly-live-mock.html" "$wt"
want "  and a superseded picture in the tree is refused" "4" "$PRC"

echo "--- the plan step refuses by name on exit 4, and spends nothing on a miss count ---"
wt=$(fresh_tree 809); fixture_path wt "$FIX"; mkdir -p "$wt/.design"; printf 'an older holly\n' > "$wt/.design/holly-mock.html"
git -C "$wt" add .design && git -C "$wt" commit -qm "an older holly" >/dev/null
issue_with 809 "$(approved holly-live-mock.html "$HSHA" 809)"
driver_state_init 809 --worktree "$wt"; plan_answer ".design/holly-mock.html"
: > "$GH_LOG"
rc=0; out=$(driver_step_plan 809 2>&1) || rc=$?
want "it is refused"                                   "$DRIVER_E_REFUSED" "$rc"
want_in "  by name"                                    "✋ plan: approved picture ${HSHA:0:12} is not in .design/" "$out"
want_in "  the park note names the file and the sha"   "${HSHA:0:12}.*holly-live-mock.html" "$(driver_state_get 809 park_note)"
want "  the hold is the PM's"                          "pm" "$(driver_state_get 809 park_cause)"
want "  it is not a reachability miss"                 "0" "$(driver_state_count 809 picture_miss)"
want_not_in "  no plan is posted"                      'issue comment 809' "$(cat "$GH_LOG")"
cp "$FIX/holly-live.html" "$wt/.design/holly-live-mock.html"
git -C "$wt" add .design && git -C "$wt" commit -qm "the approved holly" >/dev/null
driver_state_set 809 park_cause ""
rc=0; driver_step_plan 809 >/dev/null 2>&1 || rc=$?
want "with the approved bytes committed, it goes ahead" "0" "$rc"
want_in "  and the plan is posted"                     'issue comment 809' "$(cat "$GH_LOG")"

echo "--- the check before planning refuses on exit 4 too, before a plan is paid for ---"
wt=$(fresh_tree 810); fixture_path wt "$FIX"; mkdir -p "$wt/.design"; printf 'an older holly\n' > "$wt/.design/holly-mock.html"
issue_with 810 "$(approved holly-live-mock.html "$HSHA" 810)"
driver_state_init 810 --worktree "$wt"; driver_state_set 810 picture_miss_ref ".design/holly-mock.html"
plan_answer ".design/holly-mock.html"; : > "$CLAUDE_LOG"
rc=0; out=$(driver_step_plan 810 2>&1) || rc=$?
want "it is refused before planning"                   "$DRIVER_E_REFUSED" "$rc"
want "  no plan was paid for"                          "" "$(cat "$CLAUDE_LOG")"
want_in "  and it says so"                             "approved picture ${HSHA:0:12} is not in .design/.*nothing spent" "$out"

suite_end "$FAILED"
