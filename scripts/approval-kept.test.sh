#!/usr/bin/env bash
# approval-kept.test.sh — an approval survives an update that only brought the
# trunk in and left the PR's own screens alone, and nothing else: a commit of its
# own, a merge resolution that edits one of its screens, a rewritten history or a
# comparison that cannot be read all void it. The PR's screens are read at the
# approved head as well as the new one; a partial screen list holds every other
# non-test file; the approved head comes from a review's commit or a clear-hold
# comment the hold's removal followed. The last section runs on real git history.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
K="$HERE/approval-kept.sh"
design() { jq --argjson d "$1" '.design = $d' "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"; }
# Most cases pin the screen list as complete, so they test the rule, not the default.
PRECISE='{"surfacePaths": ["apps/web/**", ":(exclude)**/*.test.ts"], "surfacePathsComplete": true}'
design "$PRECISE"

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
# A fixture that re-answers the same (commit, path) differently is not a real forge, so it clears the cache.
blob() { rm -rf "$STATE/swarm/blobs"; jq -n --arg b "$3" '{sha:$b}' > "$FIX/gh/api-$(printf '%s' "repos/acme/widgets/contents/$2?ref=$1" | tr '/?&=' '____').json"; }
fresh() { rm -rf "$FIX"/gh/api-repos_* "$FIX/gh/contents-404" "$STATE/swarm/blobs"; : > "$GH_LOG"; compare develop "$A" ""; }
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

echo "--- a file at a commit is asked once: the next check of the same heads reads none ---"
fresh
A1=1111111111111111111111111111111111111111; H1=2222222222222222222222222222222222222222
compare develop "$A1" "apps/web/a.tsx,apps/web/b.tsx"; compare develop "$H1" "x"
compare "$A1" "$H1" "lib/x.ts" "t,2" '.files = [range(300) | {filename:"lib/f\(.).ts"}]'
blob "$A1" apps/web/a.tsx s1; blob "$H1" apps/web/a.tsx s1; blob "$A1" apps/web/b.tsx s2; blob "$H1" apps/web/b.tsx s2
: > "$GH_LOG"; check "$A1" "$H1" >/dev/null; want "first check: kept" "0" "$?"
want "and it read each screen at both heads" "4" "$(grep -c '/contents/' "$GH_LOG")"
: > "$GH_LOG"; check "$A1" "$H1" >/dev/null; want "second check: still kept" "0" "$?"
want "and it asked GitHub for no file contents" "0" "$(grep -c '/contents/' "$GH_LOG")"
printf 'gh: Not Found (HTTP 404)\n' > "$FIX/gh/contents-404"; rm -f "$FIX"/gh/api-repos_acme_widgets_contents_*
compare develop "$A1" "apps/web/c.tsx"; : > "$GH_LOG"
check "$A1" "$H1" >/dev/null; check "$A1" "$H1" >/dev/null
want "a file absent at a commit is remembered too" "2" "$(grep -c '/contents/' "$GH_LOG")"
rm -f "$FIX/gh/contents-404"; rm -rf "$STATE/swarm/blobs"; : > "$GH_LOG"
check "$A1" "$H1" >/dev/null; check "$A1" "$H1" >/dev/null
want "an unreadable file is never remembered: each check asks again" "2" "$(grep -c '/contents/' "$GH_LOG")"

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

echo "--- the PR's screens are read at the approved head too ---"
fresh
compare develop "$A" "apps/web/mine.tsx"
compare develop "$H" "lib/api.ts"
compare "$A" "$H" "apps/web/mine.tsx,apps/web/theirs.tsx" "t,2"
out=$(check "$A" "$H"); rc=$?
want "a resolution that took develop's version of its screen: voided" "1" "$rc"
want_in "and the screen is named"            'own screen files: apps/web/mine.tsx' "$out"
fresh
compare develop "$A" "apps/web/new.tsx"
compare develop "$H" "x"
compare "$A" "$H" "apps/web/new.tsx" "2"
check "$A" "$H" >/dev/null; want "a screen the PR added and the merge dropped: voided" "1" "$?"
fresh
compare develop "$A" "x" "" '.files = [{filename:"apps/web/renamed.tsx", previous_filename:"apps/web/old.tsx"}]'
compare develop "$H" "x"
compare "$A" "$H" "x" "2" '.files = [{filename:"apps/web/old.tsx", previous_filename:"apps/web/renamed.tsx"}]'
check "$A" "$H" >/dev/null; want "a rename the merge undid: voided" "1" "$?"
fresh
compare develop "$A" "apps/web/mine.tsx"
compare develop "$H" "x"
compare "$A" "$H" "lib/x.ts" "t,2" '.files = [range(300) | {filename:"lib/f\(.).ts"}]'
blob "$A" apps/web/mine.tsx s1; blob "$H" apps/web/mine.tsx s2
check "$A" "$H" >/dev/null; want "and in the 300-file fallback" "1" "$?"
compare develop "$A" "x" "" '.files = [range(300) | {filename:"apps/web/f\(.).tsx"}]'
check "$A" "$H" >/dev/null; want "a 300-file own diff at the approved head is a cut list" "2" "$?"

