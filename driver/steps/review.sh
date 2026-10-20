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
# Critical and Major do, and a Minor goes on its screen's polish list
# (_driver_review_defer). What blocks, past the rounds, stays with this ticket: the
# ship step refuses and names it. Nothing leaves a review
# as a follow-up ticket: filing Minors made every passing review open new work,
# 110 of the 339 bugs filed in one week. Nits are dropped — and the count is SAID,
# because dropped silently reads exactly like never raised.
#
# ONE CALL, NOT SEVERAL AGENTS. The driver runs one review brief per round. What
# that brief does inside itself — how many reviewers it asks, in what order — is
# Superpowers' business. Inside a ticket, splitting the work belongs to the
# skill; the driver never starts several agents on one ticket.
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
  local -a dargs=(); local rbase own_paths="" p
  rbase=$(driver_state_get "$t" repair_base)
  if [ "$(driver_state_get "$t" mode)" = repair ] && [ -n "$rbase" ]; then
    # --first-parent: a merge's second side is the trunk's commits, never the repair's.
    own_paths=$(git -C "$wt" log --first-parent --diff-merges=cc --name-only --format= "$rbase"..HEAD 2>/dev/null | sed '/^$/d' | sort -u)
    dargs=("$rbase"..HEAD --)
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
  [ -n "$diff" ] || [ -z "$own_paths$rbase" ] || [ "$(driver_state_get "$t" mode)" != repair ] \
    || diff="(none — this repair made no change of its own: a clean merge of $INTEGRATION_BRANCH, or nothing at all. The PR was reviewed before it; judge only this.)"
  # THE REVIEWER CONFIRMS A POLISH ITEM IS FIXED, not the builder's own record of it.
  local claimed=""
  [ "$(driver_state_get "$t" mode)" = repair ] || claimed=$(bash "${DRIVER_POLISH_LIST:-$KIT_ROOT/scripts/polish-list.sh}" taken "$t" 2>/dev/null)
  [ -z "$claimed" ] || diff="${diff}

[POLISH ITEMS THE BUILDER SAYS IT FIXED — confirm each one against the change. One that is not really fixed is a finding at its grade (an item that names no grade is a Minor), with the item's words as its summary:
$(printf '%s\n' "$claimed" | awk -F'\t' 'NF { printf "- %s (polish list #%s)\n", $2, $1 }')]"
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

  _driver_review_touched "$t" "$ans_file" "$wt" "$trunk"
  verdict=$(jq -r '.verdict // ""' "$ans_file" | tr '[:lower:]' '[:upper:]')
  # A TOOLING BUILD GETS ONE ROUND, graded as a later round: only Critical and Major block.
  local tier maxr="$DRIVER_MAX_REVIEW_ROUNDS" ground="$round"
  tier=$(driver_change_tier "$t" "$wt" "$trunk" | cut -f1)
  if [ "$tier" = tooling ]; then maxr=1; [ "$ground" -ge 2 ] || ground=2; fi
  _driver_review_defer "$t" "$ans_file" "$ground"
  verdict=$(jq -r '.verdict // ""' "$ans_file" | tr '[:lower:]' '[:upper:]')

  rc=0; _driver_review_hold_signed "$t" "$ans_file" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  nsend=$(_driver_count "$ans_file" blocking)
  # `-le`, not `-lt`: the design's flowchart sends work back on round 1 OR 2, so two
  # rounds means two chances to fix, and the pass after them ships.
  if [ "$verdict" = "BLOCKED" ] && [ "${nsend:-0}" -gt 0 ] && [ "$round" -le "$maxr" ]; then
    driver_say "✋ review round $round of $maxr: $nsend blocking ($(driver_blocking_grades "$ground")) finding(s) — $(_driver_join "$(_driver_findings "$ans_file" blocking)")"
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

  rc=0; driver_push_requires "$t" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  # Past the last rework round, every blocking finding stays with this ticket and
  # the ship step refuses, naming it. Nothing is filed from here.

  nnit=$(_driver_count "$ans_file" nit)
  # SAY THE DROP. A nit dropped in silence is indistinguishable from a reviewer that
  # found nothing, so the count is what tells a reader which happened.
  [ "${nnit:-0}" -gt 0 ] && driver_say "   review: $nnit nit(s) dropped — taste, and taste never blocks"
  driver_say "   review: $verdict after $round round(s)"
  return "$DRIVER_OK"
}

