---
name: release
description: release a stale claimed ticket back to ready (use when a claim has gone idle)
---

You are releasing a ticket that was claimed but has gone stale.

The queue lives **outside the repo** at `$STATE_DIR/`. Source of truth: GitHub labels + the claim refs on origin lockfile dirs.

## Guard

```bash
```

## Argument

Argument is the ticket number, e.g. `/release 9822`. If absent, ask the user and stop.

## Workflow

   ```bash
   ```

   After release, also flip the GH Issue label `$LBL_CLAIMED` (claimed) → `$LBL_READY` (ready) so the canonical source matches. Ticket ids ARE issue numbers:

   ```bash
   . "$(git rev-parse --show-toplevel)/scripts/toolkit-env.sh" || exit 1
   gh issue edit <ISSUE_NUM> --repo "$REPO_SLUG" --remove-label "$LBL_CLAIMED" --add-label "$LBL_READY"
   gh issue comment <ISSUE_NUM> --repo "$REPO_SLUG" --body "Released by /release — claim went idle (>24h with no commits)."
   ```


1. **Read the claim record** — the ref on origin is the lock.

   ```bash
   . "$(git rev-parse --show-toplevel)/scripts/toolkit-env.sh" || exit 1
   TICKET_KEY=NNNN
   CLAIM=$("$CL" show "$TICKET_KEY") || { echo "#$TICKET_KEY has no active claim. Nothing to release."; exit 0; }
   ```

   The record says who claimed it and when.

2. **Sanity check the claim is genuinely stale.** Read the record:

   ```bash
   jq . <<<"$CLAIM"
   ```

   The `branch` field tells you which branch to check.

   ```bash
   BRANCH=$(jq -r '.branch' <<<"$CLAIM")
   REPO_NAME=$(jq -r '.repo // ""' <<<"$CLAIM")   # empty = the main repo
   REPO_PATH=$(toolkit_repo_path "$REPO_NAME") || exit 1
   git -C "$REPO_PATH" log -1 --format="%cr %s" "origin/$BRANCH" 2>/dev/null
   ```

   - If the branch had a commit in the last 24h → **stop.** Tell the user the claim looks active. The point of `/release` is reclaiming idle claims, not stealing live work.
   - If the branch is missing or last commit > 24h old → safe to release.

3. **Release atomically — delete the claim ref and flip the label back to `$LBL_READY` (ready).**

   ```bash
   "$CL" release "$TICKET_KEY" --force
   gh issue edit "$TICKET_KEY" --repo "$REPO_SLUG" --remove-label "$LBL_CLAIMED" --add-label "$LBL_READY"
   gh issue comment "$TICKET_KEY" --repo "$REPO_SLUG" --body "Released by /release — claim went idle (>24h with no commits)."
   node "$(git rev-parse --show-toplevel)/scripts/sync-project-board.js" >/dev/null 2>&1 || true   # the board mirrors the labels
   ```

   Deleting the ref is the atomic act — any agent running `/claim` next sees the ticket free again. The label flip is the visible mirror; the board follows the label.

4. **Optional: deal with the abandoned branch.** Tell the user the branch name. **Do not delete it** — there might be salvageable work. Suggest:
   *"If the work was truly abandoned, run `git push origin --delete $BRANCH` after confirming. Otherwise leave it for the original agent."*

5. **Report to the user**
   - Which ticket was released
   - Which branch was idle (and how long)
   - Suggested next step (someone can now `/claim` it)

## What you do not do

- Don't release a claim with commits in the last 24h.
- Don't delete the abandoned branch yourself.
- Don't release `in-review` tickets — those are with a human reviewer.
- Don't run any git commands except the read-only `git log` for staleness check.
