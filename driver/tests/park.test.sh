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
mkdir -p "$FIX/wt101/apps/web/.next"; printf 'build\n' > "$FIX/wt101/apps/web/.next/out"
driver_state_init 101 --worktree "$FIX/wt101" --branch tkt-101/work
fix_issue 101 OPEN "status:claimed"

echo "--- a park pushes, opens a draft, briefs, labels, then releases ---"
out=$(driver_park 101 "the plan asked a question" "which table owns the org id?" 2>&1); rc=$?
want "park reports parked"  "20" "$rc"
want "the branch reached origin" "1" \
  "$(git -C "$FIX/origin" rev-parse --verify tkt-101/work >/dev/null 2>&1 && echo 1)"
want "even the uncommitted work" "1" \
  "$(git -C "$FIX/origin" show tkt-101/work:half.txt >/dev/null 2>&1 && echo 1)"
want "the worktree's build cache is removed" "gone" "$([ -e "$FIX/wt101/apps/web/.next" ] && echo kept || echo gone)"
want "and never committed into the park" "" \
  "$(git -C "$FIX/origin" ls-tree -r --name-only tkt-101/work | grep '\.next/' || true)"
want_in "a DRAFT pr, so the reconciler reads it as in-review" 'pr create.*--draft' "$(cat "$GH_LOG")"
want_in "the resume brief is a comment"  'issue comment 101' "$(cat "$GH_LOG")"
want_in "it names what was built"        'Built' "$(cat "$GH_LOG")"
want_in "where it stopped"               'Stopped at' "$(cat "$GH_LOG")"
want_in "and the question, answerable in a line" 'which table owns the org id' "$(cat "$GH_LOG")"
want_in "how to resume"                  'Resume' "$(cat "$GH_LOG")"
# A person's question goes through the owner's loop (#177): the owner's label and
# channel, and the answer back on the queue. The hold is pixel sign-off, not this.
want_in "the question reaches the owner's loop" 'issue edit 101 .*--add-label needs:owner-decision' "$(cat "$GH_LOG")"
want_not_in "and the hold label stays off"   'needs:human-approval' "$(cat "$GH_LOG")"
# The answer removes the owner's label; a status:parked beside it would block every spawn.
want_not_in "an asked park adds no status:parked" 'issue edit 101 .*--add-label status:parked' "$(cat "$GH_LOG")"
want_in "and still lets the claim label go" 'issue edit 101 .*--remove-label status:claimed' "$(cat "$GH_LOG")"
want_in "it keeps a status label: needs-human, which its answer lifts" 'issue edit 101 .*--add-label status:needs-human' "$(cat "$GH_LOG")"
want_in "and the claim is released"      'release 101' "$(cat "$RELEASES")"

echo "--- the ORDER, which is the whole design: push · draft · brief · label · release ---"
# Asserted as a sequence over every outside call, so a step moved out of place fails.
# The rule is not "a release happens"; it is that everything else is already true when
# it does, because a ref dropped early is a ticket a peer takes mid-park.
seq=$(sed -e 's/^git push.*/PUSH/' \
          -e 's/^gh issue edit .*needs:owner-decision.*/ASK/' \
          -e 's/^gh issue comment .*Waiting on the owner.*/ASK/' \
          -e 's/^gh pr create.*/DRAFT/' \
          -e 's/^gh issue comment.*/BRIEF/' \
          -e 's/^gh issue edit.*/LABEL/' \
          -e 's/^claim-lock release.*/RELEASE/' "$ORDER" \
      | grep -E '^(PUSH|DRAFT|BRIEF|ASK|LABEL|RELEASE)$' | tr '\n' ' ' | sed 's/ $//')
want "the order is exactly the design's" "PUSH DRAFT BRIEF ASK ASK LABEL RELEASE" "$seq"
want "and the release is last of all"    "RELEASE" "$(printf '%s' "$seq" | awk '{print $NF}')"

