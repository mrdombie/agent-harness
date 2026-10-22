#!/usr/bin/env bash
# signoff-push-guard.test.sh — sign-off comes last. On a branch whose PR the owner
# signed (a review, a marked clear-hold, or the hold removed by hand on GitHub), a
# push whose head differs from the signed head in one of the PR's own screens is
# refused without a `pixel-change-after-signoff: <why>` trailer since the sign-off;
# with one, the hold goes back on, the PR gets a before/after comment and the
# owner's batch a lane-hold line. The trees are compared, not the commits: a merge
# taking the trunk's side, a resolution dropping a screen, a force-push back and a
# side-branch fast-forward are all caught. A trunk merge that resolves nothing,
# docs and changelog files, a PR never signed or still held, and a push with no PR
# all go. Unreadable sign-offs fail shut, for screens only. The last case pushes
# through a real pre-push hook.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
G="$HERE/signoff-push-guard.sh"
jq '.design = {"surfacePaths": ["apps/web/**", ":(exclude)**/*.test.ts"], "surfacePathsComplete": true}' \
  "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"
export COORDINATOR_SHADOW=1
WORK="$STATE/coordinator/agent-work.log"

# gh: `pr list` from prlist.json, `api <endpoint>` from api-<endpoint>.json, edits and
# comments recorded; a file named fail-<verb> makes that verb fail.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr list")    [ -f "$FIX/gh/fail-prlist" ] && exit 1; cat "$FIX/gh/prlist.json" 2>/dev/null || echo '[]'; exit 0 ;;
  "pr edit")    [ -f "$FIX/gh/fail-edit" ] && exit 1; exit 0 ;;
  "issue edit"|"pr comment") exit 0 ;;
esac
[ "$1" = api ] || exit 0
[ -f "$FIX/gh/fail-api" ] && exit 1
f="$FIX/gh/api-$(printf '%s' "$2" | tr '/?&=' '____').json"
[ -f "$f" ] && cat "$f" || exit 1
GH
chmod +x "$BIN/gh"

R="$REPO"
g() { git -C "$R" "$@"; }
g config user.email t@example.com; g config user.name t; g config commit.gpgsign false
mkdir -p "$R/apps/web" "$R/docs"
echo a > "$R/apps/web/page.tsx"; echo d > "$R/docs/x.md"
g add -A; g commit -qm base; g branch -M develop
git init -q --bare "$FIX/origin.git"; g remote add origin "$FIX/origin.git"; g push -q origin develop
g checkout -qb tkt-5-x
echo b >> "$R/apps/web/page.tsx"; g commit -qam "feat: the page"
SIGNED=$(g rev-parse HEAD)
g push -q --no-verify origin tkt-5-x
BASE_REMOTE=$SIGNED

signed() { # <sha|-> — an APPROVED review at that head, or none
  local rv='[]'
  [ "$1" = - ] || rv=$(jq -n --arg s "$1" '[{state:"APPROVED", user:{login:"owner", type:"User"}, commit_id:$s, submitted_at:"2026-10-17T10:00:00Z"}]')
  printf '%s\n' "$rv" > "$FIX/gh/api-repos_acme_widgets_pulls_7_reviews_per_page_100.json"
  printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_issues_7_comments_per_page_100.json"
  printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_issues_7_events_per_page_100.json"
}
haspr() { jq -n --arg l "${1:-}" '[{number:7, labels:(if $l == "" then [] else [{name:$l}] end)}]' > "$FIX/gh/prlist.json"; }
nopr()  { printf '[]\n' > "$FIX/gh/prlist.json"; }
reset() { g checkout -q tkt-5-x; g reset -q --hard "$SIGNED"; : > "$GH_LOG"; rm -f "$FIX/gh/fail-"*; rm -f "$WORK"; haspr; signed "$SIGNED"; BASE_REMOTE=$SIGNED; }
guard() { # [remote-sha] — push HEAD to tkt-5-x; prints stderr, exit code on the last line
  local l r out rc
  l=$(g rev-parse HEAD); r="${1:-$BASE_REMOTE}"
  out=$(cd "$R" && printf 'refs/heads/tkt-5-x %s refs/heads/tkt-5-x %s\n' "$l" "$r" | bash "$G" origin "$FIX/origin.git" 2>&1); rc=$?
  printf '%s\nrc=%s' "$out" "$rc"
}
TRAIL="pixel-change-after-signoff: the typecheck fix widens the column"

