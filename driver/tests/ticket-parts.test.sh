#!/usr/bin/env bash
# ticket-parts.test.sh — what a ticket names as its own is held to the branch with no model:
# a named file missing, or an item no passing feature delivers, goes back once named, then parks.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/self-check.sh" || exit 1
. "$HERE/../feature-list.sh" || exit 1

body() { # <ticket> <body text>
  jq -n --arg b "$2" --argjson n "$1" '{number: $n, title: "t", body: $b, labels: []}' > "$FIX/gh/issue-$1.json"
}

echo "--- the parser: only backticked paths under the change or acceptance, only numbered items ---"
cat > "$FIX/b.md" <<'MD'
Context: `src/context/Mentioned.tsx` is where it started.

## The change
1. Add `src/new/Card.tsx` and mount it in `src/Page.tsx`.
2. Read `src/ref/Old.tsx` (read-only) for the old shape.
- a bullet with `src/bullet/Named.ts` still names a path
- run `npx vitest run src/x` and `scripts/no-ext`, see `docs/*.md`

## Acceptance criteria
- [ ] the card shows
- [x] the page mounts it

## Out of scope
`src/out/Scope.tsx`
MD
paths=$(ticket_parts_paths "$FIX/b.md" | paste -sd' ' -)
want "the change's paths, a read-only line skipped" "src/new/Card.tsx src/Page.tsx src/bullet/Named.ts" "$paths"
items=$(ticket_parts_items "$FIX/b.md" | cut -f1 | paste -sd' ' -)
want "numbered change items and acceptance boxes" "C1 C2 A1 A2" "$items"
printf '**This part:** F1: x\n\n**Files:** src/a/One.tsx, src/b/*.tsx and more, src/[id]/Two.ts\n' > "$FIX/p.md"
want "a split part's Files line" "src/a/One.tsx src/[id]/Two.ts" "$(ticket_parts_paths "$FIX/p.md" | paste -sd' ' -)"

