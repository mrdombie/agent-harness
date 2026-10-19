#!/usr/bin/env bash
# steps/ship.sh — push, pull request, hand off. Then stop.
#
#   driver_step_ship <ticket>
#
# THE PULL REQUEST IS OPENED AS A DRAFT and marked ready only once the review
# verdict is in. Not arming auto-merge is not enough on its own: an automerge
# workflow lands any green, non-draft, mergeable pull request, so draft is the
# only state that actually holds one. Auto is armed after ready, never before —
# it fires the instant CI goes green, whatever else is unfinished.
#
# THE RUN ENDS AT THE PUSH. It does not watch CI. Agents holding a slot while
# watching a run accounted for 36 of 123 agent-hours; a watcher brings one back
# if CI goes red or the pull request conflicts, which is work nobody has to be
# alive for.
#
# The body carries the review round count and the trunk SHA the ticket was
# claimed at, so both rules are checkable by a reader rather than promised by
# the agent that wrote them.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/push-requires.sh" || exit 1

# _driver_ship_replaced <ticket> — the "## Deleted tests" lines for the tests this
# ticket's steps reported rewording or removing (steps/replaced.jsonl), last word per file.
_driver_ship_replaced() {
  jq -rs '
    def flat: gsub("[\\r\\n\\t]+"; " ") | gsub("^\\s+|\\s+$"; "");
    [.[] | select(type == "object") | {file: ((.file // "") | flat), coveredBy: ((.coveredBy // "") | flat), removedBecause: ((.removedBecause // "") | flat)}
     | select(.file != "" and (.coveredBy != "" or .removedBecause != ""))]
    | group_by(.file) | map(last) | .[]
    | if .coveredBy != "" then "- `\(.file)` → covered by `\(.coveredBy)`"
      else "- `\(.file)` → removed on purpose: \(.removedBecause)" end' "$(driver_state_dir "$1")/steps/replaced.jsonl" 2>/dev/null
}

# _driver_ship_reserve <ticket> <pr> — reserves on the polish lists every item this
# run's builder took (polish-list.sh take), for this PR: other runs skip them, and
# the coordinator's housekeeping ticks them when the PR merges. An item another PR
# already holds is not this run's to name. Records what it reserved in state.
_driver_ship_reserve() {
  local t="$1" pr="$2" pl="$KIT_ROOT/scripts/polish-list.sh" n item got=""
  while IFS=$'\t' read -r n item; do
    [ -n "$item" ] || continue
    if bash "$pl" reserve --ticket "$t" "$n" "$pr" "$item" >/dev/null 2>&1; then
      got="$got$n"$'\t'"$item"$'\n'
      # Reserved, it leaves the run's record: a later run never re-reserves it.
      bash "$pl" forget "$t" "$n" "$item" >/dev/null 2>&1
    else driver_say "   ship: polish item not reserved for #$pr (another PR holds it, or it is gone): $item (#$n)"; fi
  done <<<"$(bash "$pl" taken "$t" 2>/dev/null)"
  # Added to what earlier passes reserved: a resumed ship names them all.
  driver_state_set "$t" polish_reserved "$(printf '%s%s' "$(driver_state_get "$t" polish_reserved)" "$got" | awk 'NF && !seen[$0]++')"$'\n'

}

# _driver_ship_polish <ticket> — the "## Polish list" section: the items this run
# reserved for its PR, and the ones the plan saw that it left. Nothing reserved,
# nothing said.
_driver_ship_polish() {
  local got items left="" n item lists
  got=$(driver_state_get "$1" polish_reserved)
  [ -n "$(printf '%s' "$got" | tr -d '[:space:]')" ] || return 0
  items=$(driver_state_get "$1" polish_items)
  lists=$(printf '%s\n' "$got" | cut -f1 | grep -E '^[0-9]+$' | sort -un | sed 's/^/#/' | paste -sd' ' -)
  while IFS=$'\t' read -r n item; do
    [ -n "$item" ] || continue
    printf '%s\n' "$got" | grep -qxF -- "$n	$item" || left="$left- $item (#$n)"$'\n'
  done <<<"$items"
  printf '## Polish list\nRode along from %s.\n\nFixed here, ticked on the list when this pull request merges:\n' "$lists"
  printf '%s\n' "$got" | awk -F'\t' 'NF == 2 { print "- " $2 " (#" $1 ")" }'
  [ -z "$left" ] || printf '\nLeft on the list:\n%s' "$left"
}

# _driver_ship_closes <ticket> — "Closes" for a ticket, "Refs" for a polish list: a
# list closes only once nothing is left on it (polish-list.sh sweep), never because
# one PR that fixed some of it merged. Its labels are read now; a read that fails
# falls back to what the plan recorded.
_driver_ship_closes() {
  local labels
  if labels=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json labels -q '.labels[].name' 2>/dev/null); then
    printf '%s\n' "$labels" | grep -qxF -- "$LBL_POLISH_LIST" && { printf 'Refs'; return; }
  elif [ "$(driver_state_get "$1" polish_self)" = 1 ]; then printf 'Refs'; return
  fi
  printf 'Closes'
}

# _driver_ship_push_to_fix <ticket> — a push the project's own pre-push refused goes
# to fix once, its output as the finding, inside the fix-round ceiling (#236).
# Self-check runs the same checks, except while a reviewer is owed, so this is the
# check it could not run yet. Only a hook's refusal is a finding: git runs pre-push
# after it reached the remote, so a refusal ends "failed to push some refs" with no
# `! [` ref line; an unreachable remote never gets that far. A hook's own "fatal:"
# line says nothing about which it was. A sign-off refusal is the owner's call.
_driver_ship_push_to_fix() {
  local t="$1" f reds fixes
  [ -f "${DRIVER_PUSH_OUT:-}" ] || return 1
  driver_signoff_refusal "$t" "$DRIVER_PUSH_OUT" && return 1
  case " ${DRIVER_STEPS:-} " in *" fix "*) ;; *) return 1 ;; esac
  grep -q 'failed to push some refs' "$DRIVER_PUSH_OUT" || return 1
  grep -qE '^[[:space:]]*! \[' "$DRIVER_PUSH_OUT" && return 1
  reds=$(driver_state_count "$t" push_red); fixes=$(driver_state_count "$t" fix)
  driver_state_bump "$t" push_red
  if [ "${reds:-0}" -ge 1 ]; then
    driver_say "   ship: not sent to fix — this is the second push the pre-push refused on this run."; return 1
  fi
  if [ "${fixes:-0}" -ge "$DRIVER_MAX_REVIEW_ROUNDS" ]; then
    driver_say "   ship: not sent to fix — the $DRIVER_MAX_REVIEW_ROUNDS fix round(s) are used."; return 1
  fi
  f="$(driver_state_dir "$t")/steps/self-check.findings.json"
  jq -n --arg out "$( { grep -E '✗' "$DRIVER_PUSH_OUT"; tail -40 "$DRIVER_PUSH_OUT"; } 2>/dev/null | awk '!seen[$0]++' | cut -c1-400 | head -60)" \
    '[{id: "gate-pre-push", gate: "pre-push", command: "git push (the project'"'"'s pre-push)", exit: 1, output: $out}]' > "$f" || return 1
  driver_state_set "$t" park_note ""
  driver_say "↩ ship: the pre-push refused the push — its output goes to fix as the finding."
  return 0
}

