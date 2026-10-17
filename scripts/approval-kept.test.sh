#!/usr/bin/env bash
# approval-kept.test.sh — an approval survives an update that only brought the
# trunk in and left the PR's own screens alone, and nothing else: a commit of its
# own, a merge resolution that edits one of its screens, a rewritten history or a
# comparison that cannot be read all void it. The approved head is read back
# from the marker a sign-off writes.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
K="$HERE/approval-kept.sh"
jq '.design = {surfacePaths: ["apps/web/**", ":(exclude)**/*.test.ts"]}' "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"

cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
q=""; prev=""; ep=""; skip=0
for a in "${@:2}"; do
  case "$prev" in -q|--jq) q="$a" ;; esac
  prev="$a"
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in -X|-f|-F|-H|-q|--jq|--method|--input) skip=1 ;; -*) ;; *) [ -n "$ep" ] || ep="$a" ;; esac
done
[ "$1" = api ] || exit 0
f="$FIX/gh/api-$(printf '%s' "$ep" | tr '/?&=' '____').json"
if [ ! -f "$f" ]; then
  case "$ep" in */contents/*) [ -f "$FIX/gh/contents-404" ] && cat "$FIX/gh/contents-404" >&2 ;; esac
  exit 1
fi
if [ -n "$q" ]; then jq -r "$q" < "$f"; else cat "$f"; fi
GH
chmod +x "$BIN/gh"

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
H=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
# compare <base> <head> <files-csv> [commits-csv] [extra-jq] — commits: 2 a merge of
# the PR's own, 1 a commit of its own, t a trunk commit a merge brought in. The
# PR's own commits are added to its develop...<head> diff, as GitHub lists them.
compare() {
  local f="$FIX/gh/api-repos_acme_widgets_compare_$1...$2.json" own="$FIX/gh/api-repos_acme_widgets_compare_develop...$2.json"
  jq -n --arg f "$3" --arg c "${4:-}" \
    '{status:"ahead", files:($f | split(",") | map(select(length > 0) | {filename:.})),
      commits:($c | split(",") | map(select(length > 0)) | to_entries
               | map(.key as $i | .value as $v
                 | if $v == "t" then {sha:"t\($i)", parents:[{sha:"p"}]}
                   else {sha:"o\($i)", parents:[range($v | tonumber) | {sha:"p"}]} end))}
     | '"${5:-.}" > "$f"
  if [ "$1" != develop ] && [ -f "$own" ]; then
    jq --slurpfile s "$f" '.commits += [$s[0].commits[] | select(.sha | startswith("o"))]' "$own" > "$own.n" && mv "$own.n" "$own"
  fi
}
# blob <sha> <path> <blob-sha> — what the contents API answers for that file there
blob() { jq -n --arg b "$3" '{sha:$b}' > "$FIX/gh/api-$(printf '%s' "repos/acme/widgets/contents/$2?ref=$1" | tr '/?&=' '____').json"; }
fresh() { rm -f "$FIX"/gh/api-repos_* "$FIX/gh/contents-404"; : > "$GH_LOG"; }
check() { bash "$K" check "$@" 2>&1; }

echo "--- a develop merge that brings other tickets' screens only: the approval is kept ---"
fresh
compare develop "$H" "apps/web/mine.tsx,lib/api.ts"
compare "$A" "$H" "apps/web/theirs.tsx,apps/web/other.tsx,lib/server.ts" "t,t,2"
out=$(check "$A" "$H"); rc=$?
want "kept, though the trunk commits it brought are single-parent" "0" "$rc"
want_in "the sentence names what was kept"   'approval kept: develop-only update, screens unchanged' "$out"
want_in "and both heads, in full"            "approved $A, now $H" "$out"

echo "--- a merge resolution that edits one of its own screens: the approval goes ---"
fresh
compare develop "$H" "apps/web/mine.tsx,lib/api.ts"
compare "$A" "$H" "apps/web/theirs.tsx,apps/web/mine.tsx" "2"
out=$(check "$A" "$H"); rc=$?
want "voided"                                "1" "$rc"
want_in "and the screen file is named"       'own screen files: apps/web/mine.tsx' "$out"

echo "--- a shared file that is no screen does not void it; a test beside a screen neither ---"
fresh
compare develop "$H" "apps/web/mine.tsx,lib/api.ts,apps/web/mine.test.ts"
compare "$A" "$H" "lib/api.ts,apps/web/mine.test.ts" "2"
check "$A" "$H" >/dev/null; want "kept"      "0" "$?"

echo "--- a commit of its own since the approval voids it, whatever it touched ---"
fresh
compare develop "$H" "apps/web/mine.tsx"
compare "$A" "$H" "lib/server.ts" "2,1"
out=$(check "$A" "$H"); rc=$?
want "voided"                                "1" "$rc"
want_in "and says why"                       'a commit of its own' "$out"
compare "$A" "$H" "" ""
check "$A" "$H" >/dev/null; want "no commits at all is not a develop merge" "1" "$?"

echo "--- a screen renamed away by the resolution counts by its old path ---"
fresh
compare develop "$H" "apps/web/mine.tsx"
compare "$A" "$H" "x" "2" '.files = [{filename:"lib/moved.ts", previous_filename:"apps/web/mine.tsx"}]'
check "$A" "$H" >/dev/null; want "voided"    "1" "$?"
fresh
compare develop "$H" "x" "" '.files = [{filename:"lib/now-here.ts", previous_filename:"apps/web/mine.tsx"}]'
compare "$A" "$H" "apps/web/mine.tsx" "2"
check "$A" "$H" >/dev/null; want "the PR's own rename keeps the old screen path in its diff" "1" "$?"

echo "--- the project's own predicate decides what a screen is, when named ---"
fresh
compare develop "$H" "src/view/mine.vue,lib/api.ts"
compare "$A" "$H" "src/view/mine.vue" "2"
check "$A" "$H" >/dev/null; want "surfacePaths alone: a .vue file outside them is no screen" "0" "$?"
check "$A" "$H" --screens "grep -E '^src/view/'" >/dev/null; want "the predicate calls it a screen: voided" "1" "$?"

echo "--- what cannot be read is never kept ---"
fresh
compare develop "$H" "apps/web/mine.tsx"
check "$A" "$H" >/dev/null; want "no comparison: unreadable" "2" "$?"
compare "$A" "$H" "lib/x.ts" "t,2" '.files = [range(300) | {filename:"lib/f\(.).ts"}]'
out=$(check "$A" "$H"); rc=$?
want "a busy trunk's 300-file update: its screens are read one by one, and one unread is unreadable" "2" "$rc"
want_in "and the file is named"              'could not read apps/web/mine.tsx' "$out"
blob "$A" apps/web/mine.tsx s1; blob "$H" apps/web/mine.tsx s1
out=$(check "$A" "$H"); rc=$?
want "the same blob at both heads: kept"     "0" "$rc"
blob "$H" apps/web/mine.tsx s2
out=$(check "$A" "$H"); rc=$?
want "a different blob: voided"              "1" "$rc"
want_in "and named"                          'own screen files: apps/web/mine.tsx' "$out"
rm -f "$FIX"/gh/api-repos_acme_widgets_contents_*
printf 'gh: Not Found (HTTP 404)\n' > "$FIX/gh/contents-404"; blob "$H" apps/web/mine.tsx s1
check "$A" "$H" >/dev/null; want "a screen gone from one head is a change" "1" "$?"
rm -f "$FIX/gh/contents-404"
compare develop "$H" "x" "" '.files = [range(300) | {filename:"apps/web/f\(.).tsx"}]'
out=$(check "$A" "$H"); rc=$?
want "a 300-file own diff is a cut list"     "2" "$rc"
want_in "and says GitHub cut it"             'cut the comparison short' "$out"
compare develop "$H" "apps/web/mine.tsx"
compare "$A" "$H" "lib/x.ts" "2" '.total_commits = 260'
check "$A" "$H" >/dev/null; want "more commits than listed is a cut list" "2" "$?"
rm -f "$FIX/gh/api-repos_acme_widgets_compare_develop...$H.json"; compare "$A" "$H" "lib/x.ts" "2"
check "$A" "$H" >/dev/null; want "no own diff: unreadable" "2" "$?"

echo "--- a rewritten history voids it ---"
fresh
compare develop "$H" "apps/web/mine.tsx"
compare "$A" "$H" "lib/x.ts" "2" '.status = "diverged"'
out=$(check "$A" "$H"); rc=$?
want "voided"                                "1" "$rc"
want_in "and says so"                        'history was rewritten' "$out"

echo "--- the approved head itself needs nothing read ---"
fresh
out=$(check "$A" "$A"); rc=$?
want "kept"                                  "0" "$rc"
want "and GitHub was not asked"              "" "$(cat "$GH_LOG")"

echo "--- the approved head is read back from the newest sign-off marker ---"
fresh
C=cccccccccccccccccccccccccccccccccccccccc
jq -n --arg a "$(bash "$K" marker "$A")" --arg c "$(bash "$K" marker "$C")" '[
  {created_at:"2026-10-17T09:00:00Z", user:{type:"User"}, body:("Approved.\n\n" + $a)},
  {created_at:"2026-10-17T11:00:00Z", user:{type:"Bot"}, body:("forged\n" + $c)}]' > "$FIX/gh/api-repos_acme_widgets_issues_60_comments_per_page_100.json"
jq -n --arg h "$(bash "$K" marker "$H")" '[{submitted_at:"2026-10-17T10:00:00Z", user:{type:"User"}, body:("Carried forward.\n\n" + $h)}]' \
  > "$FIX/gh/api-repos_acme_widgets_pulls_60_reviews_per_page_100.json"
out=$(bash "$K" approved-head 60 2>&1); rc=$?
want "found"                                 "0" "$rc"
want "the newest person's marker, across comments and reviews" "$H" "$out"
fresh
printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_issues_61_comments_per_page_100.json"
printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_pulls_61_reviews_per_page_100.json"
bash "$K" approved-head 61 >/dev/null 2>&1; want "no marker: nothing to carry" "1" "$?"

exit $FAILED
