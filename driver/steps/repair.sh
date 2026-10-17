#!/usr/bin/env bash
# steps/repair.sh — a red or clashing pull request, fixed on its own branch.
#
#   driver_step_repair <ticket>
#
# It runs after `reenter`, in the PR's own tree at origin's head. Three things can be
# wrong, and the driver does what needs no thinking itself:
#
#   A CLASH  the integration branch is merged in. A clean merge is a commit and the
#            step is done with it, with no model call. A conflicted merge is left in
#            progress, with the files named, for the one model call this step makes.
#   A RED    the PR's checks that settled red, read from its status rollup and handed
#            over with the brief that sent the repair. A rollup nobody could read is
#            said to be unreadable. It is not read as green.
#   NOTHING  nothing red and nothing clashing, so there is no model call. The steps
#            after this one still run every gate and the review, so an approved
#            merge sent here is judged like any other.
#
# THE ANSWER IS NOT THE EVIDENCE. What comes back is checked against the tree:
#   - no unmerged path and no merge in progress, and for a clash the trunk is an
#     ancestor of the head
#   - no conflict marker in any file that conflicted
#   - nothing uncommitted, and the head has moved past where the repair started
#   - each fix carries its proof. A TEST is re-run at its fix's parent and at the
#     fix, by the same proof build and fix use, and both commits must be this
#     repair's own. A GATE (a fix no test can pin, such as a lint rule, a type error
#     or a lockfile) has its command run at the head, read by its exit code. The
#     self-check step after this one runs every gate regardless.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1
# driver_prove_red_green lives with the build step: one proof, read by every step.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build.sh" || exit 1

