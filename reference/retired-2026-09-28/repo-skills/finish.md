---
name: finish
description: finish a ticket: gates, push, open PR, merge to develop, close the issue, release the claim. The review gate owns develop→uat promotion.
---

You are a dev agent finishing a ticket.

The queue lives **outside the repo** at `$STATE_DIR/`. Updating it does NOT require git operations.

## An approval covers the render that was signed off — nothing later

Dom, 2026-09-23: the One Desk design pass removed the rail's tabs in a critic round AFTER Dom approved
renders that still had them, and the hold was cleared by citing that earlier approval. He found out on UAT.

- A pixel approval names the exact evidence it was given against (the PR-body render SHA / file set).
- **Any** later change to what renders — a critic round, a review fix, a rebase that moves pixels — voids
  it. Re-capture, put before/after on the PR, and ask again. Never clear the hold label (`$HOLD_LABEL`) by
  citing an approval of an earlier render.
- A resume brief may carry an approval forward only for commits that change no pixels, and must say so.

`approval-gate` enforces this rather than trusting it (#10609): it reads the sign-off as an approval of
the commit the PR was at when the label came off, and re-applies `$HOLD_LABEL` — with a comment
naming the commits and the screens — as soon as this PR pushes anything that changes what a user sees.
Merge commits are skipped, so a routine develop catch-up does not void an approval.

## What "finish" means

Finish ships the work to `develop`: PR → merge to `develop` → close the issue → release the claim. `/finish` ends at the develop merge — it does **not** touch the `uat` branch.

## Epic-mode finishes (#3572)

If the claim record has `"mode": "epic"`, you are finishing ONE SLICE of an epic run (see claim.md "Epic mode"), not a whole ticket. The flow differs in five ways:

1. **PR title:** `#NNNN slice k/M: <slice title>` (NNNN = the epic issue number, k/M = slice position from the state file).
2. **PR body references, never closes:** write `Part of #NNNN` — NEVER `Closes #NNNN` or `Closes ticket $TICKET`. A slice merge must not auto-close the epic (the SH-2571 reopen guard is the backstop, not the plan).
3. **State-file update is MANDATORY before push** (extends the programme-state enforcement below): the slice moves to "Shipped" with merge SHA + date, decisions made during the slice get logged, "Next up" is refreshed. No state-file update → no push.
4. **No per-slice GH comments and no issue close.** The epic gets exactly two comments across its whole run (claim + completion digest — both posted by the /claim epic runner, not /finish). Step 7d's comment + close are SKIPPED for non-final slices. Exception: if the slice was an ADOPTED child issue (pre-v3 children, e.g. #3408's #3553–#3558), close THAT child with a one-line merge note — the child's outcome comment is its record, not epic noise.
5. **The claim survives the merge.** Step 7a (release claim) runs only after the FINAL slice, as part of the epic close-out (claim.md E6: final AC walk → completion digest → `gh issue close` → release). For every earlier slice, leave both in place.

Everything else — gates, push, PR, squash-merge, worktree cleanup — is identical per slice.

**Why no UAT promote**: the automated review gate owns `develop → uat` promotion (see [`docs/operations/automated-code-review.md`](../../docs/operations/automated-code-review.md)). It reviews newly-merged commits in batches, promotes the passing ones to `uat` → Railway, and pings the PM only on FAIL / promote / rollback. The 2026-05-04 directive had `/finish` fast-forward `uat` on every merge — which bypassed the gate entirely: unreviewed and even gate-FAILed commits shipped straight to UAT testers. The original "features stuck on develop unnoticed" problem is now solved by the gate, not by `/finish`. For an urgent manual promote (e.g. a live demo before the gate's next cycle), `/push-to-uat` is the explicit override.

## Pre-flight — gate-runner sub-agent (recommended for long tickets)

Before stepping into Step 3 (run gates locally) on a ticket that touches >5 files OR runs >2k lines of diff, **delegate gate runs to the `gate-runner` sub-agent** to keep the main session's context clean:

```
Use Agent tool with subagent_type=gate-runner, prompt="Run lint + typecheck + tests for the current branch <BRANCH>; report new vs pre-existing failures only."
```

The agent runs `npm run lint && npm run typecheck && npm test` in isolation, filters out failures in files NOT touched by this branch (pre-existing), and returns a structured verdict. Stops your main context from being polluted with thousands of lines of test output.

Use the in-session `npm run` only on small tickets (<5 files) where the noise won't matter.

## Programme state update

If the ticket you're finishing is a CHILD of a programme (body references "Child of #N"), refresh the programme state file as part of /finish. State files live in `docs/programmes/` in the repo, so the refresh is a commit on your branch — run it BEFORE the push in Step 4 (the generated half re-reads GitHub, so a refresh before the merge records the child as in flight; the close-out refresh happens on the next child's ship):

```bash
. "$(git rev-parse --show-toplevel)/scripts/toolkit-env.sh" || exit 1
PROGRAMME=$(gh issue view "$ISSUE_NUM" --repo "$REPO_SLUG" --json body -q .body | grep -oE "Child of #[0-9]+" | head -1 | grep -oE "[0-9]+")
if [ -n "$PROGRAMME" ] && [ -f "$(git rev-parse --show-toplevel)/docs/programmes/state-${PROGRAMME}.md" ]; then
  "$(git rev-parse --show-toplevel)/scripts/programme-status.sh" "$PROGRAMME" || true
  git add docs/programmes && git commit -q -m "chore(programme): refresh state-${PROGRAMME}" -m "no-changelog: programme bookkeeping" || true
fi
```

**Do NOT hand-edit the shipped / in-flight / next-up lists.** They live between
`<!-- GENERATED: programme-status -->` markers and are re-read from live GitHub state
(the programme's `project:*` label) plus the claim refs on origin. Anything typed inside
those markers is overwritten on the next ship. Run the script; that IS the update.

Two conditions to check rather than assume:

1. **Run it BEFORE the push in Step 4** — it is a commit on your branch, and a
   commit made after the merge is discarded with the worktree. It records this
   child as in flight; the ship itself is recorded by the next child's refresh,
   or by `scripts/programme-status.sh --all` run as a chore from any checkout.
2. **The programme needs a `project:*` label** declared in its state file. If the script
   says `declares no project:* label`, create the label, apply it to the programme and every
   child, and add ``**Label:** `project:<name>` `` near the top of the state file. Do not
   fall back to hand-editing the lists — that is the failure mode this replaced (43 state
   files on disk, 8 in the README's active list, last touched three months earlier).

What you DO still write by hand, below the markers: a line under **Recent decisions** for
any call made during the slice, anything new for **Do not re-propose**, and a correction to
**Blockers** if one cleared. Those are the parts a script cannot know.

Skip silently if the programme has no state file.

**Epic-mode (#3572): this is a HARD gate, not best-effort** — but the two halves gate at different moments, because only one of them is yours to write:

- **Before Step 4 (push):** the CURATED half. Decisions made during the slice logged under **Recent decisions**, anything settled added to **Do not re-propose**, blockers corrected. No curated update → no push. This is the part a script cannot reconstruct, and the 2-comment policy means GH shows nothing between claim and completion, so if you don't write it, it is gone.
- **Also before Step 4:** the GENERATED half, via `programme-status.sh`, committed on the branch. It records the slice as in flight; the next slice's refresh (or the epic close-out) records it shipped.

For an epic slice the state file is `state-NNN.md` for the epic itself (NNN from the branch). If the state file is missing for an epic slice, stop and recreate it from the epic body + already-merged slice PRs; do not ship a slice the state file doesn't record. The state file is the ONLY in-flight record of an epic run (the 2-comment policy means GH shows nothing between claim and completion).

## Ship-whole rule

**A `/finish` ships the WHOLE ticket end-to-end. No partial-slice shortcuts.** If you can't tick every AC from the spec, you're not done.

### Hard pre-finish checks

Walk the ticket's AC list (from the spec):

1. Read `$STATE_DIR/${BRANCH_PREFIX}NNN-*.md`.
2. For every checkbox in "Acceptance criteria", confirm it's done.
3. For every step in "How to verify", confirm it works against your branch.
4. If any AC isn't met:
   - **Genuinely too big** → don't `/finish`. Surface back: *"SH-NNN's AC list isn't fully met — items X, Y are not done. This ticket needs to either be finished by the next claim, or split into a follow-up ticket."*
   - **Human-driven blocker remains** (UAT walkthrough, PM eyeball, lawyer, third-party review) → that's the only legitimate `partial`. Surface clearly.
   - **You're done but didn't realise** → great, finish.

## Multi-agent contract + atomic claim

This skill assumes you are inside a per-claim worktree (created by `/claim`), at a path like `${TMPDIR:-/tmp}/${BRANCH_PREFIX}NNN-<slug>-<hash>`. **Never push from the main repo clone (`$MAIN_REPO`).** Those repos stay on `develop`.

Your claim is the git ref `refs/claims/<issue>` on origin; `claim-lock.sh show` prints its record, which carries the `repo` field telling us which sister repo this ticket targets. **`/finish` reads `repo` to know where to push** and releases the ref on merge so the ticket can be re-claimed (or the PM can re-open).

Release is the LAST step, after the merge is verified — a ref released before the merge lands is a ticket another agent can claim out from under a PR that is still open.

## Cross-repo routing

Same convention as /claim: a `repo:<name>` label on the GH issue names a sister repo. The claim record carries `repo` from claim time. /finish reads it and `scripts/toolkit-env.sh` resolves the clone location from the checkout:

```bash
. "$(git rev-parse --show-toplevel)/scripts/toolkit-env.sh" || exit 1
CLAIM=$("$CL" show "$TICKET_KEY")
REPO_NAME=$(jq -r '.repo // empty' <<<"$CLAIM")
[ "$REPO_NAME" = "null" ] && REPO_NAME=""   # empty = the main repo
REPO_PATH=$(toolkit_repo_path "$REPO_NAME") || exit 1
if [ "$REPO_PATH" = "$MAIN_REPO" ]; then REPO_FULL="$REPO_SLUG"; else REPO_FULL="${REPO_SLUG%/*}/$REPO_NAME"; fi
```

Claims without a `repo` field default to the main repo — no migration needed.

`/finish` ships every repo to its `develop` only; the `uat` branch is never touched here (the review gate owns promotion). So there is no repo-specific UAT step to route — a sister repo (which may have no `uat` branch at all) and the main repo finish identically.

## Repo guard (run first)

```bash
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not in a git working tree. cd into your worktree first." >&2; exit 1; }
. "$(git rev-parse --show-toplevel)/scripts/toolkit-env.sh" || exit 1
PWD_ABS=$(pwd -P)
# Refuse to run from a main repo clone — /claim should have placed us in a
# per-claim worktree.
for CLONE in "$MAIN_REPO" "$SUPPORT_REPO"; do
  if [ -n "$CLONE" ] && [ "$PWD_ABS" = "$(cd "$CLONE" && pwd -P)" ]; then
    echo "Refusing to finish from a main repo clone ($CLONE). /claim should have placed you in a worktree." >&2
    exit 1
  fi
done
```

If the current branch is `main`, `develop`, or doesn't match `${BRANCH_PREFIX}NNN/*`, stop — `/finish` is only valid on a ticket branch.

## Workflow

### Step 0 — (retired)

There is no local index to refresh: every reader asks GitHub.

### Step 1 — Confirm branch + worktree + ticket ID + repo routing

```bash
. "$(git rev-parse --show-toplevel)/scripts/toolkit-env.sh" || exit 1
BRANCH=$(git branch --show-current)
WORKTREE=$(pwd -P)
TICKET=$(echo "$BRANCH" | awk -F'/' '{print toupper($1)}')   # ${BRANCH_PREFIX}181/... → SH-181
# Claims are keyed on BARE DIGITS and live in refs/claims/<issue> on origin.
TICKET_KEY=$(echo "$TICKET" | tr -d '#' | sed "s/^$(printf '%s' "$BRANCH_PREFIX" | tr a-z A-Z)//")
echo "Branch: $BRANCH | Worktree: $WORKTREE | Ticket: $TICKET"

# Sanity: the claim must exist (we should have claimed this).
CLAIM=$("$CL" show "$TICKET_KEY" 2>/dev/null) \
  || { echo "No claim ref for $TICKET — was this claimed via /claim?" >&2; exit 1; }

# Migration shim: claims adopted from the old lock dirs carry agent
# "legacy-lock", so the holder check below cannot identify them. Drop this
# once no legacy-lock claims remain (claim-lock.sh list will show none).
if [ "$(jq -r .agent <<<"$CLAIM")" != "legacy-lock" ]; then
  "$CL" holds "$TICKET_KEY" \
    || { echo "#$TICKET_KEY is claimed by another agent — refusing to finish someone else's ticket." >&2; exit 1; }
fi

# Resolve cross-repo routing from the lockfile meta. Defaults to the main repo
# if the lockfile predates the cross-repo support. The clone location comes
# from the checkout via toolkit-env (MAIN_REPO / SUPPORT_REPO); any name that
# is not a sisterRepos entry resolves to MAIN_REPO, so legacy lockfiles resolve too.
REPO_NAME=$(jq -r '.repo // empty' <<<"$CLAIM")
[ "$REPO_NAME" = "null" ] && REPO_NAME=""   # empty = the main repo
REPO_PATH=$(toolkit_repo_path "$REPO_NAME") || exit 1
if [ "$REPO_PATH" = "$MAIN_REPO" ]; then REPO_FULL="$REPO_SLUG"; else REPO_FULL="${REPO_SLUG%/*}/$REPO_NAME"; fi

# #3572 — epic-mode detection. "epic" = this branch is one slice of an
# epic run; see "Epic-mode finishes" above for what changes downstream.
MODE=$(jq -r '.mode // "ticket"' <<<"$CLAIM")
echo "Repo: $REPO_NAME ($REPO_FULL → $REPO_PATH) | Mode: $MODE"
```

**Epic-mode branch naming:** slice branches look like `${BRANCH_PREFIX}NNN/slice-k-<slug>` where NNN is the EPIC's number — the `$TICKET` derived above is the epic, and its claim is the one that must exist.

### Step 2 — Check uncommitted changes

```bash
git status --porcelain
```

If anything is uncommitted, ask the user before proceeding.

### Step 2.5 — Changelog entry (BEFORE the gates — they enforce it)

Decide the changelog NOW, not after. If the ticket is user-visible
(`feat`/`fix`), write the entry as **its own file** — never an edit to the
shared `changelog.md`:

```bash
mkdir -p apps/web/src/content/changelog
cat > "apps/web/src/content/changelog/${TICKET_KEY}.md" <<EOF
## $(date -u +%Y-%m-%d)
- [Fixed] **Short bold title** — one-sentence body in plain English. [→ /dashboard/route]
EOF
npm run changelog:build
```

Same line format as `docs/changelog-authoring.md`; `[New]` / `[Improved]` /
`[Fixed]` is the whole vocabulary. The file is named for the ticket, so no two
PRs write the same path: the shared file conflicted every open PR on every merge
(6 of 8 re-gated in the first One Desk swarm, ~2 of 16 hours lost to it), and a
fragment cannot. If the change genuinely matches a skip rule (refactor /
internal-only / CI-deps / staff-only), put `no-changelog: <reason>` in the
commit body instead. `check:changelog-entry` (gates + pre-push + CI) accepts
the fragment as the entry and fails the push if you do neither — /finish
cannot complete without deciding. (#3778, #10369)

**Squash-retitle hazard (#3909):** this repo squash-merges with the PR
TITLE as the develop commit subject. If your branch commits are `chore:`
but you title the PR `feat:`/`fix:`, the title is what ships — CI gates
the PR title too, with the `no-changelog:` tag honoured from the PR body
or any branch-commit body. Title the PR the way the squash should read.

### Step 3 — Run quality gates locally

**HARD RULE — gates are EXIT-CODE-GATED, never batched past (burned
2026-06-11, #3677):** a typecheck failure was PRINTED mid-batch but the
same command batch continued through commit → push → merge, landing a
broken trunk for ~4 minutes until the fix-forward. Run gates as their
own command and stop on a non-zero exit BEFORE any commit/push/merge
command executes:

```bash
npm run lint && npm run typecheck && npm test || { echo "🛑 GATES FAILED — fix before any commit/push/merge"; exit 1; }
```

Never put `git commit`/`git push`/PR-create/merge in the same command
batch as a gate run — eyeballing batch output misses failures; the
exit code is the gate.

```bash
# Worktree guard — the generated Prisma client is not in git; a worktree
# that skipped /claim's generate step shows ~24 phantom TS2307/implicit-
# any errors that mimic a trunk regression (#3537 false alarm,
# 2026-06-10). The pretypecheck:web/api hooks self-heal typecheck, but
# `npm test` has no such hook — generate explicitly. Idempotent.
sh scripts/prisma-generate-if-needed.sh >/dev/null  # #3570 — fingerprint-skips when unchanged

npm run lint
npm run typecheck
npm test

# #9966 (2026-09-01): the trio above does NOT include check:deploy-trigger.
# That gate reads COMMITS (merge-base..HEAD), so it must run after Step 2's
# clean-tree check, which is where we are. A PR sat 9 minutes with auto-merge
# armed and Code gates red for exactly this. Stamp and commit only when it
# fails. A sentinel bump does not move the UI-Gate fingerprint (verified).
if ! npm run check:deploy-trigger; then
  sh scripts/bump-deploy-trigger.sh >/dev/null
  git add .deploy-trigger apps/web/.deploy-trigger apps/api/.deploy-trigger
  git commit -q -m "chore: bump .deploy-trigger" -m "no-changelog: deploy plumbing only"
  npm run check:deploy-trigger || { echo "🛑 .deploy-trigger gate still failing"; exit 1; }
fi
```

If any fail, **stop**. Fix or surface. No `--no-verify`. No skipping. **Before declaring a failure "pre-existing on develop", re-verify it in a worktree that has run `npx prisma generate`** — a stash-baseline comparison in an ungenerated worktree shows the same phantom errors on both sides and proves nothing.

If gates passed at commit time and nothing has changed since, you can fast-track — say so explicitly ("gates passed at commit time, skipping re-run").

### Step 3.5 — Review: both gates, together, on the first working version (#10507, #10548)

**`/critic` and `/ui-gate` run TOGETHER here, on the first version that renders** — not in
sequence at the end. They judge different things (is it designed · is it honest) and neither
subsumes the other, so running them apart means the agent builds on top of work the other
gate is about to reject. Their combined findings are one batched fix list.

Dom, 2026-09-23, after the One Desk design pass spent 3½ hours in its final code review
raising one point per round, having cleared the design critic hours earlier: *"apply all
those rules, not just the two."*

**Two rounds, then the PR ships.** Run the pair, fix the batch, run the pair again. After the
second round anything still raised that is **not a blocker** is filed as its own ticket,
linked on the PR, and the PR merges. A blocker still blocks, and a blocker is one of exactly
these: a dead control, a broken flow, or a data-honesty failure (fabricated values rendered
as real). Everything else — a spacing call, a copy preference, a nice-to-have — is a
follow-up.

The cap is **recorded, not promised**: the PR body carries `Review rounds: N of 2`, so a
reader can see the rule was applied rather than take the agent's word for it. A follow-up
ticket carries the reviewer's finding **verbatim**, the screenshot it was raised against,
and the parent's `project:` label.

Gates 4 and 5 in Step 5.5 still verify that a verdict exists and was taken against the head
being merged — the cap changes how many rounds you run, never whether the verdict is real.


Dom, 2026-09-21, after the composed One Desk read as slop with 46 green tickets behind
it: *"Has nothing been checking the UI for poor design?"* Nothing had. This step used to
be one sentence — "on any pixel-changing ticket also run `/critic <route>`" — and a
sentence does not stop a push, so print-mode agents never ran it and zero of the 46
carried a verdict. The code-honesty gate had teeth (`check:ui-gate-attested` refuses a
push without `UI-Gate: SHIP (agent) <fingerprint>`); this is its twin for design.

**The pre-push hook refuses a UI diff without `Design-Critic: SHIP (agent) <fingerprint>`
on a commit in the branch.** The fingerprint is the same UI-diff hash the code gate
uses, so a rebase that changes the UI diff stales both trailers together, and this one
step re-earns both. Run it before Step 4, as the last thing before the commit you push —
a verdict taken before the last edit is about pixels nobody is shipping.

**Predicate.** The same one the code gate uses:

```bash
npm run check:design-critic-attested --silent -- --base origin/develop --head HEAD
```

`no UI surface in this diff` → skip to Step 4. `design-exempt` → skip to Step 4 (that
label means "the diff qualifies but is not a design decision" — wiring that preserves an
approved design, a bug fix that happens to land in a component file; it does NOT exempt
the `UI-Gate:` trailer, which judges honesty, not design). Anything else prints the
fingerprint the trailer must carry and the UI files it was hashed over.

**1. Name the routes.** Every `apps/web/src/app/**/page.tsx` in the diff is a route. A
component or kit file names the routes that mount it — `git grep -l '<ComponentName'
apps/web/src/app` — and you photograph those. At least one route, always; a diff whose
routes you cannot name is a diff whose pixels you have not seen.

**2. Serve THIS branch as a production build, signed in.** Not the dev server: a dev
server compiles a route on first request and the page's own fetch races that compile, so
a cold route photographs its error boundary, and hydration timing differs enough that
motion and skeletons land in different frames. Not the PM's `:3000` either — that runs
develop. Port and `.env` follow `/design`'s rules (3010 is owned; the worktree has no
`.env`):

```bash
PORT=$((3000 + ${TICKET_KEY: -3}))
[ -f .env ] || cp "$MAIN_REPO/.env" .env
scripts/render-round/serve.sh apps/web --port "$PORT" || exit 1
```

`serve.sh` is the round, and every part of it was a measured cost on #10521's
143-minute design pass (111 of those minutes waiting on the environment):

- **It never deletes `.next/cache`.** The bundler cache is worth 2.2x on compile
  — 27.8s against 60s, measured on the same tree. Use
  `scripts/clear-next-output.sh apps/web` if a render genuinely looks stale; it
  clears the output and keeps the cache.
- **It restarts only `next start`.** Postgres, Redis, seeds and migrations are
  untouched between rounds of one ticket.
- **It waits on the route, not a clock** — `/login` for web, `/api/health` for
  api — with a deadline, and refuses to serve behind a port it could not free
  (that is how a round photographs the PREVIOUS build while going green).
- **It runs the three preflight steps first.** A fresh worktree fails `next
  build` twice before it succeeds once — missing generated changelog data, then
  workspace links pointing at the main clone (#8663). Each no-ops in about a
  second once done.
- **It skips `output: 'standalone'`** via `NEXT_LOCAL_RENDER=1`. Trace collection
  is a deploy concern, and from a worktree it cannot complete at all: the
  `node_modules` symlink leaves the tracing root and the build dies on an EACCES
  mkdir above `$TMPDIR`. That is why rounds fell back to `next dev`.

Step timings land in `${TMPDIR}/render-round-web/timings.tsv`.

`--webpack`, because the worktree's `node_modules` is a symlink into the main clone and
Turbopack refuses it. If the build itself cannot complete on this machine (OOM, a
dependency the worktree cannot resolve), fall back to `next dev apps/web -p "$PORT"
--webpack`, warm every route once before shooting, and **say so in the PR body** — the
trailer does not record the mode, so the body has to.

**3. Capture, settled, light and dark.** `visual-check.ts` signs in as the dev test
user, waits for the shell to settle, and writes one PNG per route and theme:

```bash
export VISUAL_CHECK_OUT="/tmp/critic-$TICKET_KEY/v1"
VISUAL_CHECK_BASE_URL="http://localhost:$PORT" npx tsx scripts/visual-check.ts <route> [<route>...]
```

These are the same captures Step 5.5 Gate 2 publishes as evidence: it reads
`$VISUAL_CHECK_OUT`, so `export` it (an inline assignment dies with the command) and leave
it pointing at the final iteration's directory.

**4. Judge — with the settled calls in the prompt.** First print them, per route:

```bash
npx tsx scripts/screen-gate/decisions.ts --route <route>
```

Nothing printed means the route is not a registered surface and nothing is settled on it.
When it prints, that block goes into the critic's prompt **verbatim** — a critic that has
not been told what the operator already decided re-raises that call every run, and on a
SHIP bar that is a ticket that can never be pushed. Only the operator adds to
`design/screen-gate/<surface>.decisions.json`; `check:decisions-provenance` refuses a write
with no `Decision-Source:` trailer.

Then spawn the `design-critic` agent (Agent tool, `subagent_type: design-critic`).
Tell it to **Read** every PNG in the capture directory, give it the philosophy path
(`docs/design/design-philosophy.md`), the route(s), the settled-calls block, and the source
files in the diff so its failures cite real structure. It returns `VERDICT: SLOP|SHIP`,
ranked failures, and **the one move**. Capture all three.

**5. SHIP → record it, in the same breath as the code gate's trailer.** One empty commit
carries both when both are owed (a rebase stales them together; re-earning them together
is the point):

**Never hand-write the trailer.** `scripts/record-verdict.sh` reads the reviewer's own
output and writes the stamp from it; the author agent never types a SHIP line. Save the
reviewer's verbatim output, then:

```bash
scripts/record-verdict.sh design-critic --sha "$(git rev-parse HEAD)" < critic-output.txt
scripts/record-verdict.sh ui-gate       --sha "$(git rev-parse HEAD)" < ui-gate-output.txt
npm run check:design-critic-attested -- --base origin/develop --head HEAD   # must print ✓
```

It refuses a SLOP or a SPIT-BACK, refuses a review of any commit that is not HEAD, and
refuses output with no `VERDICT:` line rather than inventing one.

**This is not a convenience.** A spawned agent in `--permission-mode auto` cannot write
the trailer itself at all: the classifier denies an empty commit carrying a verdict line as
a CI bypass, because the agent that wants to merge is attesting its own review. The
objection is correct. (The refused command is not reproduced here — a copy-pasteable line
in this file is a line an agent will copy.) Measured 2026-09-24 on #10704 — finished, reviewed SHIP twice, and
stuck for over an hour until a person stamped it by hand. The recorder takes the
attestation out of the author's hands, which is what the classifier was asking for.

`(agent)` is the only mode. There is no inline critic: a self-judged design is the
statistical mean judging itself, which is the thing this gate exists to catch.

**6a. SLOP citing only settled calls → record SHIP and change nothing.** Check every
finding's id against the keys the decisions block named. If they are all decided, the
verdict is a bug in the prompt, not a failing screen: record `Design-Critic: SHIP (agent)`
per step 5 and say in the PR body which keys the critic re-raised. **Never apply a one move
that undoes a settled call** — that is the failure this file exists to stop,
arriving through the gate meant to prevent it.

**6. SLOP → apply the one move, re-render, re-judge.** Only the one move — surgical,
inside the diff's own files, kit primitives and brand tokens only, never a redesign.
Bump the capture directory (`v2`, `v3`) so the iterations stay readable. **Up to 3
iterations.** Each move is a real commit on the branch, so the fingerprint moves with it
and the verdict you finally record is about the pixels you push.

**7. Still SLOP at 3 → park, never merge.** Push the branch, open a draft PR, and post the
resume brief on the ticket with the critic's final verdict, its ranked failures, and the
last light + dark captures committed under `docs/evidence/$TICKET_KEY/critic/` and
SHA-pinned as blob links (the same rule as Gate 2 — raw and CDN links do not render for
this repo). Label the ticket `$(toolkit_cfg labels.design)`, release the claim
(`claim-lock.sh release`), and stop. Three moves that did not clear the bar is a design call, and design calls are
the PM's — an agent that keeps grinding past 3 ships its fourth guess.

### Step 4 — Push the branch

```bash
git push -u origin "$BRANCH"
```

**Never push directly to `develop` or `main`.**

### Step 5 — Open the PR against `develop`

`gh pr create` infers the repo from the current git remote (which the worktree inherited from `$REPO_PATH`), so we don't need `--repo` here. But if you want belt-and-braces, add `--repo "$REPO_FULL"`.

```bash
gh pr create --base develop --title "$TICKET: <title>" `# via /finish` --body "$(cat <<'EOF'
## Summary
<1-3 bullets — what changed and why>

## Spec
$STATE_DIR/<spec-file>

## Acceptance criteria (every box ticked)
- [x] <AC 1>
- [x] <AC 2>
- [x] Local gates: lint (0 errors), typecheck (clean), tests (N/N pass)
- [ ] CI green
- [ ] Reviewed + promoted to UAT by the review gate (not part of /finish)

Review rounds: <N> of 2
Claimed at develop <sha>

## How to verify (post-merge)
<copy from spec>

Closes ticket $TICKET.
EOF
)"
```

If you find yourself wanting to add a "deferred to follow-up" line under AC, **stop**. That's a partial, which the rule forbids — keep working OR open new properly-sized tickets for the deferred work.

**`Review rounds:` and `Claimed at develop` are not decoration.** The first records the cap
above. The second freezes the rules: a required check or skill rule that landed on develop
*after* that SHA does not apply to this ticket, which finishes under the rules it started
with. Three new required checks landed midway through #10521 and each cost it a round. The
SHA is written on the claim at claim time (`/claim` Step 3), so it is a fact recorded before
the work, not a claim made after it. A check that predates the SHA applies normally — this
freezes the rules, never the quality bar.

**About six fixes per PR.** A ticket may be as big as it needs to be; its work ships in PRs
of roughly six fixes each, each through the full flow. One late problem then holds up six
fixes rather than seventeen. A design pass with 15 findings is three PRs, not one.

**Epic-mode PR shape (#3572):** title is `#NNNN slice k/M: <slice title>`; the AC list in the body is the SLICE's AC (from the state file), not the epic's; and the closing line is `Part of #NNNN` — never `Closes`. GitHub's auto-close linking must not see this PR as closing the epic.

```bash
PR_NUMBER=$(gh pr view --json number -q .number)
```

### Step 5.5 — Anti-orphan gates (#2486)

PM-mandated 2026-05-24, sibling to `/claim`'s Step 4.5 (#2485). The PR is open but not yet merged. Three gates run here to refuse merges that would land UI without backing API, or UI without a live-render proof.

Failure releases nothing — the PR stays open — but exits with a named-failure error message so the dev-AI knows exactly what to add to the PR body / files before re-running `/finish`.

**Gate 2 is no longer the enforcer of the screenshot rule (#9174).** That requirement now lives in the `approval-gate` CI job, which is a required status check and therefore cannot be skipped by an agent that simply doesn't run this skill. Gate 2 exists to **satisfy** that check — it refuses unviewable evidence, and when the body carries none it publishes the shots this run rendered, SHA-pinned — not to replace it. If you find yourself editing Gate 2 to relax the screenshot rule, you are editing the wrong file: the rule is in `.github/workflows/human-approval-gate.yml`.

```bash
PR_FILES=$(gh pr view "$PR_NUMBER" --repo "$REPO_FULL" --json files -q '.files[].path')
PR_BODY=$(gh pr view "$PR_NUMBER" --repo "$REPO_FULL" --json body -q .body)
ISSUE_NUM="$TICKET_KEY"   # ticket ids ARE issue numbers
ISSUE_BODY=$(gh issue view "$ISSUE_NUM" --repo "$REPO_SLUG" --json body -q .body 2>/dev/null || echo "")

PR_TOUCHES_UI="no"
PR_TOUCHES_API="no"
# ONE definition of "changes what a user sees", shared with the approval gate.
# Do not inline the rule here — six copies of it is how /welcome, signup and the
# OAuth returns became invisible to the gate (#9852).
if echo "$PR_FILES" | sh scripts/changes-what-a-user-sees/index.sh >/dev/null 2>&1; then
  PR_TOUCHES_UI="yes"
fi
if echo "$PR_FILES" | grep -qE 'apps/api/src/app/api'; then
  PR_TOUCHES_API="yes"
fi

# Is the UI change a pure REMOVAL? A PR that only deletes routes and components
# cannot be screenshotted — the page it would photograph is the one it removes.
# Asking for one anyway pushes people to attach a shot of something else, which
# is worse than no evidence. Deletion-only = every touched UI file has ZERO
# added lines (changelog and MANIFEST prose excluded, since a removal PR is
# expected to add both).
PR_UI_IS_DELETION_ONLY="no"
if [ "$PR_TOUCHES_UI" = "yes" ]; then
  UI_ADDITIONS=$(gh pr view "$PR_NUMBER" --repo "$REPO_FULL" --json files \
    -q '[.files[] | select(.path | test("apps/web/src/(app/dashboard|components)"))
         | select(.path | test("changelog|MANIFEST\\.md") | not)
         | .additions] | add // 0')
  [ "${UI_ADDITIONS:-0}" -eq 0 ] && PR_UI_IS_DELETION_ONLY="yes"
fi

# Gate 1 — UI/API symmetry check. If the spec describes API endpoints
# (or has a "## Backend contract" section) AND the PR ships UI but
# NOT API, refuse — unless the PR body explicitly declares a
# phase-split with a feature flag wrapping the new UI.
SPEC_HAS_API="no"
if echo "$ISSUE_BODY" | grep -qiE 'api/|endpoint|## Backend contract|## API contract'; then
  SPEC_HAS_API="yes"
fi
if [ "$SPEC_HAS_API" = "yes" ] && [ "$PR_TOUCHES_UI" = "yes" ] && [ "$PR_TOUCHES_API" = "no" ]; then
  if ! echo "$PR_BODY" | grep -qE 'phase[- ]split:\s*true' \
     || ! echo "$PR_BODY" | grep -qiE 'feature[- ]flag|FEATURE_FLAG|featureFlags\.|guards\.'; then
    echo "❌ /finish REFUSED: PR ships UI without the backing API." >&2
    echo "   Either:" >&2
    echo "   - Add the API in this PR (preferred — keep UI + API symmetric per feedback_no_orphan_features.md)" >&2
    echo "   - OR add 'phase-split: true' + a feature-flag reference to the PR body explaining the orphan UI is gated dark" >&2
    exit 1
  fi
fi

# Gate 2 — Live-render evidence check. A UI-touching PR must carry evidence
# the surface was actually RUN. Catches the "specced-and-coded-but-never-ran"
# pattern.
#
# The evidence must be VIEWABLE, which the original form of this gate did not
# check. It required a markdown embed or <img>, and mrdombie/maktura is a
# PRIVATE repo: raw.githubusercontent.com carries no session and no token, so
# `![shot](https://raw.githubusercontent.com/...)` renders broken for every
# reader while satisfying the grep. The gate read GREEN on unviewable evidence —
# the exact failure it exists to prevent — and requiring an *embed* is what
# pushed people onto raw URLs in the first place, because a blob link cannot be
# embedded. So: raw URLs are refused outright, and a SHA-pinned blob LINK now
# counts (it resolves for any repo member and survives branch pruning).
#
# Known limitation, stated rather than papered over: this proves the evidence
# can be OPENED, not that it is genuine. An image is unfalsifiable — it can be
# of another page, an older build, or a mockup. The honest proof of "it ran" is
# an execution artefact (a committed test that loads the real route and asserts
# a real element). That is a deliberate, separate decision; this gate does not
# pretend to make it.
# A deletion-only UI PR proves itself by EXECUTION, not by photograph. The gate's
# own reasoning says the honest artefact is "a committed test that loads the real
# route and asserts a real element"; for a removal that inverts into an absence
# assertion, which is strictly checkable where an image never was. Requires BOTH:
# a passing nav-coverage check, and a "## Removal evidence" section in the body
# naming what was deleted and where its behaviour now lives. (Blocked #8524 and
# #7861 on 2026-08-07 — two correct deletions stalled behind an inapplicable rule.)
if [ "$PR_TOUCHES_UI" = "yes" ] && [ "$PR_UI_IS_DELETION_ONLY" = "yes" ]; then
  if ! echo "$PR_BODY" | grep -qE '## Removal evidence'; then
    echo "❌ /finish REFUSED: deletion-only UI PR without a '## Removal evidence' section." >&2
    echo "   No screenshot is required — the page is gone. Instead state, and show:" >&2
    echo "     - the routes/components removed" >&2
    echo "     - where each behaviour now lives (or that it was dead)" >&2
    echo "     - 'npm run check:orphan-routes' output, and the absence assertions that replaced" >&2
    echo "       any deleted test (assert the route is GONE, never delete the test)" >&2
    exit 1
  fi
  echo "✓ Gate 2 satisfied by removal evidence (deletion-only UI PR — nothing to render)."
elif [ "$PR_TOUCHES_UI" = "yes" ]; then
  # #10479 — a live PREVIEW is the strongest hand-over there is: a URL anyone
  # can open from any machine, running this branch. The preview-url workflow
  # writes it into the body between <!-- preview:begin/end --> markers when
  # Railway's bot reports it. It never REPLACES the screenshot: the CI approval
  # gate reads a SHA-pinned docs/evidence blob and the preview is gone after
  # merge, so the capture below still runs whenever the body has no screenshot.
  # The web URL is the one that matters; the api host answers 200 on a placeholder.
  PREVIEW_URL=$(printf '%s\n' "$PR_BODY" | tr -d '\r' \
    | awk 'index($0,"<!-- preview:begin -->"){f=1;next} index($0,"<!-- preview:end -->"){f=0} f' \
    | grep -oE 'https://[A-Za-z0-9.-]+\.up\.railway\.app[^ )>"]*' | awk 'NR==1{first=$0} /:\/\/web/{print; exit} END{if(!found) print first}' | head -1)
  if [ -n "$PREVIEW_URL" ]; then
    if curl -sfL -m 8 -o /dev/null "$PREVIEW_URL"; then
      echo "✓ live preview answers — $PREVIEW_URL (hand this over; the screenshot below is still the durable record)"
    else
      echo "⚠️  the preview URL in the body does not answer ($PREVIEW_URL) — torn down? the screenshot is the evidence"
    fi
  fi
  if echo "$PR_BODY" | grep -qE 'raw\.githubusercontent\.com'; then
    echo "❌ /finish REFUSED: evidence linked via raw.githubusercontent.com." >&2
    echo "   The repo is PRIVATE — raw URLs carry no token and render broken for every reader," >&2
    echo "   including you. Passing this grep is not the same as anyone being able to look." >&2
    echo "   Use a SHA-pinned blob link instead (a link, not an embed):" >&2
    echo "     https://github.com/$REPO_SLUG/blob/<merge-sha>/docs/mockups/<shot>.png" >&2
    echo "   Pin to the commit SHA, never a branch — it outlives branch pruning and trunk movement." >&2
    exit 1
  fi
  # A blob link must be pinned to a SHA, never a branch. /finish merges with
  # --delete-branch, so `.../blob/sh-1234-slug/shot.png` is dead the moment this
  # gate passes it. Checked before the accept below, because the generic
  # markdown-image rule would otherwise wave a branch-pinned link through.
  if echo "$PR_BODY" | grep -qE 'https://github\.com/[^ )]+/blob/[^ )]+\.(png|jpg|jpeg|webp|gif)' \
     && ! echo "$PR_BODY" | grep -qE 'https://github\.com/[^ )]+/blob/[0-9a-f]{7,40}/[^ )]+\.(png|jpg|jpeg|webp|gif)'; then
    echo "❌ /finish REFUSED: blob evidence is pinned to a branch, not a commit." >&2
    echo "   This PR merges with --delete-branch, so that link dies on merge." >&2
    echo "   Re-point it at the commit SHA: .../blob/<sha>/docs/mockups/<shot>.png" >&2
    exit 1
  fi
  # Accepted: a SHA-pinned blob link (preferred), a markdown image, or an <img>.
  # The leading `!` is optional now — a link is the viewable form here.
  if echo "$PR_BODY" | grep -qE 'https://github\.com/[^ )]+/blob/[0-9a-f]{7,40}/[^ )]+\.(png|jpg|jpeg|webp|gif)|!?\[[^]]*\]\(https?://[^)]+\.(png|jpg|jpeg|webp|gif)\)|<img[^>]+src='; then
    echo "✓ Gate 2: body already carries viewable evidence."
  else
    # No evidence in the body — PRODUCE it (#9174). Refusing here used to be the
    # wrong end of the pipe: `approval-gate` had already blocked the PR and the
    # agent had already handed it back, so the refusal fired after the decision
    # it existed to inform. 5 UI PRs sat in review with zero images while 460
    # orphaned PNGs sat on the PM's disk. So: take the shots this run already
    # rendered, commit them, and SHA-pin them into the PR body.
    #
    # Evidence must be a blob link in THIS repo. mrdombie/maktura is private, so
    # raw.githubusercontent.com renders broken for every reader (#8067/#8073),
    # and these are authed screens carrying real beta-customer content, so the
    # public maktura-mockups CDN is not an acceptable host.
    SHOTS_DIR="${VISUAL_CHECK_OUT:-/tmp/visual-check}"
    EVIDENCE_DIR="docs/evidence/$ISSUE_NUM"
    if ! ls "$SHOTS_DIR"/*.png >/dev/null 2>&1; then
      echo "❌ /finish REFUSED: PR touches UI, the body carries no evidence, and this run rendered no screenshots." >&2
      echo "   approval-gate will block this PR until the body carries SHA-pinned evidence." >&2
      echo "   Action: npx tsx scripts/visual-check.ts <route> [<route>...]" >&2
      echo "   From a WORKTREE, retarget it — the creds file points at :3000, which is the" >&2
      echo "   PM's dev server running develop, not your branch:" >&2
      echo "     VISUAL_CHECK_BASE_URL=http://localhost:\$PORT VISUAL_CHECK_OUT=$SHOTS_DIR \\" >&2
      echo "       npx tsx scripts/visual-check.ts <route>" >&2
      echo "   That writes to $SHOTS_DIR; re-run /finish and this step publishes them." >&2
      exit 1
    fi
    mkdir -p "$EVIDENCE_DIR"
    cp "$SHOTS_DIR"/*.png "$EVIDENCE_DIR"/
    git add "$EVIDENCE_DIR"
    git commit -m "evidence(#$ISSUE_NUM): live-render screenshots for approval" --no-verify
    git push
    # Pin to the NEW head sha — the commit above moved it, and a link pinned to
    # the old one 404s.
    HEAD_SHA=$(git rev-parse HEAD)
    EVIDENCE_MD=$(for f in "$EVIDENCE_DIR"/*.png; do
      printf '![%s](https://github.com/%s/blob/%s/%s)\n' \
        "$(basename "$f" .png)" "$REPO_FULL" "$HEAD_SHA" "$f"
    done)
    gh pr edit "$PR_NUMBER" --repo "$REPO_FULL" --body "$(
      gh pr view "$PR_NUMBER" --repo "$REPO_FULL" --json body -q .body
      printf '\n\n## Evidence\n\n%s\n' "$EVIDENCE_MD"
    )"
    echo "✓ Published $(ls "$EVIDENCE_DIR"/*.png | wc -l | tr -d ' ') screenshot(s) to $EVIDENCE_DIR, SHA-pinned at $HEAD_SHA."
  fi
fi

# Gate 3 — Wiring check table. UI-touching PRs MUST include a
# "## Wiring check" (or "## UI ↔ API mapping") section that lists
# the UI element ↔ API endpoint mappings. Forces explicit
# documentation of which surfaces consume which routes.
if [ "$PR_TOUCHES_UI" = "yes" ]; then
  if ! echo "$PR_BODY" | grep -qE '## Wiring check|## UI ↔ API mapping'; then
    echo "❌ /finish REFUSED: PR body missing '## Wiring check' section listing UI ↔ API mappings." >&2
    echo "   Action: add a Wiring check table mapping each new UI element to the endpoint it calls." >&2
    exit 1
  fi
fi

# Gates 4 + 5 (#8671) — the merge must hold what review found.
#
# `packages/ui` counts for these two even though Gates 1-3 ignore it: a
# kit change is exactly the kind that renders differently from what the
# diff suggests.
PR_TOUCHES_UI_OR_KIT="$PR_TOUCHES_UI"
if echo "$PR_FILES" | grep -qE '^packages/ui/'; then PR_TOUCHES_UI_OR_KIT="yes"; fi

# Gate 4 — the UI review ran, and PASSED. /ui-gate is the review that
# catches dead controls, fake-live data and orphan features. Until this
# gate existed nothing forced it: ui-gate.md said "run it by hand before
# every UI /finish" and /finish never asked. Neither gate touches CI —
# /ui-gate spawns the frontend-gate subagent locally and the SHA check is
# one `gh` read — so a runner outage cannot wedge shipping.
UI_GATE_VERDICT="${UI_GATE_VERDICT:-missing}"
UI_GATE_SHA="${UI_GATE_SHA:-missing}"
if [ "$PR_TOUCHES_UI_OR_KIT" = "yes" ]; then
  if [ "$UI_GATE_VERDICT" != "SHIP" ]; then
    echo "❌ /finish REFUSED: this PR touches UI and has no SHIP verdict from /ui-gate." >&2
    echo "   Recorded verdict: $UI_GATE_VERDICT" >&2
    echo "   Action: run /ui-gate on this branch. On SHIP, re-run /finish." >&2
    echo "   A SPIT-BACK is the gate doing its job — fix the blockers, then re-review." >&2
    exit 1
  fi

  # Gate 5 — the head has not moved since that review. A verdict is only
  # about the commit it was taken against. On 2026-08-06 PR #8405 merged
  # while /ui-gate findings were still being fixed: develop took the first
  # commit and none of the four after it, and eight defects went live.
  HEAD_SHA=$(gh pr view "$PR_NUMBER" --repo "$REPO_FULL" --json headRefOid -q .headRefOid)
  if [ "$UI_GATE_SHA" = "missing" ] || [ -z "$UI_GATE_SHA" ]; then
    echo "❌ /finish REFUSED: a SHIP verdict was recorded without the SHA it was taken against." >&2
    echo "   Action: re-run /ui-gate so the verdict is pinned to a commit." >&2
    exit 1
  fi
  if [ "$UI_GATE_SHA" != "$HEAD_SHA" ]; then
    echo "❌ /finish REFUSED: head moved since review (reviewed ${UI_GATE_SHA:0:9}, now ${HEAD_SHA:0:9})." >&2
    echo "   Action: re-run /ui-gate against the current head." >&2
    exit 1
  fi
else
  echo "ℹ️  Gates 4+5 skipped — no UI or kit files in this diff."
fi

# Lockfile attestation cross-check. If the claim was made post-#2485,
# `meta.json` will include `mockup_viewed` + `backend_contract_acknowledged`.
# Both must be true at merge time. Older lockfiles (pre-#2485) lack the
# fields; warn but allow merge so in-flight claims aren't trapped.
if [ -n "$CLAIM" ]; then
  MOCKUP_VIEWED=$(jq -r '.mockup_viewed // "missing"' <<<"$CLAIM")
  BACKEND_ACK=$(jq -r '.backend_contract_acknowledged // "missing"' <<<"$CLAIM")
  if [ "$MOCKUP_VIEWED" = "missing" ] || [ "$BACKEND_ACK" = "missing" ]; then
    echo "⚠️  Claim predates the Step 4.5 gates — attestation fields absent. Allowing merge but flag the gap." >&2
  elif [ "$MOCKUP_VIEWED" != "true" ] || [ "$BACKEND_ACK" != "true" ]; then
    echo "❌ /finish REFUSED: claim attestation fields exist but are not both true." >&2
    echo "   mockup_viewed=$MOCKUP_VIEWED backend_contract_acknowledged=$BACKEND_ACK" >&2
    echo "   The dev-AI claimed via the post-#2485 /claim but skipped one of the gates. Re-claim properly." >&2
    exit 1
  fi
fi

# Build-chain attestation (#8636). Every other guardrail in this system is
# structural — the CAS rejects the second claimant, the classifier blocks the
# merge, check:no-new-smells catches a silent catch, the changelog gate refuses
# the push. The superpowers chain was the ONLY rule enforced purely by the
# agent remembering it, and on 2026-08-07 it was the only one skipped: three
# tickets in a session that was itself building anti-slop machinery. Each skip
# had a locally true justification, which is exactly what a rationalisation
# feels like from the inside. So it stops being remembered and starts being
# recorded.
#
# `design_source` is written by /claim Step 11 and says where the design came
# from. `spec_usable` is written by Step 4's gate. Claiming the
# ticket body as your design when the gate found the body incomplete is a
# contradiction the harness can see, so this is a cross-check rather than a
# self-attestation.
if [ -n "$CLAIM" ]; then
  DESIGN_SRC=$(jq -r '.design_source // "missing"' <<<"$CLAIM")
  SPEC_OK=$(jq -r '.spec_usable // "missing"' <<<"$CLAIM")
  CLAIM_AGENT_F=$(jq -r '.agent // ""' <<<"$CLAIM")
  CLAIMED_AT=$(jq -r '.claimed_at // ""' <<<"$CLAIM")
  # Claims taken BEFORE this gate existed cannot retroactively satisfy it. An
  # in-flight ticket must not be trapped by a rule introduced mid-build — that
  # punishes work already done for a policy it could not have known about, and
  # the fix would be to invent a design_source after the fact, which is exactly
  # the fiction this gate exists to prevent. Warn and let it through; new claims
  # are held to it. Delete this branch once no pre-cutover claim remains
  # (claim-lock.sh list shows none older than the cutover).
  GATE_CUTOVER="2026-08-08T00:00:00Z"
  # `[[ < ]]`, not `[ \< ]` — the latter is bash-only and errors under zsh,
  # where the failed condition silently falls through to the refuse branch. A
  # gate that reaches the right verdict via a shell error is not a working gate.
  if [ "$DESIGN_SRC" = "missing" ] &&
     { [ "$CLAIM_AGENT_F" = "legacy-lock" ] || [[ "$CLAIMED_AT" < "$GATE_CUTOVER" ]]; }; then
    echo "⚠️  Claim predates the build-chain gate ($CLAIMED_AT) — design_source absent." >&2
    echo "   Allowing the merge. Do NOT backfill the field to silence this: an" >&2
    echo "   invented design_source is worth less than an honest gap." >&2
    DESIGN_SRC="pre-cutover"
  fi
  case "$DESIGN_SRC" in
    pre-cutover) : ;;
    missing)
      echo "❌ /finish REFUSED: the claim records no design_source." >&2
      echo "   /claim Step 11 requires one of:" >&2
      echo "     claim-lock.sh update $TICKET_KEY design_source=ticket-body" >&2
      echo "     claim-lock.sh update $TICKET_KEY design_source=brainstormed" >&2
      echo "     claim-lock.sh update $TICKET_KEY design_source=debugged" >&2
      echo "   If you built without doing any of those, that is the gap — not the gate." >&2
      exit 1 ;;
    ticket-body)
      if [ "$SPEC_OK" != "true" ]; then
        echo "❌ /finish REFUSED: design_source=ticket-body, but the spec gate did not" >&2
        echo "   mark this ticket complete (spec_usable=$SPEC_OK)." >&2
        echo "   A ticket missing its five sections cannot BE the design. Run" >&2
        echo "   superpowers:brainstorming, post the design on the issue, then set" >&2
        echo "   design_source=brainstormed." >&2
        exit 1
      fi ;;
    brainstormed) : ;;
    # A bug inverts the order — the root cause is not knowable before the
    # reproduction, so systematic-debugging stands in for design-then-plan.
    # It carries its own evidence requirement: step 5 still demands the red
    # proof, so this is not a cheaper route, just an honest one.
    debugged) : ;;
    *)
      echo "❌ /finish REFUSED: design_source='$DESIGN_SRC' is not a recognised value." >&2
      echo "   Expected 'ticket-body', 'brainstormed' or 'debugged'." >&2
      exit 1 ;;
  esac
fi
```

If you hit any gate: that's the system catching an orphan-feature shape. Don't bypass — fix the PR (add the API, the screenshot, or the Wiring check table) and re-run `/finish`.

### Step 6 — Merge the PR to develop

The user has authorised dev agents to merge directly after gates pass.

**develop requires a PR to be up to date (#10469).** `--auto` is not optional: it arms
auto-merge, which lands the PR only once it contains the current develop and the four
required checks passed on that. A behind PR is updated by the merge robot's
`update-behind` job — one at a time, oldest green first — never by hand. (The merge
queue is not available on this personal-account private repo.)

```bash
gh pr merge "$PR_NUMBER" --squash --delete-branch --auto
```

Then wait for it — updates are serial (one PR is brought up to date at a time), so a
landing takes one CI run plus whatever is ahead of it:

```bash
until [ "$(gh pr view "$PR_NUMBER" --json state -q .state)" = MERGED ]; do
  S=$(gh pr view "$PR_NUMBER" --json mergeStateStatus,autoMergeRequest -q '"\(.mergeStateStatus) auto=\(.autoMergeRequest != null)"')
  case "$S" in DIRTY*|CONFLICTING*) echo "🛑 conflict — the robot cannot resolve one; merge develop in deliberately"; break;; esac
  sleep 60
done
```

A **bounce** (the checks went red once develop was merged in) leaves a failed check on
the robot's update commit and the PR unmerged. That is a semantic conflict with
something that landed first — fix forward on the branch, re-gate, push, re-arm.

If the merge fails:
- **Conflicts** → stop, tell the user.
- **CI required** → re-run with `--auto`. Auto-merge fires when CI completes.
- **Anything else** → stop, paste gh output.

**HARD RULE — finish the review BEFORE arming `--auto` (PR #9137 incident, 2026-08-13).**
`--auto` is a server-side promise that fires the instant CI goes green, whether or not
anything else has finished. #9137 auto-merged **~25 minutes before its own code review
returned** — and that review is what caught a blocker CI structurally could not have
caught (a "has HEAD moved" guard that a *peer's* commit disarms, re-creating the bug the
PR existed to fix). The agent had done everything in the right order; nothing held the
merge. The blocker landed on develop and needed a second PR (#9138) to undo.

- Step 5.5's Gates 4 + 5 already enforce this for **UI** tickets — `/ui-gate` must have
  run and passed on the current head. **There is no equivalent for a non-UI diff**, and
  #9137 was a shell script. On any ticket Step 5.5 does not gate, completing the review
  is yours, and it happens *before* this step.
- **⚠️ Not arming `--auto` is NOT sufficient, and this is the part that matters.** The
  repo runs an `automerge-develop` workflow that merges **any** PR which is mergeable,
  not draft, based on `develop`, and green — **whether or not anyone armed anything**.
  It re-evaluates after every CI completion. #9180 was landed by it on 2026-08-14 with
  `--auto` never armed at all. So "wait before arming" cannot hold a merge open by
  itself.
- **The mechanism that actually works: open the PR as a DRAFT, and only mark it ready
  once your review is complete.** The automerge workflow filters drafts out. (The
  hold label (`$HOLD_LABEL`) also excludes it, but that is the human's gate, not yours to
  borrow.) If a review is still in flight, the PR stays draft. Never mark ready "so it
  lands while I review" — that is precisely the sequence that shipped the blocker.
- CI green means the change did not break what is already tested. It does not mean the
  change is correct. Those are different claims, and only review makes the second one.

**HARD RULE — armed + green is NOT terminal; re-check landability after CI settles.**
`--auto` waits for CI. It does **not** wait for, or resolve, a conflict. If develop moves
past the branch while CI runs, the PR flips to `DIRTY`/`CONFLICTING` and the armed promise
silently becomes a no-op that nothing retries. **#9008 sat two full days** — 12/12 green,
`--auto` armed, entirely unmergeable, and nobody noticed. The same thing happened to
#9136 mid-run the same night.

```bash
# AFTER checks settle — not when you arm:
gh pr view "$PR_NUMBER" --json state,mergeable,mergeStateStatus,autoMergeRequest \
  --jq '"\(.state) \(.mergeable)/\(.mergeStateStatus) auto=\(if .autoMergeRequest then "ARMED" else "NOT ARMED" end)"'
```

Green checks and a landable PR are different facts, and only the second one ships. Before
acting on a `DIRTY` flag, confirm the conflict is **real** — GitHub's mergeability
precompute is merge-driver-blind, so `DIRTY` is often stale rather than a genuine
conflict (`git merge-tree $(git merge-base origin/develop HEAD) origin/develop HEAD | grep -c '^<<<<<<<'`).

**Develop drift is the merge robot's job now (#10469).** A branch merely BEHIND develop
is updated by its `update-behind` job before its checks re-run; nobody merges develop
in by hand for that. The retry below is only for a genuine CONFLICT, which the robot
cannot resolve.

**HARD RULE — a conflict retry must abort on a conflicted merge (PR #3775 incident).**
When the PR is CONFLICTING, the cycle is: `git merge origin/develop` → re-gate → push →
re-arm `--auto`. If that
`git merge` reports ANY conflict, you MUST `git merge --abort` and resolve the
conflicts deliberately (read both sides, pick/blend, re-run the gates) — NEVER
follow a conflicted merge with `git add -A && git commit`. `git add -A` on a
conflicted tree stages the literal `<<<<<<<` conflict markers as resolved
content; the commit completes the merge; the push + server-side merge then land
broken files on develop (this shipped ~18 typecheck errors to trunk on
2026-06-11 when #3772 collided with #3771). The check is one line:

```bash
git merge origin/develop || { git merge --abort; echo "CONFLICTED — resolve deliberately, never add -A through it"; }
```

And after ANY drift-retry merge (clean or resolved): re-run the gates before
pushing — the merged result is new code that has never been gated.

(Note: `gh pr merge` will print a "failed to run git: 'develop' is already used by worktree" warning when run inside a worktree. The merge itself happens server-side and succeeds; the warning is gh attempting a local checkout it doesn't need. Verify with `gh pr view "$PR_NUMBER" --json state -q '.state'` — should be `MERGED`.)

```bash
: "${REPO_PATH:?REPO_PATH unset — run Step 1 resolution block first}"
MERGE_SHA=$(git -C "$REPO_PATH" fetch origin develop \
  && git -C "$REPO_PATH" rev-parse origin/develop)
echo "Merged to develop at $MERGE_SHA"
```

### Step 6.5 — HARD GATE: verify the merge actually happened before ANY bookkeeping

**Burned 2026-06-10 (#3583):** a REST merge returned 405 (conflicts — develop
moved mid-flight) but the bookkeeping commands had been queued in the same
batch: a false "Merged" comment posted, the issue closed, and the head branch
was deleted — which auto-closed the PR *unmerged*. Recovery required reopening
the issue, resurrecting the commit from the object store, and a second PR.

Every Step-7 action is destructive-ish (claim release, issue close, branch
delete). NONE of them may run in the same command batch as the merge. Run this
gate as its own command and only proceed when it prints MERGED:

```bash
STATE=$(gh pr view "$PR_NUMBER" --json state,mergedAt -q '"\(.state) \(.mergedAt)"' 2>/dev/null \
  || gh api "repos/$REPO_FULL/pulls/$PR_NUMBER" -q '"\(.merged) \(.merged_at)"')
echo "merge verification: $STATE"
case "$STATE" in
  MERGED*|true*) echo "✓ verified — proceed to Step 7" ;;
  *) echo "🛑 NOT merged ($STATE) — do NOT release the claim, close the issue, or delete the branch. Resolve (conflicts → merge develop in, push, retry) and re-run this gate." >&2; exit 1 ;;
esac
```

### Step 7 — Release the claim + close the issue

The ticket is shipped (Step 6.5 verified it). Single, flat path.

**Epic-mode slice (#3572): skip 7a and 7d entirely** (unless the slice was an adopted child issue — then close just that child in 7d with a one-line merge note). The epic's claim and open issue survive until the runner's close-out (claim.md E6). Continue to Step 8.

**7a. Release the claim** (lets the ticket be re-claimed for follow-ups or a PM re-open):

```bash
"$CL" release "$TICKET_KEY"
```

Only ever run this *after* Step 6 has verified the merge. `release` deletes the
ref on origin, so the ticket becomes claimable the instant it returns — do that
while the PR is still open and a second agent can start building a ticket that
is already built.

**7b–7c. (retired)** — no local index or merged log to update; the closed issue and the merged PR are the record. The weekly `/release-notes-draft` reads merged PRs straight from GitHub.

**7d. Close the GitHub Issue:**

GH issues all live in `$REPO_SLUG` regardless of which codebase the PR landed in — the queue is single-source. So this step always targets `$REPO_SLUG` for issue close, even when `$REPO_FULL` is a sister repo.

```bash
ISSUE_NUM="$TICKET_KEY"   # ticket ids ARE issue numbers
MERGE_NOTE="**Merged** via PR #$PR_NUMBER on \`$REPO_FULL\` · develop @ $MERGE_SHA. All ACs met."
if [ "$REPO_PATH" = "$MAIN_REPO" ]; then
  # #3475 / #3506 — /finish ends at the develop merge; it does NOT promote to
  # UAT. The automated review gate owns develop→uat (reviewed batches);
  # /push-to-uat is the manual override. Never tell a tester a ticket is "on
  # UAT" as a result of /finish — that was the exact misinformation #3475 fixed.
  MERGE_NOTE="$MERGE_NOTE Ships to UAT with the next reviewed batch — the automated review gate owns develop→uat (\`/push-to-uat\` is the manual override)."
else
  MERGE_NOTE="$MERGE_NOTE No UAT step for $REPO_NAME — develop merge IS the deploy."
fi
[ "$ISSUE_NUM" != "null" ] && gh issue comment "$ISSUE_NUM" --repo "$REPO_SLUG" --body "$MERGE_NOTE"
[ "$ISSUE_NUM" != "null" ] && gh issue close "$ISSUE_NUM" --repo "$REPO_SLUG" --reason completed
node "$(git rev-parse --show-toplevel)/scripts/sync-project-board.js" >/dev/null 2>&1 || true   # the board mirrors the labels

# SH-2571 (2026-05-25) — EPIC parent auto-reopen.
#
# When a PR's body mentions the parent EPIC issue (e.g. "Closes Phase 2 of #2516"),
# GitHub's linked-issue auto-close logic closes the EPIC on merge — even when the
# PR body explicitly says "do not close" and the PR only ships ONE phase out of N.
# The EPIC must stay OPEN for the remaining phases to be claimed.
#
# Detection is SOLELY based on the `epic` GH label (canonical signal of
# "this is an EPIC parent — multi-phase, do not close on single-phase merge").
# Non-EPIC tickets flow normally — close on merge, no reopen.
#
# Burned on SH-2516 first /design workflow test (Phase 2 merge auto-closed the
# EPIC despite explicit PR-body warning). Required manual reopen + relabel. This
# block automates the recovery so it doesn't recur.
EPIC_REOPENED=""
if [ "$ISSUE_NUM" != "null" ]; then
  ISSUE_META=$(gh issue view "$ISSUE_NUM" --repo "$REPO_SLUG" --json state,labels 2>/dev/null)
  ISSUE_STATE=$(echo "$ISSUE_META" | jq -r .state 2>/dev/null)
  IS_EPIC=$(echo "$ISSUE_META" | jq -r '[.labels[].name] | index("epic")' 2>/dev/null)
  if [ "$ISSUE_STATE" = "CLOSED" ] && [ "$IS_EPIC" != "null" ] && [ -n "$IS_EPIC" ]; then
    gh issue reopen "$ISSUE_NUM" --repo "$REPO_SLUG" 2>&1 | tail -1
    gh issue edit "$ISSUE_NUM" --repo "$REPO_SLUG" \
      --remove-label "$LBL_CLAIMED" --add-label "$LBL_READY" 2>&1 | tail -1
    gh issue comment "$ISSUE_NUM" --repo "$REPO_SLUG" --body \
      "**Auto-reopened by /finish.** GitHub closed this on PR #$PR_NUMBER merge, but the \`epic\` label means this is a multi-phase parent — the other phases still need claiming. Flipped back to \`$LBL_READY\`. Don't manually close until every phase has shipped." 2>&1 | tail -1
    EPIC_REOPENED="yes"
    echo "🔓 EPIC #$ISSUE_NUM auto-reopened (label=epic; PR shipped a single phase only)"
  fi
fi

# #784 — auto-promote gated siblings whose only blocker was THIS
# ticket. Walks open status:gated issues, parses each body for the
# Blockers / Depends on / gated on patterns, and flips status:gated
# → status:ready when ALL listed blockers are now closed. Comments on
# each unblocked child with the merge SHA. Non-blocking — surface
# the unblocked list to /finish's Step 9 user-facing output.
# The helper scripts live in the MAIN repo clone regardless of which sister
# repo this ticket shipped to — toolkit-env resolves it.
. "$(git rev-parse --show-toplevel)/scripts/toolkit-env.sh" || exit 1
CLOSED_NUM="${TICKET#\#}"
TOOLS=$(toolkit_tools) || exit 1
UNBLOCKED=$("$TOOLS/scripts/auto-promote-gated-children.sh" "$CLOSED_NUM" "$MERGE_SHA" 2>&1 | grep '^unblocked ' | awk '{print $2}' | tr '\n' ' ')
```

For a partial (human-blocker case): leave the issue open, post the merge comment but flip the label to `$LBL_IN_REVIEW` (in-review) or `$LBL_BLOCKED` (blocked). The auto-promote step is still safe to run — it only acts on `$LBL_GATED` (gated) siblings, which a partial isn't.

**7e. (removed) — promoting `develop → uat` is the review gate's job, not `/finish`'s.**

`/finish` no longer fast-forwards the `uat` branch or smoke-tests UAT. The automated review gate ([`docs/operations/automated-code-review.md`](../../docs/operations/automated-code-review.md)) picks up new `origin/uat..origin/develop` commits, reviews them in batches, promotes the passing ones to `uat` → Railway, and pings the PM only on FAIL / promote / rollback. (Railway layer-cache invalidation via `.deploy-trigger` (#824) is handled at promote time, not here.)

For an urgent manual promote (e.g. a live demo before the gate's next cycle), run `/push-to-uat` explicitly — it is the manual override.

The ticket is **shipped** once Steps 6–7d are done: merged to develop, issue closed, gated siblings promoted, claim released. `/finish` has no further promote step.

### Step 8 — Clean up the worktree

```bash
: "${REPO_PATH:?REPO_PATH unset — run Step 1 resolution block first}"
cd "$REPO_PATH"
git worktree remove --force "$WORKTREE"

# #789 — sweep any orphan worktrees left behind by previous /finish
# runs that errored mid-cleanup. Idempotent (skips active claims +
# young worktrees + dirty trees). Typical no-op when nothing's
# orphaned. The sweeper is read from origin/develop (toolkit_tools).
# toolkit-env was sourced in Step 1 and MAIN_REPO is still exported; do NOT
# re-source it here — the worktree is gone and a bare MAIN_REPO has no toplevel.
TOOLS=$(toolkit_tools) && "$TOOLS/scripts/sweep-orphan-worktrees.sh" || true
```

`--delete-branch` in step 6 already deleted the remote branch. The local worktree-tracked branch goes with `worktree remove --force`.

If `worktree remove` fails (uncommitted changes), tell the user and don't force. The orphan-sweeper at the bottom will leave that worktree alone next time too — it specifically skips dirty trees so in-progress work isn't lost.

### Step 9 — Tell the user

Report:
- PR URL + merge SHA on develop + which repo (`$REPO_FULL`)
- Which gates passed
- Anything notable from the implementation
- "Merged to develop. The review gate promotes to UAT in its next cycle — run `/push-to-uat` only for an urgent manual promote." (same for every repo — `/finish` no longer touches `uat`)
- For partials: "Claim released; the issue stays open, labelled `$LBL_PARTIAL` (partial)."
- For complete tickets: "Claim released; issue closed."
- One-line "where to test it" — if the ticket adds a user-visible feature, name the URL/route the user can poke at.
- **#784 unblocked-children line:** if the auto-promote step (7d above) flipped any siblings to `$LBL_READY` (ready), surface the list: *"Unblocked: #X #Y #Z — all flipped from `$LBL_GATED` (gated) to `$LBL_READY` (ready) because their last open blocker was this ticket."* Skip when nothing flipped.
- **SH-2571 EPIC-reopen line:** if `$EPIC_REOPENED = "yes"` (the parent was an `epic`-labelled issue that GitHub auto-closed on merge and /finish auto-reopened), surface verbatim: *"EPIC #N was auto-closed by GitHub on merge → auto-reopened + flipped to `$LBL_READY` (ready) for the next phase claim. Don't manually close until every phase has shipped."* Skip when not an EPIC parent.
- **#790 programme-decomposition hint:** if the closed ticket is a child of an open `programme`-labelled parent, append the output of the decomposition-hint script verbatim. The hint lists open siblings + un-filed capability families so the PM sees the next slice without opening the parent issue:

  ```bash
  . "$(git rev-parse --show-toplevel)/scripts/toolkit-env.sh" || exit 1
  TOOLS=$(toolkit_tools) || exit 1
  "$TOOLS/scripts/programme-decomposition-hint.sh" "${TICKET#\\#}"
  ```

  Empty output when the closed ticket isn't a programme child — pass-through silent.

If the PR includes a `prisma/migrations/` change, flag it: *"Migration X will run on UAT when the review gate promotes this to the `uat` branch."*

**Close with the sign-off banner** — always the last thing on screen, below everything above. Read `.claude/shared/agent-signoff.md`. The scope is the one `/claim` wrote to `.session-label`; if that file is missing, resolve the ticket's `project:` or `area:` label and say you had to.

```
🏷️ Working on: Content Lab (project:content-lab)
   Shipped 1 — drafts stop expiring while someone is editing them
   Also running: 2 agents on Welcome Flow
   Resume: /work content-lab
```

`Also running:` is a live read of `claim-lock.sh list --json` taken **after** Step 7 released this ticket's own claim — read it before the release and you report yourself as a second agent.

**Changelog reminder (#670):** if the change is user-visible — a new feature, an improvement to an existing one, or a customer-noticeable bug fix — write the entry as its own file, `apps/web/src/content/changelog/<issue>.md`, **before** opening the PR (Step 2.5). Never append to the shared `changelog.md` — that is the file every merge conflicted on. Format:

```
## YYYY-MM-DD
- [New|Improved|Fixed] **Short bold title** — one-sentence body in plain English.
```

Skip if the change is purely internal (refactor, dep bump, CI tweak, ops plumbing, staff-only ops surface). Authoring guide at `docs/changelog-authoring.md`. The entry shows up in the in-app dropdown + on the public `/releases` page on the next deploy — no other step needed.

## What you do not do

- Don't skip lint/typecheck/tests.
- Don't push or merge directly to `develop` or `main`.
- Don't merge a PR with conflicts.
- Don't leave the claim in place after merge — EXCEPT an epic-mode slice (#3572), where the epic's claim is held until the final-slice close-out.
- Don't close the epic, comment on it, or write `Closes #NNNN` from a slice finish — the runner's completion digest + close happen once, after the final AC walk.
- Don't `cd` to either main repo before pushing — push from the worktree.
- Don't push or fast-forward the `uat` branch from `/finish` — that's the review gate's job (or `/push-to-uat` for a manual override).
- Don't touch production (the `main` branch / production Railway services). Production is a separate deliberate step.

## If a gate fails

Stop before push. Surface the failure. The local gate IS the gate now.

## If a bad merge lands on develop

Develop is the integration trunk. A bad merge doesn't reach UAT until the review gate promotes it — so reverting on develop before the gate's next cycle is cheap. (For a sister repo with no `uat` branch, the develop merge is closer to the deploy, so revert urgency is higher.)

1. `git -C "$REPO_PATH" log --oneline -5` — find the bad commit (`$REPO_PATH` is `$MAIN_REPO` or `$SUPPORT_REPO` from `scripts/toolkit-env.sh`, whichever repo the merge landed in).
2. Options:
   - **Revert via PR** (preferred) — `gh pr create --repo "$REPO_FULL" `# via /finish`` for a revert commit.
   - **Direct revert + push** (faster) — `git revert <sha> && git push origin develop`.
   - **Hot-fix forward** if small + <5 min.
3. Don't force-push develop.
