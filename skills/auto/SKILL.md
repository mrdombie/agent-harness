---
name: auto
description: Pick up the most urgent work and keep going. Triages HEALTH → HALF-FINISHED → NEW, takes the top item, ships it, re-triages, repeats until the context window is done. Usage: /agent-harness:auto | /agent-harness:auto --dry (triage board only) | /agent-harness:auto --tier 2
---

You are running the **autonomous work loop**. Triage, take the top item, ship it,
re-triage, take the next. **No check-ins between items.** You have standing
authorization to keep going until the context window ends or a stop condition
fires.

**You are not choosing what to build. You are choosing what is most broken.**
The ordering is fixed and it is not a preference:

| Tier | Question it answers | Why it outranks the next |
|---|---|---|
| 🔴 **1 HEALTH** | Is the project broken right now? | Broken trunk/UAT makes every other merge unverified. Shipping onto a red pipeline is shipping blind. |
| 🟠 **2 HALF-FINISHED** | What did we already pay for and not land? | The work exists. Finishing it costs a fraction of building it, and it rots — a PR 5 days behind develop is a rebase, at 30 it's a rewrite. |
| 🟢 **3 NEW** | What is the highest-value thing not started? | Only when nothing is broken and nothing is stranded. |

Never skip a tier because a lower one looks more interesting. If Tier 1 has a
row, Tier 1 is the work.

## Guards (run first, once)

```bash
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated — run: gh auth login" >&2; exit 1; }
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
test -x "$CL" || { echo "claim-lock.sh missing — the queue is not bootstrapped" >&2; exit 1; }
SKIP="$STATE_DIR/.auto-skip"; touch "$SKIP"
```

`.auto-skip` is the loop's memory of what it already tried and could not take.
**Append to it every time you decline an item**, with a reason:
`echo "9160	needs-dom	mockup posted, parked" >> "$SKIP"`. Without it the loop
re-picks the same blocked row forever. It is per-machine and disposable —
`: > "$SKIP"` at the start of a genuinely fresh run.

---

# Step 1 — Triage (one pass, ~8 probes, run them in parallel)

Everything below is read-only. Run the whole set before deciding anything —
a partial triage picks the wrong tier.

**First, claim the scope as your own.** A label left behind by an earlier `/agent-harness:work`
session would make `/agent-harness:standup` — and the sign-off banner — announce a scope this run
does not have. `/agent-harness:auto` takes the whole board, so it says so:

```bash
printf '%s\t%s\n' "auto" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
  > "$STATE_DIR/.session-label"
```

Overwrite, never delete. An empty file reads as "no work in play" and silences the
sign-off backstop — which is exactly wrong for a loop that is about to ship all day.

## 1A · Is UAT serving what `uat` points at?

Promotion succeeding is **not** the deploy landing; that gap once hid 8 failed
`api` deploys for two days.

```bash
gh run list --repo "$REPO_SLUG" --workflow "deploy-watch.yml" --limit 3 \
  --json databaseId,conclusion,createdAt -q '.[] | [.databaseId,(.conclusion//"-"),.createdAt] | @tsv'
UAT_URL=$(toolkit_cfg uat.url) || exit 1
curl -s -m 8 -o /dev/null -w "web=%{http_code}\n"    "$UAT_URL/api/health"
curl -s -m 8 -o /dev/null -w "worker=%{http_code}\n" "$UAT_URL/api/health/worker"
```

A red `deploy-watch` **is** the alarm. `worker` serves no sha, so a version
probe is structurally blind to it — check the heartbeat separately or you will
miss a worker that has been dead for days.

## 1B · Is trunk red?

```bash
gh run list --repo "$REPO_SLUG" --branch develop --limit 20 \
  --json databaseId,name,status,conclusion,createdAt \
  -q '.[] | select(.conclusion=="failure") | [.databaseId,.name,.createdAt] | @tsv'
```

**A red check is not evidence of a code failure until you know it ran.** A job
Actions could never start is stamped `conclusion: failure`, identical to a real
test failure. Discriminate on step count, never elapsed time:

```bash
gh api "repos/$REPO_SLUG/actions/runs/$RUN_ID/jobs" -q '[.jobs[].steps[]?] | length'
# 0  → never started. Says nothing about the code. This is a Tier-1 INFRA row.
# 60+ → it genuinely ran. This is a Tier-1 TRUNK row.
```

