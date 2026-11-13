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
# the effect, and three of the four send work back:
#
#   critical  wrong data, a security hole, lost work, something published unapproved
#   major     a person is misled or stuck: an untrue screen, a dead control, a
#             failure shown as success
#   minor     polish — spacing, wording, a small visual slip
#   nit       taste
#
# In round 1 Critical, Major and Minor go back to the build step; from round 2 only
# Critical and Major do (_driver_review_defer). What blocks, past the rounds, stays with
# this ticket: the ship step refuses and names it. Nits are dropped — and the count is
# SAID, because dropped silently reads exactly like never raised.
#
# NOTHING LEAVES A REVIEW AS A TICKET OR A LIST (the owner, 2026-11-02: finding tickets
# and polish lists switched off; since 2026-11-03 the check filters instead). A finding in a file this change
# touched is fixed in this change (_driver_review_same_change); one in a file it did not
# touch is pre-existing and goes to the nightly sweep's queue; anything else that does not
# block is dropped, noted in the PR. No follow-up ticket, no polish list.
#
# MERGE FIRST (release.mergeFirst, the owner, 2026-10-22): until the release a Critical,
# and a finding in this change's own files, block and are fixed in place.
#
# REVIEW ONCE (the owner, 2026-10-22: review was 26% of driver usage). The model reviews
# a change once. A later pass calls it again only when the fix round touched a file the
# first review never saw — files changed since the reviewed head, held against the
# reviewed diff's file list — and that second review is graded as round 2: only Critical
# and Major block. Never a third. Otherwise the pass records no new review: the fix step
# already proved each finding red-then-green, or parked. Settings: review.maxRounds
# (passes, default 2) and review.secondOnlyOnNewFiles (default true; false re-reviews
# every pass up to the ceiling).
#
# BY PRIORITY UNDER MERGE FIRST (the owner, 2026-10-23). Only a Critical blocks then, so
# the model reviews only a ticket at release.reviewPriorities (default P0 P1). Any other
# ships on CI with no model call; a person's stop and the push's own reviewers still run.
#
# ONE HUNTER, THEN A CHECK ON EACH FINDING (the owner, 2026-11-03; Anthropic's own shape for
# code review: agents hunt, then a separate pass judges each finding). Three full voters kept
# a finding only when two reported it: 65% of build usage, and a real bug one voter found was
# thrown away. A review step's agent count is bounded and configured, never left to a skill's
# top level (the owner, 2026-11-02). The HUNTER (_driver_review_hunt) is one `claude -p`
# session running `code-review` at review.effort (default high: one forked context, no
# finder or verifier agents of its own) with no Agent tool; a hunter whose transcript shows a
# subagent of its own fails the step (_driver_review_capped). Its findings are candidates.
# Only when one is not a nit, the CHECK (_driver_review_check) is ONE more session, Read,
# Grep and Glob only, at review.checkEffort (default medium), handed each candidate's claim
# and place with the code around its line and the diff — never the hunter's reasoning, so it
# does not inherit the argument. It tries to disprove each finding and answers its verdict
# first, then one line quoting the code that decided it; only a
# finding judged not real is dropped. A check that answers nothing usable keeps every
# candidate (fail safe), and says so. review.check false counts the hunter's findings as they
# are. What the step then does with the answer (_driver_review_panel): it drops a nit (style,
# cleanup); a pre-existing defect leaves
# the change for the nightly sweep's queue (scripts/sweep-queue.sh), never the builder and
# never a ticket; and a finding already raised on this change (steps/review.posted.jsonl,
# keyed by scripts/finding-key.jq) is not raised again. The grades then act as above.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/push-requires.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tier.sh" || exit 1

driver_step_review() { # <ticket>
  local t="${1:?driver_step_review: need a ticket}"
  local rc round ans_file verdict nsend ungraded nnit
  export DRIVER_TICKET="$t"

  round=$(driver_state_count "$t" review)

  # A VERDICT NOBODY CAN GIVE IS ASKED ABOUT BEFORE THE REVIEW IS PAID FOR. The
  # full requirement run is after the model; a row the driver cannot run would only
  # refuse there, or at the push.
  rc=0; driver_push_requires_unpayable "$t" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  # Merge first: below the review priorities the model's answer cannot stop the merge.
  local skipwhy
  if skipwhy=$(_driver_review_priority_skip "$t"); then
    _driver_review_priority_skipped "$t" "$skipwhy"; return $?
  fi

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
  # A REPAIR IS REVIEWED ON ITS OWN CHANGE. The PR was reviewed (and maybe signed off)
  # before; re-reviewing all of it sent fixes, screens among them, after the sign-off.
  # Its own change: every commit since the repair began, and of a trunk merge only the
  # files whose resolution differs from both sides.
  local -a dargs=(); local rbase own_paths="" own_scope="" p
  rbase=$(driver_state_get "$t" repair_base)
  # AN ADOPTED DRAFT IS REVIEWED WHOLE: the driver never reviewed any of it.
  if [ "$(driver_state_get "$t" mode)" = repair ] && [ -n "$rbase" ] && ! driver_adopted "$t"; then
    # --first-parent: a merge's second side is the trunk's commits, never the repair's.
    own_paths=$(git -C "$wt" log --first-parent --diff-merges=cc --name-only --format= "$rbase"..HEAD 2>/dev/null | sed '/^$/d' | sort -u)
    dargs=("$rbase"..HEAD --); own_scope=1
    while IFS= read -r p; do [ -n "$p" ] && dargs+=("$p"); done <<<"$own_paths"
    if [ -n "$own_paths" ]; then diff=$(git -C "$wt" diff "${dargs[@]}" 2>/dev/null); else diff=""; fi
    driver_say "   review: the repair's own change since $(printf '%s' "$rbase" | cut -c1-8), $(printf '%s' "$own_paths" | grep -c .) file(s)"
  elif [ -n "$trunk" ]; then
    dargs=("$trunk"...HEAD)
    diff=$(git -C "$wt" diff "${dargs[@]}" 2>/dev/null)
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
$(git -C "$wt" diff --stat "${dargs[@]}" 2>/dev/null)
Read the rest in the worktree — do NOT review the part above as if it were the whole change.]"
  fi
  [ -n "$diff" ] || [ -z "$own_paths$rbase" ] || [ "$(driver_state_get "$t" mode)" != repair ] || driver_adopted "$t" \
    || diff="(none — this repair made no change of its own: a clean merge of $INTEGRATION_BRANCH, or nothing at all. The PR was reviewed before it; judge only this.)"
  # A LATER PASS ASKS FIRST WHETHER THERE IS ANYTHING NEW TO REVIEW.
  local tier maxr="$DRIVER_MAX_REVIEW_ROUNDS" again
  tier=$(driver_change_tier "$t" "$wt" "$trunk" | cut -f1)
  [ "$tier" != tooling ] || maxr=1
  # A QUICK CHANGE (steps/size.sh) is graded as tooling is: Critical and Major block, a
  # Minor does not. One that blocks takes the ticket to the full route's
  # fix step (build-ticket), so a quick change is never reviewed twice on its own route.
  local quick=""; [ "$(driver_state_get "$t" route)" = quick ] && quick=1
  if [ "$round" -ge 1 ]; then
    again=$(_driver_review_again "$t" "$wt" "$round" "$maxr" "${dargs[@]}")
    if [ "${again%% *}" != run ]; then
      _driver_review_no_call "$t" "${again%% *}" "${again#* }"; return $?
    fi
    driver_say "   review: round $((round + 1)) of $maxr — ${again#run }"
    diff="$diff

