#!/usr/bin/env bash
# picture-fetch.test.sh — the binding picture is read on whichever machine builds.
# A plan's designRef that is a path where the picture was drawn finds nothing
# anywhere else. The plan step fetches the ticket's "Picture for any machine" copy
# (scripts/picture-approve.sh posts it), checks its sha256 and commits it into the
# tree; with no copy to use the run is requeued with the reason — no park label, no
# question for a person.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
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
wt=$(fresh_tree 701)
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

echo "--- a published copy whose sha256 does not match is not the approved picture ---"
wt=$(fresh_tree 702)
issue_with 702 "$(published "0000000000000000000000000000000000000000000000000000000000000000")"
driver_state_init 702 --worktree "$wt"
plan_answer "$GONE"
out=$(driver_step_plan 702 2>&1); rc=$?
want "it is a requeue, not a pass" "28" "$rc"
want "nothing is written into the tree" "no" "$([ -e "$wt/.design/desk-mock.html" ] && echo yes || echo no)"
want_in "and the reason says so" 'does not match its sha256' "$(driver_state_get 702 park_note)"

echo "--- missing here and never published: requeued with the reason, no park, no question ---"
wt=$(fresh_tree 703)
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

echo "--- a picture that is on this machine is used where it is ---"
wt=$(fresh_tree 704)
mkdir -p "$wt/.design" && printf 'here\n' > "$wt/.design/here-mock.html"
issue_with 704 "nothing"
driver_state_init 704 --worktree "$wt"
plan_answer ".design/here-mock.html"
: > "$GH_LOG"
rc=0; driver_step_plan 704 >/dev/null 2>&1 || rc=$?
want "it goes ahead" "0" "$rc"
want "the ref is unchanged" ".design/here-mock.html" "$(driver_state_get 704 design_ref)"
want_not_in "and no comment was read for it" 'issue view 704 .*comments' "$(cat "$GH_LOG")"

echo "--- a URL is not a local path: nothing to fetch ---"
wt=$(fresh_tree 705)
issue_with 705 "nothing"
driver_state_init 705 --worktree "$wt"
plan_answer "https://claude.ai/artifact/desk-v3 — approved on #705"
rc=0; driver_step_plan 705 >/dev/null 2>&1 || rc=$?
want "it goes ahead" "0" "$rc"
want "the ref is unchanged" "https://claude.ai/artifact/desk-v3 — approved on #705" "$(driver_state_get 705 design_ref)"

exit $FAILED