# _driver_review_touched <ticket> <review.json> <tree> <trunk> — FIX WHAT YOU TOUCH (the
# owner, 2026-10-20). Every free item on the polish list of a screen this change touches
# — the ticket's screen labels, and design.screenOf over the files it changes — is a
# finding of this review at the grade it carries (none named: Minor). Critical, Major and
# Minor block, so it comes back to fix like any other; it is cleared by fixing it and
# recording it on its list (polish-list.sh take), never by leaving it because this change
# did not add it. One PR left narration an earlier critic had flagged on its screen, and
# the next critic failed the screen for it. A repair is judged on its own change and
# takes none on; a list that cannot be read is said, not guessed.
#
# TWO KINDS STAY ON THE LIST, NOT BLOCKING (the PM's call, 2026-10-20): an item that is
# the owner's call, and one that needs a new picture — anything beyond the approved
# picture's pixels. The list marks them ("owner's call", "needs:owner", "[picture]",
# "needs a picture"). A taken item is cleared only because the review step was shown
# it and raised nothing: the builder's record alone is a claim, the reviewer the check.
_driver_review_touched() {
  local t="$1" f="$2" wt="$3" trunk="$4" files items taken add pl="${DRIVER_POLISH_LIST:-$KIT_ROOT/scripts/polish-list.sh}"
  [ "$(driver_state_get "$t" mode)" = repair ] && return 0
  files="$(driver_state_dir "$t")/steps/touched-files.txt"
  git -C "$wt" diff --name-only "$trunk"...HEAD > "$files" 2>/dev/null || : > "$files"
  if ! items=$(bash "${DRIVER_SCREEN_FINDINGS:-$KIT_ROOT/scripts/screen-findings.sh}" polish "$t" "$files" 2>&1); then
    driver_say "   review: the polish lists of the screens this change touches could not be read — $(printf '%s' "$items" | head -1)"
    return 0
  fi
  [ -n "$items" ] || return 0
  taken=$(bash "$pl" taken "$t" 2>/dev/null)
  local held; held=$(printf '%s\n' "$items" | cut -f3 | grep -ciE "owner'?s call|needs:owner|\[picture\]|needs a (new )?picture")
  [ "${held:-0}" -eq 0 ] || driver_say "   review: $held item(s) on the screen's polish list are the owner's call or need a new picture — left on the list, not blocking"
  add=$(printf '%s\n' "$items" | while IFS=$'\t' read -r g n it; do
          [ -n "$it" ] || continue
          printf '%s\n' "$it" | grep -qiE "owner'?s call|needs:owner|\[picture\]|needs a (new )?picture" && continue
          printf '%s\n' "$taken" | grep -qxF -- "$n	$it" && continue
          jq -nc --arg g "$g" --arg n "$n" --arg it "$it" --arg t "$t" --arg pl "$pl" '{
            id: ("polish-" + $n + "-" + ($it | @base64 | gsub("[^A-Za-z0-9]"; "") | .[0:10])),
            file: ("(polish list #" + $n + ")"), line: 0, grade: $g, summary: $it,
            reason: "already known on a screen this change touches: what you touch, you fix",
            fix: ("fix it in this change, then record it: bash " + $pl + " take " + $n + " " + $t + " \"" + $it + "\"")}'
        done | jq -sc '.')
  [ "$(printf '%s' "$add" | jq 'length' 2>/dev/null)" -gt 0 ] 2>/dev/null || return 0
  jq --argjson add "$add" '.findings = ((.findings // []) + $add)
      | if ([$add[] | select(.grade != "nit")] | length) > 0 then .verdict = "BLOCKED" else . end' "$f" > "$f.t" && mv "$f.t" "$f"
  driver_say "   review: $(printf '%s' "$add" | jq 'length') item(s) already on the polish list of a screen this change touches are findings of this review"
}