[ROUND $((round + 1)): only $(driver_blocking_grades 2) block. ${again#run }]"
  fi
  # THE BUILD IS HELD TO ITS SCREEN CHECKLIST, written up front by the plan or quick step.
  local scl; scl=$(driver_state_get "$t" screen_checklist)
  if [ -n "$scl" ] && [ "$scl" != "[]" ]; then diff="${diff}

[SCREEN CHECKLIST the plan committed to — check the shipped code against each line. A line it does not meet is a finding; a person misled or stuck is Major:
$(printf '%s' "$scl" | jq -r '.[]? | "- \(.state): loading — \(.loading); failed — \(.failed); retry in flight — \(.retry); empty — \(.empty); phone — \(.phone)"' 2>/dev/null)]"
  fi
  # A PERSON'S STOP IS READ BY THE REVIEW TOO: a Critical a person named since the last
  # hand-off is an open blocking finding, not history. Ship refuses on it regardless.
  local pstop pstoprc=0
  pstop=$(bash "${DRIVER_PERSON_STOP:-$KIT_ROOT/scripts/person-stop.sh}" check "$t" $(driver_state_get "$t" pr) 2>&1) || pstoprc=$?
  [ "$pstoprc" -ne 1 ] || diff="${diff}

[A PERSON HAS STOPPED THIS — each line is an open blocking finding of theirs. Report each as a Critical finding unless this change visibly fixes it, and say which. Ship will not land it while their stop stands, whatever your verdict:
$(printf '%s\n' "$pstop" | sed 's/^/- /')]"
  # NEVER RAISED TWICE: the next review is told what this change was already handed.
  local posted; posted="$(driver_state_dir "$t")/steps/review.posted.jsonl"
  [ ! -s "$posted" ] || diff="${diff}

[ALREADY RAISED ON THIS CHANGE — never return any of these again, reworded or not:
$(jq -r '"- \(.file // "?") — \(.summary // "")"' "$posted" 2>/dev/null)]"
  # AREA GUIDES: the nearest REVIEW.md above each changed path, read from the trunk so a
  # change never writes the guide it is judged by. On a repair the changed set is its own.
  local changed guides=""
  if [ -n "$own_scope" ]; then changed="$own_paths"
  elif [ "${#dargs[@]}" -gt 0 ]; then changed=$(git -C "$wt" diff --name-only "${dargs[@]}" 2>/dev/null)
  else changed=""; fi
  [ -z "$changed" ] || [ -z "$trunk" ] \
    || guides=$(printf '%s\n' "$changed" | bash "$KIT_ROOT/scripts/review-guide.sh" "$wt" "$trunk" 2>/dev/null)
  [ -z "$guides" ] || diff="${diff}

[AREA REVIEW GUIDES — what each area asks of its reviewer: what to skip, the nit cap, the evidence wanted. Hold the change to the guide of every file it touches:
${guides}]"
  driver_fact_put "$t" review DIFF \
    "${diff:-(none — nothing to diff: no $INTEGRATION_BRANCH resolves in $wt, or the branch carries no change)}"
  # THE REVIEWER IS CLAUDE CODE'S OWN code-review, at review.effort (default high: one
  # forked context, no agents of its own; max only when configured), against the base this
  # change is judged on: the repair's own base, else the trunk.
  local effort; effort=$(driver_opt review.effort high)
  case "$effort" in
    low|medium|high|xhigh|max) : ;;
    *) driver_say "⚠ review: harness.json's review.effort is '${effort}', which is not low, medium, high, xhigh or max, so high is used."
       effort=high ;;
  esac
  driver_fact_put "$t" review EFFORT "$effort"
  local target="$trunk"
  [ "$(driver_state_get "$t" mode)" != repair ] || [ -z "$rbase" ] || driver_adopted "$t" || target="$rbase"
  driver_fact_put "$t" review TARGET "${target:-HEAD~1}"
  # RENDERS is a fact about a screen, and the driver takes none. Saying so is the
  # point: the reviewer is told there are no renders rather than shown the word
  # {{RENDERS}} and left to guess whether that meant a clean screen.
  driver_fact_put "$t" review RENDERS \
    "$(driver_state_get "$t" renders | sed -e 's/^$/(none — this run took no renders, so judge no screen from them)/')"
  driver_fact_put "$t" review ROUND "$((round + 1))"

  # The build answers: one per plan task, so the whole file rather than the last one.
  local built="$(driver_state_dir "$t")/steps/build.all.json"
  [ -s "$built" ] || built="$(driver_state_dir "$t")/steps/build.json"
  local seen_head; seen_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
  rc=0; _driver_review_hunt "$t" "$built" "$effort" || rc=$?
  # A REVIEWER THAT HAD NOT REPORTED IS RUN AGAIN, NOT ASKED ABOUT: the answer is always
  # yes. Once, by itself, and not a round (nothing is counted until a verdict is read).
  local silent
  if silent=$(_driver_review_silent "$t" "$rc"); then
    driver_say "↻ review: the reviewer had not reported ($silent) — running the review once more; this is not a second round"
    driver_state_set "$t" park_note ""
    rc=0; _driver_review_hunt "$t" "$built" "$effort" || rc=$?
    if silent=$(_driver_review_silent "$t" "$rc"); then
      driver_say "✋ review: machine fault reviewer-silent — the reviewer had not reported twice ($silent). Parked as the machine's, not a question; the next run reviews again."
      driver_state_set "$t" machine_fault "the review step's reviewer had not reported, twice"
      driver_state_set "$t" park_note "machine fault, nothing to answer: the review step's reviewer had not reported, twice ($silent). The next run reviews again."
      driver_state_set "$t" park_cause driver
      return "$DRIVER_E_MACHINE"
    fi
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  driver_state_bump "$t" review
  # WHAT THIS REVIEW SAW is recorded only once its answer is read as a review (below):
  # a refused answer is no review, and the next pass must not treat it as one.
  driver_state_set "$t" reviewed_head ""
  round=$((round + 1))
  ans_file="$(driver_state_dir "$t")/steps/review.json"
  # A new review cycle (a build, or a repair) starts its deferred list empty.
  [ "$round" -gt 1 ] || rm -f "$(driver_state_dir "$t")/steps/review.deferred.jsonl"

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

  # THE CHECK, THE TAG AND NEVER TWICE, before any grade has an effect.
  _driver_review_panel "$t" "$ans_file" "$round" || return "$DRIVER_E_REFUSED"

  # Off until the release: a critic finding the reviewer copied off the PR is no finding.
  driver_drop_critic_findings "$ans_file" review "$t" && _driver_review_verdict_off_grades "$ans_file" "$(driver_blocking_grades "$round")" 1
  # A finding that only says the branch clashes is the PR's repair, never a block or a ticket.
  driver_drop_clash_findings "$ans_file" review && _driver_review_verdict_off_grades "$ans_file" "$(driver_blocking_grades "$round")" 1
  verdict=$(jq -r '.verdict // ""' "$ans_file" | tr '[:lower:]' '[:upper:]')
  # A TOOLING BUILD GETS ONE ROUND, graded as a later round: only Critical and Major block.
  local ground="$round"
  if [ "$tier" = tooling ] || [ -n "$quick" ]; then [ "$ground" -ge 2 ] || ground=2; fi
  _driver_review_same_change "$t" "$ans_file" "$ground" "$wt" "${dargs[@]}"
  _driver_review_defer "$t" "$ans_file" "$ground"
  verdict=$(jq -r '.verdict // ""' "$ans_file" | tr '[:lower:]' '[:upper:]')

  rc=0; _driver_review_hold_signed "$t" "$ans_file" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  nsend=$(_driver_count "$ans_file" blocking)
  # `-le`, not `-lt`: every model round's blockers go to fix, and the pass after the
  # last round calls no model (_driver_review_again) — never a third review.
  if [ "$verdict" = "BLOCKED" ] && [ "${nsend:-0}" -gt 0 ] && [ "$round" -le "$maxr" ]; then
    driver_say "✋ review round $round of $maxr: $nsend blocking ($(driver_blocking_grades "$ground")) finding(s) — $(_driver_join "$(_driver_findings "$ans_file" blocking)")"
    _driver_review_seen "$t" "$wt" "$seen_head" "${dargs[@]}"
    _driver_review_posted "$t" "$ans_file" "$round"
    return "$DRIVER_E_REWORK"
  fi

  # SHIP BESIDE AN OPEN CRITICAL OR MAJOR. The contract already refuses this, and that
  # is exactly why the driver has to as well: a check and the thing it checks derived
  # from one input is one input away from agreeing about nothing. Past the rounds the
  # rework branch above stops firing, so without this a Critical typed under a SHIP
  # verdict walks into the ship step and lands.
  if [ "$verdict" = "SHIP" ] && [ "${nsend:-0}" -gt 0 ]; then
    driver_say "✋ review: SHIP beside $nsend open blocking ($DRIVER_BLOCKING_GRADES) finding(s) — $(_driver_join "$(_driver_findings "$ans_file" blocking)"). The verdict is read off the grades; it is not typed beside them."
    return "$DRIVER_E_REFUSED"
  fi
  _driver_review_seen "$t" "$wt" "$seen_head" "${dargs[@]}"

  rc=0; driver_push_requires "$t" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  _driver_review_posted "$t" "$ans_file" "$round"

  # Past the last rework round, every blocking finding stays with this ticket and
  # the ship step refuses, naming it. Nothing is filed from here.

  nnit=$(_driver_count "$ans_file" nit)
  # SAY THE DROP. A nit dropped in silence is indistinguishable from a reviewer that
  # found nothing, so the count is what tells a reader which happened.
  [ "${nnit:-0}" -gt 0 ] && driver_say "   review: $nnit nit(s) dropped — taste, and taste never blocks"
  driver_say "   review: $verdict after $round round(s)"
  return "$DRIVER_OK"
}