driver_step_ship() { # <ticket>
  local t="${1:?driver_step_ship: need a ticket}"
  local wt branch dirty ahead verdict rounds sha head body trunk r title nblock blist
  export DRIVER_TICKET="$t"
  wt=$(driver_state_get "$t" worktree); branch=$(driver_state_get "$t" branch)

  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    driver_say "✋ ship: there is no worktree on the record for #$t."
    return "$DRIVER_E_REFUSED"
  fi
  [ -n "$branch" ] || branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ "$branch" = "$INTEGRATION_BRANCH" ] || [ "$branch" = "HEAD" ]; then
    driver_say "✋ ship: the worktree is on '$branch'. Nothing is ever pushed or merged straight to the trunk."
    return "$DRIVER_E_REFUSED"
  fi

  dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
  if [ -n "$dirty" ]; then
    driver_say "✋ ship: uncommitted changes — $(printf '%s' "$dirty" | awk '{print $NF}' | tr '\n' ' '). A change that is not committed is a change the gates never read."
    return "$DRIVER_E_REFUSED"
  fi

  # origin's ref FIRST, exactly as the start step resolves it. A clone whose only
  # develop is origin/develop has no local ref of that name, and then rev-list
  # errors, `ahead` comes back empty, and an empty string read as 0 says a finished
  # branch has no commits — which refuses, and refuses again on every resume,
  # because ship is by then the only unfinished step.
  trunk=""
  for r in "origin/$INTEGRATION_BRANCH" "$INTEGRATION_BRANCH"; do
    git -C "$wt" rev-parse --verify -q "$r" >/dev/null 2>&1 && { trunk="$r"; break; }
  done
  if [ -z "$trunk" ]; then
    driver_say "✋ ship: neither origin/$INTEGRATION_BRANCH nor $INTEGRATION_BRANCH resolves in $wt, so there is nothing to measure the branch against."
    return "$DRIVER_E_REFUSED"
  fi
  ahead=$(git -C "$wt" rev-list --count "$trunk..$branch" 2>/dev/null)
  case "$ahead" in ''|*[!0-9]*)
    driver_say "✋ ship: could not count $branch against $trunk. An unreadable count is not a count of zero."
    return "$DRIVER_E_REFUSED" ;;
  esac
  if [ "$ahead" -eq 0 ]; then
    driver_say "✋ ship: $branch has no commits on it against $trunk. There is nothing to ship."
    return "$DRIVER_E_REFUSED"
  fi

  # THE VERDICTS HAVE TO DESCRIBE THIS HEAD. The review step records them, and any
  # commit after it — a park's work-in-progress commit is the real case — moves the
  # diff they were bound to. review is finished by then, so a resumed run comes
  # straight here and the push is refused for ever with nothing able to re-record.
  local recorded_at; recorded_at=$(driver_state_get "$t" push_requires_at)
  if [ "$recorded_at" != "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" ]; then
    local prc=0
    driver_push_requires "$t" || prc=$?
    if [ "$prc" -ne 0 ]; then
      driver_say "✋ ship: the branch moved after the reviews were recorded, and re-recording them did not succeed. Nothing is pushed."
      return "$prc"
    fi
  fi

  # A REPAIR SHIPS ONTO THE PULL REQUEST IT REPAIRED, and only that one. Asked before
  # the push: with that PR gone, the repair has nowhere to land, and opening a new one
  # would be a second PR for one ticket.
  local mode open_pr="" REPAIR_BODY=""; mode=$(driver_state_get "$t" mode)
  if [ "$mode" = repair ]; then
    local open_row
    open_row=$(driver_gh_read swarm_gh pr list --repo "$REPO_SLUG" --head "$branch" --state open --json number,isDraft -q '.[0] // empty | "\(.number) \(.isDraft // false)"' 2>/dev/null) || {
      driver_say "✋ ship: could not ask GitHub whether the pull request for $branch is still open (${DRIVER_LOOKUP_TRIES:-3} tries)."
      driver_state_set "$t" park_note "could not list the open pull requests for $branch at ship (${DRIVER_LOOKUP_TRIES:-3} tries)"
      return "$DRIVER_E_UNREAD"; }
    open_pr=${open_row%% *}
    if [ -z "$open_pr" ]; then
      driver_say "✋ ship: the pull request this repair was for is no longer open on $branch. A repair never opens a new one."
      driver_state_set "$t" park_note "the pull request for $branch closed while it was being repaired"
      return "$DRIVER_E_REFUSED"
    fi
    # A DRAFT THE DRIVER NEVER BUILT IS NOT ITS TO READY: whoever left it a draft did so on purpose.
    if [ "${open_row#* }" = true ] && ! driver_built "$t"; then
      driver_say "✋ ship: PR #$open_pr is a draft and this ticket's record holds no build of the driver's — a repair does not ready or arm it, so nothing is pushed."
      driver_state_set "$t" park_note "PR #$open_pr is a draft the driver did not build; a repair never readies it. Resume it with the prose claim."
      return "$DRIVER_E_REFUSED"
    fi
    # AND THE VERDICT IS READ BEFORE THE PUSH, not after. A repaired PR is usually
    # ready with auto-merge already armed, so for it the push IS the landing: CI goes
    # green and it merges, whatever the review said. Holding it as a draft, as a fresh
    # build does, is not available here, so an unreviewed repair is not pushed at all.
    local rverdict; rverdict=$(jq -r '.verdict // ""' "$(driver_state_dir "$t")/steps/review.json" 2>/dev/null | tr '[:lower:]' '[:upper:]')
    if [ "$rverdict" != "SHIP" ]; then
      driver_say "✋ ship: the review verdict on this repair is '${rverdict:-none}', and PR #$open_pr may already have auto-merge armed — so nothing is pushed. The repair stays in $wt."
      driver_state_set "$t" park_note "the repair's review verdict is ${rverdict:-none}; it was not pushed, because PR #$open_pr would merge it"
      return "$DRIVER_E_REFUSED"
    fi
    # NO CONFLICT MARKER IS EVER PUSHED, whichever pass left it: the last look before
    # the push that lands it.
    local marked; marked=$(driver_conflict_markers "$wt" "$trunk")
    if [ -n "$marked" ]; then
      driver_say "✋ ship: conflict markers are committed in $(printf '%s' "$marked" | tr '\n' ' ')— nothing is pushed."
      driver_state_set "$t" park_note "conflict markers are committed on $branch in: $(printf '%s' "$marked" | tr '\n' ' ')"
      return "$DRIVER_E_REFUSED"
    fi
    # THE DELETED-TESTS GATE BEFORE THE PUSH TOO, for the same reason. It judges the
    # body the PR carries, plus a "## Deleted tests" line for each test this ticket's
    # steps reported replacing, and those lines go into the PR body BEFORE the push, so
    # the CI check reading the body sees them on its first run of the new head.
    local rbody rlines missing="" newbody l rdt rdtrc=0
    rbody=$(driver_gh_read swarm_gh pr view "$open_pr" --repo "$REPO_SLUG" --json body -q .body 2>/dev/null) || {
      driver_say "✋ ship: could not read the body of pull request #$open_pr (${DRIVER_LOOKUP_TRIES:-3} tries), so the deleted-tests check has nothing to read. Nothing is pushed."
      driver_state_set "$t" park_note "could not read the body of #$open_pr at ship (${DRIVER_LOOKUP_TRIES:-3} tries)"
      return "$DRIVER_E_UNREAD"; }
    rlines=$(_driver_ship_replaced "$t")
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      printf '%s\n' "$rbody" | grep -qxF -- "$l" || missing="$missing$l"$'\n'
    done <<<"$rlines"
    missing=${missing%$'\n'}
    newbody="$rbody"
    if [ -n "$missing" ]; then
      if printf '%s\n' "$rbody" | grep -qiE '^[[:space:]]*##[[:space:]]*Deleted tests[[:space:]]*$'; then
        newbody=$(printf '%s\n' "$rbody" | ADD="$missing" awk '{ print } !d && tolower($0) ~ /^[ \t]*##[ \t]*deleted tests[ \t]*$/ { print ENVIRON["ADD"]; d = 1 }')
      else
        newbody=$(printf '%s\n\n## Deleted tests\n%s\n' "$rbody" "$missing")
      fi
    fi
    rdt=$(printf '%s\n' "$newbody" | bash "${DRIVER_DELETED_TESTS:-$KIT_ROOT/scripts/check-deleted-tests.sh}" \
           --repo "$wt" --base "$trunk" --head HEAD --body-file - 2>&1) || rdtrc=$?
    if [ "$rdtrc" -ne 0 ]; then
      driver_say "✋ ship: this repair deletes tests that PR #$open_pr does not account for — nothing is pushed, because on this PR the push is the merge."
      printf '%s\n' "$rdt" | sed 's/^/   /' | while IFS= read -r l; do driver_say "$l"; done
      driver_state_set "$t" park_note "the repair deletes tests the PR body does not account for under '## Deleted tests': $(printf '%s\n' "$rdt" | awk '/ — /{sub(/^ +/, ""); print}' | tr '\n' ';')"
      return "$DRIVER_E_REFUSED"
    fi
    if [ "$newbody" != "$rbody" ] && ! swarm_gh pr edit "$open_pr" --repo "$REPO_SLUG" --body "$newbody" >/dev/null 2>&1; then
      driver_say "✋ ship: the '## Deleted tests' lines could not be added to PR #$open_pr's body, so CI would refuse the push. Nothing is pushed."
      driver_state_set "$t" park_note "could not add the Deleted tests section to #$open_pr"
      return "$DRIVER_E_REFUSED"
    fi
    REPAIR_BODY="$newbody"
  fi

  if ! driver_ensure_hooks "$MAIN_REPO" "$wt"; then
    driver_state_set "$t" park_note "git hooks could not be set up in $wt, so nothing was pushed"
    return "$DRIVER_E_REFUSED"
  fi
  driver_push "$t" "$wt" "$branch" ship || {
    # Sign-off comes last: a refusal for changing signed screens is the owner's call, said as one.
    if grep -q 'sign-off comes last' "$DRIVER_PUSH_OUT" 2>/dev/null; then
      local signed_why; signed_why=$(grep -m1 'sign-off comes last' "$DRIVER_PUSH_OUT" | sed 's/^[^A-Za-z]*pre-push blocked: //' | cut -c1-300)
      driver_say "✋ ship: the owner has signed this PR's screens and this build changes them — nothing is pushed. $signed_why"
      driver_state_set "$t" park_note "Needs the owner: this PR's screens were signed off and this build changes them after that ($signed_why). Either the change becomes a follow-up ticket, or it is a fix the PR cannot merge without and its commit says pixel-change-after-signoff: <why>, which puts the hold back on for the owner to sign again."
      return "$DRIVER_E_REFUSED"
    fi
    driver_say "✋ ship: could not push $branch — this project's pre-push refused it: $DRIVER_PUSH_WHY (all of it: $DRIVER_PUSH_OUT)"
    driver_state_set "$t" park_note "the push was refused: $DRIVER_PUSH_WHY"
    _driver_ship_push_to_fix "$t" && return "$DRIVER_E_REWORK"
    return "$DRIVER_E_REFUSED"; }

  verdict=$(jq -r '.verdict // ""' "$(driver_state_dir "$t")/steps/review.json" 2>/dev/null | tr '[:lower:]' '[:upper:]')
  rounds=$(driver_state_count "$t" review)
  # The ticket's own subject. On the record when the start step put it there; asked
  # for otherwise, because a pull request titled with the number twice tells a
  # reader nothing, and the title is what a squash merge ships as its commit.
  title=$(driver_state_get "$t" title)
  [ -n "$title" ] || title=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json title -q .title 2>/dev/null)
  [ -n "$title" ] || title="see the ticket"
  sha=$(driver_state_get "$t" claimed_at_sha)
  head=$(git -C "$wt" rev-parse HEAD)

  # THE TESTS THIS RUN REWORDED OR REMOVED, as the build and fix steps reported them.
  # The deleted-tests gate below is still the judge of each line; this only stops a
  # ticket that strengthened its tests from parking because nobody wrote them down.
  local d replaced=""
  d="$(driver_state_dir "$t")/steps"
  replaced=$(_driver_ship_replaced "$t")
  local polish="" closes pr_n; closes=$(_driver_ship_closes "$t")
  # A PR already open has its number now: its items are reserved before the body says so.
  pr_n=$(swarm_gh pr list --repo "$REPO_SLUG" --head "$branch" --state open --json number -q '.[0].number // empty' 2>/dev/null) || pr_n=""
  if [ -n "$pr_n" ] && [ "$mode" != repair ]; then _driver_ship_reserve "$t" "$pr_n"; polish=$(_driver_ship_polish "$t"); fi

  body=$(cat <<PRBODY
$closes #$t

Built by the driver: $(driver_state_get "$t" 'done|join(" → ")')

Review rounds: ${rounds:-0} of $DRIVER_MAX_REVIEW_ROUNDS
Claimed at: ${sha:-unknown}
Head: $head

$(if [ -n "$(driver_state_get "$t" design_ref | tr -d '[:space:]')" ]; then
    echo "Renders this run compared against the approved design:"
  else
    echo "Renders this run took (designSource=$(driver_state_get "$t" design_source): no approved picture, so no parity check was made):"
  fi)
$(driver_state_get "$t" renders | sed 's/^/  /')
${polish:+
$polish
}${replaced:+
## Deleted tests
$replaced}
PRBODY
)
  # `|| true` on the create alone is right: a park may already have opened the draft,
  # and a resume finds it there. What is NOT right is taking the create's silence as a
  # pull request existing — so the next line asks.
  # A PULL REQUEST A PARK ALREADY OPENED carries the park's title and body. Shipping
  # rewrites both, or the shipped PR says "parked" and carries none of this evidence.
  if [ "$mode" = repair ]; then
    # ITS WORDS ARE NOT THE DRIVER'S TO REWRITE. The PR may be a person's or /claim's,
    # with a Lesson section a reviewer already read; the repair says what it did in a
    # comment below. The deleted-tests gate judges the body the PR actually carries.
    body="$REPAIR_BODY"
  else
  # A FAILED LOOKUP IS NOT "NO PULL REQUEST": read as one, the edit is skipped and a
  # parked PR ships with the park's words. Asked and refused, it parks.
  open_pr=$(driver_gh_read swarm_gh pr list --repo "$REPO_SLUG" --head "$branch" --state open --json number -q '.[0].number // empty' 2>/dev/null) || {
    driver_say "✋ ship: could not ask GitHub whether $branch already has a pull request (${DRIVER_LOOKUP_TRIES:-3} tries), so its title and body cannot be made right."
    driver_state_set "$t" park_note "could not list the open pull requests for $branch at ship (${DRIVER_LOOKUP_TRIES:-3} tries)"
    return "$DRIVER_E_UNREAD"; }
  if [ -n "$open_pr" ] && ! swarm_gh pr edit "$open_pr" --repo "$REPO_SLUG" --title "#$t: $title" --body "$body" >/dev/null 2>&1; then
    # READ BY ITS EXIT CODE, like ready and merge: a PR left with the park's title and
    # body ships "parked" as its squash subject, without the section the gate judged.
    driver_say "✋ ship: pull request #$open_pr for $branch exists and its title and body could not be rewritten, so it would ship carrying the park's words."
    driver_state_set "$t" park_note "the existing pull request #$open_pr could not be rewritten at ship"
    return "$DRIVER_E_REFUSED"
  fi
  swarm_gh pr create --repo "$REPO_SLUG" --draft \
    --base "$INTEGRATION_BRANCH" --head "$branch" \
    --title "#$t: $title" \
    --body "$body" >/dev/null 2>&1 || true
  if ! pr_n=$(swarm_gh pr view "$branch" --repo "$REPO_SLUG" --json number -q .number 2>/dev/null); then
    driver_say "✋ ship: $branch is pushed and there is no pull request for it. An expired token, a protected base or a rate limit all look like this, and every write here is wrapped — so this asks rather than announcing a hand-off that does not exist."
    return "$DRIVER_E_REFUSED"
  fi
  fi
  # A new PR has its number only now, and a repair keeps its own body: reserve, then
  # add the section to the body it carries.
  if [ -z "$polish" ] && [ -n "$(bash "$KIT_ROOT/scripts/polish-list.sh" taken "$t" 2>/dev/null)" ]; then
    case "$pr_n" in ''|*[!0-9]*) pr_n=$(swarm_gh pr view "$branch" --repo "$REPO_SLUG" --json number -q .number 2>/dev/null) ;; esac
    case "$pr_n" in
      ''|*[!0-9]*) driver_say "   ship: the pull request's number could not be read, so its polish items are not reserved" ;;
      *) _driver_ship_reserve "$t" "$pr_n"; polish=$(_driver_ship_polish "$t")
         # A repair rewrites none of the PR's words: its items go in the repair comment.
         if [ -n "$polish" ] && [ "$mode" != repair ]; then
           body="$body

