#!/usr/bin/env bash
# steps/build.sh — the build step, and the one guarantee the driver makes with
# its own hands rather than by asking.
#
#   driver_step_build <ticket>
#
# TEST-FIRST, PROVED. The epic's headline measurement is that test-first was used
# 0 times in 161 runs while every instruction insisted on it. An instruction
# nothing checks is a wish. So the driver does not ask whether the test came
# first — it runs the test against the tree WITHOUT the change and requires it to
# FAIL, then against the tree WITH the change and requires it to PASS.
#
# That is why the build brief has to report, per item, the commit that added the
# test and the commit that made it pass: two commits are what make the claim
# checkable. A single squashed commit cannot be told from a test written
# afterwards, which is exactly the thing being prevented.
#
# It is also why this is not "did the agent say it did TDD". A test that is green
# before the change is the commonest failure in this repo's history — a test
# whose selector matches nothing, whose assertion is true of any tree, or which
# reads a file instead of running the code. All three are GREEN at the base
# commit, and all three fail here.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1

# driver_prove_red_green <repo> <test-file> <test-commit> <impl-commit> <command>
#
#   0  it failed without the change and passed with it
#   1  it passed WITHOUT the change — the test does not test the change
#   2  it still failed WITH the change — the change does not do the job
#   3  the commits could not be read
#
# BOTH trees are the reported test file copied into a checkout: the change's PARENT
# for the red half, the change itself for the green half. Two things follow from
# that and neither is incidental.
#
# Checking out the test commit itself would not do — on a branch where the test and
# the change are adjacent that tree is the same tree, and the proof would be of
# nothing.
#
# And the version has to be the REPORTED one in both halves. A test sharpened while
# the change was built is ordinary, and then the change's own tree holds an earlier
# version; running that one measures a different test in each half and attributes
# both answers to the change. A first version that asserts the opposite of the
# change is green before and red after, so the two readings disagree — and the
# wrong one says "still fails with the change" about a change that works.
# The two proof trees need what the TICKET worktree was given, or a test command
# that resolves through the shared install — `npx x`, `./node_modules/.bin/x`,
# `npm test` — fails with 127 in both of them. 127 in the second reads as "the
# change does not do the job", the rework burns every try, and the ticket parks.
# On a project with a gitignored install that is every ticket, so this is not a
# nicety: without it the step's whole guarantee is unreachable there.
_driver_proof_install() { # <repo> <tree>
  [ -d "$1/node_modules" ] && ln -sfn "$1/node_modules" "$2/node_modules"
  [ -d "$1/.husky/_" ] && { mkdir -p "$2/.husky"; cp -R "$1/.husky/_" "$2/.husky/_"; }
  return 0
}

driver_prove_red_green() {
  local repo="$1" tfile="$2" tsha="$3" isha="$4" cmd="$5"
  local base tmp rc_red rc_green

  # TWO COMMITS HAVE TO BE TWO. Reported as one, the parent holds neither the test
  # nor the change, the test is copied in and goes red, and the commit makes it
  # green — so a squash that did no test-first at all reads as a clean proof.
  # Nothing about the trees can tell them apart; only the two shas can.
  if [ "$(git -C "$repo" rev-parse --verify "$tsha" 2>/dev/null)" \
     = "$(git -C "$repo" rev-parse --verify "$isha" 2>/dev/null)" ]; then
    printf 'the test and the change are the same commit (%s) — one commit cannot show which came first\n' \
      "$(printf '%s' "$isha" | cut -c1-8)"; return 3
  fi

  base=$(git -C "$repo" rev-parse --verify "$isha^" 2>/dev/null) || {
    printf 'the change commit %s has no parent to compare against\n' "$isha"; return 3; }
  git -C "$repo" cat-file -e "$tsha:$tfile" 2>/dev/null || {
    printf 'no %s in %s — the commit named as adding the test does not contain it\n' "$tfile" "$tsha"; return 3; }
  # AND IT HAS TO BE THERE WHEN THE CHANGE LANDS. The green half runs at $isha; if
  # the test was committed afterwards it is absent there, and a suite-wide command
  # then runs nothing and exits 0 — "then green" said about a run that never
  # executed the test, which is exactly test-written-afterwards.
  git -C "$repo" cat-file -e "$isha:$tfile" 2>/dev/null || {
    printf '%s is not in the change commit %s — a test committed after the change cannot have come before it\n' \
      "$tfile" "$(printf '%s' "$isha" | cut -c1-8)"; return 3; }

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/driver-proof-XXXXXX")
  git -C "$repo" worktree add -q --detach "$tmp/before" "$base" 2>/dev/null || {
    rm -rf "$tmp"; printf 'could not check out %s\n' "$base"; return 3; }
  _driver_proof_install "$repo" "$tmp/before"
  mkdir -p "$(dirname "$tmp/before/$tfile")"
  git -C "$repo" show "$tsha:$tfile" > "$tmp/before/$tfile"
  ( cd "$tmp/before" && eval "$cmd" ) >"$tmp/before.out" 2>&1
  rc_red=$?

  git -C "$repo" worktree add -q --detach "$tmp/after" "$isha" 2>/dev/null || {
    git -C "$repo" worktree remove --force "$tmp/before" >/dev/null 2>&1; rm -rf "$tmp"
    printf 'could not check out %s\n' "$isha"; return 3; }
  _driver_proof_install "$repo" "$tmp/after"
  # The SAME version of the test in both trees. A test sharpened while the change
  # was built is ordinary, and then the change's own tree holds an EARLIER version:
  # running that one measures a different test in each half, and the two answers get
  # attributed to the change. One version, two trees.
  mkdir -p "$(dirname "$tmp/after/$tfile")"
  git -C "$repo" show "$tsha:$tfile" > "$tmp/after/$tfile"
  ( cd "$tmp/after" && eval "$cmd" ) >"$tmp/after.out" 2>&1
  rc_green=$?

  git -C "$repo" worktree remove --force "$tmp/before" >/dev/null 2>&1
  git -C "$repo" worktree remove --force "$tmp/after"  >/dev/null 2>&1
  local red_out after_out
  red_out=$(head -5 "$tmp/before.out" 2>/dev/null | tr '\n' ' ')
  after_out=$(head -5 "$tmp/after.out" 2>/dev/null | tr '\n' ' ')
  rm -rf "$tmp"

  if [ "$rc_red" -eq 0 ]; then
    printf '%s passes without the change — it does not test it. (%s)\n' "$tfile" "$red_out"
    return 1
  fi
  if [ "$rc_green" -ne 0 ]; then
    printf '%s still fails with the change (exit %s): %s\n' "$tfile" "$rc_green" "$after_out"
    return 2
  fi
  printf '%s: red (exit %s) at %s, then green at %s\n' \
    "$tfile" "$rc_red" "$(printf '%s' "$base" | cut -c1-8)" "$(printf '%s' "$isha" | cut -c1-8)"
  return 0
}

