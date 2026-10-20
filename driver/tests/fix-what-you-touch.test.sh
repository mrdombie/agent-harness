#!/usr/bin/env bash
# fix-what-you-touch.test.sh — a change that touches a screen takes on what is already
# known to be wrong with it. Every free item on that screen's polish list becomes a
# finding of the review at its own grade (none named: Minor); Critical, Major and Minor
# block, so the review cannot pass beside one; an item the builder fixed and recorded
# (polish-list.sh take) is cleared; a repair takes none on.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/review.sh" || exit 1

wt="$FIX/wt601"
git -C "$REPO" worktree add -q "$wt" -b "tkt-601/work" develop
printf 'x\n' > "$wt/page.tsx"; git -C "$wt" add page.tsx; git -C "$wt" commit -qm "feat: the voices page"
driver_state_init 601 --worktree "$wt" --branch "tkt-601/work"

# What the screen's lists hold, stood in for: grade \t list \t item.
cat > "$FIX/sf" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/sf.calls"
printf 'major\t77\t[Major] nine narration lines on the voices page\nminor\t77\tthe lock icon sits 2px low\n'
SH
cat > "$FIX/pl" <<'SH'
#!/usr/bin/env bash
[ "$1" = taken ] && [ -f "$FIX/taken" ] && cat "$FIX/taken"; exit 0
SH
chmod +x "$FIX/sf" "$FIX/pl"
export DRIVER_SCREEN_FINDINGS="$FIX/sf" DRIVER_POLISH_LIST="$FIX/pl"
f="$FIX/review.json"

echo "--- a SHIP on a screen with open polish is not a pass ---"
echo '{"verdict":"SHIP","findings":[]}' > "$f"
_driver_review_touched 601 "$f" "$wt" develop >/dev/null 2>&1
want "the verdict is BLOCKED"                 "BLOCKED" "$(jq -r .verdict "$f")"
want "both items are findings"                "2" "$(jq '.findings | length' "$f")"
want "each at the grade it carries"           "major minor" "$(jq -r '[.findings[].grade] | join(" ")' "$f")"
want "and they block"                         "2" "$(jq -r "[.findings[] | $(driver_blocking_select)] | length" "$f")"
want_in "the fix names how to record it"      'take 77 601' "$(jq -r '.findings[1].fix' "$f")"
want_in "the screens are read off the files the change touches" 'polish 601 .*touched-files.txt' "$(cat "$FIX/sf.calls")"
want "the touched files are recorded"         "page.tsx" "$(cat "$(driver_state_dir 601)/steps/touched-files.txt")"

echo "--- an item the builder fixed and recorded is cleared ---"
printf '77\tthe lock icon sits 2px low\n77\t[Major] nine narration lines on the voices page\n' > "$FIX/taken"
echo '{"verdict":"SHIP","findings":[]}' > "$f"
_driver_review_touched 601 "$f" "$wt" develop >/dev/null 2>&1
want "nothing is added"                       "0" "$(jq '.findings | length' "$f")"
want "and the SHIP stands"                    "SHIP" "$(jq -r .verdict "$f")"
rm -f "$FIX/taken"

echo "--- a repair is judged on its own change ---"
driver_state_set 601 mode repair
echo '{"verdict":"SHIP","findings":[]}' > "$f"
_driver_review_touched 601 "$f" "$wt" develop >/dev/null 2>&1
want "a repair takes nothing on"              "0" "$(jq '.findings | length' "$f")"
driver_state_set 601 mode new

echo "--- the review step reads the verdict after it ---"
grep -q '_driver_review_touched "$t" "$ans_file"' "$HERE/../steps/review.sh" \
  && grep -A1 '_driver_review_touched "$t" "$ans_file"' "$HERE/../steps/review.sh" | grep -q 'verdict=' \
  && ok "the step calls it and re-reads the verdict" || bad "the review step does not call it, or acts on the verdict it had before"

exit $FAILED
