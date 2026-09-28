#!/usr/bin/env bash
# steps/review.sh — one review call per round, at most two rounds, and then it
# ends. What each finding costs is decided by its GRADE, not by which list it
# arrived in.
#
#   driver_step_review <ticket>
#     0  ship
#     30 a Critical or a Major, and a round left — go back to the build step
#     24 the answer was not a verdict, or not a grade, this driver understands
#
# WHY A CEILING. The median screen fix took seven rejections and six hours from
# open to merge, against twenty-five minutes for everything else. A review loop
# with no end is not thoroughness; it is one late problem holding up six fixes.
# Two rounds, and then the loop ends — the ceiling is on the ROUNDS, not on the
# outcome.
#
# WHY A GRADE. A ceiling alone still spends each round on whatever the reviewer
# raised: the step-runner went four rounds — eleven findings, then seven, then
# six — and about a quarter of them were spacing and wording. So the grade decides
# the effect, and only two of the four send work back:
#
#   critical  wrong data, a security hole, lost work, something published unapproved
#   major     a person is misled or stuck: an untrue screen, a dead control, a
#             failure shown as success
#   minor     polish — spacing, wording, a small visual slip
#   nit       taste
#
# Critical and Major go back to the build step and, past the rounds, stay with this
# ticket: the ship step refuses and names them, so filing one as a follow-up too
# would put the same finding in two places with nobody owning either. Minors leave
# as ONE follow-up ticket carrying every line verbatim, at the Minor priority, so
# they are worked when nothing bigger waits. Nits are dropped — and the count is
# SAID, because dropped silently reads exactly like never raised.
#
# ONE CALL, NOT SEVERAL AGENTS. The driver runs one review brief per round. What
# that brief does inside itself — how many reviewers it asks, in what order — is
# Superpowers' business. Inside a ticket, splitting the work belongs to the
# skill; the driver never starts several agents on one ticket.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1

driver_step_review() { # <ticket>
  local t="${1:?driver_step_review: need a ticket}"
  local rc round ans_file verdict nsend ungraded nnit
  export DRIVER_TICKET="$t"

  round=$(driver_state_count "$t" review)

  # The three facts only this step can gather. The brief asks for the DIFF against
  # the trunk it will merge into, the renders of every screen the change touches, and
  # which round this is — and a placeholder with no value now refuses the step, so
  # each one is written here rather than reaching the model as `{{DIFF}}`.
  local wt trunk r diff
  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  trunk=""
  for r in "origin/$INTEGRATION_BRANCH" "$INTEGRATION_BRANCH"; do
    git -C "$wt" rev-parse --verify -q "$r" >/dev/null 2>&1 && { trunk="$r"; break; }
  done
  if [ -n "$trunk" ]; then
    diff=$(git -C "$wt" diff "$trunk"...HEAD 2>/dev/null)
  else
    diff=""
  fi
  # BOUNDED, AND THE TRUNCATION IS SAID. A lockfile or a generated file takes a diff
  # into the megabytes, and a reviewer handed a silently-cut diff reviews a change it
  # cannot see the rest of — which is worse than being told. The cap is a project fact
  # so a repo with large legitimate diffs can raise it.
  local cap bytes; cap=$(driver_opt review.diffBytes 400000)
  # A CONFIGURED NUMBER THAT IS NOT A NUMBER IS SAID. Silently replaced, an operator who
  # writes "400kb" gets the default and no line telling them their setting is inert —
  # and every other configured number in this kit (cmdTimeout, STALE_HOURS, the prepare
  # shape one file over) says so.
  case "$cap" in
    ''|*[!0-9]*|0)
      driver_say "⚠ review: harness.json's review.diffBytes is '${cap}', which is not a number of bytes, so the default 400000 is used."
      cap=400000 ;;
  esac
  # MEASURED THE WAY IT IS CUT. `${#diff}` counts CHARACTERS and `head -c` cuts BYTES,
  # so on a diff with any non-ASCII in it the branch fired late and the banner reported
  # a character count labelled bytes. LC_ALL=C makes both halves bytes.
  bytes=$(LC_ALL=C printf '%s' "$diff" | wc -c | tr -d ' ')
  if [ "${bytes:-0}" -gt "$cap" ]; then
    diff="$(LC_ALL=C printf '%s' "$diff" | LC_ALL=C head -c "$cap")

