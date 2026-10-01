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
#   4  a half ran out of time — a hang says nothing about the change
#   5  a proof tree could not be prepared — the measurement was never made
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
# 0 prepared · 1 this project's setup could not be run here.
#
# THE EXIT CODE IS READ. Wrapped in `>/dev/null 2>&1 || true` it re-opened the exact
# bug the prepare list exists to close: a failed generate leaves the test command
# resolving through a missing artifact, so it exits 127 in BOTH halves, the second
# 127 reads as "the change does not do the job", the rework loop burns every try, and
# the ticket parks blaming a change that works. The measurement was never made, and a
# measurement that could not be made is not a red.
_driver_proof_install() { # <repo> <tree>
  [ -d "$1/node_modules" ] && driver_link_dir "$1/node_modules" "$2/node_modules"
  [ -d "$1/.husky/_" ] && { mkdir -p "$2/.husky"; cp -R "$1/.husky/_" "$2/.husky/_"; }
  # >&2, because the caller is a command substitution: `why=$(driver_prove_red_green …)`.
  # Left on stdout, driver_prepare_worktree's own narration was captured into $why and
  # printed as part of the proof's verdict — and on the refusal path the park note was
  # the same sentence twice, naming a temp tree that had already been deleted.
  driver_prepare_worktree "$2" >&2 || return 1
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
  if ! _driver_proof_install "$repo" "$tmp/before"; then
    git -C "$repo" worktree remove --force "$tmp/before" >/dev/null 2>&1; rm -rf "$tmp"
    printf 'the tree without the change could not be prepared, so the test was never run there: %s\n' "$DRIVER_PREPARE_WHY"
    return 5
  fi
  mkdir -p "$(dirname "$tmp/before/$tfile")"
  git -C "$repo" show "$tsha:$tfile" > "$tmp/before/$tfile"
  ( cd "$tmp/before" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$cmd" ) >"$tmp/before.out" 2>&1
  rc_red=$?

  git -C "$repo" worktree add -q --detach "$tmp/after" "$isha" 2>/dev/null || {
    git -C "$repo" worktree remove --force "$tmp/before" >/dev/null 2>&1; rm -rf "$tmp"
    printf 'could not check out %s\n' "$isha"; return 3; }
  if ! _driver_proof_install "$repo" "$tmp/after"; then
    git -C "$repo" worktree remove --force "$tmp/before" >/dev/null 2>&1
    git -C "$repo" worktree remove --force "$tmp/after"  >/dev/null 2>&1; rm -rf "$tmp"
    printf 'the tree with the change could not be prepared, so the test was never run there: %s\n' "$DRIVER_PREPARE_WHY"
    return 5
  fi
  # The SAME version of the test in both trees. A test sharpened while the change
  # was built is ordinary, and then the change's own tree holds an EARLIER version:
  # running that one measures a different test in each half, and the two answers get
  # attributed to the change. One version, two trees.
  mkdir -p "$(dirname "$tmp/after/$tfile")"
  git -C "$repo" show "$tsha:$tfile" > "$tmp/after/$tfile"
  ( cd "$tmp/after" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$cmd" ) >"$tmp/after.out" 2>&1
  rc_green=$?

  git -C "$repo" worktree remove --force "$tmp/before" >/dev/null 2>&1
  git -C "$repo" worktree remove --force "$tmp/after"  >/dev/null 2>&1
  local red_out after_out
  red_out=$(head -5 "$tmp/before.out" 2>/dev/null | tr '\n' ' ')
  after_out=$(head -5 "$tmp/after.out" 2>/dev/null | tr '\n' ' ')
  rm -rf "$tmp"

  # A HANG IS NOT A RED. Out of time says nothing about the change, and it is
  # reported before the red/green reading so a watch-mode runner cannot be read as a
  # test that failed honestly.
  if [ "$rc_red" -eq 124 ] || [ "$rc_green" -eq 124 ]; then
    printf '%s ran out of time (over %ss) — a command that does not return cannot prove anything. A watch-mode runner is the usual cause.\n' \
      "$tfile" "$DRIVER_CMD_TIMEOUT"
    return 4
  fi
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


# driver_prove_by_break <repo> <test-file> <test-commit> <break-file> <find> <replace> <command>
#
# THE PROOF FOR A TASK WHOSE DELIVERABLE IS THE TEST. The code it covers already
# exists, so there is no tree without the change to be red at — the red/green proof
# above can only ever say "passes without the change" about it, and the 2026-09-30
# trial parked a test-only ticket for exactly that. Here the break is planted
# instead: the production code the test covers is broken in a throwaway tree, the
# test must FAIL, the break is removed, and the test must PASS. That is "plant the
# death, not the typo" run by the driver rather than asked of the model.
#
# The break is a literal find/replace, not a patch: a model's hand-written diff
# hunks are the usual reason `git apply` says no, and a refusal the model cannot
# fix is a rework loop about formatting.
#
# 0 red with the break, green without · 1 green with the break — the test does not
# cover that code · 2 red without the break · 3 the answer cannot be checked ·
# 4 out of time · 5 the tree could not be prepared
driver_prove_by_break() {
  local repo="$1" tfile="$2" tsha="$3" bfile="$4" find="$5" repl="$6" cmd="$7"
  local tmp n rc_red rc_green red_out green_out

  git -C "$repo" cat-file -e "$tsha:$tfile" 2>/dev/null || {
    printf 'no %s in %s — the commit named as adding the test does not contain it\n' "$tfile" "$tsha"; return 3; }
  # THE BREAK IS IN THE CODE, NEVER IN THE TEST. Breaking the test itself proves the
  # test can be made to fail, which any test can.
  if [ "$bfile" = "$tfile" ]; then
    printf 'the break is planted in the test file %s itself — it has to break the code the test covers\n' "$tfile"; return 3
  fi
  git -C "$repo" cat-file -e "$tsha:$bfile" 2>/dev/null || {
    printf 'no %s in %s — the break names a file that is not there\n' "$bfile" "$(printf '%s' "$tsha" | cut -c1-8)"; return 3; }
  if [ -z "$find" ] || [ "$find" = "$repl" ]; then
    printf 'the break changes nothing in %s — find is empty or equal to replace\n' "$bfile"; return 3
  fi

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/driver-break-XXXXXX")
  git -C "$repo" worktree add -q --detach "$tmp/tree" "$tsha" 2>/dev/null || {
    rm -rf "$tmp"; printf 'could not check out %s\n' "$tsha"; return 3; }
  _driver_break_done() { git -C "$repo" worktree remove --force "$tmp/tree" >/dev/null 2>&1; rm -rf "$tmp"; }
  if ! _driver_proof_install "$repo" "$tmp/tree"; then
    _driver_break_done
    printf 'the tree for the planted break could not be prepared, so the test was never run there: %s\n' "$DRIVER_PREPARE_WHY"
    return 5
  fi
  cp "$tmp/tree/$bfile" "$tmp/original"
  # Literal on both sides: no regex, no interpolation. The count is the assertion that
  # the substitution landed — a replace that matched nothing still "succeeds".
  n=$(BREAK_FIND="$find" BREAK_REPL="$repl" perl -0777 -i -pe \
        'BEGIN{$f=$ENV{BREAK_FIND};$r=$ENV{BREAK_REPL};$c=0} $c += s/\Q$f\E/$r/g; END{print STDERR $c}' \
        "$tmp/tree/$bfile" 2>&1 >/dev/null)
  if [ "${n:-0}" -eq 0 ] 2>/dev/null || ! [ "${n:-0}" -ge 0 ] 2>/dev/null; then
    _driver_break_done
    printf 'the break text is not in %s at %s — nothing was broken, so nothing would be measured\n' "$bfile" "$(printf '%s' "$tsha" | cut -c1-8)"
    return 3
  fi
  ( cd "$tmp/tree" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$cmd" ) >"$tmp/red.out" 2>&1
  rc_red=$?
  cp "$tmp/original" "$tmp/tree/$bfile"
  ( cd "$tmp/tree" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$cmd" ) >"$tmp/green.out" 2>&1
  rc_green=$?
  red_out=$(head -5 "$tmp/red.out" 2>/dev/null | tr '\n' ' ')
  green_out=$(head -5 "$tmp/green.out" 2>/dev/null | tr '\n' ' ')
  _driver_break_done

  if [ "$rc_red" -eq 124 ] || [ "$rc_green" -eq 124 ]; then
    printf '%s ran out of time (over %ss) — a command that does not return cannot prove anything. A watch-mode runner is the usual cause.\n' \
      "$tfile" "$DRIVER_CMD_TIMEOUT"
    return 4
  fi
  if [ "$rc_red" -eq 0 ]; then
    printf '%s still passes with %s broken — it does not test that code. (%s)\n' "$tfile" "$bfile" "$red_out"
    return 1
  fi
  if [ "$rc_green" -ne 0 ]; then
    printf '%s fails with the code intact (exit %s): %s\n' "$tfile" "$rc_green" "$green_out"
    return 2
  fi
  printf '%s: red (exit %s) with %s broken, then green with it restored, at %s\n' \
    "$tfile" "$rc_red" "$bfile" "$(printf '%s' "$tsha" | cut -c1-8)"
  return 0
}

driver_step_build() { # <ticket>
  local t="${1:?driver_step_build: need a ticket}"
  local repo tries rc ntasks bad task slot ans tfile tcmd tsha isha bfile why prc
  local want_task got_task pair seen_pairs=""
  export DRIVER_TICKET="$t"
  repo=$(driver_state_get "$t" worktree)
  [ -n "$repo" ] || repo="$MAIN_REPO"

  driver_check_timeout || true
  driver_state_bump "$t" build
  tries=$(driver_state_count "$t" build)

  # ONE CALL PER PLAN TASK, because that is what the brief and the contract say:
  # build.md opens "You are building **one** task from the plan", and
  # briefs/schemas/build.json carries ONE `task` string and ONE `testFirst` object.
  # This step used to read `.items[]` with `test_file` / `test_commit` / `impl_commit`
  # — four names the contract does not have and `additionalProperties: false`
  # forbids — so an answer meeting the contract was refused here and an answer this
  # could read was refused by the validator. The same defect as the plan step's, in
  # the step the trial never reached.
  #
  # Sequential, never parallel: inside a ticket the fan-out belongs to
  # superpowers:subagent-driven-development, which the brief invokes, with a fresh
  # helper per task. The driver never starts several agents on one ticket.
  ntasks=$(jq -r '[.tasks[]?] | length' "$(driver_state_dir "$t")/steps/plan.json" 2>/dev/null)
  if [ "${ntasks:-0}" -eq 0 ]; then
    driver_say "✋ build: the plan carries no task to build. A build that changed nothing is not a build that passed."
    return "$DRIVER_E_REFUSED"
  fi

  bad=0
  : > "$(driver_state_dir "$t")/steps/build.all.json"
  local i=0
  while [ "$i" -lt "$ntasks" ]; do
    task=$(jq -c --argjson i "$i" '.tasks[$i]' "$(driver_state_dir "$t")/steps/plan.json")
    i=$((i+1))
    slot="build-task-$i"
    ans="$(driver_state_dir "$t")/steps/$slot.json"

    # The one task this call builds, as the brief's own placeholder.
    driver_fact_put "$t" "$slot" PLAN_TASK "$(printf '%s' "$task" | jq .)"
    rc=0; driver_ai_step "$t" build --as "$slot" || rc=$?
    if [ "$rc" -ne 0 ]; then
      # A question, a skipped Skill or a broken answer is not a rework loop: those
      # park, and they park with their OWN reason. Running them through the ceiling
      # would rewrite the model's question as "build refused (exit 24)" on the last
      # try, and the operator would be handed a code in place of the question they
      # have to answer. Only an UNPROVED build is worth another try.
      return "$rc"
    fi
    jq -c . "$ans" >> "$(driver_state_dir "$t")/steps/build.all.json"
    # The tests this task reworded or removed, on the run's one ledger: the commits
    # stay on the branch across build tries and restarts, so their reports must too.
    jq -c '(.replacedTests // [])[]' "$ans" >> "$(driver_state_dir "$t")/steps/replaced.jsonl" 2>/dev/null || true

    # THE ANSWER MUST NOT BE ABOUT A DIFFERENT TASK. The proof re-runs whatever two
    # shas it is handed and cannot tell which task they belong to — so an answer that
    # returns ANOTHER task's title and commits proves red-then-green perfectly, `bad`
    # stays 0, and the step reports every task built while one was never touched. The
    # suite's own two-task case did exactly that and passed.
    #
    # IT IS NOT BYTE EQUALITY WITH THE TITLE ASKED FOR. Nothing in build.md told the
    # model the string had to be verbatim, so a restored full stop or a normalised dash
    # would have sent a perfectly built task round the rework loop five times and then
    # parked it saying "the tests still do not prove the change" — a sentence that is
    # false, about tests that are fine. Adding a checker without adding the prompt is
    # this repo's own named defect, so the brief now states the rule AND the check only
    # fires on the thing that is unambiguously wrong: a title belonging to a different
    # task in this same plan. A title matching none of them is said and allowed.
    want_task=$(printf '%s' "$task" | jq -r '.title // ""')
    got_task=$(jq -r '.task // ""' "$ans")
    if [ -n "$got_task" ] && [ "$got_task" != "$want_task" ]; then
      if jq -e --arg g "$got_task" --arg w "$want_task" \
           '[.tasks[]?.title] | index($g) != null and $g != $w' \
           "$(driver_state_dir "$t")/steps/plan.json" >/dev/null 2>&1; then
        driver_say "✋ build: this call was given '$want_task' and the answer builds '$got_task', which is another task in this plan. A task nobody built is a task that ships unbuilt."
        bad=1; continue
      fi
      driver_say "   build: the answer calls this task '$got_task'; the plan calls it '$want_task'"
    fi
    # A TASK WHOSE DELIVERABLE IS THE TEST is proved by a planted break, because the
    # code it covers is already there and nothing can be red before it. Dom's rule,
    # 2026-09-30: break the production code, show red, restore, show green.
    if jq -e '.testOnly | type == "object"' "$ans" >/dev/null 2>&1; then
      tfile=$(jq -r '.testOnly.test.file // ""' "$ans")
      tcmd=$(jq -r  '.testOnly.command // ""'   "$ans")
      tsha=$(jq -r  '.testOnly.testCommit // ""' "$ans")
      bfile=$(jq -r '.testOnly.break.file // ""' "$ans")
      if [ -z "$tfile" ] || [ -z "$tcmd" ] || [ -z "$tsha" ] || [ -z "$bfile" ]; then
        driver_say "✋ build '$(jq -r '.task // "?"' "$ans")' is test-only and names no break to prove it (testOnly needs test.file, command, testCommit and break)."
        bad=1; continue
      fi
      pair="$(git -C "$repo" rev-parse --verify -q "$tsha^{commit}" 2>/dev/null || printf '%s' "$tsha"):break:$bfile"
      case " $seen_pairs " in
        *" $pair "*)
          driver_say "✋ build '$got_task' is proved by the same test commit and break as an earlier task. One proof cannot be two tasks."
          bad=1; continue ;;
      esac
      seen_pairs="$seen_pairs $pair"
      why=""; prc=0
      why=$(driver_prove_by_break "$repo" "$tfile" "$tsha" "$bfile" "$(jq -r '.testOnly.break.find' "$ans")" "$(jq -r '.testOnly.break.replace' "$ans")" "$tcmd") || prc=$?
    else
    tfile=$(jq -r '.testFirst.test.file // ""' "$ans")
    tcmd=$(jq -r  '.testFirst.command // ""'   "$ans")
    tsha=$(jq -r  '.testFirst.testCommit // ""' "$ans")
    isha=$(jq -r  '.testFirst.implCommit // ""' "$ans")
    if [ -z "$tfile" ] || [ -z "$tcmd" ] || [ -z "$tsha" ] || [ -z "$isha" ]; then
      driver_say "✋ build '$(jq -r '.task // "?"' "$ans")' names no test to prove it (testFirst needs test.file, command, testCommit and implCommit)."
      bad=1; continue
    fi
    # AND ITS OWN COMMITS. A pair already proved for an earlier task proves that task
    # again, not this one — same hole as the title, reached by the other door.
    #
    # KEYED ON THE RESOLVED COMMIT, not on the string the model typed. The contract asks
    # for seven characters or more, so `a1b2c3d` and its full sha are two keys for one
    # commit — and that is a third door to the same hole.
    pair="$(git -C "$repo" rev-parse --verify -q "$tsha^{commit}" 2>/dev/null || printf '%s' "$tsha"):$(git -C "$repo" rev-parse --verify -q "$isha^{commit}" 2>/dev/null || printf '%s' "$isha")"
    case " $seen_pairs " in
      *" $pair "*)
        driver_say "✋ build '$got_task' is proved by the same two commits as an earlier task ($(printf '%s' "$tsha" | cut -c1-8) then $(printf '%s' "$isha" | cut -c1-8)). One change cannot be two tasks built test-first."
        bad=1; continue ;;
    esac
    seen_pairs="$seen_pairs $pair"
    why=""; prc=0
    why=$(driver_prove_red_green "$repo" "$tfile" "$tsha" "$isha" "$tcmd") || prc=$?
    fi
    if [ "$prc" -eq 0 ]; then
      driver_say "   build $(jq -r '.task // "?"' "$ans") — $why"
    elif [ "$prc" -eq 5 ]; then
      # Not a rework and not a red: the proof was never taken. Retrying it five times
      # would spend the whole ceiling on a tree this machine cannot build, and then
      # park accusing the change.
      driver_say "✋ build $(jq -r '.task // "?"' "$ans") — $why"
      driver_state_set "$t" park_note "$why"
      return "$DRIVER_E_REFUSED"
    elif [ "$prc" -eq 4 ]; then
      # A HANG IS NOT A FAILING TEST, so it does not go in the retry bucket. Folded in
      # with the rest it was tried five times — at the default ceiling that is five
      # attempts times two proof halves of waiting — and the ticket then parked blaming
      # the change, which is what this step's own header forbids. It returns its own
      # code so the orchestrator parks with the real reason immediately.
      driver_say "✋ build $(jq -r '.task // "?"' "$ans") — $why"
      return "$DRIVER_E_TIMEOUT"
    else
      driver_say "✋ build $(jq -r '.task // "?"' "$ans") — $why"
      bad=1
    fi
  done

  if [ "$bad" -eq 0 ]; then
    driver_say "   build: all $ntasks task(s) proved red before green"
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