echo "--- a screen list not marked complete holds every other non-test file ---"
design '{"surfacePaths": ["apps/web/**"]}'
fresh
compare develop "$H" "apps/web/mine.tsx,packages/copy/strings.ts"
compare "$A" "$H" "packages/copy/strings.ts" "t,2"
out=$(check "$A" "$H"); rc=$?
want "copy outside surfacePaths: voided"     "1" "$rc"
want_in "and named"                          'own screen files: packages/copy/strings.ts' "$out"
compare develop "$H" "apps/web/mine.test.tsx,apps/web/__tests__/deep/a.tsx,lib/x.spec.ts"
compare "$A" "$H" "apps/web/mine.test.tsx,apps/web/__tests__/deep/a.tsx,lib/x.spec.ts" "t,2"
check "$A" "$H" >/dev/null; want "tests are never screens" "0" "$?"
design '{"surfacePaths": ["apps/web/**"], "neverScreens": ["**/.deploy-trigger"]}'
compare develop "$H" ".deploy-trigger,apps/web/.deploy-trigger"
compare "$A" "$H" ".deploy-trigger,apps/web/.deploy-trigger" "t,2"
check "$A" "$H" >/dev/null; want "design.neverScreens names files that never draw" "0" "$?"
design '{"surfacePaths": ["apps/web/**"], "surfacePathsComplete": true}'
compare develop "$H" "packages/copy/strings.ts"
compare "$A" "$H" "packages/copy/strings.ts" "t,2"
check "$A" "$H" >/dev/null; want "marked complete, the list alone decides" "0" "$?"