[TRUNCATED at $cap bytes of $bytes. The files it touches, in full:
$(git -C "$wt" diff --stat "$trunk"...HEAD 2>/dev/null)
Read the rest in the worktree — do NOT review the part above as if it were the whole change.]"
  fi
  driver_fact_put "$t" review DIFF \
    "${diff:-(none — nothing to diff: no $INTEGRATION_BRANCH resolves in $wt, or the branch carries no change)}"
  # RENDERS is a fact about a screen, and the driver takes none. Saying so is the
  # point: the reviewer is told there are no renders rather than shown the word
  # {{RENDERS}} and left to guess whether that meant a clean screen.
  driver_fact_put "$t" review RENDERS \
    "$(driver_state_get "$t" renders | sed -e 's/^$/(none — this run took no renders, so judge no screen from them)/')"
  driver_fact_put "$t" review ROUND "$((round + 1))"

  # The build answers: one per plan task, so the whole file rather than the last one.
  local built="$(driver_state_dir "$t")/steps/build.all.json"
  [ -s "$built" ] || built="$(driver_state_dir "$t")/steps/build.json"
  rc=0; driver_ai_step "$t" review "$built" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  driver_state_bump "$t" review
  round=$((round + 1))
  ans_file="$(driver_state_dir "$t")/steps/review.json"

  verdict=$(jq -r '.verdict // ""' "$ans_file" | tr '[:lower:]' '[:upper:]')
  case "$verdict" in
    SHIP|BLOCKED) : ;;
    *)
      driver_say "✋ review: '$(jq -r '.verdict // "(none)"' "$ans_file")' is not a verdict. It is SHIP or BLOCKED; anything else is a reviewer that did not decide."
      return "$DRIVER_E_REFUSED" ;;
  esac

  # A GRADE OUTSIDE THE SCALE HAS NO EFFECT DEFINED FOR IT, so acting on it means
  # guessing. Treating it as non-blocking is how a Critical typed `crit` ships;
  # treating it as blocking is how a Nit costs the round a real defect needed.
  ungraded=$(jq -r --arg g "$DRIVER_GRADES" \
    '($g | split(" ")) as $scale
     | [.findings[]? | (.grade // "(none)") | . as $g0 | select($scale | index($g0) | not)] | unique | join(", ")' \
    "$ans_file")
  if [ -n "$ungraded" ]; then
    driver_say "✋ review: '$ungraded' is not a grade. It is one of: $DRIVER_GRADES. A finding the scale does not name has no effect defined for it."
    return "$DRIVER_E_REFUSED"
  fi

  nsend=$(_driver_count "$ans_file" blocking)
  # `-le`, not `-lt`: the design's flowchart sends work back on round 1 OR 2, so two
  # rounds means two chances to fix, and the pass after them ships.
  if [ "$verdict" = "BLOCKED" ] && [ "${nsend:-0}" -gt 0 ] && [ "$round" -le "$DRIVER_MAX_REVIEW_ROUNDS" ]; then
    driver_say "✋ review round $round of $DRIVER_MAX_REVIEW_ROUNDS: $nsend critical/major finding(s) — $(_driver_join "$(_driver_findings "$ans_file" blocking)")"
    return "$DRIVER_E_REWORK"
  fi

  # SHIP BESIDE AN OPEN CRITICAL OR MAJOR. The contract already refuses this, and that
  # is exactly why the driver has to as well: a check and the thing it checks derived
  # from one input is one input away from agreeing about nothing. Past the rounds the
  # rework branch above stops firing, so without this a Critical typed under a SHIP
  # verdict walks into the ship step and lands.
  if [ "$verdict" = "SHIP" ] && [ "${nsend:-0}" -gt 0 ]; then
    driver_say "✋ review: SHIP beside $nsend open critical/major finding(s) — $(_driver_join "$(_driver_findings "$ans_file" blocking)"). The verdict is read off the grades; it is not typed beside them."
    return "$DRIVER_E_REFUSED"
  fi

  # Past the last rework round. A Critical or a Major stays with this ticket and the
  # ship step refuses, naming it. Only the Minors leave.
  if ! _driver_file_minors "$t" "$ans_file" "$round"; then
    # A LEFTOVER NOBODY FILED IS A LEFTOVER LOST, and the ceiling's whole justification
    # is that nothing is lost by ending the loop. Returning OK here left the finding as
    # one line of stdout inside the state directory — a file on the machine that ran it,
    # which is the one place a handover must not depend on — and on a SHIP verdict no
    # park ever happened, so nobody was ever told. Refusing makes the orchestrator park
    # with the finding as the question.
    return "$DRIVER_E_REFUSED"
  fi

  nnit=$(_driver_count "$ans_file" nit)
  # SAY THE DROP. A nit dropped in silence is indistinguishable from a reviewer that
  # found nothing, so the count is what tells a reader which happened.
  [ "${nnit:-0}" -gt 0 ] && driver_say "   review: $nnit nit(s) dropped — taste, and taste never blocks"
  driver_say "   review: $verdict after $round round(s)"
  return "$DRIVER_OK"
}

# _driver_class <blocking|minor|nit> — the jq selector for that class, in the ONE
# place it is written. Two copies of "what counts as blocking" is two places for the
# count and the list to disagree, which is how a message names three findings and the
# branch above acts on two.
_driver_class() { # <class>
  case "$1" in
    blocking) printf 'select(.grade == "critical" or .grade == "major")' ;;
    *)        printf 'select(.grade == "%s")' "$1" ;;
  esac
}