## 1C · Is CI able to run at all?

**Establish which runner the repo is actually on before you diagnose anything.**
Measured 2026-08-15: every job — PR gates *and* scheduled workflows — ran on
`ubuntu-latest`, `Runner.Listener` was not running on this machine, and
`repos/$REPO_SLUG/actions/runners` returned `total_count: 0`. On a
GitHub-hosted repo that zero is the **normal resting state**, not an alarm. A
check that treats it as one fires Tier 1 every single run.

```bash
# Which runner did the most recent jobs use? This is the discriminator.
RID=$(gh run list --repo "$REPO_SLUG" --limit 1 --json databaseId -q '.[0].databaseId')
gh api "repos/$REPO_SLUG/actions/runs/$RID/jobs" \
  -q '.jobs[] | [.name, (.labels|join(",")), (.steps|length|tostring)] | @tsv'

# Are jobs being picked up at all? A queue that is not draining is the real alarm.
gh run list --repo "$REPO_SLUG" --limit 30 \
  --json databaseId,name,status,createdAt \
  -q '.[] | select(.status=="queued" or .status=="waiting") | [.databaseId,.name,.createdAt] | @tsv'

curl -s -m 8 https://www.githubstatus.com/api/v2/components.json \
  | jq -r '.components[] | select(.name=="Actions") | .status'
```

**Alarm only if** a run has sat `queued`/`waiting` well past its normal duration,
**or** `Actions` is not `operational`, **or** jobs are coming back with 0 steps.
Nothing else in this probe is a Tier-1 row on its own.

**Then branch on the labels you just read:**

- **`ubuntu-latest`** → GitHub-hosted. Disk, Docker volumes and `Runner.Listener`
  are irrelevant; skip them. A stuck queue plus `Actions: operational` usually
  means billing, which is the account owner's — surface it.
- **`self-hosted`** → only then run the local checks below, in this order,
  because each one alone lies:

  ```bash
  pgrep -fl "Runner.Listener" | head -3
  df -h / | tail -1
  docker system df 2>/dev/null | head -5
  tail -20 "${ACTIONS_RUNNER_DIR:-$HOME/actions-runner}"/_diag/Runner_*.log 2>/dev/null | tail -20
  ```

  - `total_count: 0` with a live `Runner.Listener` → wrong scope (a
    user-account repo has no `/orgs/…/actions/runners` endpoint; it 404s), not a
    dead runner. Do not restart it.
  - `offline`/`busy=true` with a live process and `Actions: major_outage` →
    upstream. The runner is healthy and correctly backing off. **Do not restart
    and do not re-register** — a restart cannot fix a 503 and it drops the
    queued job. Judge branches on local gates until it clears.
  - CI red with `No space left on device` → orphaned ephemeral-postgres volumes
    in the **Docker VM** disk (the host can still show 100 GB free).
    `docker system df` shows it: TOTAL ≫ ACTIVE with a huge reclaimable %.

## 1D · Open PRs — what is red, what is stranded

```bash
gh pr list --repo "$REPO_SLUG" --state open --limit 100 \
  --json number,title,isDraft,updatedAt,headRefName,statusCheckRollup,mergeable \
  -q '.[] | [(.number|tostring),
             ((.statusCheckRollup // []) | map(select(.conclusion=="FAILURE")) | length | tostring),
             (.updatedAt[0:10]), (.mergeable//"?"), .headRefName, .title[0:60]] | @tsv'
```

## 1E · Live claims — the ref is the claim

```bash
"$CL" list --json | jq -r '.[] | [(.issue|tostring),(.agent//"?"),(.branch//"?"),(.claimed_at//"")[0:16]] | @tsv'
```

## 1F · Label-vs-ref drift, both directions

```bash
gh issue list --repo "$REPO_SLUG" --state open --limit 300 --label "$LBL_CLAIMED" \
  --json number,title -q '.[] | [(.number|tostring), .title[0:60]] | @tsv'
gh issue list --repo "$REPO_SLUG" --state open --limit 300 --label "$LBL_IN_REVIEW" \
  --json number,title,labels \
  | jq -r --arg h "$HOLD_LABEL" '.[] | [(.number|tostring),
             (if ([.labels[].name]|index($h)) then "HUMAN" else "ORPHAN" end),
             .title[0:60]] | @tsv'
```