echo "--- a screen change after sign-off, without the trailer, is refused ---"
reset
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: tighten the page"
out=$(guard)
want_in "refused"                          'rc=1$' "$out"
want_in "it says sign-off comes last"      'sign-off comes last' "$out"
want_in "it names the signed head and the file" "signed PR #7 at ${SIGNED:0:7}, and this push changes its screens: apps/web/page.tsx" "$out"
want_in "and the trailer that lets it go"  'pixel-change-after-signoff: <why>' "$out"
want_not_in "the hold is not touched"      'pr edit' "$(cat "$GH_LOG")"

echo "--- with the trailer: allowed, and the hold goes back on ---"
reset
echo c >> "$R/apps/web/page.tsx"
g commit -qam "fix: the red check needs a wider column" -m "$TRAIL"
AFTER=$(g rev-parse HEAD)
out=$(guard)
want_in "allowed"                          'rc=0$' "$out"
want_in "the hold is re-added to the PR"   '^pr edit 7 --repo acme/widgets --add-label needs:human-approval$' "$(cat "$GH_LOG")"
want_in "and to its ticket"                '^issue edit 5 --repo acme/widgets --add-label needs:human-approval$' "$(cat "$GH_LOG")"
want_in "the PR gets a before/after"       "pr comment 7 .*Before:\*\* the signed head \`${SIGNED:0:7}\`" "$(tr '\n' ' ' < "$GH_LOG")"
want_in "saying the push is still pending" 'pending its push' "$(cat "$GH_LOG")"
want_in "naming the new head and compare"  "After:\*\* \`${AFTER:0:7}\` — https://github.com/acme/widgets/compare/$SIGNED...$AFTER" "$(cat "$GH_LOG")"
want_in "and why"                          'Why:\*\* the typecheck fix widens the column' "$(cat "$GH_LOG")"
want_in "the owner's batch gets the line"  "lane-hold:7:${AFTER:0:7}	PR #7 needs your sign-off again: changed after sign-off — before ${SIGNED:0:7}, after ${AFTER:0:7} \(apps/web/page.tsx\)" "$(cat "$WORK" 2>/dev/null)"

echo "--- SIGNOFF_GUARD_DRYRUN=1: the same decision, no side effects ---"
reset
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: x" -m "$TRAIL"
out=$(SIGNOFF_GUARD_DRYRUN=1 guard)
want_in "a reasoned change still goes"          'rc=0$' "$out"
want_in "saying it is a dry run"                'dry run' "$out"
want_not_in "no hold, label, comment or edit"   'pr edit|issue edit|pr comment' "$(cat "$GH_LOG")"
want "and no notify"                             "" "$(cat "$WORK" 2>/dev/null)"
reset
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: no reason"
out=$(SIGNOFF_GUARD_DRYRUN=1 guard)
want_in "an unreasoned change is refused the same way" 'rc=1$' "$out"
want_in "with the same line"                    'pre-push blocked: sign-off comes last' "$out"
want_not_in "and nothing touched"               'pr edit|issue edit|pr comment' "$(cat "$GH_LOG")"
g reset -q --hard "$AFTER"

echo "--- once the hold is back on, later screen commits need no new trailer or comment ---"
g push -q --no-verify -f origin HEAD:tkt-5-x; BASE_REMOTE=$AFTER; haspr needs:human-approval; : > "$GH_LOG"
echo d >> "$R/apps/web/page.tsx"; g commit -qam "fix: follow-up while held"
out=$(guard)
want_in "allowed"                          'rc=0$' "$out"
want_not_in "no second comment or edit"    'pr comment|pr edit' "$(cat "$GH_LOG")"
g push -q --no-verify -f origin "$SIGNED:refs/heads/tkt-5-x"

echo "--- the hold cannot be put back: refused ---"
reset; touch "$FIX/gh/fail-edit"
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: x" -m "$TRAIL"
want_in "refused"                          'rc=1$' "$(guard)"

