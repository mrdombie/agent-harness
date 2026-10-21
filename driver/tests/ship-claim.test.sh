#!/usr/bin/env bash
# ship-claim.test.sh — a run that hands off is not a run that died, and the ticket
# must not be told it did. The real claim lock, the real ship step and the real
# reconciler, against a bare origin in the fixture and a gh that remembers labels.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/ship.sh" || exit 1
CLK="$HERE/../../scripts/claim-lock.sh"
R="$HERE/../../scripts/reconcile-claims.sh"
export CL="$CLK" CLAIM_REMOTE=origin NOTIFY=0
export GIT_AUTHOR_NAME=f GIT_AUTHOR_EMAIL=f@x GIT_COMMITTER_NAME=f GIT_COMMITTER_EMAIL=f@x

git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop

# The fixture's gh, plus the three things the reconciler reads back: an edit moves the
# labels on the ticket's file, a label list answers from those files, and the open
# pull request for a branch comes from $FIX/gh/open-<branch>.
mv "$BIN/gh" "$BIN/gh-base"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue edit")
    printf '%s\n' "$*" >> "$GH_LOG"
    [ -f "$FIX/gh-fail" ] && grep -qxF "issue edit" "$FIX/gh-fail" && { echo "gh: refused (induced)" >&2; exit 1; }
    f="$FIX/gh/issue-$3.json"; [ -f "$f" ] || exit 1
    shift 3; prev=""
    for a in "$@"; do
      case "$prev" in
        --add-label)    jq --arg l "$a" '.labels = ((.labels | map(select(.name != $l))) + [{name:$l}])' "$f" > "$f.t" && mv "$f.t" "$f" ;;
        --remove-label) jq --arg l "$a" '.labels |= map(select(.name != $l))' "$f" > "$f.t" && mv "$f.t" "$f" ;;
      esac
      prev="$a"
    done
    exit 0 ;;
  "issue list")
    printf '%s\n' "$*" >> "$GH_LOG"
    want=""; prev=""; for a in "$@"; do [ "$prev" = --label ] && want="$a"; prev="$a"; done
    for f in "$FIX"/gh/issue-*.json; do
      jq -r --arg l "$want" 'select(.state == "OPEN" and any(.labels[]; .name == $l)) | .number' "$f"
    done
    exit 0 ;;
  "pr list")
    head=""; prev=""; for a in "$@"; do [ "$prev" = --head ] && head="$a"; prev="$a"; done
    o="$FIX/gh/open-$(printf '%s' "$head" | tr '/' '_')"
    if [ -n "$head" ] && [ -f "$o" ]; then printf '%s\n' "$*" >> "$GH_LOG"; cat "$o"; exit 0; fi ;;
esac
exec "$(dirname "$0")/gh-base" "$@"
SH
chmod +x "$BIN/gh"

DEADPID=$( (exec sh -c 'echo $$') )
while kill -0 "$DEADPID" 2>/dev/null; do DEADPID=$((DEADPID + 1)); done

ref_present() { git -C "$REPO" ls-remote origin "refs/claims/$1" 2>/dev/null | grep -q . && echo yes || echo no; }
labels() { jq -r '[.labels[].name] | join(",")' "$FIX/gh/issue-$1.json"; }
# spawn-claim's post-exit reconcile: the run's session pid is named as exited.
reconcile() { ( cd "$REPO" && CLAIM_REPO="$REPO" CLAIM_EXITED_PID="$DEADPID" bash "$R" 2>&1 ); }
setup() { # <ticket>
  local t=$1 wt="$FIX/wt$1"
  git -C "$REPO" worktree add -q "$wt" -b "tkt-$t/work" develop
  printf 'change for %s\n' "$t" > "$wt/f$t.txt"
  git -C "$wt" add "f$t.txt"; git -C "$wt" commit -qm "feat: thing $t"
  driver_state_init "$t" --worktree "$wt" --branch "tkt-$t/work"
  driver_state_set "$t" claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
  fix_issue "$t" OPEN "status:claimed"
  bash "$CLK" acquire "$t" --branch "tkt-$t/work" --worktree "$wt" --pid "$DEADPID" >/dev/null 2>&1
}

echo "--- a run that ships and hands off frees its own claim, and nothing calls it gone ---"
setup 601
want "the claim is held before the ship" "yes" "$(ref_present 601)"
driver_state_put 601 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 601 review
for st in start plan build self-check review record; do driver_state_done 601 "$st"; done
out=$(driver_step_ship 601 2>&1); rc=$?
want "it ships" "0" "$rc"
want_in "and hands off" 'issue comment 601 .*Handed off at' "$(cat "$GH_LOG")"
want "the claim is freed by the run itself" "no" "$(ref_present 601)"
want "the ticket is in review"              "status:in-review" "$(labels 601)"
printf '[{"number":42,"state":"OPEN"}]\n' > "$FIX/gh/open-tkt-601_work"
: > "$GH_LOG"
out=$(reconcile)
want_not_in "the reconciler posts no failure wording" 'is gone' "$(cat "$GH_LOG")"
want_not_in "and no claim-released note at all"       'issue comment 601' "$(cat "$GH_LOG")"
want "the ticket stays in review"                     "status:in-review" "$(labels 601)"

echo "--- in review could not be set: the claim stays, never back to ready ---"
setup 602
driver_state_put 602 review '{"verdict":"SHIP","findings":[]}'; driver_state_bump 602 review
fix_gh_fail "issue edit"
out=$(driver_step_ship 602 2>&1); rc=$?
fix_gh_ok
want "it still ships" "0" "$rc"
want "the claim is kept for the reconciler" "yes" "$(ref_present 602)"
want_not_in "and the ticket is not offered again" 'status:ready' "$(labels 602)"

echo "--- a holder that dies with no ending keeps today's wording ---"
setup 603
git -C "$FIX/wt603" push -q origin tkt-603/work
printf '[{"number":43,"state":"OPEN"}]\n' > "$FIX/gh/open-tkt-603_work"
: > "$GH_LOG"
out=$(reconcile)
want_in "the dead holder is reported as gone" 'issue comment 603 .*Claim released, ticket not.*The agent holding this is gone' "$(tr '\n' ' ' < "$GH_LOG")"
want "its claim is freed"                     "no" "$(ref_present 603)"
want "and it is marked in review"             "status:in-review" "$(labels 603)"

exit "$FAILED"