$polish"
           swarm_gh pr edit "$pr_n" --repo "$REPO_SLUG" --body "$body" >/dev/null 2>&1 \
             || driver_say "   ship: the polish section could not be added to #$pr_n's body"
         fi ;;
    esac
  fi

  # A DELETED TEST IS ACCOUNTED FOR BEFORE ANYTHING LANDS. The body this step writes
  # carries a "## Deleted tests" section only for what build and fix
  # reported, so a branch that deletes a test file or drops
  # it(/test( cases stops here as a draft — pushed and visible, never auto-merged —
  # with the files named for whoever picks the park up. On the origin project eleven
  # test files went in one merge, one of them pinned a behaviour the rebuild dropped,
  # and nothing went red because the test that would have was among the deleted.
  local dt dtrc=0
  dt=$(printf '%s\n' "$body" | bash "${DRIVER_DELETED_TESTS:-$KIT_ROOT/scripts/check-deleted-tests.sh}" \
         --repo "$wt" --base "$trunk" --head HEAD --body-file - 2>&1) || dtrc=$?
  if [ "$dtrc" -ne 0 ]; then
    driver_say "✋ ship: this branch deletes tests the pull request does not account for, so it stays a draft."
    printf '%s\n' "$dt" | sed 's/^/   /' | while IFS= read -r l; do driver_say "$l"; done
    driver_state_set "$t" park_note "deleted tests to account for under '## Deleted tests' in the PR body: $(printf '%s\n' "$dt" | awk '/ — /{sub(/^ +/, ""); print}' | tr '\n' ';')"
    return "$DRIVER_E_REFUSED"
  fi

  # Ready, and only then auto. A draft is the only state an automerge workflow
  # will not land, so the draft is what holds the pull request while the review
  # is unfinished — and an unreviewed ticket stops HERE, with the work visible.
  if [ "$verdict" != "SHIP" ]; then
    # NAME WHAT BLOCKS, not the code. review is recorded finished by the time this
    # runs, so every resume walks straight back to here and refuses identically —
    # and what blocks is every finding whose grade blocks, none of which ship. Nits
    # were dropped in the review step, so reading the whole list here would hand the
    # operator taste to "clear" before a merge.
    # The operator has to be handed the findings, or the ticket is simply stuck with
    # "exit 24" as its only explanation.
    nblock=$(jq -r "[.findings[]? | $(driver_blocking_select)] | length" "$(driver_state_dir "$t")/steps/review.json" 2>/dev/null)
    driver_say "✋ ship: the review verdict is '${verdict:-none}' after ${rounds:-0} of $DRIVER_MAX_REVIEW_ROUNDS round(s), so the pull request stays a draft. The work is pushed and visible; it is not landing."
    if [ "${nblock:-0}" -gt 0 ]; then
      blist=$(jq -r '[.findings[]? | '"$(driver_blocking_select)"' | "\(.grade) \(.file // "?"):\(.line // "?") \(.summary // "")"] | join("; ")' "$(driver_state_dir "$t")/steps/review.json" 2>/dev/null)
      driver_say "   ship: ${nblock} blocking finding(s) to clear — $blist"
      # ON THE RECORD, not just on stdout. driver_say writes the terminal and a log
      # file inside the state directory — the one place a handover must not depend on,
      # because a park exists to be read by somebody who is not this process. The
      # orchestrator puts this note in the park brief.
      driver_state_set "$t" park_note "${nblock} blocking finding(s) from the review to clear: $blist"
    fi
    return "$DRIVER_E_REFUSED"
  fi

  # THESE TWO ARE THE HAND-OFF, so their exit codes are read. A draft nobody marked
  # ready never lands, and an unarmed pull request waits for a person who was told the
  # run was finished — both of which read exactly like success when the call is wrapped.
  if ! swarm_gh pr ready "$branch" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    driver_say "✋ ship: the pull request for $branch could not be marked ready, so it is still a draft and cannot land. The work is pushed and reviewed; the hand-off is not done."
    return "$DRIVER_E_REFUSED"
  fi
  if ! swarm_gh pr merge "$branch" --repo "$REPO_SLUG" --auto --squash >/dev/null 2>&1; then
    driver_say "✋ ship: auto-merge would not arm on the pull request for $branch. It is ready and reviewed, and nothing will land it — so this says so rather than handing off."
    return "$DRIVER_E_REFUSED"
  fi
  if [ "$mode" = repair ]; then
    # SAID AS WHAT IT WAS. A repair step that made no model call (nothing red, nothing
    # clashing, no caller brief) and one answered "unchanged" changed nothing, and a
    # comment calling them repaired would be the PR claiming a fix nobody made.
    local rj said; rj="$(driver_state_dir "$t")/steps/repair.json"
    if [ ! -f "$rj" ]; then
      said="Re-checked by the driver at $head: nothing was red or clashing, so nothing was changed; the gates and the review ran again."
    elif [ "$(jq -r '.status // ""' "$rj" 2>/dev/null)" = unchanged ]; then
      said="Re-checked by the driver at $head: unchanged: $(jq -r '.reason // "no reason given"' "$rj"). The gates and the review ran again."
    else
      said="Repaired by the driver at $head: $(jq -r '.cause // "see the run log"' "$rj" 2>/dev/null || echo "see the run log")."
    fi
    swarm_gh pr comment "$open_pr" --repo "$REPO_SLUG" --body "$said Review rounds: ${rounds:-0} of $DRIVER_MAX_REVIEW_ROUNDS. Steps: $(driver_state_get "$t" 'done|join(" → ")').${polish:+

$polish}" >/dev/null 2>&1 || true
  fi
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" \
    --body "Handed off at $head — pull request ready, auto-merge armed. Not waiting for CI: a watcher brings an agent back on red or a conflict." >/dev/null 2>&1 || true

  driver_state_set "$t" run_brief ""   # shipped: the run's brief has been acted on
  driver_say "   ship: $branch pushed, pull request ready, auto-merge armed at $(printf '%s' "$head" | cut -c1-8). Handing off."
  return "$DRIVER_OK"
}