echo "--- the trees decide, not the commits pushed ---"
g checkout -q develop; echo z > "$R/apps/web/other.tsx"; echo a2 > "$R/apps/web/page.tsx"; echo q > "$R/docs/y.md"; g add -A; g commit -qm "trunk: another ticket"
g push -q origin develop; TRUNK=$(g rev-parse HEAD)
reset
g merge -q --no-edit -X ours "$TRUNK" >/dev/null 2>&1
want_in "a trunk merge that keeps the signed screen goes" 'rc=0$' "$(guard)"
reset
g merge -q --no-edit -X theirs "$TRUNK" >/dev/null 2>&1
out=$(guard)
want_in "a merge taking the trunk's side of the signed screen is refused" 'rc=1$' "$out"
want_in "naming that screen, not the trunk's own" 'its screens: apps/web/page.tsx$' "$(printf '%s\n' "$out" | grep 'its screens')"
reset
g merge -q --no-edit "$TRUNK" >/dev/null 2>&1
printf 'a\nb\nresolved\n' > "$R/apps/web/page.tsx"; g add -A; g commit -qm "merge develop" --no-edit
want_in "a resolution that edits the signed screen is refused" 'rc=1$' "$(guard)"
reset
echo n > "$R/apps/web/new.tsx"; g add -A; g commit -qm "feat: a new screen"; S2=$(g rev-parse HEAD)
g push -q --no-verify -f origin HEAD:tkt-5-x; signed "$S2"; BASE_REMOTE=$S2
g merge -q --no-edit --no-commit -X ours "$TRUNK" >/dev/null 2>&1; g rm -q apps/web/new.tsx; g commit -q --no-edit
want_in "a resolution that drops a signed screen is refused" 'rc=1$' "$(guard)"
g push -q --no-verify -f origin "$SIGNED:refs/heads/tkt-5-x"
reset
g reset -q --hard "$SIGNED~1"
want_in "a force-push back to before the sign-off is refused" 'rc=1$' "$(guard)"
reset
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: by the side door"
g push -q --no-verify origin HEAD:refs/heads/wip
want_in "a screen commit that reached the remote on a side branch is refused" 'rc=1$' "$(guard)"
g push -q --no-verify origin --delete wip; g fetch -q --prune origin

echo "--- the PR's own change decides, not the heads: develop edits elsewhere in a signed screen ---"
g checkout -q develop; printf 'l1\nl2\nl3\n\n\n\n\nl8\n' > "$R/apps/web/long.tsx"; g add apps/web/long.tsx; g commit -qm "trunk: a long screen"; g push -q origin develop
reset; g merge -q --no-edit -X ours develop >/dev/null 2>&1
printf 'l1\nL2\nl3\n\n\n\n\nl8\n' > "$R/apps/web/long.tsx"; g add apps/web/long.tsx; g commit -qm "feat: the long screen"; S3=$(g rev-parse HEAD)
g push -q --no-verify -f origin HEAD:tkt-5-x; signed "$S3"; BASE_REMOTE=$S3
g checkout -q develop; printf 'l1\nl2\nl3\n\n\n\n\nL8\n' > "$R/apps/web/long.tsx"; g add apps/web/long.tsx; g commit -qm "trunk: another ticket's footer"; g push -q origin develop
g checkout -q tkt-5-x; g merge -q --no-edit develop >/dev/null 2>&1
want "(a clean merge: it resolved nothing)" "" "$(g show --remerge-diff --format= HEAD)"
want_in "a clean merge where develop edited another part of the signed screen goes" 'rc=0$' "$(guard)"
printf 'l1\nL2\nl3\n\nsneaked\n\n\nL8\n' > "$R/apps/web/long.tsx"; g add apps/web/long.tsx; g commit -q --amend --no-edit
want_in "a merge that slips an edit into it is refused" 'rc=1$' "$(guard)"
g reset -q --hard "$S3"; g merge -q --no-edit develop >/dev/null 2>&1
printf 'l1\nl2\nl3\n\n\n\nL2\nL8\n' > "$R/apps/web/long.tsx"; g add apps/web/long.tsx; g commit -q --amend --no-edit
want_in "a merge that moves the PR's own line elsewhere in it is refused" 'rc=1$' "$(guard)"
g reset -q --hard "$S3"
printf 'l1\nL2!\nl3\n\n\n\n\nl8\n' > "$R/apps/web/long.tsx"; g add apps/web/long.tsx; g commit -qm "fix: the PR's own"
want_in "a commit of the PR's own editing it is refused" 'rc=1$' "$(guard)"
g push -q --no-verify -f origin "$SIGNED:refs/heads/tkt-5-x"

