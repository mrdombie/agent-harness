#!/usr/bin/env bash
# park.test.sh — parking is the refusal path, and it has one job: leave the work
# recoverable by somebody who is not this process. Push first — an unpushed
# branch is the only thing a park can actually lose — then a draft PR so the
# reconciler reads it as in-review, then the brief, then the label, then release
# the claim, in that order.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/park.sh" || exit 1
git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop
# ONE ORDERED LOG FOR EVERY CALL OUT OF THE PROCESS. The order is what this step
# exists for, and it cannot be expressed across two files: with gh calls in one and
# claim-lock calls in another, `tail -1 "$RELEASES"` is ALWAYS the release, because
# park makes exactly one claim-lock call. The assertion was structurally true —
# moving the release to the very first line of driver_park left the suite green.
ORDER="$FIX/order.log"; : > "$ORDER"; export ORDER
RELEASES="$FIX/releases"; : > "$RELEASES"
cat > "$BIN/claim-lock" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RELEASES"
printf 'claim-lock %s\n' "$*" >> "$ORDER"
SH
chmod +x "$BIN/claim-lock"; export CL="$BIN/claim-lock" RELEASES
# gh and git go into the same log, in the order they are called.
cat > "$BIN/gh-order" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$ORDER"
exec "$BIN/gh" "$@"
SH
cat > "$BIN/git" <<'SH'
#!/usr/bin/env bash
case " $* " in *" push "*) printf 'git push\n' >> "$ORDER" ;; esac
exec /usr/bin/git "$@"
SH
chmod +x "$BIN/gh-order" "$BIN/git"; export SWARM_GH="$BIN/gh-order"
# bash caches where it found a command. `git` was already called above, so the cache
# holds /usr/bin/git and the shim created after it is never reached — `command -v git`
# answers /usr/bin/git with the shim sitting first on PATH. Drop the cache.
hash -r 2>/dev/null || true

git -C "$REPO" worktree add -q "$FIX/wt101" -b tkt-101/work develop
printf 'half\n' > "$FIX/wt101/half.txt"
driver_state_init 101 --worktree "$FIX/wt101" --branch tkt-101/work
fix_issue 101 OPEN "status:claimed"

echo "--- a park pushes, opens a draft, briefs, labels, then releases ---"
out=$(driver_park 101 "the plan asked a question" "which table owns the org id?" 2>&1); rc=$?
want "park reports parked"  "20" "$rc"
want "the branch reached origin" "1" \
  "$(git -C "$FIX/origin" rev-parse --verify tkt-101/work >/dev/null 2>&1 && echo 1)"
want "even the uncommitted work" "1" \
  "$(git -C "$FIX/origin" show tkt-101/work:half.txt >/dev/null 2>&1 && echo 1)"
want_in "a DRAFT pr, so the reconciler reads it as in-review" 'pr create.*--draft' "$(cat "$GH_LOG")"
want_in "the resume brief is a comment"  'issue comment 101' "$(cat "$GH_LOG")"
want_in "it names what was built"        'Built' "$(cat "$GH_LOG")"
want_in "where it stopped"               'Stopped at' "$(cat "$GH_LOG")"
want_in "and the question, answerable in a line" 'which table owns the org id' "$(cat "$GH_LOG")"
want_in "how to resume"                  'Resume' "$(cat "$GH_LOG")"
want_in "the hold label goes on"         'needs:human-approval' "$(cat "$GH_LOG")"
want_in "and the claim is released"      'release 101' "$(cat "$RELEASES")"

echo "--- the ORDER, which is the whole design: push · draft · brief · label · release ---"
# Asserted as a sequence over every outside call, so a step moved out of place fails.
# The rule is not "a release happens"; it is that everything else is already true when
# it does, because a ref dropped early is a ticket a peer takes mid-park.
seq=$(sed -e 's/^git push.*/PUSH/' \
          -e 's/^gh pr create.*/DRAFT/' \
          -e 's/^gh issue comment.*/BRIEF/' \
          -e 's/^gh issue edit.*/LABEL/' \
          -e 's/^claim-lock release.*/RELEASE/' "$ORDER" \
      | grep -E '^(PUSH|DRAFT|BRIEF|LABEL|RELEASE)$' | tr '\n' ' ' | sed 's/ $//')
want "the order is exactly the design's" "PUSH DRAFT BRIEF LABEL RELEASE" "$seq"
want "and the release is last of all"    "RELEASE" "$(printf '%s' "$seq" | awk '{print $NF}')"

echo "--- a park with nothing to push still parks ---"
: > "$GH_LOG"; : > "$RELEASES"; : > "$ORDER"
driver_state_init 202
fix_issue 202 OPEN "status:claimed"
out=$(driver_park 202 "start refused" "the ticket is gated" 2>&1); rc=$?
want "it still parks"               "20" "$rc"
want_in "and still leaves a brief"  'issue comment 202' "$(cat "$GH_LOG")"
want_in "and still releases"        'release 202' "$(cat "$RELEASES")"
want_not_in "no PR for a branchless park" 'pr create' "$(cat "$GH_LOG")"

echo "--- the reason reaches the brief ---"
want_in "the reason is in the comment" 'start refused' "$(cat "$GH_LOG")"

exit $FAILED
