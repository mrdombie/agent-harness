#!/usr/bin/env bash
# steps/start.sh — everything that happens before the AI is called at all.
#
#   driver_step_start <ticket>
#
# It asks the refusal questions first and does the expensive things afterwards,
# in that order, because a refusal must be cheap: the whole point of a gate is
# that it fires before the work.
#
# WHAT IT REFUSES, AND WHY EACH ONE IS HERE
#   closed            there is nothing to build
#   the hold label    a person owns it; an agent taking it is a slot nobody can use
#   gated             the PM flips that label, never the driver
#   not ready         a status that is not ready is a status somebody chose
#   already claimed   a peer holds it. NEVER adopt a live claim: two agents on one
#                     branch is the failure the ref-based lock exists to prevent
#   unreadable        a ticket that cannot be read is not a ticket that is fine
#
# THE CLAIM IS THE REF, taken by compare-and-swap. Exit 10 from the lock means a
# peer won, and there is nothing to retry: the answer is another ticket.
#
# THE WORKTREE is cut from a freshly fetched trunk, at a path of its own, and the
# trunk SHA it was cut at is frozen onto the record — so a required check that
# lands mid-build is known not to apply to a ticket claimed before it existed.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1

driver_step_start() { # <ticket>
  local t="${1:?driver_step_start: need a ticket}"
  local meta st labels repo slug branch wt sha l
  export DRIVER_TICKET="$t"
  driver_state_init "$t"

  meta=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json state,labels,title \
           -q '.state + "\u0001" + ([.labels[].name]|join(",")) + "\u0001" + .title' 2>/dev/null)
  if [ -z "$meta" ]; then
    driver_say "✋ start: #$t could not be read. Note that a pull request resolves here too — check you were given an issue."
    return "$DRIVER_E_REFUSED"
  fi
  st=$(printf '%s' "$meta" | cut -d$'\001' -f1)
  labels=$(printf '%s' "$meta" | cut -d$'\001' -f2)

  if [ "$st" != "OPEN" ]; then
    driver_say "✋ start: #$t is $st. There is nothing to build."
    return "$DRIVER_E_REFUSED"
  fi
  case ",$labels," in
    *",$HOLD_LABEL,"*)
      driver_say "✋ start: #$t carries $HOLD_LABEL — a person owns it. An agent holding it is a slot nobody can use."
      return "$DRIVER_E_REFUSED" ;;
  esac
  case ",$labels," in
    *",$LBL_GATED,"*)
      driver_say "✋ start: #$t is $LBL_GATED. The PM flips that label, not the driver."
      return "$DRIVER_E_REFUSED" ;;
  esac
  case ",$labels," in
    *",$LBL_READY,"*|*",$LBL_CLAIMED,"*) : ;;
    *)
      driver_say "✋ start: #$t is not $LBL_READY (labels: ${labels:-none}). A status that is not ready is a status somebody chose."
      return "$DRIVER_E_REFUSED" ;;
  esac

  # The claim. Already ours is fine — a resumed run re-enters here.
  if bash "$CL" holds "$t" >/dev/null 2>&1; then
    if [ "$(driver_state_get "$t" worktree)" = "" ]; then
      driver_say "✋ start: a peer holds the claim on #$t. Never adopt a live claim — two agents on one branch is what the ref exists to stop."
      return "$DRIVER_E_REFUSED"
    fi
  else
    # A branch already on the record is KEPT. Naming a second one is how a resumed
    # run ends up with its commits on a branch nobody ships: the worktree, the
    # commits and the pull request are all on the first name, and everything after
    # this line would look at the second. The worktree below is guarded that way
    # already; the branch was not, and the two have to agree.
    branch=$(driver_state_get "$t" branch)
    if [ -z "$branch" ]; then
      slug=$(printf '%s' "$meta" | cut -d$'\001' -f3 | tr '[:upper:]' '[:lower:]' \
             | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40)
      [ -n "$slug" ] || slug="ticket-$t"
      branch="${BRANCH_PREFIX}${t}/${slug}"
    fi
    if ! bash "$CL" acquire "$t" --branch "$branch" >/dev/null 2>&1; then
      driver_say "✋ start: a peer holds the claim on #$t. Never adopt a live claim — two agents on one branch is what the ref exists to stop."
      return "$DRIVER_E_REFUSED"
    fi
    driver_state_set "$t" branch "$branch"
  fi
  branch=$(driver_state_get "$t" branch)

  # The worktree. A resumed run keeps the one it already has: cutting a second is
  # how a run ends up with its commits in a tree nobody ships.
  wt=$(driver_state_get "$t" worktree)
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    driver_say "   start: resuming in the worktree it already has ($wt)"
  else
    repo="$MAIN_REPO"
    git -C "$repo" fetch -q origin "$INTEGRATION_BRANCH" 2>/dev/null || true
    sha=$(git -C "$repo" rev-parse --verify "origin/$INTEGRATION_BRANCH" 2>/dev/null) \
      || sha=$(git -C "$repo" rev-parse --verify "$INTEGRATION_BRANCH" 2>/dev/null)
    if [ -z "$sha" ]; then
      driver_say "✋ start: no $INTEGRATION_BRANCH in $repo to cut from."
      return "$DRIVER_E_REFUSED"
    fi
    wt="${TMPDIR:-/tmp}"; wt="${wt%/}/${BRANCH_PREFIX}${t}-$(openssl rand -hex 3 2>/dev/null || printf '%s' $$)"
    if ! git -C "$repo" worktree add -q "$wt" -b "$branch" "$sha" 2>/dev/null; then
      driver_say "✋ start: could not create a worktree at $wt on $branch."
      return "$DRIVER_E_REFUSED"
    fi
    # The shared install, never one per worktree. A missing one is not fatal:
    # plenty of repos have nothing to link.
    [ -d "$repo/node_modules" ] && ln -sfn "$repo/node_modules" "$wt/node_modules"
    # Hook shims are generated at install time and gitignored, so a fresh
    # worktree runs ZERO hooks — silently. Copy them where they exist.
    [ -d "$repo/.husky/_" ] && { mkdir -p "$wt/.husky"; cp -R "$repo/.husky/_" "$wt/.husky/_"; }
    driver_state_set "$t" worktree "$wt"
    driver_state_set "$t" claimed_at_sha "$sha"
    driver_say "   start: #$t claimed, worktree at $wt on $branch (cut at $(printf '%s' "$sha" | cut -c1-8))"
  fi

  bash "$CL" update "$t" worktree="$wt" branch="$branch" >/dev/null 2>&1 || true
  swarm_gh issue edit "$t" --repo "$REPO_SLUG" \
    --remove-label "$LBL_READY" --add-label "$LBL_CLAIMED" >/dev/null 2>&1 || true
  return "$DRIVER_OK"
}