driver_step_build() { # <ticket>
  local t="${1:?driver_step_build: need a ticket}"
  local repo tries rc n bad item id tfile tcmd tsha isha why
  export DRIVER_TICKET="$t"
  repo=$(driver_state_get "$t" worktree)
  [ -n "$repo" ] || repo="$MAIN_REPO"

  driver_state_bump "$t" build
  tries=$(driver_state_count "$t" build)

  # The build brief invokes superpowers:subagent-driven-development: inside a
  # ticket, splitting the work belongs to Superpowers. The driver never starts
  # several agents on one ticket itself — it runs one brief, and that brief's
  # skill does the fan-out, with test-driven-development inside each task.
  rc=0; driver_ai_step "$t" build "$(driver_state_dir "$t")/steps/plan.json" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # A question, a skipped Skill or a broken answer is not a rework loop: those
    # park, and they park with their OWN reason. Running them through the ceiling
    # would rewrite the model's question as "build refused (exit 24)" on the last
    # try, and the operator would be handed a code in place of the question they
    # have to answer. Only an UNPROVED build is worth another try.
    return "$rc"
  fi

  n=$(jq -r '(.items // []) | length' "$(driver_state_dir "$t")/steps/build.json")
  if [ "${n:-0}" -eq 0 ]; then
    driver_say "✋ build: the answer carries no items. A build that changed nothing is not a build that passed."
    return "$DRIVER_E_REFUSED"
  fi

  bad=0
  local i=0
  while [ "$i" -lt "$n" ]; do
    item=$(jq -c --argjson i "$i" '.items[$i]' "$(driver_state_dir "$t")/steps/build.json")
    id=$(printf '%s' "$item" | jq -r '.id // "?"')
    tfile=$(printf '%s' "$item" | jq -r '.test_file // ""')
    tcmd=$(printf '%s'  "$item" | jq -r '.test_command // ""')
    tsha=$(printf '%s'  "$item" | jq -r '.test_commit // ""')
    isha=$(printf '%s'  "$item" | jq -r '.impl_commit // ""')
    i=$((i+1))

    if [ -z "$tfile" ] || [ -z "$tcmd" ] || [ -z "$tsha" ] || [ -z "$isha" ]; then
      driver_say "✋ build item $id names no test to prove it (needs test_file, test_command, test_commit, impl_commit)."
      bad=1; continue
    fi
    if why=$(driver_prove_red_green "$repo" "$tfile" "$tsha" "$isha" "$tcmd"); then
      driver_say "   build item $id — $why"
    else
      driver_say "✋ build item $id — $why"
      bad=1
    fi
  done

  if [ "$bad" -eq 0 ]; then
    driver_say "   build: every item proved red before green"
    return "$DRIVER_OK"
  fi
  _driver_build_out_of_tries "$t" "$tries" && return "$DRIVER_E_REFUSED"
  return "$DRIVER_E_REWORK"
}

# True when this was the last try. Five, per the approved design's flowchart: a
# loop with no ceiling is a run that never parks and never finishes.
_driver_build_out_of_tries() {
  [ "$2" -ge "$DRIVER_MAX_BUILD_TRIES" ] || return 1
  driver_say "✋ build: $2 of $DRIVER_MAX_BUILD_TRIES tries used and the tests still do not prove the change. Parking."
  return 0
}