# _driver_findings <review.json> <class> — one `file:line — summary` per line. One
# reader, so a finding is worded identically wherever it is printed, filed or parked.
_driver_findings() { # <review.json> <class>
  jq -r "[.findings[]? | $(_driver_class "$2") | \"\(.file // \"?\"):\(.line // \"?\") — \(.summary // \"\")\"] | .[]" "$1" 2>/dev/null
}

# _driver_count <review.json> <class> — how many findings of that class. jq counts the
# FINDINGS; counting the lines of the printed form counts a summary with a newline in
# it twice, and the number is what decides whether work goes back.
_driver_count() { # <review.json> <class>
  jq -r "[.findings[]? | $(_driver_class "$2")] | length" "$1" 2>/dev/null
}

# _driver_join <lines> — one line, findings separated by "; ", for a message.
_driver_join() { printf '%s' "$1" | tr '\n' ';' | sed 's/;$//; s/;/; /g'; }

_driver_file_minors() { # <ticket> <review.json> <round>
  local t="$1" f="$2" round="$3" lines n programme body title
  lines=$(_driver_findings "$f" minor)
  n=$(_driver_count "$f" minor)
  [ "${n:-0}" -gt 0 ] || return 0
  programme=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json labels \
    -q "[.labels[].name | select(startswith(\"$SWARM_PROGRAMME_PREFIX\"))] | first // \"\"" 2>/dev/null)

  # ONE TICKET, NOT N. A Minor is polish, and N polish tickets is a queue nobody
  # reads; one ticket per pull request is a thing a person picks up when nothing
  # bigger waits. It carries the Minor priority so the queue orders it that way.
  title="review polish from #$t: $n minor finding(s)"
  body=$(printf 'Left over from the review of #%s (round %s). Every one is graded **Minor**: polish, never blocking, worked when nothing bigger waits.\n\nThe findings, verbatim:\n\n%s\n' \
           "$t" "$round" "$(printf '%s\n' "$lines" | sed 's/^/- /')")

  # THE CREATE'S EXIT CODE IS READ. The ceiling is justified by "nothing is lost by
  # ending the loop", and with the call wrapped a rate limit, issues turned off, or a
  # title still carrying a newline lost the findings while the log asserted the
  # opposite. What did not land is named, and left on the record for the park brief —
  # the state directory's own log is on this machine, and a handover must not be.
  if swarm_gh issue create --repo "$REPO_SLUG" \
       --title "$(printf '%s' "$title" | tr '\n' ' ')" \
       --body "$body" \
       ${DRIVER_LABEL_MINOR:+--label "$DRIVER_LABEL_MINOR"} \
       ${programme:+--label "$programme"} >/dev/null 2>&1; then
    driver_say "   review: $n minor finding(s) left as one follow-up at ${DRIVER_LABEL_MINOR:-no priority label}, each line verbatim"
    return 0
  fi

  local flat
  flat=$(_driver_join "$lines")
  driver_say "✋ review: the follow-up ticket could NOT be opened, so these $n finding(s) are not written down anywhere a person will find them: $flat"
  driver_state_set "$t" park_note "review polish that could not be filed as a ticket: $flat"
  return 1
}