echo "--- globs read as git pathspecs written as globs ---"
gl() { design "{\"surfacePaths\": $1, \"surfacePathsComplete\": true}"; fresh; compare develop "$H" "$2"; compare "$A" "$H" "$2" "2"; check "$A" "$H" >/dev/null; echo $?; }
want "a/**/b matches deep"                   "1" "$(gl '["apps/**/Card.tsx"]' apps/web/src/ui/Card.tsx)"
want "a/**/b matches no directory between"   "1" "$(gl '["apps/**/Card.tsx"]' apps/Card.tsx)"
want "a plain directory matches under it"    "1" "$(gl '["apps/web"]' apps/web/src/a.tsx)"
want "and not a sibling that shares a prefix" "0" "$(gl '["apps/web"]' apps/webby/a.tsx)"
want "**/__tests__/** excludes nested tests" "0" "$(gl '["apps/**", ":(exclude)**/__tests__/**"]' apps/web/src/__tests__/a.tsx)"
want "* stays in one directory"              "0" "$(gl '["apps/*.tsx"]' apps/web/a.tsx)"
want "a dot is a dot"                        "0" "$(gl '["apps/a.tsx"]' apps/aXtsx)"
design "$PRECISE"

echo "--- the approved head: a review's own commit, or a clear-hold comment the hold's removal followed ---"
signoffs() { # <comments-json> <reviews-json> <events-json>
  printf '%s\n' "$1" > "$FIX/gh/api-repos_acme_widgets_issues_60_comments_per_page_100.json"
  printf '%s\n' "$2" > "$FIX/gh/api-repos_acme_widgets_pulls_60_reviews_per_page_100.json"
  printf '%s\n' "$3" > "$FIX/gh/api-repos_acme_widgets_issues_60_events_per_page_100.json"
}
C=cccccccccccccccccccccccccccccccccccccccc
MA=$(bash "$K" marker "$A"); MC=$(bash "$K" marker "$C")
OFF='[{"event":"unlabeled","label":{"name":"needs:human-approval"},"actor":{"login":"tester","type":"User"},"created_at":"2026-10-17T09:00:05Z"}]'
cm() { jq -n --arg at "$1" --arg b "$2" --arg ty "${3:-User}" '{created_at:$at, user:{login:"tester", type:$ty}, body:$b}'; }
fresh
signoffs "[$(cm 2026-10-17T09:00:00Z "Approved by @tester in the agent window on 2026-10-17.

$MA")]" '[]' "$OFF"
out=$(bash "$K" approved-head 60 2>&1); rc=$?
want "clear-hold's comment, then the hold off: found" "0" "$rc"
want "its head"                              "$A" "$out"
signoffs "[$(cm 2026-10-17T09:00:00Z "Approved by @tester in the agent window on 2026-10-17.

$MA"), $(cm 2026-10-17T11:00:00Z "Approved by @tester in the agent window on 2026-10-17.

$MC")]" '[]' "$OFF"
want "a later comment no removal followed is a forgery, ignored" "$A" "$(bash "$K" approved-head 60 2>/dev/null)"
signoffs "[$(cm 2026-10-17T08:00:00Z "Approved by @tester.

$MC")]" '[]' "$OFF"
bash "$K" approved-head 60 >/dev/null 2>&1; want "a removal long after the comment does not vouch for it" "1" "$?"
signoffs "[$(cm 2026-10-17T09:00:00Z "Looks good to me.

$MC")]" '[]' "$OFF"
bash "$K" approved-head 60 >/dev/null 2>&1; want "a marker in any other words counts for nothing" "1" "$?"
signoffs "[$(cm 2026-10-17T09:00:00Z "Approved by @tester.

$MC" Bot)]" '[]' "$OFF"
bash "$K" approved-head 60 >/dev/null 2>&1; want "a bot's comment counts for nothing" "1" "$?"
signoffs "[$(cm 2026-10-17T09:00:00Z "Approved by @tester.

$MA")]" "[{\"state\":\"APPROVED\",\"submitted_at\":\"2026-10-17T10:00:00Z\",\"commit_id\":\"$H\",\"user\":{\"login\":\"peer\",\"type\":\"User\"},\"body\":\"$MC\"}]" "$OFF"
want "a newer approving review: GitHub's own commit, never its body" "$H" "$(bash "$K" approved-head 60 2>/dev/null)"
signoffs '[]' "[{\"state\":\"COMMENTED\",\"submitted_at\":\"2026-10-17T10:00:00Z\",\"commit_id\":\"$H\",\"user\":{\"login\":\"peer\",\"type\":\"User\"},\"body\":\"\"}]" "$OFF"
bash "$K" approved-head 60 >/dev/null 2>&1; want "a review that is not an approval: nothing" "1" "$?"
rm -f "$FIX/gh/api-repos_acme_widgets_issues_60_events_per_page_100.json"
bash "$K" approved-head 60 >/dev/null 2>&1; want "an unreadable timeline: could not tell" "2" "$?"

echo "--- the signed head: any sign-off, a bare removal of the hold on GitHub included ---"
cmts() { # <sha:committer-date>… — the PR's commits, oldest first
  local a=() c; for c in "$@"; do a+=("$(jq -n --arg s "${c%%:*}" --arg d "${c#*:}" '{sha:$s, commit:{committer:{date:$d}}}')"); done
  printf '%s\n' "${a[@]}" | jq -s . > "$FIX/gh/api-repos_acme_widgets_pulls_60_commits_per_page_100.json"
}
signoffs '[]' '[]' "$OFF"
cmts "$A:2026-10-17T08:00:00Z" "$H:2026-10-17T08:30:00Z" "$C:2026-10-17T09:30:00Z"
want "no marker, the hold removed by a person: signed at the head then" "$H" "$(bash "$K" signed-head 60 2>/dev/null)"
bash "$K" approved-head 60 >/dev/null 2>&1; want "while approved-head, which clears holds, still wants a marker" "1" "$?"
signoffs '[]' '[]' '[{"event":"unlabeled","label":{"name":"needs:human-approval"},"actor":{"login":"ci[bot]","type":"Bot"},"created_at":"2026-10-17T09:00:05Z"}]'
bash "$K" signed-head 60 >/dev/null 2>&1; want "a bot's removal is no sign-off" "1" "$?"
signoffs "[$(cm 2026-10-17T09:00:00Z "Approved by @tester in the agent window on 2026-10-17.

$MA")]" '[]' "$OFF"
want "a marked sign-off and the removal it caused: the marked head" "$A" "$(bash "$K" signed-head 60 2>/dev/null)"
signoffs "[$(cm 2026-10-17T07:00:00Z "Approved by @tester in the agent window on 2026-10-17.

$MA")]" '[]' '[{"event":"unlabeled","label":{"name":"needs:human-approval"},"actor":{"login":"tester","type":"User"},"created_at":"2026-10-17T07:00:05Z"},{"event":"unlabeled","label":{"name":"needs:human-approval"},"actor":{"login":"tester","type":"User"},"created_at":"2026-10-17T10:00:00Z"}]'
want "a later bare removal outranks an older marked one" "$C" "$(bash "$K" signed-head 60 2>/dev/null)"
signoffs '[]' '[]' "$OFF"; cmts "$C:2026-10-17T09:30:00Z"
bash "$K" signed-head 60 >/dev/null 2>&1; want "a removal no commit can place: signed, head unknown" "3" "$?"
rm -f "$FIX/gh/api-repos_acme_widgets_pulls_60_commits_per_page_100.json"
bash "$K" signed-head 60 >/dev/null 2>&1; want "commits unreadable: could not tell" "2" "$?"
signoffs '[]' '[]' '[]'
bash "$K" signed-head 60 >/dev/null 2>&1; want "never signed" "1" "$?"

echo "--- on real git history ---"
# The forge answers compare and contents from a real repository.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
q=""; prev=""; ep=""; skip=0
for a in "${@:2}"; do
  case "$prev" in -q|--jq) q="$a" ;; esac; prev="$a"
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in -X|-f|-F|-H|-q|--jq|--method|--input) skip=1 ;; -*) ;; *) [ -n "$ep" ] || ep="$a" ;; esac
done
g() { git -C "$SIMREPO" "$@"; }
case "$ep" in
  repos/*/compare/*)
    r=${ep#*/compare/}; B=${r%%...*}; H=${r#*...}
    B=$(g rev-parse "$B") || exit 1; H=$(g rev-parse "$H") || exit 1
    mb=$(g merge-base "$B" "$H")
    if [ "$B" = "$H" ]; then st=identical; elif [ "$mb" = "$B" ]; then st=ahead; elif [ "$mb" = "$H" ]; then st=behind; else st=diverged; fi
    commits=$(g rev-list --reverse --parents "$mb..$H" | jq -R 'split(" ") | {sha: .[0], parents: (.[1:] | map({sha: .}))}' | jq -s .)
    files=$(g diff --name-status -M "$mb" "$H" | jq -R 'split("\t") | if (.[0]|startswith("R")) then {filename: .[2], previous_filename: .[1]} else {filename: .[1]} end' | jq -s .)
    out=$(jq -n --arg st "$st" --argjson c "$commits" --argjson f "$files" '{status:$st, total_commits:($c|length), commits:$c, files:$f}') ;;
  repos/*/contents/*)
    r=${ep#*/contents/}; p=${r%%\?ref=*}; ref=${r#*\?ref=}; p=$(printf '%b' "${p//%/\\x}")
    s=$(g rev-parse "$ref:$p" 2>/dev/null) || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    out=$(jq -n --arg s "$s" '{sha:$s}') ;;
  *) exit 1 ;;