echo "--- what goes ---"
reset
echo t > "$R/apps/web/page.test.ts"; echo e >> "$R/docs/x.md"; g add -A; g commit -qm "test: more"
out=$(guard)
want_in "a test and a doc after sign-off"  'rc=0$' "$out"
want "and GitHub is not asked"             "" "$(cat "$GH_LOG")"
# The config is tracked in this fixture, so a reset restores it: set it after.
cp "$HARNESS_CFG_PATH" "$FIX/cfg.complete"
partial() { jq '.design = {"surfacePaths": ["apps/web/**/*.tsx"], "extraScreens": ["apps/web/app/globals.css", "apps/web/public/**"]}' "$FIX/cfg.complete" > "$HARNESS_CFG_PATH"; }
reset
mkdir -p "$R/apps/web/content/changelog"
echo e > "$R/apps/web/content/changelog/6.md"; g add apps; g commit -qm "docs(changelog): reword"
want_in "release-note wording under a screen path goes (owner, 2026-10-18)" 'rc=0$' "$(guard)"
reset; partial
mkdir -p "$R/apps/web/content/changelog" "$R/.changeset"
echo e > "$R/apps/web/content/changelog/5.md"; echo e > "$R/CHANGELOG.md"; echo e > "$R/.changeset/x.json"; echo e >> "$R/docs/x.md"
g add apps .changeset CHANGELOG.md docs; g commit -qm "docs(changelog): entry"
want_in "a partial screen list: docs and changelog files go" 'rc=0$' "$(guard)"
reset; partial
mkdir -p "$R/apps/api/src"; echo e > "$R/apps/api/src/route.ts"; echo e > "$R/apps/web/util.ts"; g add apps; g commit -qm "fix: a server-only change"
want_in "a server-only fix outside the screen set goes" 'rc=0$' "$(guard)"
reset; partial
mkdir -p "$R/apps/web/app"; echo e > "$R/apps/web/app/globals.css"; g add apps; g commit -qm "fix: a colour"
out=$(guard)
want_in "a file in design.extraScreens is a screen" 'rc=1$' "$out"
want_in "named"                                 'its screens: apps/web/app/globals.css$' "$(printf '%s\n' "$out" | grep 'its screens')"
cp "$FIX/cfg.complete" "$HARNESS_CFG_PATH"
reset; nopr
echo c >> "$R/apps/web/page.tsx"; g commit -qam "feat: more"
want_in "a screen change with no PR"       'rc=0$' "$(guard)"
reset; signed -
echo c >> "$R/apps/web/page.tsx"; g commit -qam "feat: more"
want_in "a screen change on a PR never signed" 'rc=0$' "$(guard)"
reset; haspr needs:human-approval
echo c >> "$R/apps/web/page.tsx"; g commit -qam "feat: more"
want_in "a screen change on a PR still held" 'rc=0$' "$(guard)"
reset; g update-ref -d refs/remotes/origin/tkt-5-x
want_in "the signed head, pushed where the remote has no copy of it" 'rc=0$' "$(guard 0000000000000000000000000000000000000000)"
g fetch -q origin
reset
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: x"
out=$(cd "$R" && printf 'refs/heads/tkt-5-x 0000000000000000000000000000000000000000 refs/heads/tkt-5-x %s\n' "$SIGNED" | bash "$G" origin x 2>&1; echo "rc=$?")
want_in "a branch deletion"                'rc=0$' "$out"

echo "--- only this PR's own commits give a reason ---"
reset
g checkout -q develop; mkdir -p "$R/lib"; echo s > "$R/lib/other.ts"; g add lib
g commit -qm "feat: another PR's change (#9)" -m "pixel-change-after-signoff: another PR's reason"
g push -q origin develop; g checkout -q tkt-5-x
g merge -q --no-edit -X ours develop >/dev/null 2>&1
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: no reason given"
out=$(guard)
want_in "a reason on the trunk's squash commit does not excuse this push" 'rc=1$' "$out"
want_not_in "and is never shown as this PR's"   "another PR's reason" "$(cat "$GH_LOG")"

