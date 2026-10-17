#!/usr/bin/env bash
# signoff-push-guard.test.sh — sign-off comes last. On a branch whose PR carries an
# approval-head record, a push that changes a screen after that head is refused
# without a `pixel-change-after-signoff: <why>` trailer; with one, the hold goes
# back on, the PR gets a before/after comment and the owner's batch a lane-hold
# line. What was signed, a trunk merge that resolves nothing, a test file, a PR
# never signed and a push with no PR all go. Unreadable sign-offs fail shut, for
# screens only. The last case pushes through a real pre-push hook.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
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
haspr() { printf '[{"number":7}]\n' > "$FIX/gh/prlist.json"; }
nopr()  { printf '[]\n' > "$FIX/gh/prlist.json"; }
reset() { g reset -q --hard "$SIGNED"; : > "$GH_LOG"; rm -f "$FIX/gh/fail-"*; rm -f "$WORK"; haspr; signed "$SIGNED"; }
guard() { # [remote-sha] — push HEAD to tkt-5-x; prints stderr, exit code on the last line
  local l r out rc
  l=$(g rev-parse HEAD); r="${1:-$BASE_REMOTE}"
  out=$(cd "$R" && printf 'refs/heads/tkt-5-x %s refs/heads/tkt-5-x %s\n' "$l" "$r" | bash "$G" origin "$FIX/origin.git" 2>&1); rc=$?
  printf '%s\nrc=%s' "$out" "$rc"
}

echo "--- a screen change after sign-off, without the trailer, is refused ---"
reset
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: tighten the page"
out=$(guard)
want_in "refused"                          'rc=1$' "$out"
want_in "it says sign-off comes last"      'sign-off comes last' "$out"
want_in "it names the commit and the file" "$(g rev-parse --short=7 HEAD) fix: tighten the page — apps/web/page.tsx" "$out"
want_in "and the trailer that lets it go"  'pixel-change-after-signoff: <why>' "$out"
want_not_in "the hold is not touched"      'pr edit' "$(cat "$GH_LOG")"

echo "--- with the trailer: allowed, and the hold goes back on ---"
reset
echo c >> "$R/apps/web/page.tsx"
g commit -qam "fix: the red check needs a wider column" -m "pixel-change-after-signoff: the typecheck fix widens the column"
AFTER=$(g rev-parse HEAD)
out=$(COORDINATOR_SHADOW=1 guard)
want_in "allowed"                          'rc=0$' "$out"
want_in "the hold is re-added to the PR"   '^pr edit 7 --repo acme/widgets --add-label needs:human-approval$' "$(cat "$GH_LOG")"
want_in "and to its ticket"                '^issue edit 5 --repo acme/widgets --add-label needs:human-approval$' "$(cat "$GH_LOG")"
want_in "the PR gets a before/after"       "pr comment 7 .*Before:\*\* the signed head \`${SIGNED:0:7}\`" "$(tr '\n' ' ' < "$GH_LOG")"
want_in "naming the new head and compare"  "After:\*\* \`${AFTER:0:7}\` — https://github.com/acme/widgets/compare/$SIGNED...$AFTER" "$(cat "$GH_LOG")"
want_in "and why"                          'Why:\*\* the typecheck fix widens the column' "$(cat "$GH_LOG")"
want_in "the owner's batch gets the line"  "lane-hold:7:${AFTER:0:7}	PR #7 needs your sign-off again: changed after sign-off — before ${SIGNED:0:7}, after ${AFTER:0:7} \(apps/web/page.tsx\)" "$(cat "$WORK" 2>/dev/null)"

echo "--- a trailer on one commit does not cover another ---"
reset
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: one" -m "pixel-change-after-signoff: needed"
echo d >> "$R/apps/web/page.tsx"; g commit -qam "fix: two"
out=$(guard)
want_in "refused"                          'rc=1$' "$out"
want_in "naming the bare commit"           'fix: two' "$out"
want_not_in "not the one that said why"    'fix: one' "$out"

echo "--- the hold cannot be put back: refused ---"
reset; touch "$FIX/gh/fail-edit"
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: x" -m "pixel-change-after-signoff: needed"
want_in "refused"                          'rc=1$' "$(guard)"

echo "--- what goes ---"
reset
echo t > "$R/apps/web/page.test.ts"; echo e >> "$R/docs/x.md"; g add -A; g commit -qm "test: more"
out=$(guard)
want_in "a test and a doc after sign-off"  'rc=0$' "$out"
want "and GitHub is not asked"             "" "$(cat "$GH_LOG")"
reset; nopr
echo c >> "$R/apps/web/page.tsx"; g commit -qam "feat: more"
want_in "a screen change with no PR"       'rc=0$' "$(guard)"
reset; signed -
echo c >> "$R/apps/web/page.tsx"; g commit -qam "feat: more"
want_in "a screen change on a PR never signed" 'rc=0$' "$(guard)"
reset
want_in "the signed head itself, pushed new" 'rc=0$' "$(guard 0000000000000000000000000000000000000000)"
reset
echo c >> "$R/apps/web/page.tsx"; g commit -qam "fix: x"
out=$(cd "$R" && printf 'refs/heads/tkt-5-x 0000000000000000000000000000000000000000 refs/heads/tkt-5-x %s\n' "$SIGNED" | bash "$G" origin x 2>&1; echo "rc=$?")
want_in "a branch deletion"                'rc=0$' "$out"

echo "--- a trunk merge: only what its resolution changed counts ---"
g checkout -q develop; echo z > "$R/apps/web/other.tsx"; echo a2 > "$R/apps/web/page.tsx"; g add -A; g commit -qm "trunk: another ticket"
g push -q origin develop; TRUNK=$(g rev-parse HEAD); g checkout -q tkt-5-x
reset
g merge -q --no-edit -X ours "$TRUNK" 2>/dev/null
want_in "a merge that keeps the signed screen" 'rc=0$' "$(guard)"
reset
g merge -q --no-edit "$TRUNK" >/dev/null 2>&1
printf 'a\nb\nresolved\n' > "$R/apps/web/page.tsx"; g add -A; g commit -qm "merge develop" --no-edit
want_in "a resolution that edits the signed screen" 'rc=1$' "$(guard)"
g checkout -q tkt-5-x

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

exit "$FAILED"