# _driver_review_defer <ticket> <review.json> <round> — FROM ROUND 2 A MINOR DOES NOT
# BLOCK (the owner, 2026-10-20). Round 1 fixes every Critical, Major and Minor; a grade
# that blocks in round 1 and not in this round leaves the findings and goes on the
# polish list of the screen it is on (polish-list.sh add), fixed by the next change
# there. No screen resolves, or the list cannot be written: it is kept as a note under
# "Minor, deferred" in the PR, still not blocking. Either way it is recorded in
# steps/review.deferred.jsonl. Builds and repairs count their own rounds the same way.
_driver_review_defer() {
  local t="$1" f="$2" round="$3" late defer d tmp i n x slug labels text list put=0 kept=0
  local pl="${DRIVER_POLISH_LIST:-$KIT_ROOT/scripts/polish-list.sh}" sf="${DRIVER_SCREEN_FINDINGS:-$KIT_ROOT/scripts/screen-findings.sh}"
  late=$(driver_blocking_grades "$round")
  local first; first=$(driver_blocking_grades 1)
  [ "$late" != "$first" ] || return 0
  defer=$(jq -c --arg late "$late" "[.findings[]? | $(driver_blocking_select 1)
      | select((.grade // \"\") as \$g | (\$late | split(\" \")) | index(\$g) == null)]" "$f" 2>/dev/null)
  n=$(printf '%s' "$defer" | jq 'length' 2>/dev/null)
  [ "${n:-0}" -gt 0 ] || return 0
  d="$(driver_state_dir "$t")/steps"; tmp="$d/defer-file.txt"
  labels=$(bash "$sf" screens "$t" 2>/dev/null)
  i=0
  while [ "$i" -lt "$n" ]; do
    x=$(printf '%s' "$defer" | jq -c ".[$i]"); i=$((i + 1))
    list=""
    case "$(printf '%s' "$x" | jq -r '.id // ""')" in
      polish-*) list=$(printf '%s' "$x" | jq -r '.file // ""' | sed -n 's/.*#\([0-9][0-9]*\).*/\1/p'); list="#${list:-?}" ;;
      *)
        printf '%s\n' "$(printf '%s' "$x" | jq -r '.file // ""')" > "$tmp"
        # The screen the finding's own file maps to, before the ticket's own screen labels.
        slug=$(bash "$sf" screens "$t" "$tmp" 2>/dev/null | L="$labels" awk 'BEGIN { n = split(ENVIRON["L"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") s[a[i]] = 1 } NF && !($0 in s) { print; exit }')
        [ -n "$slug" ] || slug=$(printf '%s\n' "$labels" | sed '/^$/d' | head -1)
        text=$(printf '%s' "$x" | jq -r --arg r "$round" --arg t "$t" '"[\(.grade | ascii_downcase | (.[0:1] | ascii_upcase) + .[1:])] \(.summary // "") — \(.file // "?"):\(.line // "?") (review round \($r) of #\($t))"')
        if [ -n "$slug" ] && bash "$pl" add "$slug" "$text" >/dev/null 2>&1; then list="$slug"; fi ;;
    esac
    if [ -n "$list" ]; then put=$((put + 1)); else kept=$((kept + 1)); fi
    printf '%s' "$x" | jq -c --arg l "$list" --argjson r "$round" '{grade, file, line, summary, round: $r, list: $l}' >> "$d/review.deferred.jsonl"
  done
  rm -f "$tmp"
  jq --arg late "$late" --arg first "$first" '
      ($late | split(" ")) as $L | ($first | split(" ")) as $F
      | .findings = [(.findings // [])[] | select((.grade // "") as $g | (($F | index($g)) != null and ($L | index($g)) == null) | not)]
      | if .verdict == "BLOCKED" and ([.findings[] | select((.grade // "") as $g | $L | index($g))] | length) == 0
        then .verdict = "SHIP" else . end' "$f" > "$f.t" && mv "$f.t" "$f"
  driver_say "   review round $round: $n finding(s) graded outside this round's blocking set ($late) do not block — $put on a screen's polish list, $kept noted in the PR under \"Minor, deferred\""
}

# _driver_review_hold_signed <ticket> <review.json> — on a repair of a PR the owner
# signed off, a Critical or Major on a screen file is the owner's call: a fix there
# changes pixels after the sign-off. It parks for the owner, naming them, and the
# verdict is left as the reviewer gave it. Signed is approval-kept's signed-head (a
# hold removed on GitHub counts); unreadable counts as signed, the cautious side.
# Screens are #234's one screen set (approval-kept.sh screens: surfacePaths plus
# extraScreens), never "every file" while surfacePaths is set.
_driver_review_hold_signed() {
  local t="$1" f="$2" pr ak arc files screens held
  [ "$(driver_state_get "$t" mode)" = repair ] || return 0
  pr=$(driver_state_get "$t" pr); [ -n "$pr" ] || return 0
  [ "$(_driver_count "$f" blocking)" -gt 0 ] 2>/dev/null || return 0
  files=$(jq -r "[.findings[]? | $(_driver_class blocking) | .file // empty] | unique | .[]" "$f" 2>/dev/null)
  ak="${DRIVER_APPROVAL_KEPT:-$KIT_ROOT/scripts/approval-kept.sh}"
  screens=$(printf '%s\n' "$files" | bash "$ak" screens 2>/dev/null | jq -Rsc 'split("\n") | map(select(length > 0))')
  [ "${screens:-[]}" != "[]" ] || return 0
  arc=0; bash "$ak" signed-head "$pr" >/dev/null 2>&1 || arc=$?
  [ "$arc" -eq 1 ] && return 0
  held=$(jq -r --argjson s "$screens" "[.findings[]? | $(_driver_class blocking) | select((.file // \"\") as \$x | \$s | index(\$x)) | \"\\(.grade) \\(.file):\\(.line // \"?\") \\(.summary // \"\")\"] | join(\"; \")" "$f")
  driver_say "✋ review: PR #$pr $([ "$arc" -eq 2 ] && echo 'may be signed off (its sign-offs could not be read)' || echo 'is signed off'), and the review graded its screens: $held — a fix would change pixels after the sign-off, so it parks for the owner."
  driver_state_set "$t" park_note "Needs the owner: PR #$pr's screens were signed off$([ "$arc" -eq 2 ] && echo ' (or its sign-offs could not be read)'), and the review of this repair found on them: $held. Either each becomes a follow-up ticket, or it is a fix the PR cannot merge without and its commit says pixel-change-after-signoff: <why>, which puts the hold back on for the owner to sign again."
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
