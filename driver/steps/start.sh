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
#
# AND IT IS PREPARED, because a linked node_modules and a copy of the hook shims are
# not the whole of what a worktree needs. Measured on the 2026-09-27 trial: every
# push from a driver worktree was refused —
#
#   ✗ pre-push blocked: the prompt-template hash does not describe the prompt sources.
#       Error: Cannot find module '@/generated/prisma/client'
#
# — because the generated database client is gitignored and per-checkout, so a fresh
# worktree has none and every hook that imports it dies. The kit cannot know what a
# project generates, so the project says: `worktree.prepare` in harness.json, a list
# of commands run in the new tree. Absent is normal and skipped. PRESENT AND FAILING
# IS A REFUSAL — an unprepared tree cannot push, and discovering that at the push is
# discovering it after the whole build.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1

driver_step_start() { # <ticket>
  local t="${1:?driver_step_start: need a ticket}"
  local meta st labels repo slug branch wt sha l hrc cw cb ow ob
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
  # The subject, kept on the record. The ship step titles the pull request with it,
  # and the title is what a squash merge ships as its commit message — so reading it
  # once here beats a second call later, or a title that is the number twice.
  driver_state_set "$t" title "$(printf '%s' "$meta" | cut -d$'\001' -f3)"

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
  # AND PARKED IS RESUMABLE. A park is this driver's own state — it means a run
  # stopped and left a resume brief — so refusing it here would mean the only way
  # back into a parked ticket is a person editing a label. The hold label is
  # checked above and is the thing that actually stops a resume, which is the
  # separation T2-7 is about: a park nobody has to answer carries only the status.
  case ",$labels," in
    *",$LBL_READY,"*|*",$LBL_CLAIMED,"*|*",$LBL_PARKED,"*) : ;;
    *)
      driver_say "✋ start: #$t is not $LBL_READY (labels: ${labels:-none}). A status that is not ready is a status somebody chose."
      return "$DRIVER_E_REFUSED" ;;
  esac

  # A branch already on the record is KEPT. Naming a second one is how a resumed run
  # ends up with its commits on a branch nobody ships: the worktree, the commits and
  # the pull request are all on the first name, and everything after this line would
  # look at the second. The worktree below is guarded that way already; the branch
  # was not, and the two have to agree.
  branch=$(driver_state_get "$t" branch)
  if [ -z "$branch" ]; then
    slug=$(printf '%s' "$meta" | cut -d$'\001' -f3 | tr '[:upper:]' '[:lower:]' \
           | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40)
    [ -n "$slug" ] || slug="ticket-$t"
    branch="${BRANCH_PREFIX}${t}/${slug}"
  fi

  # The claim, READ BY ITS EXIT CODE. `holds` answers "do WE own it": 0 ours, 11
  # free, 12 a peer. Treating a plain success as "somebody has it" inverts the
  # question — our own claim, taken but not yet carrying a worktree on the record,
  # then reads as a peer's. That window spans a fetch and a worktree add, so a run
  # killed inside it could never resume itself: it parked, the park added the hold
  # label and released the claim, and a person had to clear a label for a state that
  # was this run's own, while the message sent them looking for an agent that does
  # not exist.
  bash "$CL" holds "$t" >/dev/null 2>&1; hrc=$?
  case "$hrc" in
    0)  # "OURS" IS ONLY AS FINE AS THE IDENTITY BEHIND IT, AND THAT IDENTITY IS THE
        # MACHINE. The lock compares `<login>@<host>`, the same string for every agent
        # on the box, so rc 0 means "somebody here holds it" — believing it reads a
        # live peer's claim as our own, cuts a second worktree on a second branch, and
        # then rewrites the peer's branch and worktree onto their claim, which makes
        # their work invisible to every reconciler while both agents build the ticket.
        #
        # What tells the two apart is the claim's OWN record: it names the branch and
        # worktree it was taken for. Ours iff that worktree is the one on our record,
        # or — for a claim taken and then killed before the worktree existed — it
        # names no worktree and the branch is the one we would use.
        cw=$(bash "$CL" show "$t" 2>/dev/null | jq -r '.worktree // ""' 2>/dev/null)
        cb=$(bash "$CL" show "$t" 2>/dev/null | jq -r '.branch // ""' 2>/dev/null)
        ow=$(driver_state_get "$t" worktree)
        # THE BRANCH ON THE CLAIM IS NOT ENOUGH ON ITS OWN. It is derived from the ticket
        # and its title, so a sibling that acquired seconds ago and has not recorded a
        # worktree yet carries exactly the branch this run would compute — and matching
        # on that adopted it. OUR RECORD is what separates them: this run writes the
        # branch onto it one statement after acquiring, so an empty record means we never
        # acquired, whatever the claim says.
        ob=$(driver_state_get "$t" branch)
        if { [ -n "$cw" ] && [ "$cw" = "$ow" ]; } \
        || { [ -z "$cw" ] && [ -n "$ob" ] && [ "$cb" = "$ob" ]; }; then
          driver_say "   start: #$t is already ours — resuming"
        else
          driver_say "✋ start: another run on this host holds the claim on #$t (its branch is ${cb:-unnamed}, its worktree ${cw:-none}, and ours is ${ow:-none}). The lock's identity is this machine, not this run, so a match there is not ownership."
          return "$DRIVER_E_REFUSED"
        fi ;;
    12) driver_say "✋ start: a peer holds the claim on #$t. Never adopt a live claim — two agents on one branch is what the ref exists to stop."
        return "$DRIVER_E_REFUSED" ;;
    *)  # Free, as far as the cache can see. `acquire` is the compare-and-swap that
        # settles it, and losing it means a peer won between the two calls.
        if ! bash "$CL" acquire "$t" --branch "$branch" >/dev/null 2>&1; then
          driver_say "✋ start: a peer took the claim on #$t first. Never adopt a live claim — two agents on one branch is what the ref exists to stop."
          return "$DRIVER_E_REFUSED"
        fi ;;
  esac
  driver_state_set "$t" branch "$branch"

  # The worktree. A resumed run keeps the one it already has: cutting a second is
  # how a run ends up with its commits in a tree nobody ships.
  wt=$(driver_state_get "$t" worktree)
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    driver_say "   start: resuming in the worktree it already has ($wt)"
    if ! driver_ensure_hooks "$MAIN_REPO" "$wt"; then
      driver_state_set "$t" park_note "git would run no pre-push hook in $wt"
      return "$DRIVER_E_REFUSED"
    fi
  else
    repo="$MAIN_REPO"
    git -C "$repo" fetch -q origin "$INTEGRATION_BRANCH" 2>/dev/null || true
    sha=$(git -C "$repo" rev-parse --verify "origin/$INTEGRATION_BRANCH" 2>/dev/null) \
      || sha=$(git -C "$repo" rev-parse --verify "$INTEGRATION_BRANCH" 2>/dev/null)
    if [ -z "$sha" ]; then
      driver_say "✋ start: no $INTEGRATION_BRANCH in $repo to cut from."
      return "$DRIVER_E_REFUSED"
    fi
    # UNDER THE PROJECT'S OWN WORKTREE ROOT, not $TMPDIR. On macOS $TMPDIR is a
    # /var/folders directory the system prunes, and between the build and the push
    # the tree is the only copy of the work — the 2026-09-28 trial ended with 9
    # commits in one of them.
    # A refusing resolver returns 1 inside $( ), which an assignment would swallow
    # and leave a path of "/<ticket>"; check it, and let its own reason stand.
    local wt_root
    wt_root=$(driver_worktree_root) || {
      driver_say "✋ start: no worktree root — the reason is printed above."
      return "$DRIVER_E_REFUSED"
    }
    wt="$wt_root/${BRANCH_PREFIX}${t}-$(openssl rand -hex 3 2>/dev/null || printf '%s' $$)"
    mkdir -p "$(dirname "$wt")" 2>/dev/null || true
    # A fresh branch has reworded and removed no tests: the ledger starts empty.
    mkdir -p "$(driver_state_dir "$t")/steps" && : > "$(driver_state_dir "$t")/steps/replaced.jsonl"
    if ! git -C "$repo" worktree add -q "$wt" -b "$branch" "$sha" 2>/dev/null; then
      driver_say "✋ start: could not create a worktree at $wt on $branch."
      return "$DRIVER_E_REFUSED"
    fi
    # The shared install, never one per worktree. A missing one is not fatal:
    # plenty of repos have nothing to link, and the linker says so and exits 0.
    if ! driver_link_install "$repo" "$wt"; then
      driver_say "✋ start: could not link the shared install into $wt."
      driver_state_set "$t" worktree "$wt"
      driver_state_set "$t" park_note "the shared install could not be linked into $wt"
      return "$DRIVER_E_REFUSED"
    fi
    if ! driver_ensure_hooks "$repo" "$wt"; then
      driver_state_set "$t" worktree "$wt"
      driver_state_set "$t" park_note "git would run no pre-push hook in $wt"
      return "$DRIVER_E_REFUSED"
    fi
    if ! driver_prepare_worktree "$wt"; then
      driver_state_set "$t" worktree "$wt"
      driver_state_set "$t" park_note "$DRIVER_PREPARE_WHY"
      return "$DRIVER_E_REFUSED"
    fi
    driver_state_set "$t" worktree "$wt"
    driver_state_set "$t" claimed_at_sha "$sha"
    driver_say "   start: #$t claimed, worktree at $wt on $branch (cut at $(printf '%s' "$sha" | cut -c1-8))"
  fi

  bash "$CL" update "$t" worktree="$wt" branch="$branch" >/dev/null 2>&1 || true
  # status:parked comes off as well as status:ready: a resumed park that kept it
  # would read as stopped on a board while an agent is building it.
  swarm_gh issue edit "$t" --repo "$REPO_SLUG" \
    --remove-label "$LBL_READY" --remove-label "$LBL_PARKED" \
    --add-label "$LBL_CLAIMED" >/dev/null 2>&1 || true
  return "$DRIVER_OK"
}