driver_step_repair() { # <ticket>
  local t="${1:?driver_step_repair: need a ticket}"
  local d wt branch pr base trunk row mstate failing="" unreadable=0 conflicted="" conflicts_fact merged=0
  local need=0 rc ans i n proof bid tfile tcmd tsha isha why prc grc dirty briefs_text
  export DRIVER_TICKET="$t"
  d=$(driver_state_dir "$t")
  wt=$(driver_state_get "$t" worktree); branch=$(driver_state_get "$t" branch)
  pr=$(driver_state_get "$t" pr); base=$(driver_state_get "$t" repair_base)
  if [ -z "$wt" ] || [ ! -d "$wt" ] || [ -z "$base" ]; then
    driver_say "✋ repair: there is no re-entered worktree on the record for #$t — reenter runs first."
    return "$DRIVER_E_REFUSED"
  fi
  trunk="origin/$INTEGRATION_BRANCH"
  git -C "$wt" fetch -q origin "+refs/heads/$INTEGRATION_BRANCH:refs/remotes/$trunk" 2>/dev/null || true
  git -C "$wt" rev-parse --verify -q "$trunk" >/dev/null 2>&1 || trunk="$INTEGRATION_BRANCH"

  # The PR as GitHub sees it now, not as the brief that sent this saw it.
  row=$(swarm_gh pr list --repo "$REPO_SLUG" --state open --limit 200 \
          --json number,mergeStateStatus,statusCheckRollup 2>/dev/null) || unreadable=1
  if [ "$unreadable" -eq 0 ] && printf '%s' "$row" | jq -e 'type == "array"' >/dev/null 2>&1; then
    row=$(printf '%s' "$row" | jq -c --argjson n "${pr:-0}" '[.[] | select(.number == $n)] | first // empty')
  else
    unreadable=1; row=""
  fi
  if [ -n "$row" ]; then
    mstate=$(printf '%s' "$row" | jq -r '.mergeStateStatus // ""')
    failing=$(printf '%s' "$row" | jq -r '[.statusCheckRollup[]? | select((.conclusion // .state // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED")) | (.name // .context // "?")] | join(", ")')
  else
    mstate=$(driver_state_get "$t" merge_state); unreadable=1
  fi

  # ---- the clash ---------------------------------------------------------------
  local resumed_merge=0 marked
  if [ -f "$(git -C "$wt" rev-parse --git-path MERGE_HEAD 2>/dev/null)" ]; then
    # A resumed pass finds the merge it left for the model. What it conflicted in is
    # the record's list as well as git's: a file staged unresolved is no longer a U
    # path, and the merge is still not finished.
    resumed_merge=1
    conflicted=$(printf '%s\n%s\n' "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" "$(driver_state_get "$t" repair_conflicted)" | sed '/^$/d' | sort -u)
    [ -n "$conflicted" ] || conflicted=$(git -C "$wt" diff --cached --name-only 2>/dev/null)
    driver_say "   repair: resuming the merge of $trunk an earlier pass left in progress"
  elif ! git -C "$wt" merge-base --is-ancestor "$trunk" HEAD 2>/dev/null && [ "$mstate" = DIRTY ]; then
    if git -C "$wt" merge --no-edit "$trunk" >"$d/steps/repair-merge.out" 2>&1; then
      merged=1
      driver_say "   repair: merged $trunk into $branch cleanly at $(git -C "$wt" rev-parse --short HEAD)"
    else
      conflicted=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)
      if [ -z "$conflicted" ]; then
        git -C "$wt" merge --abort >/dev/null 2>&1
        driver_say "✋ repair: merging $trunk failed with nothing conflicted — $(tail -3 "$d/steps/repair-merge.out" | tr '\n' ' ')"
        return "$DRIVER_E_REFUSED"
      fi
      driver_say "   repair: merging $trunk conflicted in $(printf '%s' "$conflicted" | tr '\n' ' ')— handed to the model"
    fi
  fi
  if [ -n "$conflicted" ]; then
    conflicts_fact="merging $trunk into $branch conflicted, and the merge is left in progress for you in: $(printf '%s' "$conflicted" | tr '\n' ' ')"
    driver_state_set "$t" repair_conflicted "$conflicted"
  elif [ "$merged" -eq 1 ]; then
    conflicts_fact="merged $trunk cleanly; nothing conflicted"
  else
    conflicts_fact="not needed: the branch does not clash with $trunk"
  fi

  # A MARKER ALREADY COMMITTED is caught on every pass, before anything decides
  # there is nothing to do: an interrupted pass may have left one, and with CI green
  # nothing else would ever look.
  if [ "$resumed_merge" -eq 0 ]; then
    marked=$(driver_conflict_markers "$wt" "$trunk")
    if [ -n "$marked" ]; then
      driver_say "✋ repair: a conflict marker is committed on $branch in $(printf '%s' "$marked" | tr '\n' ' ')— an earlier pass concluded a merge that was never resolved."
      driver_state_set "$t" park_note "conflict markers are committed on $branch in: $(printf '%s' "$marked" | tr '\n' ' ')"
      return "$DRIVER_E_REFUSED"
    fi
  fi
  [ -n "$conflicted" ] && need=1
  [ -n "$failing" ] && need=1
  [ "$unreadable" -eq 1 ] && need=1
  # A CALLER'S BRIEF IS ALWAYS READ. An owner's answer on a ticket with an open PR
  # arrives as a repair with a note; read only when something is red, it would be
  # dropped on a green PR. The brief written for a note-less healing run is not one.
  [ "$(driver_state_get "$t" repair_brief_source)" = caller ] && need=1
  if [ "$need" -eq 0 ]; then
    if [ "$merged" -eq 1 ]; then driver_say "   repair: the clash is merged, and nothing is red"
    else driver_say "   repair: nothing red and nothing clashing on PR #$pr — no fix to make; the gates and the review still run"; fi
    return "$DRIVER_OK"
  fi

  # ---- the one model call ------------------------------------------------------
  briefs_text=$(cat "$(driver_state_get "$t" repair_brief)" 2>/dev/null)
  driver_fact_put "$t" repair BRIEF "$DRIVER_BRIEF_PREFACE

