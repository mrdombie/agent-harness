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

# _driver_repair_clashes <tree> <trunk> <mergeStateStatus> <mergeable> — 0 when the
# branch clashes with the trunk: GitHub says DIRTY or CONFLICTING, or a trial merge
# conflicts. GitHub computes mergeability lazily, so UNKNOWN is not clean. The trial
# runs in a throwaway detached tree, so nothing in the ticket's own tree (an
# untracked file included) can stop it or be touched by it.
_driver_repair_clashes() {
  local wt="$1" trunk="$2" u tmp
  [ "$3" = DIRTY ] && return 0
  [ "$4" = CONFLICTING ] && return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/repair-trial.XXXXXX") || return 1
  rmdir "$tmp"
  git -C "$wt" worktree add -q --detach "$tmp" HEAD >/dev/null 2>&1 || return 1
  git -C "$tmp" -c user.email=trial@invalid -c user.name=trial merge --no-commit --no-ff -q "$trunk" >/dev/null 2>&1
  u=$(git -C "$tmp" diff --name-only --diff-filter=U 2>/dev/null)
  git -C "$wt" worktree remove --force "$tmp" >/dev/null 2>&1 || rm -rf "$tmp"
  git -C "$wt" worktree prune >/dev/null 2>&1
  [ -n "$u" ]
}

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

  # The PR as GitHub sees it now (the shared copy), not as the brief that sent this saw it.
  local mergeable=""
  if row=$(driver_open_prs); then
    row=$(printf '%s' "$row" | jq -c --argjson n "${pr:-0}" '[.[] | select(.number == $n)] | first // empty')
  else
    unreadable=1; row=""
  fi
  if [ -n "$row" ]; then
    mstate=$(printf '%s' "$row" | jq -r '.mergeStateStatus // ""')
    mergeable=$(printf '%s' "$row" | jq -r '.mergeable // ""')
    # The sign-off hold's own check is red BY the hold: no repair turns it green.
    failing=$(printf '%s' "$row" | jq -r --arg gate "$(driver_opt coordinator.holdCheck approval)" '[.statusCheckRollup[]? | select((.conclusion // .state // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))
      | select(((.name // .context // "") | ascii_downcase) | contains($gate | ascii_downcase) | not) | (.name // .context // "?")] | join(", ")')
  else
    mstate=$(driver_state_get "$t" merge_state); unreadable=1
  fi

  # A STALE RED IS RE-RUN, NOT ASKED ABOUT. #12612 parked on a lesson check that failed
  # on 18 Oct against a PR body fixed since. A failing Actions check that finished before
  # the PR's last update, or more than DRIVER_STALE_CHECK_HOURS (12) ago, is re-run
  # (each run once per record) and leaves the red list; a fresh red stays on it.
  if [ -n "$failing" ] && [ -n "$row" ]; then
    local stale sname srun rerun_done rerun_names=""
    rerun_done=$(driver_state_get "$t" reran_runs)
    stale=$(printf '%s' "$row" | jq -r --argjson h "${DRIVER_STALE_CHECK_HOURS:-12}" '
      (.updatedAt // "") as $upd | ((now - $h * 3600) | todate) as $cut
      | .statusCheckRollup[]? | select(.__typename == "CheckRun")
      | select((.conclusion // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))
      | select((.completedAt // "") != "" and ((.completedAt < $upd) or (.completedAt < $cut)))
      | ((.detailsUrl // "") | ((capture("/actions/runs/(?<r>[0-9]+)") | .r) // "")) as $run
      | select($run != "") | "\(.name)\t\($run)"' 2>/dev/null)
    while IFS=$'\t' read -r sname srun; do
      [ -n "$srun" ] || continue
      case " $rerun_done " in *" $srun "*) continue ;; esac
      if swarm_gh run rerun "$srun" --failed --repo "$REPO_SLUG" >/dev/null 2>&1; then
        rerun_done="$rerun_done $srun"
        driver_say "   repair: '$sname' failed on an older run ($srun) — re-run rather than asked about"
        rerun_names="$rerun_names|$sname|"
      fi
    done <<EOS
$stale
EOS
    driver_state_set "$t" reran_runs "${rerun_done# }"
    if [ -n "$rerun_names" ]; then
      failing=$(printf '%s' "$failing" | awk -v k="$rerun_names" 'BEGIN { RS = ", " }
        { sub(/\n$/, "") } $0 != "" && index(k, "|" $0 "|") == 0 { o = o (o == "" ? "" : ", ") $0 } END { printf "%s", o }')
    fi
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
  elif ! git -C "$wt" merge-base --is-ancestor "$trunk" HEAD 2>/dev/null \
       && _driver_repair_clashes "$wt" "$trunk" "$mstate" "$mergeable"; then
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
  # WORK AN EARLIER ROUND MADE AND NEVER PUSHED. A repair that parks is not pushed, so
  # the next round re-enters a tree ahead of the PR: the trunk already merged, fixes
  # already committed. GitHub still reads the old head as clashing and red, the model
  # rightly finds nothing to do, and #12840 parked ten times on "committed nothing".
  # Those commits are this repair's: the PR's red and its clash belong to the older
  # head, and the gates, the review and the push after this step take the new one.
  local prhead carried=0 old_red=""
  prhead=$(printf '%s' "$row" | jq -r '.headRefOid // ""' 2>/dev/null)
  if [ -n "$prhead" ] && [ -z "$conflicted" ] \
     && [ "$(git -C "$wt" rev-parse HEAD)" != "$prhead" ] \
     && git -C "$wt" merge-base --is-ancestor "$prhead" HEAD 2>/dev/null \
     && git -C "$wt" merge-base --is-ancestor "$trunk" HEAD 2>/dev/null; then
    carried=$(git -C "$wt" rev-list --count "$prhead"..HEAD 2>/dev/null || echo 0)
    old_red="$failing"; failing=""
    driver_say "   repair: this tree is $carried commit(s) ahead of PR #$pr's head with $trunk merged in — an earlier round's work, never pushed. ${old_red:+The red (${old_red}) is on the older head; }the gates, the review and the push take this one."
    base=$prhead; driver_state_set "$t" repair_base "$prhead"
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

  # NO COMMIT ON A RED PR IS NOT A REPAIR, whatever the answer calls itself. #13317
  # answered 'repaired' and then 'unchanged', committing nothing both times, with five
  # checks red, and parked twice as "the driver's" fault. So it is asked once more,
  # the red checks named in front of its brief; a second empty answer parks with them.
  local pre_model attempt=1 reask st
  while :; do
    pre_model=$(git -C "$wt" rev-parse HEAD)
    rc=0; driver_ai_step "$t" repair || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    ans="$d/steps/repair.json"
    jq -c '(.replacedTests // [])[]' "$ans" >> "$d/steps/replaced.jsonl" 2>/dev/null || true
    reask=""; st=$(jq -r '.status // ""' "$ans")
    if [ -n "$failing" ] || [ "$unreadable" -eq 1 ]; then
      if [ "$st" = unchanged ]; then
        reask="answered unchanged"
      elif [ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$wt" rev-parse "$base" 2>/dev/null)" ] \
           && [ ! -f "$(git -C "$wt" rev-parse --git-path MERGE_HEAD 2>/dev/null)" ]; then
        reask="answered '${st:-?}' and committed nothing (the head is still $(printf '%s' "$base" | cut -c1-8))"
      fi
    fi
    [ -n "$reask" ] && [ "$attempt" -eq 1 ] || break
    attempt=2
    driver_say "↩ repair: $reask while ${failing:+checks are red ($failing)}$([ "$unreadable" -eq 1 ] && echo 'the checks could not be read') — asked once more, with the red checks named."
    driver_fact_put "$t" repair BRIEF "YOUR LAST ANSWER WAS NOT A REPAIR. You $reask, and the pull request is still red: ${failing:-its checks could not be read — run gh pr checks $pr}. A repair on a red PR ends in commits that turn those checks green, each with its proof. If a check is red for a reason you cannot fix here (it waits on a person's sign-off, or on something outside this branch), answer with a question that names the check and what it waits on — do not answer unchanged or repaired with nothing committed.

$DRIVER_BRIEF_PREFACE

${briefs_text:-(no brief came with this repair — it was sent as a healing spawn with no note)}"
  done

  # UNCHANGED is an answer only to a brief: the brief is already met, nothing is red,
  # nothing clashes, and nothing was committed. A red check or a conflict answered
  # "unchanged" is a guess — that is what a park and its question are for.
  if [ "$(jq -r '.status // ""' "$ans")" = unchanged ]; then
    if [ -n "$failing" ] || [ -n "$conflicted" ] || [ "$unreadable" -eq 1 ]; then
      driver_say "✋ repair: answered unchanged while ${failing:+checks are red ($failing)}${conflicted:+ a merge conflicts}$([ "$unreadable" -eq 1 ] && echo ' the checks could not be read'). Unchanged is not an answer to those — park with a question instead."
      driver_state_set "$t" park_note "the repair answered unchanged $attempt time(s) while the PR is red or clashing${failing:+ — red checks: $failing}${conflicted:+ — conflicted: $(printf '%s' "$conflicted" | tr '\n' ' ')}"
      return "$DRIVER_E_REFUSED"
    fi
    if [ "$carried" -gt 0 ] && [ "$(git -C "$wt" rev-parse HEAD)" = "$pre_model" ] && [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      driver_say "   repair: unchanged — the $carried unpushed commit(s) are the repair; they go to the gates and the push"
      return "$DRIVER_OK"
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
    local um; um=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
    [ -n "$um" ] || um=$(driver_state_get "$t" repair_conflicted | tr '\n' ' ')
    driver_say "✋ repair: the merge is unfinished — unmerged paths or a merge still in progress in $wt${um:+: $um}"
    driver_state_set "$t" park_note "the repair left the merge of $trunk unfinished${um:+ — still conflicting: $um}"
    return "$DRIVER_E_REFUSED"
  fi
  conflicted=$(driver_state_get "$t" repair_conflicted)
  if [ -n "$conflicted" ]; then
    if ! git -C "$wt" merge-base --is-ancestor "$trunk" HEAD 2>/dev/null; then
      driver_say "✋ repair: the clash was resolved without merging $trunk in — it is not an ancestor of the head."
      return "$DRIVER_E_REFUSED"
    fi
    # A resolution that takes the trunk's side everywhere leaves a PR with none of its change.
    local own_before own_after
    own_before=$(git -C "$wt" diff --name-only "$trunk"..."$base" 2>/dev/null)
    own_after=$(git -C "$wt" diff --name-only "$trunk"...HEAD 2>/dev/null)
    if [ -z "$own_after" ] || [ -z "$(printf '%s\n' "$own_after" | grep -xF -f <(printf '%s\n' "$own_before") 2>/dev/null)" ]; then
      driver_say "✋ repair: after the conflict resolution the PR's diff against $trunk ${own_after:+touches none of its own files ($(printf '%s' "$own_before" | tr '\n' ' '))}${own_after:-is empty} — the resolution dropped the PR's own change."
      driver_state_set "$t" park_note "the conflict resolution left PR #$pr without its own change: its diff against $trunk no longer touches $(printf '%s' "$own_before" | tr '\n' ' ')"
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
    driver_state_set "$t" park_note "the repair step answered '$(jq -r '.status // "?"' "$ans")' and committed nothing, $attempt time(s)${failing:+ — red checks: $failing}"
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
