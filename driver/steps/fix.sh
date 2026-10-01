#!/usr/bin/env bash
# steps/fix.sh — the rework round, and the only step that reads what the reviewer
# found.
#
#   driver_step_fix <ticket>
#
# WHY IT EXISTS. `briefs/fix.md` shipped carrying {{BLOCKERS}} and nothing sent it
# anything: there was no step file, `fix` was not in the order, and `grep -rn
# BLOCKERS driver/` was empty outside the tests. A review that graded a Critical
# returned exit 30, the orchestrator rewound to the build step, and the build step
# re-ran the ORIGINAL plan task — blind to what the reviewer had just said. So the
# two-round ceiling bounded a loop that could not act, and both rounds spent an
# agent re-deciding what to build rather than fixing what was wrong.
#
# IT IS A NO-OP UNTIL THERE IS SOMETHING TO FIX, and it says so. On the first pass
# no review has happened, so there are no findings and no agent is started. That is
# what lets it sit in the fixed order rather than being conditionally skipped —
# and a step that is conditionally skipped reports exactly like a step that passed.
#
# CRITICAL AND MAJOR ONLY. A Minor left the review as its own follow-up and a Nit
# was dropped; pulling either in here would spend a rework round on polish, which
# is the measurement that put the ceiling there in the first place.
#
# AND THE FIX IS PROVED THE SAME WAY THE BUILD IS. Each cleared finding names the
# commit that added its test and the commit that made it pass, and the driver runs
# that test at the change's parent and at the change. A fix whose test is green
# before the fix is a fix nothing pins — the same defect the build step exists to
# catch, reached one round later.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1
# driver_prove_red_green lives with the build step: one proof, read by both, so a
# second copy cannot start disagreeing with it about what red means.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build.sh" || exit 1

