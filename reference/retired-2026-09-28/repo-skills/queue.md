---
name: queue
description: Show the current state of the external ticket queue
---

You are showing the user the current state of the work queue.

**GitHub is the queue.** Tickets are issues in `$REPO_SLUG` and their whole
taxonomy lives in labels: `status:*`, `P0`–`P3`, `effort:*`, `area:*`, `type:*`,
`repo:*`, `epic`/`epic-child`, `needs:*`. Read them directly.

There is no local mirror of the queue any more; read GitHub.
issues** — 86 open tickets it had simply never been told about, invisible to
anything reading the mirror — and listed 15 tickets as claimed when 4 were.

## Guard

```bash
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated — run: gh auth login" >&2; exit 1; }
```

## Workflow

1. **Read the board from GitHub.** One call, everything needed to render:

   ```bash
   . "$(git rev-parse --show-toplevel)/scripts/toolkit-env.sh" || exit 1
   gh issue list --repo "$REPO_SLUG" --state open --limit 1000 \
     --json number,title,labels,createdAt \
     -q '.[] | [
           (.number|tostring),
           ([.labels[].name | select(startswith("P"))] | first // "P?"),
           ([.labels[].name | select(startswith("'"$STATUS_PREFIX"'")) | ltrimstr("'"$STATUS_PREFIX"'")] | first // "none"),
           ([.labels[].name | select(startswith("area:"))]   | first // "area:UNFILED" | ltrimstr("area:")),
           ([.labels[].name | select(startswith("effort:"))] | first // "" | ltrimstr("effort:")),
           .title
         ] | @tsv'
   ```

   A ticket with no `area:` label sorts under `UNFILED` — surface that count in
   the takeaway rather than dropping it. Tickets missing labels are exactly what
   the mirror used to lose.

2. **Read live claims from the refs — not from labels.** `$LBL_CLAIMED` (claimed) is a
   mirror written after the claim succeeds and it goes stale; the ref is the claim.

   ```bash
   "$(git rev-parse --show-toplevel)/scripts/claim-lock.sh" list
   ```

   A ticket labelled `$LBL_CLAIMED` with **no** live ref is a zombie: held by
   nothing, so `/claim` will not hand it out and no agent is building it. Call
   these out explicitly — they need `/release-stale`.

3. **Read what is waiting on a human.** Parked tickets deliberately hold no
   claim, so they appear nowhere in step 2:

   ```bash
   gh issue list --repo "$REPO_SLUG" --state open --limit 100 \
     --label "$HOLD_LABEL" --json number,title -q '.[] | "#\(.number) \(.title)"'
   ```

4. **Render the area-grouped board.** Group by area; within each, sort by
   priority (P0 → P3), then status (in-review → claimed → partial → blocked →
   ready → drafting), then number.

   ```
   📋 Queue — <YYYY-MM-DD HH:MM>

   AREA INDEX  (🔒 = ≥1 live claim or in-review)
   🔒 VISUAL-MEDIA    6 active         #8555, #8556, #8557, #8558, #8559, #8560
   🔒 PERSONAS        2 active         #8571, #6997
   🔓 INTELLIGENCE    4 (none locking) #7341, #7352, #7355, #7356
   …

   AREA: VISUAL-MEDIA  🔒
   - #8555  P0 in-review  M   Library grid overlaps itself — virtualiser
   - #8558  P0 in-review  M   One tile per COPY, not per image — dedupe
   …

   WAITING ON A HUMAN
   - #8356  $HOLD_LABEL  Creator chain overwrite (PR #8614)

   PARKED / DRAFTING (low-attention)
   - #1394  P0 drafting  Voice Discovery programme
   …

   RECENTLY MERGED
   - #8616 Green develop — split-test routes become adapters (2026-08-07)
   …(the last 5-8 PRs merged to develop)
   ```

   Rules:
   - **Lock indicator:** 🔒 when an area has a live claim ref or an `in-review`
     ticket. 🔓 otherwise.
   - **Per-ticket line:** `#NNNN  P?  status  effort  Title (~60–80 chars)`.
   - **Parked / drafting** roll up into one low-attention section across all areas.
   - **Recently merged:** `gh pr list --repo "$REPO_SLUG" --state merged --base develop --limit 8 --json number,title,mergedAt`
     (`ticket_id\tdate\tPR#\ttitle`), top 5–8. Still a local append-only log.

5. **One-line takeaway.** Examples:
   - `4 free areas (INTELLIGENCE, AI-INFRA, IMPORT, ACCESS) — /claim to pick a non-colliding ticket.`
   - `6 tickets in-review with failing checks and no owner — they need picking up, not re-claiming.`
   - `2 tickets labelled claimed with no live claim ref — run /release-stale.`
   - `12 open issues carry no area: label — they render under UNFILED.`

## What you do not do

- Don't read or edit any local ledger; GitHub is the queue.
- Don't decide "claimed" from a label. The ref is the claim.
- Don't claim a ticket — that's `/claim`.
- Don't write anything. This command is read-only.