echo "--- a park's push carries the project's park escape past a quality gate ---"
# A project's pre-push may let a park's push of a draft branch skip its quality
# gates, keyed on an env var (PARK_PUSH=1 by default, driver.parkPushEnv to rename
# it). Only the driver knows a push is a park; without the escape the hook refuses,
# the work lands in a local bundle, and nothing reaches origin. Seven parks on
# 2026-10-17 ended exactly that way.
HOOKLOG="$FIX/park-hook.log"
park_hook() { # <dir> <honoured var|-> — a pre-push that is red unless <var>=1
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env sh\n'
    printf 'echo "PARK_PUSH=${PARK_PUSH:-} MY_PARK=${MY_PARK:-}" >> "%s"\n' "$HOOKLOG"
    [ "$2" = "-" ] || printf '[ "${%s:-}" = "1" ] && exit 0\n' "$2"
    printf 'echo "✗ format:changed"\nexit 1\n'
  } > "$1/pre-push"
  chmod +x "$1/pre-push"
}
park_tree() { # <ticket> <branch> <base> — a worktree with one commit of wip on it
  git -C "$REPO" worktree add -q "$FIX/wt$1" -b "$2" "$3"
  printf 'wip\n' > "$FIX/wt$1/wip.txt"
  git -C "$FIX/wt$1" add wip.txt; git -C "$FIX/wt$1" commit -qm "wip: $1"
  driver_state_init "$1" --worktree "$FIX/wt$1" --branch "$2"
  fix_issue "$1" OPEN "status:claimed"
}
CFG_KEEP="$FIX/harness.json.keep"; cp "$HARNESS_CFG_PATH" "$CFG_KEEP"
cfg_with() { jq "$1" "$CFG_KEEP" > "$HARNESS_CFG_PATH"; }
on_origin() { git -C "$FIX/origin" rev-parse --verify -q "refs/heads/$1" 2>/dev/null; }
bundles() { find "$FIX/trees/backups" -name '*.bundle' 2>/dev/null | wc -l | tr -d ' '; }

: > "$GH_LOG"; : > "$HOOKLOG"; unset PARK_PUSH MY_PARK
park_tree 303 tkt-303/work develop
park_hook "$FIX/hooks303" PARK_PUSH; git -C "$FIX/wt303" config core.hooksPath "$FIX/hooks303"
rm -rf "$FIX/trees/backups"
out=$(driver_park 303 "the gate stopped it" "" driver 2>&1); rc=$?
want "park reports parked"                    "20" "$rc"
want "the hook was told it is a park"         "PARK_PUSH=1 MY_PARK=" "$(tail -1 "$HOOKLOG")"
want "the branch reached origin"              "$(git -C "$FIX/wt303" rev-parse HEAD)" "$(on_origin tkt-303/work)"
want_in "a draft pr is opened for it"         'pr create.*--draft.*tkt-303/work' "$(cat "$GH_LOG")"
want "and no bundle was needed"               "0" "$(bundles)"

echo "--- the escape's name is the project's: driver.parkPushEnv ---"
: > "$GH_LOG"; : > "$HOOKLOG"
cfg_with '.driver.parkPushEnv = "MY_PARK"'
park_tree 304 tkt-304/work develop
park_hook "$FIX/hooks304" MY_PARK; git -C "$FIX/wt304" config core.hooksPath "$FIX/hooks304"
out=$(export PARK_PUSH=1; driver_park 304 "the gate stopped it" "" driver 2>&1); rc=$?
want "the hook sees the project's name, and not the default" "PARK_PUSH= MY_PARK=1" "$(tail -1 "$HOOKLOG")"
want "the branch reached origin"              "$(git -C "$FIX/wt304" rev-parse HEAD)" "$(on_origin tkt-304/work)"