# _driver_review_panel <ticket> <review.json> <round> — what the hunter's answer keeps.
_driver_review_panel() {
  local t="$1" f="$2" round="$3" keydef ledger n m pre npre fixes dropped=0
  keydef=$(cat "$KIT_ROOT/scripts/finding-key.jq" 2>/dev/null) || { driver_say "✋ review: $KIT_ROOT/scripts/finding-key.jq is missing"; return 1; }
  # ONLY WHAT THE CHECK JUDGED REAL, before anything else reads the findings.
  n=$(jq '(.findings // []) | length' "$f" 2>/dev/null)
  _driver_review_check "$t" "$f" || return 1
  m=$(jq '(.findings // []) | length' "$f" 2>/dev/null)
  dropped=$((dropped + ${n:-0} - ${m:-0}))
  # STYLE AND CLEANUP NEVER BLOCK, and the drop is said.
  n=$(jq '[.findings[]? | select(.tag == "nit")] | length' "$f" 2>/dev/null)
  if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
    jq '.findings = [(.findings // [])[] | select(.tag != "nit")]' "$f" > "$f.t" && mv "$f.t" "$f" || return 1
    dropped=$((dropped + n))
    driver_say "   review: $n nit(s) dropped — style and cleanup never block"
  fi
  # A PRE-EXISTING DEFECT IS THE SWEEP'S: never back to the builder, never a ticket.
  pre=$(jq -c '[.findings[]? | select(.tag == "pre-existing")]' "$f" 2>/dev/null)
  npre=$(printf '%s' "$pre" | jq 'length' 2>/dev/null)
  if [ "${npre:-0}" -gt 0 ] 2>/dev/null; then
    _driver_review_to_sweep "$t" "$pre" "$round"
    jq '.findings = [(.findings // [])[] | select(.tag != "pre-existing")]' "$f" > "$f.t" && mv "$f.t" "$f" || return 1
    dropped=$((dropped + npre))
    driver_say "   review: $npre pre-existing finding(s) to the nightly sweep — not this change's, and never a ticket"
  fi
  # NEVER RAISED TWICE: a finding this change was already handed, and a fix round has answered
  # since, is not handed again. With no fix round since, a re-raise is the finding still standing.
  fixes=$(driver_state_count "$t" fix)
  ledger="$(driver_state_dir "$t")/steps/review.posted.jsonl"
  if [ -s "$ledger" ]; then
    n=$(jq --slurpfile p "$ledger" --argjson fx "${fixes:-0}" "$keydef"' ([$p[] | select((.fix // 0) < $fx) | .key]) as $seen | [.findings[]? | select(finding_key as $k | $seen | index($k))] | length' "$f" 2>/dev/null)
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
      jq --slurpfile p "$ledger" --argjson fx "${fixes:-0}" "$keydef"' ([$p[] | select((.fix // 0) < $fx) | .key]) as $seen | .findings = [(.findings // [])[] | select(finding_key as $k | $seen | index($k) | not)]' "$f" > "$f.t" && mv "$f.t" "$f" || return 1
      dropped=$((dropped + n))
      driver_say "   review: $n finding(s) already raised on this change are not raised again"
    fi
  fi
  cp "$f" "$f.panel" 2>/dev/null || true
  # A BLOCKED the panel emptied is read off what is left; one that named nothing stays as given.
  [ "$dropped" -eq 0 ] || _driver_review_verdict_off_grades "$f" "$(driver_blocking_grades "$round")" 1
}

