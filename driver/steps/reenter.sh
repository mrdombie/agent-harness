#!/usr/bin/env bash
# steps/reenter.sh — the repair path's way in, in place of `start`.
#
#   driver_step_reenter <ticket>
#
# A repair is sent because a pull request that was built, pushed and handed off went
# red or began to clash. The work is that pull request's, on that branch, so this step
# re-enters it. It never cuts a branch from the trunk. A fresh branch beside an open
# PR is duplicate work, a push the PR never sees, and a second claim on one ticket.
#
# WHAT IT REFUSES, BY NAME
#   closed               there is nothing to repair
#   the hold label       a person owns it
#   no open PR           a repair re-enters a PR; with none, there is nothing to
#                        re-enter, and building fresh is not a repair
#   two open PRs         which one is not the driver's guess
#   a peer's claim       never adopted, exactly as in start
#   a diverged branch    local commits origin does not have AND origin commits the
#                        local branch does not have: merging them here would be the
#                        driver deciding between two people's work
#   an unreadable list   is not "no PR"
#
# Like start it is the ALWAYS step: it runs on every pass, so a resumed repair re-reads
# the ticket, the PR and the claim, and it is idempotent: it keeps the tree it has.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1

driver_step_reenter() { # <ticket>
  local t="${1:?driver_step_reenter: need a ticket}"
  local meta st labels prs n pr branch mstate repo wt wt_root hrc cw cb ow ob here base
  export DRIVER_TICKET="$t"
  driver_state_init "$t"

  meta=$(driver_gh_read swarm_gh issue view "$t" --repo "$REPO_SLUG" --json state,labels,title \
           -q '.state + "\u0001" + ([.labels[].name]|join(",")) + "\u0001" + .title' 2>/dev/null)
  if [ -z "$meta" ]; then
    driver_say "✋ reenter: #$t could not be read from GitHub after ${DRIVER_LOOKUP_TRIES:-3} tries."
    driver_state_set "$t" park_note "reenter could not read #$t from GitHub (${DRIVER_LOOKUP_TRIES:-3} tries)"
    return "$DRIVER_E_GH"
  fi
  st=$(printf '%s' "$meta" | cut -d$'\001' -f1)
  labels=$(printf '%s' "$meta" | cut -d$'\001' -f2)
  driver_state_set "$t" title "$(printf '%s' "$meta" | cut -d$'\001' -f3)"
  if [ "$st" != "OPEN" ]; then
    driver_say "✋ reenter: #$t is $st. There is nothing to repair."
    return "$DRIVER_E_REFUSED"
  fi
  case ",$labels," in
    *",$HOLD_LABEL,"*)
      driver_say "✋ reenter: #$t carries $HOLD_LABEL — a person owns it."
      return "$DRIVER_E_REFUSED" ;;
  esac

  if ! prs=$(driver_gh_read driver_open_prs_for "$t"); then
    driver_say "✋ reenter: could not ask GitHub for #$t's open pull request (${DRIVER_LOOKUP_TRIES:-3} tries). An unreadable list is not an empty one."
    driver_state_set "$t" park_note "reenter could not list the open pull requests for #$t (${DRIVER_LOOKUP_TRIES:-3} tries)"
    return "$DRIVER_E_GH"
  fi
  n=$(printf '%s' "$prs" | grep -c .)
  if [ "$n" -eq 0 ]; then
    driver_say "✋ reenter: #$t has no open pull request on a ${BRANCH_PREFIX}${t} branch. A repair re-enters an existing pull request; with none there is nothing to repair, and building the ticket fresh is not a repair."
    driver_state_set "$t" park_note "a repair was sent for #$t and it has no open pull request to repair"
    return "$DRIVER_E_REFUSED"
  fi
  if [ "$n" -gt 1 ]; then
    driver_say "✋ reenter: #$t has $n open pull requests — $(printf '%s\n' "$prs" | awk -F'\t' '{printf "#%s on %s ", $1, $2}')— and which one to repair is not the driver's guess."
    return "$DRIVER_E_REFUSED"
  fi
  local isdraft
  IFS=$'\t' read -r pr branch _ mstate isdraft _ <<<"$prs"
  # A draft the driver never built is a person's or /claim's work in progress, not a repair.
  if [ "$isdraft" = true ] && ! driver_built "$t"; then
    driver_say "✋ reenter: PR #$pr is a draft and #$t's record holds no build of the driver's. A repair would ready and arm work nobody finished; the prose claim resumes it."
    driver_state_set "$t" park_note "PR #$pr is a draft the driver did not build; resume it with the prose claim, not a repair"
    return "$DRIVER_E_REFUSED"
  fi

  # THE CLAIM, by the same rules as start: `holds` 0 means "somebody on this machine",
  # so ours is proved from the claim's own record against ours.
  bash "$CL" holds "$t" >/dev/null 2>&1; hrc=$?
  case "$hrc" in
    0)  cw=$(bash "$CL" show "$t" 2>/dev/null | jq -r '.worktree // ""' 2>/dev/null)
        cb=$(bash "$CL" show "$t" 2>/dev/null | jq -r '.branch // ""' 2>/dev/null)
        ow=$(driver_state_get "$t" worktree); ob=$(driver_state_get "$t" branch)
        if { [ -n "$cw" ] && [ "$cw" = "$ow" ]; } \
        || { [ -z "$cw" ] && [ -n "$ob" ] && [ "$cb" = "$ob" ]; }; then
          driver_say "   reenter: #$t is already ours — resuming"
        else
          driver_say "✋ reenter: another run on this host holds the claim on #$t (its branch is ${cb:-unnamed}, its worktree ${cw:-none}, and ours is ${ow:-none})."
          return "$DRIVER_E_REFUSED"
        fi ;;
    12) driver_say "✋ reenter: a peer holds the claim on #$t. Never adopt a live claim."
        return "$DRIVER_E_REFUSED" ;;
    *)  if ! bash "$CL" acquire "$t" --branch "$branch" >/dev/null 2>&1; then
          driver_say "✋ reenter: a peer took the claim on #$t first. Never adopt a live claim."
          return "$DRIVER_E_REFUSED"
        fi ;;
  esac

  repo="$MAIN_REPO"
  git -C "$repo" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || true
  git -C "$repo" fetch -q origin "+refs/heads/$INTEGRATION_BRANCH:refs/remotes/origin/$INTEGRATION_BRANCH" 2>/dev/null || true
  if ! git -C "$repo" rev-parse --verify -q "origin/$branch" >/dev/null 2>&1; then
    driver_say "✋ reenter: PR #$pr names $branch and origin has no such branch."
    return "$DRIVER_E_REFUSED"
  fi
  driver_state_set "$t" branch "$branch"

  # THE TREE. A recorded tree on this branch is kept; anything else gets a tree of its
  # own on the PR's branch. Either way it ends at origin's head or ahead of it.
  wt=$(driver_state_get "$t" worktree)
  # A worktree that already has the branch checked out (a stale record's, set aside)
  # is taken over: git refuses a second checkout of one branch.
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    local held
    held=$(git -C "$repo" worktree list --porcelain 2>/dev/null \
      | awk -v b="refs/heads/$branch" '/^worktree /{w=substr($0, 10)} $0 == "branch " b {print w; exit}')
    if [ -n "$held" ] && [ -d "$held" ] && [ "$(cd "$held" && pwd -P)" != "$(cd "$repo" && pwd -P)" ]; then
      wt="$held"; driver_state_set "$t" worktree "$wt"
      driver_say "   reenter: $branch is already checked out in $wt — taking that tree over"
    fi
  fi
  if [ -n "$wt" ] && [ -d "$wt" ] && [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$branch" ]; then
    driver_say "   reenter: resuming in the worktree it already has ($wt)"
    git -C "$wt" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || true
  else
    if git -C "$repo" rev-parse --verify -q "refs/heads/$branch" >/dev/null 2>&1 \
       && ! git -C "$repo" merge-base --is-ancestor "refs/heads/$branch" "origin/$branch" 2>/dev/null; then
      driver_say "✋ reenter: the local $branch has diverged from origin's, and its own commits would be lost by re-cutting it. Push or remove them first."
      driver_state_set "$t" park_note "the local $branch has commits origin does not; a repair will not overwrite them"
      return "$DRIVER_E_REFUSED"
    fi
    wt_root=$(driver_worktree_root) || {
      driver_say "✋ reenter: no worktree root — the reason is printed above."
      return "$DRIVER_E_REFUSED"
    }
    wt="$wt_root/${BRANCH_PREFIX}${t}-repair-$(openssl rand -hex 3 2>/dev/null || printf '%s' $$)"
    mkdir -p "$(dirname "$wt")" 2>/dev/null || true
    if ! bash "$KIT_ROOT/scripts/worktree-sparse.sh" add "$repo" "$wt" -q -B "$branch" "origin/$branch" 2>/dev/null; then
      driver_say "✋ reenter: could not create a worktree at $wt on $branch."
      return "$DRIVER_E_REFUSED"
    fi
    git -C "$wt" branch -q --set-upstream-to="origin/$branch" 2>/dev/null || true
    driver_state_set "$t" worktree "$wt"
    if ! driver_link_install "$repo" "$wt"; then
      driver_state_set "$t" park_note "the shared install could not be linked into $wt"
      return "$DRIVER_E_REFUSED"
    fi
    if ! driver_prepare_worktree "$wt"; then
      driver_state_set "$t" park_note "$DRIVER_PREPARE_WHY"
      return "$DRIVER_E_REFUSED"
    fi
  fi
  if ! driver_ensure_hooks "$repo" "$wt"; then
    driver_state_set "$t" park_note "git hooks could not be set up in $wt"
    return "$DRIVER_E_REFUSED"
  fi

  # Origin's head, taken: the merge robot or a person may have pushed since. Commits
  # of our own that origin lacks are a resumed repair's, and kept. Both at once is a
  # divergence, and a refusal.
  # A MERGE OF THE TRUNK LEFT IN PROGRESS by an interrupted pass is resumed, not
  # fast-forwarded over: the repair step hands it back to the model and checks it.
  # A merge of anything else is not this driver's, and origin moving under an
  # unfinished merge cannot be taken without ending it.
  local mh resuming_merge=0
  here=$(git -C "$wt" rev-parse HEAD)
  if [ -f "$(git -C "$wt" rev-parse --git-path MERGE_HEAD 2>/dev/null)" ]; then
    mh=$(git -C "$wt" rev-parse -q --verify MERGE_HEAD 2>/dev/null)
    if [ -z "$mh" ] || ! git -C "$wt" merge-base --is-ancestor "$mh" "origin/$INTEGRATION_BRANCH" 2>/dev/null; then
      driver_say "✋ reenter: $wt has a merge in progress of ${mh:-something unreadable}, which is not the integration branch. It is not the driver's to finish."
      driver_state_set "$t" park_note "$wt has a merge in progress that is not of $INTEGRATION_BRANCH"
      return "$DRIVER_E_REFUSED"
    fi
    if ! git -C "$wt" merge-base --is-ancestor "origin/$branch" "$here" 2>/dev/null; then
      driver_say "✋ reenter: origin/$branch moved while a merge of $INTEGRATION_BRANCH was in progress in $wt — taking it would mean ending that merge."
      driver_state_set "$t" park_note "origin/$branch moved under an unfinished merge in $wt"
      return "$DRIVER_E_REFUSED"
    fi
    resuming_merge=1
    driver_say "   reenter: a merge of $INTEGRATION_BRANCH is in progress in $wt — resuming it"
  fi
  if [ "$resuming_merge" -eq 1 ]; then
    :
  elif git -C "$wt" merge-base --is-ancestor "$here" "origin/$branch" 2>/dev/null; then
    git -C "$wt" merge -q --ff-only "origin/$branch" >/dev/null 2>&1 || {
      driver_say "✋ reenter: could not fast-forward $wt to origin/$branch."
      return "$DRIVER_E_REFUSED"; }
  elif ! git -C "$wt" merge-base --is-ancestor "origin/$branch" "$here" 2>/dev/null; then
    driver_say "✋ reenter: $branch has diverged from origin's — commits here origin lacks, and commits on origin this tree lacks. Merging them is not the driver's call."
    driver_state_set "$t" park_note "$branch in $wt has diverged from origin/$branch"
    return "$DRIVER_E_REFUSED"
  fi

  # The head this repair starts from, once per repair round (build-ticket clears it
  # when a new brief arrives), so a resumed pass measures from the same place.
  [ -n "$(driver_state_get "$t" repair_base)" ] || driver_state_set "$t" repair_base "$(git -C "$wt" rev-parse HEAD)"
  if [ -z "$(driver_state_get "$t" claimed_at_sha)" ]; then
    base=$(git -C "$wt" merge-base "origin/$INTEGRATION_BRANCH" HEAD 2>/dev/null)
    [ -z "$base" ] || driver_state_set "$t" claimed_at_sha "$base"
  fi
  driver_state_set "$t" pr "$pr"
  driver_state_set "$t" merge_state "$mstate"

  bash "$CL" update "$t" worktree="$wt" branch="$branch" \
    ${CLAIM_RUN_ID:+run_id="$CLAIM_RUN_ID"} ${CLAIM_RUN_LOG:+run_log="$CLAIM_RUN_LOG"} >/dev/null 2>&1 || true
  swarm_gh issue edit "$t" --repo "$REPO_SLUG" --remove-label "$LBL_PARKED" >/dev/null 2>&1 || true
  driver_say "   reenter: #$t, PR #$pr on $branch at $(git -C "$wt" rev-parse --short HEAD) (merge state ${mstate:-unknown})"
  return "$DRIVER_OK"
}