echo "--- a name that is not an env var name sets nothing, and the park still parks ---"
: > "$HOOKLOG"
cfg_with '.driver.parkPushEnv = "1; rm -rf x"'
park_tree 305 tkt-305/work develop
park_hook "$FIX/hooks305" PARK_PUSH; git -C "$FIX/wt305" config core.hooksPath "$FIX/hooks305"
out=$(driver_park 305 "the gate stopped it" "" driver 2>&1); rc=$?
want "park reports parked"                    "20" "$rc"
want "nothing was set"                        "PARK_PUSH= MY_PARK=" "$(tail -1 "$HOOKLOG")"
want_in "and the park says why"               'parkPushEnv' "$out"
want "the work is bundled instead"            "1" "$([ "$(bundles)" -ge 1 ] && echo 1)"
cp "$CFG_KEEP" "$HARNESS_CFG_PATH"

echo "--- never on a trunk: a park of a trunk branch pushes without the escape ---"
: > "$HOOKLOG"; rm -rf "$FIX/trees/backups"
cfg_with '.trunks = ["develop", "uat"]'
park_tree 306 uat develop
park_hook "$FIX/hooks306" PARK_PUSH; git -C "$FIX/wt306" config core.hooksPath "$FIX/hooks306"
out=$(export PARK_PUSH=1; driver_park 306 "the gate stopped it" "" driver 2>&1); rc=$?
want "the hook is not told it is a park, even inherited" "PARK_PUSH= MY_PARK=" "$(tail -1 "$HOOKLOG")"
want "the trunk is not pushed"                "" "$(on_origin uat)"
want "and the work is bundled"                "1" "$([ "$(bundles)" -ge 1 ] && echo 1)"
cp "$CFG_KEEP" "$HARNESS_CFG_PATH"

echo "--- an escape the project refuses still leaves a bundle ---"
: > "$GH_LOG"; : > "$HOOKLOG"; rm -rf "$FIX/trees/backups"
park_tree 307 tkt-307/work develop
park_hook "$FIX/hooks307" -; git -C "$FIX/wt307" config core.hooksPath "$FIX/hooks307"
out=$(driver_park 307 "the gate stopped it" "" driver 2>&1); rc=$?
want "the escape was offered"                 "PARK_PUSH=1 MY_PARK=" "$(tail -1 "$HOOKLOG")"
want "the branch is not on origin"            "" "$(on_origin tkt-307/work)"
want_in "the park says the push failed"       'could not be pushed' "$out"
want "and the commits are bundled"            "1" "$(bundles)"
want_not_in "no draft pr for a branch that is not there" 'pr create.*tkt-307/work' "$(cat "$GH_LOG")"
for n in 303 304 305 306 307; do git -C "$FIX/wt$n" config --unset core.hooksPath; done

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

echo "--- a repair parks WITHOUT pushing: its PR may have auto-merge armed ---"
git -C "$REPO" worktree add -q "$FIX/wt150" -b tkt-150/work develop
git -C "$FIX/wt150" push -q origin tkt-150/work; ORIG=$(git -C "$FIX/wt150" rev-parse HEAD)
printf 'half a repair\n' > "$FIX/wt150/r.txt"
driver_state_init 150 --worktree "$FIX/wt150" --branch tkt-150/work
driver_state_set 150 mode repair; driver_state_set 150 pr 91
fix_issue 150 OPEN "status:in-review"; : > "$ORDER"
out=$(driver_park 150 "the review blocked the repair" "is the reviewer right?" 2>&1); rc=$?
want "park reports parked"                 "20" "$rc"
want "origin keeps the PR's head"          "$ORIG" "$(git -C "$FIX/origin" rev-parse tkt-150/work)"
want_not_in "nothing was pushed"           'git push' "$(cat "$ORDER")"
want_not_in "no draft PR is opened"        'pr create' "$(cat "$ORDER")"
want "the work is committed locally"       "" "$(git -C "$FIX/wt150" status --porcelain)"
want_in "the brief says where the repair is, and why it was not pushed" 'auto-merge' "$(cat "$GH_LOG")"
want_in "and the claim is still released"  'release 150' "$(cat "$ORDER")"