# _driver_review_hunt <ticket> <build answers> <effort> — the hunter: ONE session running
# the review brief (`code-review` at <effort>, no Agent tool) in its own slot, review-hunter,
# sharing the facts this step gathered. 0 with steps/review.json its answer; else the call's
# code, with whatever it answered in review's place, as one reviewer's always was.
_driver_review_hunt() {
  local t="$1" built="$2" effort="$3" d rc
  d="$(driver_state_dir "$t")/steps"
  rm -rf "$d/review-hunter.facts"; cp -R "$d/review.facts" "$d/review-hunter.facts"
  rm -f "$d/review-hunter.json" "$d/review-hunter.log"
  driver_say "   review: one hunter, code-review at $effort in its own session, no subagents"
  rc=0; driver_ai_step "$t" review --as review-hunter "$built" || rc=$?
  cp "$d/review-hunter.log" "$d/review.log" 2>/dev/null || true
  _driver_review_capped "$t" review-hunter "the hunter" || return "$DRIVER_E_REFUSED"
  [ "$rc" -eq 0 ] || return "$rc"
  # One id per finding: the check's judgements are matched to findings by it.
  jq '.findings = ((.findings // []) as $fs | [range(0; $fs | length) as $i | $fs[$i]
        | (.id // "f" | tostring) as $id
        | .id = (if ([$fs[0:$i][] | (.id // "f" | tostring)] | index($id)) == null then $id else "\($id)-\($i + 1)" end)])' \
    "$d/review.json" > "$d/review.json.t" && mv "$d/review.json.t" "$d/review.json"
}

# _driver_review_check_on — review.check (default true); DRIVER_REVIEW_CHECK outranks it.
_driver_review_check_on() {
  case "${DRIVER_REVIEW_CHECK:-$(driver_opt review.check true)}" in
    false|0|no|off) return 1 ;;
  esac
  return 0
}

# _driver_review_check_effort — review.checkEffort (default medium), said when it is not a level.
_driver_review_check_effort() {
  local e; e=$(driver_opt review.checkEffort medium)
  case "$e" in
    low|medium|high|xhigh|max) : ;;
    *) driver_say "⚠ review: review.checkEffort is '${e}', which is not low, medium, high, xhigh or max, so medium is used." >&2
       e=medium ;;
  esac
  printf '%s' "$e"
}

# _driver_review_context <tree> <file> <line> — the code around a finding's line, numbered:
# 12 lines either side, or the file's first 25 when it names no line.
_driver_review_context() {
  local wt="$1" p="$2" l="${3:-0}" from to
  p=$(printf '%s' "$p" | sed -e 's#^\./##' -e 's/:[0-9]*$//')
  [ -n "$p" ] && [ -f "$wt/$p" ] || { printf "(no such file in the change's tree: %s)" "${p:-none}"; return 0; }
  case "$l" in ''|*[!0-9]*) l=0 ;; esac
  if [ "$l" -gt 0 ]; then from=$((l > 12 ? l - 12 : 1)); to=$((l + 12)); else from=1; to=25; fi
  awk -v a="$from" -v b="$to" 'NR >= a && NR <= b { printf "%6d  %s\n", NR, $0 } NR > b { exit }' "$wt/$p"
}

# _driver_review_check <ticket> <review.json> — the check: ONE session (step review-check,
# Read Grep Glob only, at review.checkEffort) judges each candidate the hunter raised that is
# not a nit, and a finding it judges not real leaves the answer. Not run when there is no
# such candidate or review.check is false. A check that fails, or judges none of the
# candidates, keeps them all (fail safe); a candidate it does not judge is kept. Records
# panel.checked (candidates judged) and panel.kept, and says one line either way.
_driver_review_check() {
  local t="$1" f="$2" d wt cand n effort ceffort rc note_was ans usable judged k drop why=""
  d="$(driver_state_dir "$t")/steps"
  effort=$(head -1 "$d/review.facts/EFFORT" 2>/dev/null); effort=${effort:-high}
  cand=$(jq -c '[.findings[]? | select((.grade // "") != "nit" and (.tag // "") != "nit")]' "$f" 2>/dev/null) || cand='[]'
  n=$(printf '%s' "$cand" | jq 'length' 2>/dev/null); n=${n:-0}
  judged=0; k=$n
  if [ "$n" -eq 0 ]; then
    driver_say "   review: hunter found 0, check kept 0 (dropped 0) — nothing to check, so no check ran"
  elif ! _driver_review_check_on; then
    driver_say "   review: hunter found $n, check kept $n (dropped 0) — review.check is off, so the hunter's findings count as they are"
  else
    wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] && [ -d "$wt" ] || wt="$MAIN_REPO"
    ceffort=$(_driver_review_check_effort)
    local i fl ln block=""
    # Counted, not seq: `seq 0 -1` is empty on GNU and counts down on BSD.
    for ((i = 0; i < n; i++)); do
      fl=$(printf '%s' "$cand" | jq -r --argjson i "$i" '.[$i].file // "" | tostring')
      ln=$(printf '%s' "$cand" | jq -r --argjson i "$i" '.[$i].line // 0 | tostring')
      # The claim and where it is, never the hunter's reasoning: a check handed the argument inherits it.
      block="${block}$(printf '%s' "$cand" | jq -r --argjson i "$i" '.[$i] | "### \(.id)\n- file: \(.file // "?"), line \(.line // 0)\n- claim: \(.summary // "")"')
- the code around it:
\`\`\`
$(_driver_review_context "$wt" "$fl" "$ln")
\`\`\`

"
    done
    rm -rf "$d/review-check.facts"; rm -f "$d/review-check.json"
    driver_fact_put "$t" review-check FINDINGS "$block"
    driver_fact_put "$t" review-check DIFF "$(cat "$d/review.facts/DIFF" 2>/dev/null)"
    note_was=$(driver_state_get "$t" park_note)
    rc=0; DRIVER_STEP_EFFORT="$ceffort" driver_ai_step "$t" review-check || rc=$?
    ans="$d/review-check.json"
    usable=0
    if [ "$rc" -eq 0 ] && [ -s "$ans" ]; then
      usable=$(jq --argjson c "$cand" '[.judgements[]? | select(type == "object" and (.real | type) == "boolean") | .id | tostring] as $ids
          | [$c[] | select((.id | tostring) as $x | $ids | index($x))] | length' "$ans" 2>/dev/null) || usable=0
    fi
    if [ "${usable:-0}" -gt 0 ] 2>/dev/null; then
      judged=$usable
      drop=$(jq -c --argjson c "$cand" '[$c[].id | tostring] as $cids
          | [.judgements[]? | select(type == "object" and .real == false) | {id: (.id | tostring), reason: (.reason // "")}]
          | map(select(.id as $x | $cids | index($x))) | unique_by(.id)' "$ans")
      jq --argjson drop "$drop" '.findings = [(.findings // [])[] | select((.id | tostring) as $x | [$drop[].id] | index($x) | not)]' "$f" > "$f.t" && mv "$f.t" "$f" || return 1
      k=$((n - $(printf '%s' "$drop" | jq length)))
      [ "$judged" -eq "$n" ] || why=" — $((n - judged)) the check did not judge are kept"
      driver_say "   review: hunter found $n, check kept $k (dropped $((n - k)))$why"
      local line
      while IFS= read -r line; do [ -z "$line" ] || driver_say "   review: check dropped $line"; done < <(printf '%s' "$drop" \
        | jq -r --argjson c "$cand" '.[] | . as $x | ([$c[] | select((.id | tostring) == $x.id)] | first) as $f
            | "\($x.id) \($f.file // "?"):\($f.line // "?") — \($x.reason | tostring | gsub("\n"; " "))"')
    else
      driver_state_set "$t" park_note "$note_was"
      driver_say "   review: hunter found $n, check kept $n (dropped 0) — the check answered nothing usable (exit $rc), so the hunter's findings stand (fail safe)"
    fi
  fi
  jq --arg e "$effort" --argjson c "$judged" --argjson k "$k" \
    '.panel = ((.panel // {skill: "code-review"}) + {effort: $e, checked: $c, kept: $k})' "$f" > "$f.t" && mv "$f.t" "$f"
}

# _driver_review_spawns <transcript> — how many subagents a reviewer started of its own: an
# Agent or Task tool call at any depth, or a started task no Skill call opened. code-review
# itself runs in the one context its Skill call forks (measured 2026-11-02 at high: one task,
# spawn depth 1, opened by the Skill call, and no Agent call anywhere). A command the review
# runs is a task too (task_type local_bash), never an agent: counting it parked 6 changes.
_driver_review_spawns() {
  driver_log_events "$1" 2>/dev/null | jq -s '
    ([.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")]) as $uses
    | ([$uses[] | select(.name == "Skill") | .id // empty]) as $skills
    | ([$uses[] | select(.name == "Agent" or .name == "Task") | (.id // "agent")]
       + [.[] | select(.type == "system" and .subtype == "task_started")
          | select((.task_type // "local_agent") | test("agent"))
          | select(((.tool_use_id // "") as $i | $skills | index($i)) == null or (.spawn_depth // 1) > 1)
          | (.tool_use_id // .task_id // "task")])
    | unique | length' 2>/dev/null || echo 0
}

# _driver_review_capped <ticket> <slot> [who] — 0 when the slot's reviewer started no
# subagent of its own. Else the step fails, loudly, parked as the driver's: an unbounded
# review is a cost fault, never a verdict.
_driver_review_capped() {
  local t="$1" slot="$2" who="${3:-the reviewer}" log k
  log="$(driver_state_dir "$t")/steps/$slot.log"
  [ -s "$log" ] || return 0
  k=$(_driver_review_spawns "$log")
  [ "${k:-0}" -gt 0 ] 2>/dev/null || return 0
  driver_say "✋ review: $who started $k subagent(s) of its own. A review step's agent count is bounded and configured (one hunter, one check), never left to a skill's top level — the step fails rather than pay for an unbounded panel."
  driver_state_set "$t" park_note "the review step's $who started $k subagent(s) of its own, past the cap of none (the review runs one hunter and one check, no agents of their own). Fix the reviewer's tools or review.effort, then run again."
  driver_state_set "$t" park_cause driver
  return 1
}

# _driver_review_posted <ticket> <review.json> <round> — every finding this review handed
# on (to fix, the sweep or dropped), on the never-twice ledger. Written only once
# the step acts on them: a refused answer posted nothing, and its re-run must not lose them.
_driver_review_posted() {
  local t="$1" f="$2" round="$3" src keydef ledger fx
  src="$f.panel"; [ -f "$src" ] || src="$f"
  keydef=$(cat "$KIT_ROOT/scripts/finding-key.jq" 2>/dev/null) || return 0
  ledger="$(driver_state_dir "$t")/steps/review.posted.jsonl"
  fx=$(driver_state_count "$t" fix)
  jq -c --argjson r "$round" --argjson fx "${fx:-0}" "$keydef"' .findings[]? | select((.grade // "") != "nit")
      | select((.id // "" | tostring | startswith("polish-")) | not)
      | {key: finding_key, id, file, line, grade, summary, round: $r, fix: $fx} + (if .class then {class} else {} end)' "$src" >> "$ledger" 2>/dev/null || true
  rm -f "$f.panel"
}

# _driver_review_priority_skip <ticket> — prints the priority and returns 0 when merge first
# skips the review model for this ticket; 1 when the review runs. Under release.mergeFirst
# only a Critical blocks, and only a ticket at one of release.reviewPriorities (default P0
# P1) is reviewed: anything else, unprioritised and polish included, ships on CI. The
# priority is the PR's own P label, else its ticket's (as the merge lane reads it). Labels
# that cannot be read, a person's stop, or an open Critical from an earlier review: the
# review runs as before.
_driver_review_priority_skip() {
  local t="$1" pr il pl pri pris stoprc=0 f
  driver_merge_first || return 1
  il=$(driver_gh_read swarm_gh issue view "$t" --repo "$REPO_SLUG" --json labels -q '[.labels[]?.name]' 2>/dev/null) || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$il" || return 1
  pl='[]'
  pr=$(driver_state_get "$t" pr); [ -n "$pr" ] || pr=$(driver_state_get "$t" repair_pr)
  if [ -n "$pr" ]; then
    pl=$(driver_gh_read swarm_gh pr view "$pr" --repo "$REPO_SLUG" --json labels -q '[.labels[]?.name]' 2>/dev/null) || return 1
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$pl" || return 1
  fi
  pris=$(release_review_priorities 2>/dev/null) || pris='["P0","P1"]'
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$pris" || pris='["P0","P1"]'
  pri=$(jq -rn --argjson il "$il" --argjson pl "$pl" --argjson pris "$pris" --arg plist "${LBL_POLISH_LIST:-polish-list}" '
    def pri($ls): [$ls[]? | select(type == "string" and test("^P[0-9]$"))] | first // "";
    (if pri($pl) != "" then $pl else ($pl + $il) end) as $ls
    | pri($ls) as $p
    | if ($ls | index($plist)) != null then "polish"
      elif $p == "" then "no priority"
      elif ($pris | index($p)) != null then ""
      else $p end') || return 1
  [ -n "$pri" ] || return 1
  # A person's stop is theirs to clear, and the review is how the fix step learns of it.
  bash "${DRIVER_PERSON_STOP:-$KIT_ROOT/scripts/person-stop.sh}" check "$t" $pr >/dev/null 2>&1 || stoprc=$?
  [ "$stoprc" -eq 0 ] || return 1
  f="$(driver_state_dir "$t")/steps/review.json"
  [ ! -f "$f" ] || [ "$(_driver_count "$f" blocking)" = 0 ] || return 1
  printf '%s' "$pri"
}

# _driver_review_priority_skipped <ticket> <priority> — no model call: the answer is a
# clean SHIP that names why, so record and ship proceed.
_driver_review_priority_skipped() {
  local t="$1" pri="$2" d
  d="$(driver_state_dir "$t")/steps"; mkdir -p "$d"
  jq -n --arg why "$pri, merge-first: ships on CI" '{verdict: "SHIP", findings: [], skipped: $why}' > "$d/review.json.t" \
    && mv "$d/review.json.t" "$d/review.json" || return "$DRIVER_E_REFUSED"
  driver_state_bump "$t" review
  driver_state_bump "$t" review_skipped
  driver_state_set "$t" review_skipped_priority "$pri"
  driver_say "   review: skipped ($pri, merge-first: ships on CI)"
  return "$DRIVER_OK"
}

# _driver_review_silent <ticket> <rc> — 0, printing how, when the review call came back
# without its reviewer having reported: a question saying a subagent had not reported
# (still running, timed out), no answer at all, or an answer carrying no verdict.
# AN UNFINISHED REVIEW IS NEVER A PERSON'S DECISION. A P0 parked to the owner on 2026-10-23
# asking "Should the review step be run again so the reviewer can finish before a verdict
# is recorded? (yes/no)" — the answer is always yes, so the step asks itself. A question
# that asks to run the review again, or names a verdict not yet reached, reads as silent.
_driver_review_rerun_question() { # <question>
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | grep -Eq \
    "(re-?run|run)[^.?!]*review[^.?!]*(again|once more|a second time)|review( step)? (be )?(re-?run|run again|run once more)|reviewer[^.?!]*(finish|complete|report)[^.?!]*(before|so)|(before|until) (a|the|its) verdict|verdict (is|was|has)( not| n.t)? (yet )?(been )?(recorded|reached|returned)|no verdict (yet|was|is)"
}
_driver_review_silent() {
  local t="$1" rc="$2" f q
  f="$(driver_state_dir "$t")/steps/review.json"
  if [ "$rc" -eq "$DRIVER_E_QUESTION" ]; then
    q=$(jq -r '(.question // .park // "")' "$f" 2>/dev/null)
    driver_question_silent_agent "$q" || _driver_review_rerun_question "$q" || return 1
    printf 'it said: %s' "$(printf '%s' "$q" | cut -c1-160)"; return 0
  fi
  if [ "$rc" -eq "$DRIVER_E_SCHEMA" ]; then
    case "$(driver_state_get "$t" park_note)" in
      *"ended without an answer"*) printf 'the run ended with no answer'; return 0 ;;
    esac
    return 1
  fi
  [ "$rc" -eq 0 ] || return 1
  [ -z "$(jq -r '.verdict // "" | tostring' "$f" 2>/dev/null)" ] || return 1
  printf 'the answer carried no verdict'
}

# _driver_review_seen <ticket> <tree> <head> <diff args…> — what a review read as a
# review saw: its head, its diff's file list and the fix count then, for the next pass.
_driver_review_seen() {
  local t="$1" wt="$2" h="$3"; shift 3
  git -C "$wt" diff --name-only "$@" 2>/dev/null | sed '/^$/d' | sort -u > "$(driver_state_dir "$t")/steps/review.files.txt"
  driver_state_set "$t" reviewed_head "$h"
  driver_state_set "$t" reviewed_fix "$(driver_state_count "$t" fix)"
}

# _driver_review_again <ticket> <tree> <passes so far> <max> <diff args…> — whether a later
# pass calls the model. One line: "run <why>" — review again; "skip <why>" — no new
# review, the fix step proved the findings; "hold <why>" — no new review, and the findings
# stand (no fix ran since). The files a fix round touched are those changed since the
# reviewed head that are still in this change: a trunk merge brings files that are not.
_driver_review_again() {
  local t="$1" wt="$2" round="$3" maxr="$4" d rhead nb rfix now since new
  shift 4
  d="$(driver_state_dir "$t")/steps"
  rhead=$(driver_state_get "$t" reviewed_head)
  if [ -z "$rhead" ] || [ ! -f "$d/review.files.txt" ]; then echo "run the last pass recorded no review (refused, or never run) to compare with"; return 0; fi
  nb=$(_driver_count "$d/review.json" blocking); rfix=$(driver_state_get "$t" reviewed_fix)
  if [ "${nb:-0}" -gt 0 ] && [ "$(driver_state_count "$t" fix)" -le "${rfix:-0}" ]; then
    if [ "$round" -ge "$maxr" ]; then echo "hold the $maxr review round(s) are spent, and no fix round has answered the last review's $nb blocking finding(s)"
    else echo "run no fix round has answered the last review's $nb blocking finding(s)"; fi
    return 0
  fi
  [ "$round" -lt "$maxr" ] || { echo "skip the $maxr review round(s) are spent — never a third"; return 0; }
  case "$(driver_opt review.secondOnlyOnNewFiles true)" in
    false|0|no|off) echo "run review.secondOnlyOnNewFiles is off, so every pass is reviewed"; return 0 ;;
  esac
  git -C "$wt" cat-file -e "$rhead^{commit}" 2>/dev/null || { echo "run the reviewed head $rhead is not in this tree"; return 0; }
  now=$(git -C "$wt" diff --name-only "$@" 2>/dev/null | sed '/^$/d' | sort -u)
  since=$(git -C "$wt" diff --name-only "$rhead" 2>/dev/null | sed '/^$/d' | sort -u)
  new=$(comm -12 <(printf '%s\n' "$since") <(printf '%s\n' "$now") | comm -23 - "$d/review.files.txt" | sed '/^$/d')
  if [ -n "$new" ]; then
    echo "run the fix round touched $(printf '%s\n' "$new" | grep -c .) file(s) the last review never saw: $(printf '%s\n' "$new" | head -10 | tr '\n' ' ' | sed 's/ $//')"
  else
    echo "skip every file changed since the reviewed head $(printf '%s' "$rhead" | cut -c1-8) was in the reviewed diff"
  fi
}

# _driver_review_no_call <ticket> <skip|hold> <why> — a pass that does not call the model.
# skip: the last review's blocking findings were each answered by the fix step (proved,
# or it would have parked), so they leave the answer and the verdict is read off what is
# left. hold: they stand, and the ship step refuses on them. Either way the pass is
# counted, and the push's own reviewers still run.
_driver_review_no_call() {
  local t="$1" how="$2" why="$3" f n rc
  f="$(driver_state_dir "$t")/steps/review.json"
  driver_state_bump "$t" review
  driver_state_bump "$t" review_skipped
  if [ "$how" = skip ] && [ -f "$f" ]; then
    n=$(_driver_count "$f" blocking)
    cp "$f" "$f.before-skip" 2>/dev/null || true
    jq "del(.findings[]? | $(_driver_class blocking))
        | if (.verdict // \"\" | ascii_upcase) == \"BLOCKED\" then .verdict = \"SHIP\" else . end" "$f" > "$f.t" && mv "$f.t" "$f"
    driver_say "   review: no new review — $why. ${n:-0} finding(s) from the last review were answered by the fix round, which proved each one."
  else
    driver_say "   review: no new review — $why."
  fi
  rc=0; driver_push_requires "$t" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  n=$(_driver_count "$f" nit)
  [ "${n:-0}" -gt 0 ] && driver_say "   review: $n nit(s) dropped — taste, and taste never blocks"
  driver_say "   review: $(jq -r '.verdict // "none"' "$f" 2>/dev/null | tr '[:lower:]' '[:upper:]') after $(driver_state_count "$t" review) pass(es), $(( $(driver_state_count "$t" review) - $(driver_state_count "$t" review_skipped) )) reviewed by the model"
  return "$DRIVER_OK"
}

# _driver_review_defer <ticket> <review.json> <round> [late] — WHAT DOES NOT BLOCK THIS
# ROUND LEAVES THE FINDINGS, AND NOTHING IS FILED (the owner, 2026-11-02). Round 1 fixes
# every Critical, Major and Minor; a grade that blocks in round 1 and not in this round
# leaves. One in a file this change never touched (not inChange) is pre-existing and goes
# to the nightly sweep's queue; any other is dropped. Either way it is recorded in
# steps/review.deferred.jsonl, which the ship step notes in the PR. Never a follow-up
# ticket, never a polish list. [late] replaces the round's blocking set.
_driver_review_defer() {
  local t="$1" f="$2" round="$3" late defer n sweep nsweep d
  late="${4:-$(driver_blocking_grades "$round")}"
  # What does not block this round and is not a Nit is deferred — read off this round's
  # set alone. Comparing it with round 1's set skipped the whole step when an operator
  # configured both the same, and the reviewer's BLOCKED then stood over two Minors.
  defer=$(jq -c --arg late "$late" '[.findings[]? | select((.sameChange // false) != true)
      | select((.grade // "") as $g | $g != "nit" and (($late | split(" ")) | index($g)) == null)]' "$f" 2>/dev/null)
  n=$(printf '%s' "$defer" | jq 'length' 2>/dev/null)
  [ "${n:-0}" -gt 0 ] || { _driver_review_verdict_off_grades "$f" "$late"; return 0; }
  d="$(driver_state_dir "$t")/steps"
  sweep=$(printf '%s' "$defer" | jq -c '[.[] | select((.inChange // false) != true)]')
  nsweep=$(printf '%s' "$sweep" | jq 'length')
  [ "${nsweep:-0}" -eq 0 ] || _driver_review_to_sweep "$t" "$sweep" "$round"
  printf '%s' "$defer" | jq -c --argjson r "$round" '.[] | {id, grade, file, line, summary, round: $r,
      list: (if (.inChange // false) == true then "dropped" else "sweep" end)}' >> "$d/review.deferred.jsonl"
  jq --arg late "$late" '
      ($late | split(" ")) as $L
      | .findings = [(.findings // [])[] | select((.sameChange // false) == true or ((.grade // "") as $g | ($g != "nit" and ($L | index($g)) == null) | not))]' "$f" > "$f.t" && mv "$f.t" "$f"
  _driver_review_verdict_off_grades "$f" "$late" 1
  driver_say "   review round $round: $n finding(s) graded outside this round's blocking set ($late) do not block — $nsweep outside this change's files to the nightly sweep, $((n - nsweep)) dropped; none filed as a ticket"
}

# _driver_review_to_sweep <ticket> <findings json array> <round> — pre-existing defects to
# the nightly sweep's queue (scripts/sweep-queue.sh): never the builder's, never a ticket.
_driver_review_to_sweep() {
  local sq="${DRIVER_SWEEP_QUEUE:-$KIT_ROOT/scripts/sweep-queue.sh}"
  [ -n "${SWEEP_QUEUE:-}" ] || [ -z "${STATE_DIR:-}" ] || export SWEEP_QUEUE="$STATE_DIR/swarm/sweep/pre-existing.jsonl"
  printf '%s' "$2" | bash "$sq" add "$1" "$3" >/dev/null 2>&1 \
    || driver_say "⚠ review: the sweep queue could not take $(printf '%s' "$2" | jq length) finding(s) — they are dropped from this change all the same"
}

# _driver_review_same_change <ticket> <review.json> <graded round> <tree> <diff args…> — SAME FILE,
# SAME CHANGE (the owner, 2026-10-23). A Major or a Minor in a file this change itself
# touched is fixed in this change, in its one fix round, never filed: one ticket once
# spawned 24 findings over 8 follow-up PRs, all in the same four files. Such a finding is
# marked sameChange, which driver_blocking_select blocks in any round and under merge first.
# Graded as a later round (a second review, a tooling or a quick change: only Critical
# and Major block there) a Major alone is marked. Every finding in a file this change
# touched is marked inChange: one that does not block is dropped, never sent to the sweep
# (_driver_review_defer), which takes only what lies outside the change.
_driver_review_same_change() {
  local t="$1" f="$2" round="$3" wt="$4" own grades n
  shift 4
  own=$(git -C "$wt" diff --name-only "$@" 2>/dev/null | sed '/^$/d' | jq -Rsc 'split("\n") | map(select(length > 0))')
  [ -n "$own" ] && [ "$own" != "[]" ] || return 0
  if [ "$round" -le 1 ]; then grades="major minor"; else grades="major"; fi
  jq --argjson own "$own" --arg gs "$grades" '.findings = [(.findings // [])[]
      | (.grade // "") as $g | ((.file // "") | tostring | sub("^\\./"; "") | sub(":[0-9]+$"; "")) as $p
      | if ($own | index($p)) == null then .
        elif (($gs | split(" ")) | index($g)) != null then . + {inChange: true, sameChange: true}
        else . + {inChange: true} end]' "$f" > "$f.t" \
    && mv "$f.t" "$f" || return 0
  n=$(jq '[.findings[]? | select(.sameChange == true)] | length' "$f" 2>/dev/null)
  [ "${n:-0}" -gt 0 ] 2>/dev/null || return 0
  jq '.verdict = "BLOCKED"' "$f" > "$f.t" && mv "$f.t" "$f"
  driver_say "   review: $n finding(s) ($grades) are in files this change touched — fixed in this change's fix round (same file, same change)"
}

# _driver_review_verdict_off_grades <review.json> <blocking grades> [had-findings] — a
# BLOCKED over findings of which none blocks this round is a SHIP: the verdict is read
# off the grades. A BLOCKED that names nothing at all is left as the reviewer gave it.
_driver_review_verdict_off_grades() {
  jq --arg late "$2" --arg had "${3:-}" '
      ($late | split(" ")) as $L
      | if (.verdict // "" | ascii_upcase) == "BLOCKED" and (((.findings // []) | length) > 0 or $had != "")
           and ([(.findings // [])[] | select(((.grade // "") as $g | $L | index($g)) or (.sameChange // false) == true)] | length) == 0
        then .verdict = "SHIP" else . end' "$1" > "$1.t" && mv "$1.t" "$1"
}

# _driver_review_hold_signed <ticket> <review.json> — on a repair of a PR the owner
# signed off, a Critical or Major on a screen file is the owner's call: a fix there
# changes pixels after the sign-off. It parks for the owner, naming them, and the
# verdict is left as the reviewer gave it. A Minor there is polish, never a "cannot
# merge without": it is dropped (_driver_review_defer), and the repair
# carries on with no park and no pixel change (the owner's rule; #13339 parked on one). Signed is approval-kept's signed-head (a
# hold removed on GitHub counts); unreadable counts as signed, the cautious side.
# Screens are #234's one screen set (approval-kept.sh screens: surfacePaths plus
# extraScreens), never "every file" while surfacePaths is set.
_driver_review_hold_signed() {
  local t="$1" f="$2" pr ak arc files screens held
  [ "$(driver_state_get "$t" mode)" = repair ] || return 0
  # Merge first: the owner reviews on UAT after the merge, so no sign-off holds a fix.
  driver_merge_first && return 0
  pr=$(driver_state_get "$t" pr); [ -n "$pr" ] || return 0
  [ "$(_driver_count "$f" blocking)" -gt 0 ] 2>/dev/null || return 0
  files=$(jq -r "[.findings[]? | $(_driver_class blocking) | .file // empty] | unique | .[]" "$f" 2>/dev/null)
  ak="${DRIVER_APPROVAL_KEPT:-$KIT_ROOT/scripts/approval-kept.sh}"
  screens=$(printf '%s\n' "$files" | bash "$ak" screens 2>/dev/null | jq -Rsc 'split("\n") | map(select(length > 0))')
  [ "${screens:-[]}" != "[]" ] || return 0
  arc=0; bash "$ak" signed-head "$pr" >/dev/null 2>&1 || arc=$?
  [ "$arc" -eq 1 ] && return 0
  local must polish minors
  must=$(driver_blocking_grades 2)
  polish=$(driver_blocking_grades "$(driver_state_count "$t" review)" | tr ' ' '\n' | grep -vxF -f <(printf '%s\n' $must) | tr '\n' ' ' | sed 's/ $//')
  minors=$(jq -c --argjson s "$screens" --arg p "$polish" '[.findings[]? | select((.grade // "") as $g | ($p | split(" ")) | index($g)) | select((.file // "") as $x | $s | index($x))]' "$f")
  if [ -n "$polish" ] && [ "$(printf '%s' "$minors" | jq length)" -gt 0 ]; then
    printf '%s' "$minors" | jq '{verdict: "BLOCKED", findings: [.[] | del(.sameChange)]}' > "$f.signed"
    _driver_review_defer "$t" "$f.signed" "$(driver_state_count "$t" review)" "$must" "found on PR #$pr after its sign-off"
    rm -f "$f.signed"
    jq --argjson s "$screens" --arg p "$polish" '.findings = [(.findings // [])[] | select(((.grade // "") as $g | ($p | split(" ")) | index($g)) and ((.file // "") as $x | $s | index($x)) | not)]' "$f" > "$f.t" && mv "$f.t" "$f"
    _driver_review_verdict_off_grades "$f" "$(driver_blocking_grades "$(driver_state_count "$t" review)")" 1
    driver_say "   review: PR #$pr is signed off — its screens' polish is dropped, not put into this repair"
  fi
  held=$(jq -r --argjson s "$screens" "[.findings[]? | $(_driver_class blocking) | select((.file // \"\") as \$x | \$s | index(\$x)) | \"\\(.grade) \\(.file):\\(.line // \"?\") \\(.summary // \"\")\"] | join(\"; \")" "$f")
  [ -n "$held" ] || return 0
  driver_say "✋ review: PR #$pr $([ "$arc" -eq 2 ] && echo 'may be signed off (its sign-offs could not be read)' || echo 'is signed off'), and the review graded its screens: $held — a fix would change pixels after the sign-off, so it parks for the owner."
  driver_state_set "$t" park_note "Needs the owner: PR #$pr's screens were signed off$([ "$arc" -eq 2 ] && echo ' (or its sign-offs could not be read)'), and the review of this repair found on them: $held. Either each is dropped, or it is a fix the PR cannot merge without and its commit says pixel-change-after-signoff: <why>, which puts the hold back on for the owner to sign again."
  driver_state_set "$t" park_cause person
  return "$DRIVER_E_REFUSED"
}

# _driver_class <blocking|nit> — the jq selector for that class, in the ONE
# place it is written. Two copies of "what counts as blocking" is two places for the
# count and the list to disagree, which is how a message names three findings and the
# branch above acts on two.
_driver_class() { # <class>
  case "$1" in
    blocking) driver_blocking_select ;;
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