echo "--- no merge-base with the trunk (a shallow clone): shut for screens ---"
reset
TRUNK_WAS=$(g rev-parse refs/remotes/origin/develop)
ORPHAN=$(printf 'x' | g commit-tree "$(g mktree </dev/null)" -m orphan)
g update-ref refs/remotes/origin/develop "$ORPHAN"
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: x" -m "pixel-change-after-signoff: y"
out=$(guard)
want_in "a screen change is refused"            'rc=1$' "$out"
want_not_in "and the hold is not touched"       'pr edit' "$(cat "$GH_LOG")"
reset; g update-ref refs/remotes/origin/develop "$ORPHAN"
echo e >> "$R/docs/x.md"; g commit -qam "docs: x"
want_in "a change with no screen still goes"    'rc=0$' "$(guard)"
g update-ref refs/remotes/origin/develop "$TRUNK_WAS"

echo "--- signed by removing the hold on GitHub: no marker, still signed ---"
reset
printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_pulls_7_reviews_per_page_100.json"
printf '[{"event":"unlabeled","label":{"name":"needs:human-approval"},"actor":{"login":"owner","type":"User"},"created_at":"2026-10-17T10:00:00Z"}]\n' \
  > "$FIX/gh/api-repos_acme_widgets_issues_7_events_per_page_100.json"
jq -n --arg s "$SIGNED" '[{sha:$s, commit:{committer:{date:"2026-10-17T09:00:00Z"}}}]' > "$FIX/gh/api-repos_acme_widgets_pulls_7_commits_per_page_100.json"
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: after a label-only sign-off"
out=$(guard)
want_in "refused"                          'rc=1$' "$out"
want_in "against the head then"           "signed PR #7 at ${SIGNED:0:7}" "$out"
printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_pulls_7_commits_per_page_100.json"
out=$(guard)
want_in "a removal no commit places: still refused" 'rc=1$' "$out"
want_in "against the remote's head"        "label removal no commit could place" "$out"

echo "--- unreadable: shut for screens, open for the rest ---"
reset; touch "$FIX/gh/fail-api"
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: x"
out=$(guard)
want_in "sign-offs unreadable, screen change: refused" 'rc=1$' "$out"
want_in "saying so"                        "sign-offs could not be read" "$out"
reset; touch "$FIX/gh/fail-prlist"
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: x"
want_in "PR unreadable, screen change: refused" 'rc=1$' "$(guard)"
reset; touch "$FIX/gh/fail-prlist"
echo e >> "$R/docs/x.md"; g commit -qam "docs: x"
want_in "PR unreadable, no screen: goes"   'rc=0$' "$(guard)"

echo "--- through a real pre-push hook ---"
reset
mkdir -p "$FIX/hooks"
printf '#!/usr/bin/env bash\nbash "%s" "$@" || exit 1\n' "$G" > "$FIX/hooks/pre-push"; chmod +x "$FIX/hooks/pre-push"
g config core.hooksPath "$FIX/hooks"
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: after sign-off"
(cd "$R" && git push -q origin HEAD:refs/heads/tkt-5-x >/dev/null 2>&1); prc=$?
want "git refuses the push"                "1" "$([ "$prc" -ne 0 ] && echo 1 || echo 0)"
want "and the branch on origin is still the signed head" "$SIGNED" "$(git --git-dir="$FIX/origin.git" rev-parse tkt-5-x)"
g commit -q --amend -m "fix: after sign-off" -m "pixel-change-after-signoff: the owner asked for it"
(cd "$R" && git push -q origin HEAD:refs/heads/tkt-5-x >/dev/null 2>&1); prc=$?
want "with the trailer it goes"            "0" "$prc"
want "and lands"                           "$(g rev-parse HEAD)" "$(git --git-dir="$FIX/origin.git" rev-parse tkt-5-x)"
want_in "with the hold back on"            '^pr edit 7 .*--add-label needs:human-approval$' "$(cat "$GH_LOG")"

suite_end "$FAILED"