esac
if [ -n "$q" ]; then jq -r "$q" <<<"$out"; else printf '%s\n' "$out"; fi
GH
chmod +x "$BIN/gh"
design '{"surfacePaths": ["apps/web/**/*.tsx", ":(exclude)**/__tests__/**"]}'
export SIMREPO="$FIX/sim"; G() { git -C "$SIMREPO" "$@"; }
w() { mkdir -p "$SIMREPO/$(dirname "$1")"; printf '%s\n' "$2" > "$SIMREPO/$1"; }
reset() { rm -rf "$SIMREPO"; mkdir -p "$SIMREPO"; G init -q -b develop; G config user.email t@t; G config user.name t
  w apps/web/src/Card.tsx $'line1\ncolor=blue\nline3'; w apps/web/src/app/globals.css '.a{color:blue}'; w lib/x.txt a; G add -A; G commit -qm base; }
mergedev() { G checkout -q pr; G merge -q --no-edit develop >/dev/null 2>&1; }
real() { bash "$K" check "$A" "$(G rev-parse HEAD)" >/dev/null 2>&1; echo $?; }
reset; G checkout -qb pr; w apps/web/src/Card.tsx $'line1\ncolor=RED\nline3'; G commit -qam pr; A=$(G rev-parse HEAD)
G checkout -q develop; w lib/x.txt b; G commit -qam dev; mergedev
want "control: develop changed nothing of the PR's: kept" "0" "$(real)"
reset; G checkout -qb pr; w apps/web/src/Card.tsx $'line1\ncolor=RED\nline3'; G commit -qam pr; A=$(G rev-parse HEAD)
G checkout -q develop; w apps/web/src/Card.tsx $'line1\ncolor=green\nline3'; G commit -qam dev
G checkout -q pr; G merge -q develop >/dev/null 2>&1; G checkout -q --theirs apps/web/src/Card.tsx; G add -A; G commit -qm merge
want "the resolution took develop's Card: voided" "1" "$(real)"
reset; G checkout -qb pr; w apps/web/src/New.tsx 'new'; G add -A; G commit -qm pr; A=$(G rev-parse HEAD)
G checkout -q develop; w lib/x.txt b; G commit -qam dev; mergedev; G rm -q apps/web/src/New.tsx; G commit -q --amend --no-edit
want "the merge dropped the PR's new screen: voided" "1" "$(real)"
reset; G checkout -qb pr; w apps/web/src/app/globals.css '.a{color:red}'; G commit -qam pr; A=$(G rev-parse HEAD)
G checkout -q develop; w lib/x.txt b; G commit -qam dev; mergedev; w apps/web/src/app/globals.css '.a{color:red;display:none}'; G add -A; G commit -q --amend --no-edit
want "a stylesheet outside surfacePaths, edited in the merge: voided" "1" "$(real)"
reset; w apps/web/src/Card.tsx $'line1\ncolor=blue\nline3\n\n\n\nfooter=plain'; G commit -qam base2
G checkout -qb pr; w apps/web/src/Card.tsx $'line1\ncolor=RED\nline3\n\n\n\nfooter=plain'; G commit -qam pr; A=$(G rev-parse HEAD)
G checkout -q develop; w apps/web/src/Card.tsx $'line1\ncolor=RED\nline3\n\n\n\nfooter=BOLD'; G commit -qam "squash of a stacked PR"; mergedev
want "a develop squash carrying the PR's change and one more hunk: voided" "1" "$(real)"
reset; G checkout -qb pr; w apps/web/src/Card.tsx $'line1\ncolor=RED\nline3'; G commit -qam pr; A=$(G rev-parse HEAD)
G checkout -q develop; for i in $(seq 1 305); do w "lib/gen/f$i.txt" "$i"; done; w apps/web/src/Card.tsx $'line1\ncolor=green\nline3'; G add -A; G commit -qm dev
G checkout -q pr; G merge -q develop >/dev/null 2>&1; G checkout -q --theirs apps/web/src/Card.tsx; G add -A; G commit -qm merge
want "the same past 300 files, by blob: voided" "1" "$(real)"
reset; w apps/web/src/Old.tsx $'a\nb\nc\nd\ne'; G add -A; G commit -qm base3; G checkout -qb pr; G mv apps/web/src/Old.tsx apps/web/src/Renamed.tsx; G commit -qm rename; A=$(G rev-parse HEAD)
G checkout -q develop; w lib/x.txt b; G commit -qam dev; mergedev; G mv apps/web/src/Renamed.tsx apps/web/src/Old.tsx; G commit -q --amend --no-edit
want "the merge undid the PR's rename: voided" "1" "$(real)"
reset; w apps/web/src/__tests__/a.tsx $'x\n\n\n\ny'; G add -A; G commit -qm b4; G checkout -qb pr; w apps/web/src/__tests__/a.tsx $'X\n\n\n\ny'; G commit -qam pr; A=$(G rev-parse HEAD)
G checkout -q develop; w apps/web/src/__tests__/a.tsx $'x\n\n\n\nY'; G commit -qam dev; mergedev
want "a nested test both sides changed: kept" "0" "$(real)"