A ticket carrying `$LBL_CLAIMED` or `$LBL_IN_REVIEW` with **no live ref and
no open PR** is held by nothing and offered to nobody. That is not an edge case:
24 accumulated this way by 2026-08-11. These are Tier 2, not Tier 3.

## 1G · Open P0 bugs

```bash
gh issue list --repo "$REPO_SLUG" --state open --limit 100 \
  --label "P0" --label "type:bug" --json number,title,labels \
  -q '.[] | [(.number|tostring),
             ([.labels[].name|select(startswith("'"$STATUS_PREFIX"'"))|ltrimstr("'"$STATUS_PREFIX"'")]|first//"none"),
             .title[0:60]] | @tsv'
```

## 1H · What is parked on a human

**The label count is not the answer.** Measured 2026-08-15: 73 open issues carry
the hold label (`$HOLD_LABEL`), but **60 of them are `$LBL_READY` (ready) with no branch and no
PR** — the label went on at filing time (#9174), not because anything is waiting.
Reporting 73 buries the 7 that are genuinely blocked behind 66 that are not, and
turns the one label that should mean *look at this now* into noise.

**Parked on a human = carries the label AND has an open PR.** Nothing else counts.

```bash
gh issue list --repo "$REPO_SLUG" --state open --limit 500 \
  --label "$HOLD_LABEL" --json number,title,labels \
  -q '.[] | [(.number|tostring),
             ([.labels[].name|select(startswith("'"$STATUS_PREFIX"'"))|ltrimstr("'"$STATUS_PREFIX"'")]|first//"NONE"),
             .title[0:60]] | @tsv' > /tmp/auto-held.tsv

PRS=$(gh pr list --repo "$REPO_SLUG" --state open --limit 200 \
        --json number,headRefName,body -q '.[] | "\(.headRefName) \(.body//"")"' | tr '\n' ' ')
while IFS=$'\t' read -r n st title; do
  echo "$PRS" | grep -qE "(^| |/)(${BRANCH_PREFIX})?${n}[-/]|#${n}([^0-9]|$)" \
    && printf 'PARKED\t%s\t%s\t%s\n' "$n" "$st" "$title"
done < /tmp/auto-held.tsv
wc -l < /tmp/auto-held.tsv   # total carrying the label — context only, never the headline
```

Report the parked rows by name. Report the label total only as a one-line
footnote, and say what it is: *"N carry the label; N−7 are `$LBL_READY` (ready) with
no PR — mislabelled at filing, not waiting on you."* If that gap is large,
that IS a finding: surface it, but **do not relabel** — `/agent-harness:auto` is read-only on
labels it does not own.

---

# Step 2 — Render the board, then take the top row

**Tables. No prose.** One `▶ Taking:` line at the end is the only exception.
Every row names **what the thing does**, in plain English, with the number last.
Strip `feat(x):` / `fix(x):` prefixes. Omit any table with no rows — never print
an empty table or a "none" row.

```
⚡ AUTO — <YYYY-MM-DD HH:MM>   ·   T1:N  T2:N  T3:N

🔴 TIER 1 — HEALTH
| What's broken | Signal | Fix path | Ref |
|---|---|---|---|
| UAT api serving the previous sha | deploy-watch red ×3 | read Railway logs, fix-forward | — |
| Advisory SLA red on develop | 61 steps — really ran | attribute, fix-forward | run 3187… |

🟠 TIER 2 — HALF-FINISHED
| What it does | Why it's stalled | Age | # |
|---|---|---|---|
| Notification prefs — 54 toggles → a named set | 3 checks red, no live claim | 4d | 9043 |
| Watch subject page — every panel a control | in-review, no PR, no ref | 11d | 8953 |

🟢 TIER 3 — NEW
| What it does | P | Area | # |
|---|---|---|---|
| Invites land in the wrong workspace | P1 | ACCESS | 9019 |

🙋 NEEDS YOU (never taken by /agent-harness:auto — label + an open PR, nothing else)
| What | Status | PR | # |
|---|---|---|---|
| Notification prefs — 54 toggles → a named set | in-review | 9043 | 9039 |
_73 carry the label; 66 are $LBL_READY with no PR — mislabelled at filing._

▶ Taking: <the WORK in plain English> — Tier N, because <the one-line reason>
```

Then **take the top row and do the work.** Do not ask. Do not present options.

## Tier 1 — how each row is worked

| Row | What you do | Where it stops |
|---|---|---|
| **UAT not serving** | Get the real failure: `gh api graphql` for the Railway FAILED deploy logs (a plain `railway logs` shows the *running* — i.e. old — build). Fix-forward on a branch → `/agent-harness:finish`. | If it's credits, a Railway-side outage, or a redeploy that needs the account owner's Railway login — **surface and move to the next row**. |
| **Trunk red, really ran** | Attribute before touching: your worktree is off `origin/develop` tip while the main repo's checked-out `develop` is usually stale, so *passes in main repo, fails in worktree* = a peer's merge, not you. Pin it with `git log --oneline develop..origin/develop -- <path>`. Fix-forward green. | Never hold an unrelated green PR hostage to it — but do fix it: a red trunk blocks green-tip auto-promote for everyone. |
| **Trunk red, 0 steps** | Not a code failure. Go to the runner/infra row. | — |
| **Queue not draining** | Runs stuck `queued`/`waiting` with `Actions: operational` → usually billing. Surface it; it's the account owner's. | Move to the next row. |
| **Runner disk full** *(self-hosted jobs only)* | Diagnose with `docker system df`. **`docker volume prune -f` is authorised by the runner Mac's owner (Dom), never self-authorized** — ask, don't run it. Then `gh run rerun <id> --failed`. | Blocks on the ask; move to the next row while waiting. |
| **Actions outage** | Report it. Judge branches on local gate exit codes (`lint` / `typecheck` / `test`) until it clears. | Do not restart or re-register the runner. |
| **Open P0 bug** | `/agent-harness:claim NNNN` → build → `/agent-harness:finish`. | Normal ticket flow. |

## Tier 2 — how each row is worked, in this order

1. **Your own in-flight work** — a live claim ref on *this* machine with a
   worktree and no PR. Finish that before anything else; it is the cheapest
   thing on the board and the likeliest to rot.
2. **Open PR, red checks, no live claim.** First ask whether the checks *ran*
   (step count). Then: merge `develop` in, re-gate, `/agent-harness:finish`. Rebuilding it from
   scratch is the exact failure the resume path exists to prevent.
   - **Green but merely behind is not this row.** Run `scripts/behind-pr-action.sh` (see
     `/agent-harness:finish` Step 6): `bot` means the repo's update bot brings it up to
     date — leave it, it is not stranded. Merging develop in by hand there restarts the
     PR the bot is landing (#79).
   - Merging develop drags **prettier churn** in — commit the merge with
     `--no-verify`.
   - `.deploy-trigger` is the **root** file and it is **appended** (`>>`), never
     overwritten; `apps/.deploy-trigger` is a tracked decoy the gate never reads.
     Confirm with `npm run check:deploy-trigger`.
   - **If the premise no longer holds against develop** — after 80–170 commits
     some of these describe code that no longer exists — say so on the ticket,
     skip it, and move on. Do not force a resume.
3. **`$LBL_IN_REVIEW` (in-review), no PR, no ref** — unreachable. Find the branch
   (`git ls-remote --heads origin | grep -E "(${BRANCH_PREFIX})?NNNN[-/]"`). Branch exists →
   resume it. No branch → the label is wrong; the work never started. Flip it
   back to `$LBL_READY` and it becomes a Tier 3 row.
4. **Zombie claims** — `$LBL_CLAIMED` label, no live ref → `/agent-harness:release-stale`.
5. **Dead claim refs** — held by a process that is gone → `/agent-harness:release-stale`.
6. **Orphan worktrees** — `/agent-harness:sweep-worktrees` (dry run; report only).

## Tier 3 — new work

**Hand off to `/agent-harness:claim`.** Do not re-implement its selection: it already does
priority ordering, the area lock, the duplicate-work pass, `overlap-check.sh`,
and the anti-orphan gates. Run `/agent-harness:claim` and let it pick, then build and `/agent-harness:finish`.

---

# Step 3 — Loop

After each `/agent-harness:finish`:

1. `echo "<ticket>" >> "$STATE_DIR/.session-tickets"` (keeps
   `/agent-harness:standup` instant).
2. **Re-triage from Step 1.** Do not carry the old board forward — your own
   merge may have turned trunk red, and a peer may have broken UAT while you
   worked. A stale board is how the loop ships onto a broken pipeline.
3. Take the new top row. **No check-in.** No "shall I continue?", no summary of
   what you just did beyond one line. The sign-off banner is not a summary and is
   not covered by this — it prints on every handback, mid-loop pauses included.

Print one line per completed item as you go:

```
✅ #9043 Notification prefs — a named set   (Tier 2 · PR #9201 merged)
```

## The UI rule — this is what keeps the loop moving

**A human approves pixels.** Any item with a visible UI change cannot merge on your
say-so. Do not block the loop on it:

1. Build the mockup / surface, post the Claude artifact URL on the ticket.
2. Label `$HOLD_LABEL`, append to `.auto-skip` with reason `needs-human`.
3. **Move to the next row immediately.**

An approval-gated item is parked, not failed. The loop keeps running.

## Stop conditions (only these)

- Context window is spent.
- Tier 1 has a row that needs the operator (credits, a destructive prune, a Railway
  action on the account owner's Railway account) **and** Tiers 2 and 3 are empty.
- A migration that will not apply.
- A gate you cannot get green after real effort.
- A spec ambiguity only the PM can resolve.
- The queue is genuinely dry — run `queue-health-report.sh` and surface it.

Anything else: keep going.

## What /agent-harness:auto never does

- **Never takes a ticket wearing the hold label (`$HOLD_LABEL`).** It surfaces them and moves on.
- **Never self-flips a gate.** `$LBL_GATED` → `$LBL_READY` is the PM's call.
- **Never invents work.** If nothing is claimable, surface the queue-health
  report and stop. An empty board is a fact, not a prompt to file tickets.
- **Never proposes removals.** Zero rows in a table is a 2-user beta, not proof
  a feature is unused.
- **Never runs a destructive local command on its own authority** —
  `docker volume prune`, `git push --force`, worktree deletion of a dirty peer
  tree. Ask.
- **Never batches a gate with a push** in one shell — the push runs on the
  shell's success, not the gate's.
- **Never touches the public marketing site.** Its source is `landing/site-v25`, deployed by
  Vercel CLI; deploying from `main` wipes the site.
- **Never claims a ticket another agent holds.** The ref is the claim. Lost a
  race → back off, take the next row.

# Step 4 — Sign off

**Every handback ends with the sign-off banner** — the loop finishing, a stop
condition tripping, a pause for the operator, an interruption. Not only the end of a run.

**Render the run sheet first** — `${CLAUDE_PLUGIN_ROOT}/shared/run-sheet.md`, one list of
every ticket in the labels this run took from, in the order it gets done, so the reader can
see how far through the work is without asking. The triage board in Step 2 is for choosing
what to take; the run sheet is for showing where the work stands. Both, in that order.

Then read `${CLAUDE_PLUGIN_ROOT}/shared/agent-signoff.md` and follow it exactly. The shape:

```
🏷️ Working on: the whole board (/agent-harness:auto)
   Shipped 4 · 1 in flight (feed builder, PR open, gate red)
   Also running: 2 agents on Welcome Flow
   Resume: /agent-harness:auto
```

`Also running:` comes from a live read of `claim-lock.sh list --json` in the same
turn — Step 1E already ran it, but that board is stale by the time you sign off,
because your own merges moved it. Re-read.

When a stop condition tripped, line 2 names WHICH one, in the operator's words: "Stopped on:
the advisory gate won't go green on the third try". That is the line that tells the operator
whether to start another agent or come and look themselves.

## Flags

| Flag | Effect |
|---|---|
| *(none)* | Full loop. Triage → take → ship → re-triage → repeat. |
| `--dry` | Step 1 + Step 2's board only. Takes nothing. Read-only. |
| `--tier N` | Restrict to one tier. `--tier 1` = heal only; `--tier 2` = drain the stranded pile. |
| `--once` | Take exactly one item, ship it, stop. |

To run it hands-off across context limits, wrap it: `/loop /agent-harness:auto`.
