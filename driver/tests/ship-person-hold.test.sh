#!/usr/bin/env bash
# ship-person-hold.test.sh — a person's hold label on the ticket at ship stops the
# hand-off. needs:owner-decision or needs:human-approval put on after the step loop's
# own read (while ship runs): nothing is readied or armed, the run parks with cause
# hold, and park takes an already ready, armed PR back to draft with auto-merge off
# (driver-draft.sh), its note naming the label, who and when. A clean ticket ships.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
for _v in $(env | sed -nE 's/^((DRIVER|HARNESS|SWARM|CLAIM)_[A-Z0-9_]*)=.*/\1/p'); do unset "$_v"; done; unset KIT_ROOT
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
BT="$HERE/../build-ticket"
. "$HERE/../driver-env.sh" || exit 1
. "$HERE/../state.sh" || exit 1
# The real read of a person's stop and the real draft: they are the calls under test.
# The step loop's own hold read is the fixture's (clear): the label lands after it.
unset DRIVER_PERSON_STOP DRIVER_DRAFT
cat > "$FIX/queue-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/queue.log"
SH
chmod +x "$FIX/queue-stub.sh"; export DRIVER_QUEUE="$FIX/queue-stub.sh"

# GitHub's pull request moves as the calls move it: --disable-auto disarms, --undo drafts, ready readies.
cat > "$BIN/gh-pr" <<'SH'
#!/usr/bin/env bash
pj="$FIX/gh/api-repos_acme_widgets_pulls_42.json"
case " $* " in
  *" pr merge "*" --disable-auto "*) jq '.auto_merge = null' "$pj" > "$pj.t" && mv "$pj.t" "$pj" ;;
  *" pr merge "*" --auto "*)         jq '.auto_merge = {merge_method:"squash"}' "$pj" > "$pj.t" && mv "$pj.t" "$pj" ;;
  *" pr ready "*" --undo "*)         jq '.draft = true' "$pj" > "$pj.t" && mv "$pj.t" "$pj" ;;
  *" pr ready "*)                    jq '.draft = false' "$pj" > "$pj.t" && mv "$pj.t" "$pj" ;;
esac
exec "$BIN/gh" "$@"
SH
chmod +x "$BIN/gh-pr"; export SWARM_GH="$BIN/gh-pr"

CL="$HERE/../../scripts/claim-lock.sh"
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"; git -C "$REPO" push -q origin develop

reach_ship() { # <ticket> <hold label or ""> — review SHIP, an open PR ready with auto-merge armed
  local t="$1" hold="$2" wt="$FIX/wt$1"
  : > "$GH_LOG"; : > "$CLAUDE_LOG"; rm -f "$FIX/queue.log"; fix_gh_ok
  git -C "$REPO" worktree add -q "$wt" -b "tkt-$t/work" develop
  printf 'change\n' > "$wt/f$t.txt"; git -C "$wt" add "f$t.txt"; git -C "$wt" commit -qm "feat: thing $t"
  rm -rf "$STATE/driver/$t"
  driver_state_init "$t" --worktree "$wt" --branch "tkt-$t/work"; fix_gates_kept "$t"
  driver_state_set "$t" claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
  driver_state_set "$t" pr 42
  driver_state_put "$t" review '{"verdict":"SHIP","findings":[]}'
  driver_state_bump "$t" review
  for st in start plan build self-check review record; do driver_state_done "$t" "$st"; done
  fix_issue "$t" OPEN "status:claimed${hold:+,$hold}"
  printf '[{"event":"labeled","label":{"name":"%s"},"actor":{"login":"dom"},"created_at":"2026-11-14T10:00:00Z"}]\n' "${hold:-none}" \
    > "$FIX/gh/api-repos_acme_widgets_issues_${t}_timeline_per_page_100.json"
  printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_issues_${t}_comments_per_page_100.json"
  printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_issues_42_comments_per_page_100.json"
  printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_issues_42_timeline_per_page_100.json"
  printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_pulls_42_reviews_per_page_100.json"
  printf '{"number":42,"state":"open","draft":false,"auto_merge":{"merge_method":"squash"},"labels":[],"user":{"login":"tester"}}\n' \
    > "$FIX/gh/api-repos_acme_widgets_pulls_42.json"
  : > "$FIX/pr-created-tkt-${t}_work"
  printf '[{"number":42,"headRefName":"tkt-%s/work","headRefOid":"abc","isDraft":false}]\n' "$t" > "$FIX/gh/prs.json"
  bash "$CL" acquire "$t" --branch "tkt-$t/work" >/dev/null 2>&1
}
bt() { bash "$BT" "$@" --steps "ship" 2>&1; }
log() { cat "$GH_LOG"; }

t=900
for hold in needs:owner-decision needs:human-approval; do
  t=$((t + 1))
  echo "--- $hold on the ticket at ship: nothing readied or armed; the PR goes back to draft ---"
  reach_ship "$t" "$hold"
  out=$(bt "$t"); rc=$?
  want "it parks" "20" "$rc"
  want_not_in "no 'pr ready' that readies it" '^pr ready tkt-' "$(log)"
  want_not_in "no 'pr merge --auto'" '^pr merge .*--auto( |$)' "$(log)"
  want_in "auto-merge is disarmed on the PR" '^pr merge 42 .*--disable-auto' "$(log)"
  want_in "and it is converted to draft" '^pr ready 42 .*--undo' "$(log)"
  want_in "the park note names the label, who and when" "Held by a person: $hold, put on by dom at 2026-11-14T10:00:00Z" "$(log)"
  want_not_in "no PM marker: the label's removal resumes it" 'add-label (status:pm-decision|status:parked)' "$(log)"
done

echo "--- a ticket with neither label ships as before: ready and armed ---"
reach_ship 910 ""
jq '.draft = true | .auto_merge = null' "$FIX/gh/api-repos_acme_widgets_pulls_42.json" > "$FIX/pj" && mv "$FIX/pj" "$FIX/gh/api-repos_acme_widgets_pulls_42.json"
out=$(bt 910); rc=$?
want "it ships" "0" "$rc"
want_in "the PR is readied" '^pr ready tkt-910/work' "$(log)"
want_in "and armed" '^pr merge tkt-910/work .*--auto --squash' "$(log)"
want_not_in "nothing disarms it" 'disable-auto' "$(log)"

suite_end "$FAILED"