echo "--- screens: the same rule, for a caller with paths ---"
design "$PRECISE"
want "the screen ones, by surfacePaths" "apps/web/a.tsx" \
  "$(printf 'apps/web/a.tsx\napps/web/a.test.ts\ndocs/x.md\n' | bash "$K" screens)"
want "release notes are never in the screen set" "" \
  "$(printf 'apps/web/content/changelog/1.md\napps/web/CHANGELOG.txt\n' | bash "$K" screens)"
design '{"surfacePaths": ["apps/web/**/*.tsx"], "extraScreens": ["apps/web/app/globals.css"], "neverScreens": ["**/.deploy-trigger"]}'
want "a partial list: surfacePaths plus extraScreens, not every file" "apps/web/a.tsx
apps/web/app/globals.css" \
  "$(printf 'apps/web/a.tsx\napps/web/app/globals.css\napps/api/route.ts\napps/web/.deploy-trigger\napps/web/x.test.tsx\n' | bash "$K" screens)"
printf 'apps/web/a.tsx\napps/api/route.ts\n' | bash "$K" screens >/dev/null
want "it exits 0 when the last path is not a screen" "0" "$?"
design '{}'
want "no surfacePaths at all: the wide rule, minus release notes" "lib/y.ts" \
  "$(printf 'lib/y.ts\ndocs/x.md\nlib/y.test.ts\n' | bash "$K" screens)"
design "$PRECISE"

suite_end "$FAILED"