driver_step_fix() { # <ticket>
  local t="${1:?driver_step_fix: need a ticket}"
  local d review round wt trunk r diff blockers n rc ans i ncleared
  local tfile tcmd tsha isha why prc bad=0 bid
  export DRIVER_TICKET="$t"
  d=$(driver_state_dir "$t")
  review="$d/steps/review.json"

  if [ ! -f "$review" ]; then
    driver_say "   fix: no review has run yet, so there is nothing to fix."
    return "$DRIVER_OK"
  fi

  # ONE READER FOR "WHAT BLOCKS". The review step's own selector, so the list this
  # step is handed and the list that sent the work back cannot differ.
  n=$(jq -r '[.findings[]? | select(.grade == "critical" or .grade == "major")] | length' "$review" 2>/dev/null)
  if [ "${n:-0}" -eq 0 ]; then
    driver_say "   fix: the review graded nothing critical or major, so there is nothing to fix."
    return "$DRIVER_OK"
  fi

  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  trunk=""
  for r in "origin/$INTEGRATION_BRANCH" "$INTEGRATION_BRANCH"; do
    git -C "$wt" rev-parse --verify -q "$r" >/dev/null 2>&1 && { trunk="$r"; break; }
  done
  diff=""
  [ -z "$trunk" ] || diff=$(git -C "$wt" diff "$trunk"...HEAD 2>/dev/null)

  # VERBATIM, WITH THE GRADE AND THE PROPOSED FIX. A finding summarised on the way
  # here is a finding the fixer answers a paraphrase of.
  # THE CONTRACT'S OWN KEYS, with no alternates. `id`, `file`, `line`, `summary`,
  # `reason` and `fix` are all required by briefs/schemas/review.json, so a `//`
  # fallback to a second spelling would be this driver reading a shape the contract
  # forbids — the exact defect that made the plan step refuse its own valid example.
  blockers=$(jq -r '
    [.findings[]? | select(.grade == "critical" or .grade == "major")
     | "- id \(.id) · \(.grade) · \(.file):\(.line)\n  \(.summary)\n  why: \(.reason)\n  proposed: \(.fix)"]
    | join("\n")' "$review" 2>/dev/null)

  round=$(driver_state_count "$t" fix)
  driver_fact_put "$t" fix BLOCKERS "$blockers"
  driver_fact_put "$t" fix DIFF \
    "${diff:-(none — nothing to diff: no $INTEGRATION_BRANCH resolves in $wt, or the branch carries no change)}"
  driver_fact_put "$t" fix ROUND "$((round + 1))"

  driver_say "   fix round $((round + 1)): $n critical/major finding(s) to clear"
  rc=0; driver_ai_step "$t" fix || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  driver_state_bump "$t" fix
  ans="$d/steps/fix.json"
  # Every round's answer, as build keeps every task's: ship reads `replacedTests` from all of them.
  jq -c . "$ans" >> "$d/steps/fix.all.json" 2>/dev/null || true

  # EVERY BLOCKER IS ACCOUNTED FOR. A Critical or a Major is not deferrable, so a
  # finding that is in neither `cleared` nor `deferred` is one nobody answered —
  # and the step would otherwise report a clean round about it.
  local unanswered=""
  while IFS= read -r bid; do
    [ -n "$bid" ] || continue
    jq -e --arg b "$bid" '([.cleared[]?.blockerId] + [.deferred[]?.blockerId]) | index($b) != null' \
      "$ans" >/dev/null 2>&1 || unanswered="$unanswered $bid"
  done <<EOB
$(jq -r '[.findings[]? | select(.grade == "critical" or .grade == "major") | (.id // empty)] | .[]' "$review" 2>/dev/null)
EOB
  if [ -n "$unanswered" ]; then
    driver_say "✋ fix: finding(s)${unanswered} appear in neither cleared nor deferred. A blocker nobody answered is a blocker that ships."
    driver_state_set "$t" park_note "the fix round left${unanswered} unanswered — a critical or major finding is neither cleared nor deferrable"
    return "$DRIVER_E_REFUSED"
  fi
  # AND A BLOCKER IS NOT DEFERRABLE. The contract has a `deferred` shape because a
  # reviewer can raise something outside this ticket; it is not a way past a grade
  # that blocks, and the ship step refuses while one is open anyway.
  if [ "$(jq -r '[.deferred[]?] | length' "$ans" 2>/dev/null)" != "0" ]; then
    driver_say "✋ fix: $(jq -r '[.deferred[]?] | length' "$ans") of the findings were deferred, and a critical or major finding is not deferrable — $(jq -r '[.deferred[]? | "\(.blockerId): \(.reason)"] | join("; ")' "$ans")"
    driver_state_set "$t" park_note "the fix round deferred a blocking finding: $(jq -r '[.deferred[]? | "\(.blockerId): \(.reason)"] | join("; ")' "$ans")"
    # A PERSON DECIDES WHETHER A BLOCKER IS REALLY ONE. The fixer disagreeing with
    # a grade is a legitimate answer and it is not the driver's to settle; parking
    # it as the driver's own would leave the ticket resumable and the next round
    # free to defer it again.
    driver_state_set "$t" park_cause person
    return "$DRIVER_E_REFUSED"
  fi

  ncleared=$(jq -r '[.cleared[]?] | length' "$ans")
  i=0
  while [ "$i" -lt "${ncleared:-0}" ]; do
    bid=$(jq -r --argjson i "$i" '.cleared[$i].blockerId // "?"' "$ans")
    tfile=$(jq -r --argjson i "$i" '.cleared[$i].test.file // ""' "$ans")
    tcmd=$(jq -r  --argjson i "$i" '.cleared[$i].command // ""' "$ans")
    tsha=$(jq -r  --argjson i "$i" '.cleared[$i].testCommit // ""' "$ans")
    isha=$(jq -r  --argjson i "$i" '.cleared[$i].implCommit // ""' "$ans")
    i=$((i+1))
    if [ -z "$tfile" ] || [ -z "$tcmd" ] || [ -z "$tsha" ] || [ -z "$isha" ]; then
      driver_say "✋ fix '$bid' names no test to prove it (test.file, command, testCommit and implCommit)."
      bad=1; continue
    fi
    why=""; prc=0
    why=$(driver_prove_red_green "$wt" "$tfile" "$tsha" "$isha" "$tcmd") || prc=$?
    case "$prc" in
      0) driver_say "   fix $bid — $why" ;;
      5) driver_say "✋ fix $bid — $why"
         driver_state_set "$t" park_note "$why"
         return "$DRIVER_E_REFUSED" ;;
      4) driver_say "✋ fix $bid — $why"
         return "$DRIVER_E_TIMEOUT" ;;
      *) driver_say "✋ fix $bid — $why"; bad=1 ;;
    esac
  done

  if [ "$bad" -ne 0 ]; then
    # NOT A REWORK. A rework rewinds to here, so returning one from here is a loop
    # with this step at both ends; the reviewer's findings have not changed and a
    # second pass would be handed the same list. It parks with what could not be
    # proved.
    driver_say "✋ fix: a cleared finding is not proved by its own test. A fix whose test is green before the fix is a fix nothing pins."
    driver_state_set "$t" park_note "the fix round cleared $ncleared finding(s) and at least one is not proved red-then-green by the test it names"
    return "$DRIVER_E_REFUSED"
  fi

  driver_say "   fix: $ncleared finding(s) cleared, each proved red before green"
  return "$DRIVER_OK"
}