${briefs_text:-(no brief came with this repair — it was sent as a healing spawn with no note)}"
  driver_fact_put "$t" repair PR "#$pr on $branch, repaired from $(printf '%s' "$base" | cut -c1-12), merge state ${mstate:-unknown}"
  if [ "$unreadable" -eq 1 ]; then
    driver_fact_put "$t" repair FAILING "the pull request's checks could not be read from GitHub — read them yourself (gh pr checks $pr) before deciding anything is green"
  else
    driver_fact_put "$t" repair FAILING "${failing:-none settled red}"
  fi
  driver_fact_put "$t" repair CONFLICTS "$conflicts_fact"
  local diff; diff=$(git -C "$wt" diff "$trunk"...HEAD 2>/dev/null)
  driver_fact_put "$t" repair DIFF "${diff:-(none — the branch carries no change against $trunk)}"

  local pre_model; pre_model=$(git -C "$wt" rev-parse HEAD)
  rc=0; driver_ai_step "$t" repair || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  ans="$d/steps/repair.json"
  jq -c '(.replacedTests // [])[]' "$ans" >> "$d/steps/replaced.jsonl" 2>/dev/null || true

  # UNCHANGED is an answer only to a brief: the brief is already met, nothing is red,
  # nothing clashes, and nothing was committed. A red check or a conflict answered
  # "unchanged" is a guess — that is what a park and its question are for.
  if [ "$(jq -r '.status // ""' "$ans")" = unchanged ]; then
    if [ -n "$failing" ] || [ -n "$conflicted" ] || [ "$unreadable" -eq 1 ]; then
      driver_say "✋ repair: answered unchanged while ${failing:+checks are red ($failing)}${conflicted:+ a merge conflicts}$([ "$unreadable" -eq 1 ] && echo ' the checks could not be read'). Unchanged is not an answer to those — park with a question instead."
      driver_state_set "$t" park_note "the repair answered unchanged while the PR is red or clashing"
      return "$DRIVER_E_REFUSED"
    fi
    if [ "$(git -C "$wt" rev-parse HEAD)" != "$pre_model" ] || [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      driver_say "✋ repair: answered unchanged and changed the tree. Either it is a fix, with its proof, or it is unchanged."
      driver_state_set "$t" park_note "the repair answered unchanged and changed the tree"
      return "$DRIVER_E_REFUSED"
    fi
    # A CALLER'S BRIEF ANSWERED "UNCHANGED" IS A QUESTION, not a ship. The model saying
    # the owner's answer is already met is its judgement; shipped on it, a draft PR
    # would be readied and armed without the change anyone asked for.
    # AND ASKED ONCE PER HEAD. The answer comes back as a new brief on the same PR; a
    # second "unchanged" at the head the person was asked about is that answer acted
    # on, not a new question — or the two would ask each other for ever.
    local cur bsha; cur=$(git -C "$wt" rev-parse HEAD); bsha=$(driver_state_get "$t" repair_brief_sha)
    if [ "$(driver_state_get "$t" unchanged_asked_head)" = "$cur" ] \
       && [ -n "$(driver_state_get "$t" unchanged_asked_brief)" ] && [ "$(driver_state_get "$t" unchanged_asked_brief)" != "$bsha" ]; then
      driver_say "   repair: unchanged — $(jq -r '.reason // ""' "$ans") — a person was asked about this exact head and answered; carrying on"
      return "$DRIVER_OK"
    fi
    driver_state_set "$t" unchanged_asked_head "$cur"; driver_state_set "$t" unchanged_asked_brief "$bsha"
    driver_say "   repair: unchanged — $(jq -r '.reason // ""' "$ans") — asking rather than shipping"
    driver_state_set "$t" park_note "The repair step says this brief needs no change to the PR: $(jq -r '.reason // ""' "$ans"). Is that right — should the PR ship as it is?"
    driver_state_set "$t" park_cause person
    return "$DRIVER_E_QUESTION"
  fi

  # ---- what the tree says ------------------------------------------------------
  if [ -f "$(git -C "$wt" rev-parse --git-path MERGE_HEAD 2>/dev/null)" ] \
     || [ -n "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    driver_say "✋ repair: the merge is unfinished — unmerged paths or a merge still in progress in $wt."
    driver_state_set "$t" park_note "the repair left the merge of $trunk unfinished"
    return "$DRIVER_E_REFUSED"
  fi
  conflicted=$(driver_state_get "$t" repair_conflicted)
  if [ -n "$conflicted" ]; then
    if ! git -C "$wt" merge-base --is-ancestor "$trunk" HEAD 2>/dev/null; then
      driver_say "✋ repair: the clash was resolved without merging $trunk in — it is not an ancestor of the head."
      return "$DRIVER_E_REFUSED"
    fi
    # shellcheck disable=SC2086
    if git -C "$wt" grep -nE '^(<<<<<<<|>>>>>>>)( |$)|^=======$' HEAD -- $conflicted >/dev/null 2>&1; then
      driver_say "✋ repair: a conflict marker is still in $(git -C "$wt" grep -lE '^(<<<<<<<|>>>>>>>)( |$)|^=======$' HEAD -- $conflicted 2>/dev/null | sed 's/^HEAD://' | tr '\n' ' ')— committed, so the gates would have read a broken file."
      driver_state_set "$t" park_note "the repair committed conflict markers"
      return "$DRIVER_E_REFUSED"
    fi
  fi
  marked=$(driver_conflict_markers "$wt" "$trunk")
  if [ -n "$marked" ]; then
    driver_say "✋ repair: a conflict marker is committed on $branch in $(printf '%s' "$marked" | tr '\n' ' ')."
    driver_state_set "$t" park_note "the repair committed conflict markers in: $(printf '%s' "$marked" | tr '\n' ' ')"
    return "$DRIVER_E_REFUSED"
  fi
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
  if [ -n "$dirty" ]; then
    driver_say "✋ repair: uncommitted changes — $(printf '%s' "$dirty" | awk '{print $NF}' | tr '\n' ' '). A change that is not committed is a change the gates never read."
    return "$DRIVER_E_REFUSED"
  fi
  if [ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$wt" rev-parse "$base" 2>/dev/null)" ]; then
    driver_say "✋ repair: the repair committed nothing — the head is still $(printf '%s' "$base" | cut -c1-8)."
    driver_state_set "$t" park_note "the repair step answered 'repaired' and committed nothing"
    return "$DRIVER_E_REFUSED"
  fi

  n=$(jq -r '[.fixes[]?] | length' "$ans" 2>/dev/null)
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    proof=$(jq -r --argjson i "$i" '.fixes[$i].proof // ""' "$ans")
    bid=$(jq -r --argjson i "$i" '.fixes[$i].what // "a fix"' "$ans")
    tcmd=$(jq -r --argjson i "$i" '.fixes[$i].command // ""' "$ans")
    i=$((i+1))
    if [ "$proof" = test ]; then
      tfile=$(jq -r --argjson i "$((i-1))" '.fixes[$i].test.file // ""' "$ans")
      tsha=$(jq -r  --argjson i "$((i-1))" '.fixes[$i].testCommit // ""' "$ans")
      isha=$(jq -r  --argjson i "$((i-1))" '.fixes[$i].implCommit // ""' "$ans")
      # THIS REPAIR'S OWN COMMITS. A test and a fix the PR already carried prove the
      # build, not this repair: the fix must sit after where the repair started.
      local fx; fx=$(git -C "$wt" rev-parse --verify -q "$isha" 2>/dev/null)
      if [ -z "$fx" ] || [ "$fx" = "$(git -C "$wt" rev-parse "$base")" ] \
         || ! git -C "$wt" merge-base --is-ancestor "$base" "$fx" 2>/dev/null \
         || ! git -C "$wt" merge-base --is-ancestor "$fx" HEAD 2>/dev/null; then
        driver_say "✋ repair '$bid': ${isha:-no commit} is not a commit this repair made (it started at $(printf '%s' "$base" | cut -c1-8))."
        driver_state_set "$t" park_note "a repair fix named a commit that is not this repair's own"
        return "$DRIVER_E_REFUSED"
      fi
      why=""; prc=0
      why=$(driver_prove_red_green "$wt" "$tfile" "$tsha" "$isha" "$tcmd") || prc=$?
      case "$prc" in
        0) driver_say "   repair '$bid' — $why" ;;
        4) driver_say "✋ repair '$bid' — $why"; return "$DRIVER_E_TIMEOUT" ;;
        *) driver_say "✋ repair '$bid' — $why"
           driver_state_set "$t" park_note "a repair fix is not proved red-then-green by its own test: $why"
           return "$DRIVER_E_REFUSED" ;;
      esac
    else
      grc=0
      ( cd "$wt" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$tcmd" ) > "$d/steps/repair-gate-$i.out" 2>&1 || grc=$?
      if [ "$grc" -eq 124 ]; then
        driver_say "✋ repair '$bid': $tcmd ran out of time (over ${DRIVER_CMD_TIMEOUT}s)."
        return "$DRIVER_E_TIMEOUT"
      elif [ "$grc" -ne 0 ]; then
        driver_say "✋ repair '$bid': its gate '$tcmd' still exits $grc at the head — $(tail -3 "$d/steps/repair-gate-$i.out" | tr '\n' ' ')"
        driver_state_set "$t" park_note "a repair fix's gate '$tcmd' is still red at the head"
        return "$DRIVER_E_REFUSED"
      fi
      driver_say "   repair '$bid' — $tcmd green at the head (no test can pin it: $(jq -r --argjson i "$((i-1))" '.fixes[$i].noTestBecause // "?"' "$ans"))"
    fi
  done
  driver_state_set "$t" repair_conflicted ""
  driver_say "   repair: $(jq -r '.cause // ""' "$ans") — ${n:-0} fix(es), each proved"
  return "$DRIVER_OK"
}
