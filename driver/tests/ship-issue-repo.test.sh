#!/usr/bin/env bash
# ship-issue-repo.test.sh — a repo built from another project's queue (issueRepo) ships:
# every call about the ticket goes to the queue's repo, every call about the pull request
# to the code's own.
#
# The first ticket built in a clone passed every step and then looped at ship: the read
# of a person's stop asked the code repo for the TICKET's comments, the ticket is not
# there, and "could not be read" requeued it on every tick. `gh issue` calls were already
# sent to the queue (gh_call); a REST path naming the repo was not.
#
# The stand-in GitHub here answers as the real one does: the ticket exists only in the
# queue's repo, the pull request only in the code's.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
# This repo is acme/widgets; its tickets are filed in acme/queue.
jq '.issueRepo = "acme/queue"' "$HARNESS_CFG_PATH" > "$FIX/cfg.tmp" && cat "$FIX/cfg.tmp" > "$HARNESS_CFG_PATH"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "tickets live in another repo's queue"

# Ticket 901 is in acme/queue alone; pull request 42 in acme/widgets alone. A call about
# either aimed at the other repo is refused, as a 404 is.
cat > "$BIN/gh-two-repos" <<'SH'
#!/usr/bin/env bash
wrong() { printf '%s\n' "$*" >> "$FIX/wrong-repo.log"; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
repo=""; prev=""
for a in "$@"; do case "$prev" in --repo|-R) repo="$a" ;; esac; prev="$a"; done
case "$1" in
  issue) [ "$repo" = acme/queue ] || wrong "$@" ;;
  pr)    [ "$repo" = acme/widgets ] || wrong "$@" ;;
  api)
    for a in "$@"; do
      case "$a" in
        repos/acme/widgets/issues/901|repos/acme/widgets/issues/901[/?]*) wrong "$@" ;;
        repos/acme/queue/issues/42|repos/acme/queue/issues/42[/?]*|repos/acme/queue/pulls/*) wrong "$@" ;;
      esac
    done ;;
esac
exec "$BIN/gh" "$@"
SH
chmod +x "$BIN/gh-two-repos"; : > "$FIX/wrong-repo.log"
export SWARM_GH="$BIN/gh-two-repos"
printf '[]\n' > "$FIX/gh/api-repos_acme_queue_issues_901_comments_per_page_100.json"
printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_issues_42_comments_per_page_100.json"
printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_issues_42_timeline_per_page_100.json"
printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_pulls_42_reviews_per_page_100.json"
printf '{"number":42,"draft":true,"labels":[],"user":{"login":"tester"}}\n' > "$FIX/gh/api-repos_acme_widgets_pulls_42.json"

# The real read of a person's stop, not the fixture's stand-in: it is the call under test.
unset DRIVER_PERSON_STOP
. "$HERE/../steps/ship.sh" || exit 1
want "the kit reads the two repos apart" "acme/widgets acme/queue" "$REPO_SLUG $ISSUE_REF"

git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop
WT="$FIX/wt901"
git -C "$REPO" worktree add -q "$WT" -b "tkt-901/work" develop
printf 'change\n' > "$WT/f901.txt"
git -C "$WT" add f901.txt; git -C "$WT" commit -qm "feat: thing 901"
driver_state_init 901 --worktree "$WT" --branch "tkt-901/work"; fix_gates_kept 901
driver_state_set 901 claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
fix_issue 901 OPEN "status:claimed"
driver_state_put 901 review '{"verdict":"SHIP","findings":[]}'
driver_state_bump 901 review
for st in start plan build self-check review record; do driver_state_done 901 "$st"; done
# The pull request is open on the branch, as a parked or earlier run left it: the read of
# a person's stop then covers the ticket and the pull request both.
: > "$FIX/pr-created-tkt-901_work"
printf '[{"number":42,"headRefName":"tkt-901/work","headRefOid":"abc","isDraft":true}]\n' > "$FIX/gh/prs.json"

calls() { grep -E "^$1( |\$)" "$GH_LOG"; }
echo "--- the ticket in one repo, the pull request in another: ship readies and arms it ---"
: > "$GH_LOG"
out=$(driver_step_ship 901 2>&1); rc=$?
want "ship finishes" "0" "$rc"
want_not_in "the person's stop was read, not 'could not be read'" 'could not be read' "$out"
want "no call about the ticket or the pull request went to the wrong repo" "" "$(cat "$FIX/wrong-repo.log")"

echo "--- each call names the repo its subject lives in ---"
want_in "the ticket's comments are read in the queue's repo" '^api .*repos/acme/queue/issues/901/comments' "$(cat "$GH_LOG")"
want_not_in "never in the code's" 'repos/acme/widgets/issues/901' "$(cat "$GH_LOG")"
want_in "the pull request's comments are read in the code's repo" '^api .*repos/acme/widgets/issues/42/comments' "$(cat "$GH_LOG")"
want_in "its reviews too" '^api .*repos/acme/widgets/pulls/42/reviews' "$(cat "$GH_LOG")"
want_not_in "never in the queue's" 'repos/acme/queue/(issues/42|pulls)' "$(cat "$GH_LOG")"
want "every issue call names the queue's repo" "" "$(calls issue | grep -v -- '--repo acme/queue')"
want "every pr call names the code's repo" "" "$(calls pr | grep -v -- '--repo acme/widgets')"
want_in "the pull request is marked ready in the code's repo" '^pr ready tkt-901/work --repo acme/widgets' "$(cat "$GH_LOG")"
want_in "auto-merge is armed there" '^pr merge tkt-901/work --repo acme/widgets --auto --squash' "$(cat "$GH_LOG")"
want_in "the hand-off comment goes on the ticket, in the queue's repo" '^issue comment 901 --repo acme/queue' "$(cat "$GH_LOG")"
want_in "the body closes the ticket by its repo, never a bare number" 'Closes acme/queue#901' "$(tr '\n' ' ' < "$GH_LOG")"
want_not_in "no bare closing reference" 'Closes #901' "$(tr '\n' ' ' < "$GH_LOG")"

echo "--- the read of a person's stop, by itself ---"
: > "$GH_LOG"; : > "$FIX/wrong-repo.log"
rc=0; out=$(bash "$HERE/../../scripts/person-stop.sh" check 901 42 2>&1) || rc=$?
want "nobody stopped it, and that could be read" "0" "$rc"
want "the ticket was asked of the queue's repo, the pull request of the code's" \
  "repos/acme/queue/issues/901/comments?per_page=100 repos/acme/widgets/issues/42/comments?per_page=100" \
  "$(grep -oE 'repos/[^ ]+/issues/[0-9]+/comments[^ ]*' "$GH_LOG" | sort -u | tr '\n' ' ' | sed 's/ $//')"

echo "--- one repo for both: nothing moves ---"
rc=0; out=$( unset ISSUE_REF ISSUE_SLUG; : > "$GH_LOG"
             printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_issues_77_comments_per_page_100.json"
             printf '{"number":77,"labels":[]}\n' > "$FIX/gh/issue-77.json"
             jq 'del(.issueRepo)' "$HARNESS_CFG_PATH" > "$FIX/one.json"
             HARNESS_CFG_PATH="$FIX/one.json" SWARM_GH="$BIN/gh" bash "$HERE/../../scripts/person-stop.sh" check 77 2>&1
             grep -oE 'repos/[^ ]+/issues/77/comments' "$GH_LOG" | sort -u ) || rc=$?
want "the ticket's comments are read in the one repo" "repos/acme/widgets/issues/77/comments" "$out"

suite_end "$FAILED"
