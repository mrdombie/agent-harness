---
description: Maktura — release a stale claimed ticket back to ready (use when a claim has gone idle)
---

You are releasing a ticket that was claimed but has gone stale.

The queue lives **outside the repo** at `$HOME/.claude/socialhub-tickets/`. Source of truth: `INDEX.tsv` + `claims/` lockfile dirs.

## Guard

```bash
test -f "$HOME/.claude/socialhub-tickets/INDEX.tsv" || { echo "INDEX.tsv not found." >&2; exit 1; }
```

## Argument

Argument is the ticket ID, e.g. `/release SH-061`. If absent, ask the user and stop.

## Workflow

0. **Refresh INDEX.tsv from GitHub Issues first** — the lockfile is local but the issue's status:claimed label needs flipping back too.

   ```bash
   node ~/.claude/socialhub-tickets/scripts/rebuild-index-from-github.js >/dev/null
   ```

   After release, also flip the GH Issue label `status:claimed` → `status:ready` so the canonical source matches. Find the issue number via the existing GH→issue mapping, then:

   ```bash
   gh issue edit <ISSUE_NUM> --repo mrdombie/maktura --remove-label "status:claimed" --add-label "status:ready"
   gh issue comment <ISSUE_NUM> --repo mrdombie/maktura --body "Released by /release — claim went idle (>24h with no commits)."
   ```

   Do this AFTER step 3 (lockfile removal) so the lockfile is gone before any other agent re-claims.

1. **Check the lockfile** at `~/.claude/socialhub-tickets/claims/SH-NNN.lock`.

   ```bash
   TICKET="SH-NNN"
   LOCKFILE="$HOME/.claude/socialhub-tickets/claims/$TICKET.lock"
   ```

   - If the lockfile dir does **not** exist → tell the user *"$TICKET has no active claim. Nothing to release."* and stop.
   - If it exists, read `meta.json` to see who claimed it + when.

2. **Sanity check the claim is genuinely stale.** Read `meta.json`:

   ```bash
   cat "$LOCKFILE/meta.json"
   ```

   The `branch` field tells you which branch to check.

   ```bash
   BRANCH=$(jq -r '.branch' "$LOCKFILE/meta.json")
   # Resolve the ticket's repo clone from config.json (lockfile meta records
   # the repo name; legacy lockfiles say "social-hub", which config.json
   # also maps to the maktura clone).
   CONFIG="$HOME/.claude/socialhub-tickets/config.json"
   test -f "$CONFIG" || { echo "config.json missing — re-run scripts/bootstrap-queue.sh from your maktura clone." >&2; exit 1; }
   REPO_NAME=$(jq -r '.repo // "social-hub"' "$LOCKFILE/meta.json")
   REPO_PATH=$(jq -r --arg r "$REPO_NAME" '.repos[$r] // empty' "$CONFIG")
   [ -n "$REPO_PATH" ] && [ -d "$REPO_PATH/.git" ] || { echo "config.json has no valid path for repo '$REPO_NAME' — re-run scripts/bootstrap-queue.sh." >&2; exit 1; }
   git -C "$REPO_PATH" log -1 --format="%cr %s" "origin/$BRANCH" 2>/dev/null
   ```

   - If the branch had a commit in the last 24h → **stop.** Tell the user the claim looks active. The point of `/release` is reclaiming idle claims, not stealing live work.
   - If the branch is missing or last commit > 24h old → safe to release.

3. **Release atomically — remove the lockfile dir and reset the INDEX.tsv row.**

   ```bash
   rm -rf "$LOCKFILE"

   TMP=$(mktemp)
   awk -F'\t' -v OFS='\t' -v t="$TICKET" '
     $1==t { $3="ready"; $5="claimable" }
     { print }
   ' ~/.claude/socialhub-tickets/INDEX.tsv > "$TMP" \
     && mv "$TMP" ~/.claude/socialhub-tickets/INDEX.tsv
   ```

   The lockfile removal is the atomic act — any agent running `/claim` next will see the ticket free again. INDEX.tsv update is just so the row sorts correctly in `/queue`.

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