echo "--- a branch missing a file the ticket names goes back to build with that path named ---"
mkdir -p "$REPO/src"; : > "$REPO/src/Page.tsx"; git -C "$REPO" add -A; git -C "$REPO" commit -qm page
driver_state_init 301 --worktree "$REPO"
body 301 "## The change
1. Add \`src/new/Card.tsx\` and mount it in \`src/Page.tsx\`."
out=$(driver_step_self_check 301 2>&1); rc=$?
want "it goes back" "$DRIVER_E_REWORK" "$rc"
want_in "naming the path" 'src/new/Card.tsx' "$out"
want_not_in "and not the one on the branch" 'names `src/Page.tsx`' "$out"
want_in "the finding names it for fix" 'src/new/Card.tsx' "$(cat "$(driver_state_dir 301)/steps/self-check.findings.json")"
want_not_in "before any gate is paid for" 'lint ok' "$out"
out=$(driver_step_self_check 301 2>&1); rc=$?
want "a second miss parks" "$DRIVER_E_REFUSED" "$rc"
want_in "with the path named" 'src/new/Card.tsx' "$(driver_state_get 301 park_note)"

echo "--- the file on the branch passes, and a split part's file under its parent's number is its own ---"
mkdir -p "$REPO/src/new" "$REPO/docs/301"; : > "$REPO/src/new/Card.tsx"; : > "$REPO/docs/301/plan.json"
git -C "$REPO" add -A; git -C "$REPO" commit -qm card
body 301 "**Files:** src/new/Card.tsx, docs/300/plan.json
<!-- harness:feature-item parent=300 id=F1 test=src/a.test.ts -->"
driver_state_init 302 --worktree "$REPO"
cp "$FIX/gh/issue-301.json" "$FIX/gh/issue-302.json"
out=$(driver_step_self_check 301 2>&1); rc=$?
want "delivered, it passes" "0" "$rc"
want_in "and says so" 'every file and item #301 names' "$out"
out=$(driver_step_self_check 302 2>&1); rc=$?
want "another number's path is not this part's" "$DRIVER_E_REWORK" "$rc"

echo "--- a file the diff deletes counts as touched ---"
git -C "$REPO" checkout -q -b tkt-303
git -C "$REPO" rm -q src/Page.tsx; git -C "$REPO" commit -qm gone
driver_state_init 303 --worktree "$REPO"
body 303 "## The change
1. Delete \`src/Page.tsx\`."
rc=0; driver_step_self_check 303 >/dev/null 2>&1 || rc=$?
want "a deletion delivers it" "0" "$rc"
git -C "$REPO" checkout -q develop

echo "--- an acceptance item with no passing feature goes back with the item named ---"
driver_state_init 304 --worktree "$REPO"
body 304 "## Acceptance criteria
- [ ] the card shows
- [ ] the empty card says how to fill it"
list="$(driver_state_dir 304)/features.json"; mkdir -p "$(dirname "$list")"
jq -n '{ticket: 304, items: [
  {id:"F1", behaviour:"b", steps:["s"], test:"src/a.test.ts", covers:["A1"], passes:true, part:null},
  {id:"F2", behaviour:"c", steps:["s"], test:"src/b.test.ts", covers:["A2"], passes:false, part:null}], outside: []}' > "$list"
out=$(driver_step_self_check 304 2>&1); rc=$?
want "a failing feature sends it back" "$DRIVER_E_REWORK" "$rc"
want_in "naming the item and its feature" 'A2 .*maps to F2, which does not pass' "$out"
want_not_in "and not the item that passes" 'A1 \(' "$out"
driver_state_init 305 --worktree "$REPO"; cp "$FIX/gh/issue-304.json" "$FIX/gh/issue-305.json"
mkdir -p "$(driver_state_dir 305)"
jq '.items |= map(select(.id == "F1"))' "$list" > "$(driver_state_dir 305)/features.json"
out=$(driver_step_self_check 305 2>&1); rc=$?
want "an item no feature covers sends it back" "$DRIVER_E_REWORK" "$rc"
want_in "named" 'A2 .*maps to no feature list item' "$out"
jq '.outside = [{item:"A2", why:"a shot in the pull request"}]' "$(driver_state_dir 305)/features.json" > "$FIX/o" && mv "$FIX/o" "$(driver_state_dir 305)/features.json"
driver_state_init 306 --worktree "$REPO"; cp "$FIX/gh/issue-304.json" "$FIX/gh/issue-306.json"
mkdir -p "$(driver_state_dir 306)"; cp "$(driver_state_dir 305)/features.json" "$(driver_state_dir 306)/features.json"
rc=0; driver_step_self_check 306 >/dev/null 2>&1 || rc=$?
want "an item named outside the list with why passes" "0" "$rc"
jq '.items |= map(.passes = true)' "$list" > "$FIX/o" && mv "$FIX/o" "$list"
driver_state_init 307 --worktree "$REPO"; cp "$FIX/gh/issue-304.json" "$FIX/gh/issue-307.json"
mkdir -p "$(driver_state_dir 307)"; cp "$list" "$(driver_state_dir 307)/features.json"
rc=0; driver_step_self_check 307 >/dev/null 2>&1 || rc=$?
want "every item delivered by a passing feature passes" "0" "$rc"
jq '.items |= map(del(.covers))' "$list" > "$(driver_state_dir 307)/features.json"
jq '.items |= map(.passes = false)' "$(driver_state_dir 307)/features.json" > "$FIX/o" && mv "$FIX/o" "$(driver_state_dir 307)/features.json"
rc=0; driver_step_self_check 307 >/dev/null 2>&1 || rc=$?
want "a list from before items were mapped is not read by them" "0" "$rc"

echo "--- the plan maps every item, or is sent back ---"
printf '## The change\n1. one\n\n## Acceptance criteria\n- [ ] two\n' > "$FIX/pb.md"
jq -n '{features: [{id:"F1", behaviour:"b", steps:["s"], test:"t", passes:false, covers:["C1"]}]}' > "$FIX/plan.json"
out=$(feature_list_uncovered "$FIX/plan.json" "$FIX/pb.md"); rc=$?
want "an unmapped item is a problem" "1" "$rc"
want_in "naming it" 'A1 \(“two”\) is in no item' "$out"
jq '.features[0].covers = ["C1","A1","A9"]' "$FIX/plan.json" > "$FIX/p2" && mv "$FIX/p2" "$FIX/plan.json"
out=$(feature_list_uncovered "$FIX/plan.json" "$FIX/pb.md"); rc=$?
want_in "an id the ticket lacks is a problem" 'F1 covers A9' "$out"
jq '.features[0].covers = ["C1"] | .outside = [{item:"A1", why:"w"}]' "$FIX/plan.json" > "$FIX/p2" && mv "$FIX/p2" "$FIX/plan.json"
rc=0; feature_list_uncovered "$FIX/plan.json" "$FIX/pb.md" >/dev/null || rc=$?
want "mapped or outside, it passes" "0" "$rc"
. "$HERE/../steps/plan.sh" || exit 1
jq '.features[0].covers = ["C1"] | del(.outside)' "$FIX/plan.json" > "$FIX/p3.json"
want_in "the plan step sends an unmapped item back" 'A1 \(“two”\) is in no item' \
  "$(_driver_plan_list_problems 401 "$FIX/p3.json" "" "a ticket" "$(cat "$FIX/pb.md")")"
jq '.features[0] + {covers:["C1"]} | {items: [.]} ' "$FIX/plan.json" > "$FIX/old.json"
jq '.items[0].covers = ["A1"]' "$FIX/old.json" > "$FIX/new.json"
rc=0; feature_list_guard "$FIX/old.json" "$FIX/new.json" >/dev/null || rc=$?
want "the items a feature covers are fixed once listed" "3" "$rc"

suite_end "$FAILED"