echo "--- a park never commits a merge in progress: that would commit its conflict markers ---"
git -C "$REPO" worktree add -q "$FIX/wt151" -b tkt-151/work develop
printf 'branch\n' > "$FIX/wt151/clash.txt"; git -C "$FIX/wt151" add clash.txt; git -C "$FIX/wt151" commit -qm "feat: ours"
git -C "$FIX/wt151" push -q origin tkt-151/work
git -C "$FIX/wt151" checkout -q -b side151 develop; printf 'trunk\n' > "$FIX/wt151/clash.txt"; git -C "$FIX/wt151" add clash.txt; git -C "$FIX/wt151" commit -qm "trunk side"
SIDE=$(git -C "$FIX/wt151" rev-parse HEAD); git -C "$FIX/wt151" checkout -q tkt-151/work
git -C "$FIX/wt151" merge -q "$SIDE" >/dev/null 2>&1
BEFORE=$(git -C "$FIX/wt151" rev-parse HEAD)
driver_state_init 151 --worktree "$FIX/wt151" --branch tkt-151/work
driver_state_set 151 mode repair; driver_state_set 151 pr 94
fix_issue 151 OPEN "status:in-review"
out=$(driver_park 151 "the repair step produced no answer" "" driver 2>&1); rc=$?
want "park reports parked"                 "20" "$rc"
want "no commit was made"                  "$BEFORE" "$(git -C "$FIX/wt151" rev-parse HEAD)"
want "the merge is still in progress"      "yes" "$([ -f "$(git -C "$FIX/wt151" rev-parse --git-path MERGE_HEAD)" ] && echo yes || echo no)"
want_not_in "no conflict marker is in any commit" '<<<<<<<' "$(git -C "$FIX/wt151" show HEAD 2>/dev/null)"
want_in "the brief says the merge was left unfinished" 'left unfinished' "$(cat "$GH_LOG")"
git -C "$FIX/wt151" merge --abort 2>/dev/null

echo "--- a question the owner's channel could not take falls back to the hold label ---"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/oq-refuses"; chmod +x "$BIN/oq-refuses"
driver_state_init 152; fix_issue 152 OPEN "status:claimed"; : > "$GH_LOG"
DRIVER_OWNER_QUESTION="$BIN/oq-refuses" driver_park 152 "a question" "which one?" person >/dev/null 2>&1
want_in "the hold goes on instead"           'issue edit 152 .*--add-label needs:human-approval' "$(cat "$GH_LOG")"
want_in "and the ticket says why"            'could not be put in the owner' "$(cat "$GH_LOG")"
: > "$GH_LOG"
DRIVER_OWNER_QUESTION="$BIN/oq-refuses" driver_park 153 "the driver" "x" driver >/dev/null 2>&1
want_not_in "a driver-caused park asks nobody and holds nothing" 'needs:human-approval|needs:owner-decision' "$(cat "$GH_LOG")"
echo "--- a question the PM owns gets the PM's label, never the owner's hold ---"
# Every question used to add the hold, which only the owner may clear, so questions
# about which repo or how to split a ticket queued for him. A pm park adds the PM
# label (labels.pmDecision) and the brief names that label as the one to clear.
git -C "$REPO" worktree add -q "$FIX/wt330" -b tkt-330/work develop
driver_state_init 330 --worktree "$FIX/wt330" --branch tkt-330/work
fix_issue 330 OPEN "status:claimed"
: > "$GH_LOG"
out=$(driver_park 330 "plan asked a question rather than guessing" "which repo does this belong in?" pm 2>&1); rc=$?
want "it parks" "20" "$rc"
edit=$(grep '^issue edit 330' "$GH_LOG")
want_in     "the PM label goes on"          'status:pm-decision' "$edit"
want_not_in "the owner's hold does not"     'needs:human-approval' "$edit"
want_in     "it is still parked"            'status:parked' "$edit"
brief=$(grep -A40 '^issue comment 330' "$GH_LOG")
want_in     "the brief asks the question"   'which repo does this belong in' "$brief"
want_in     "and names the label to clear"  'clear `status:pm-decision`' "$brief"
want_not_in "and not the owner's"           'needs:human-approval' "$brief"

exit $FAILED
