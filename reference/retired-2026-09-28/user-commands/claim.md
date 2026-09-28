---
description: "Maktura — claim a ticket and build it end to end. With no argument it picks the next ready one; give it a number to claim that specific ticket. Usage: /claim | /claim 9822"
---

You are a Maktura dev agent picking up a ticket. **Claim it and build it in this session**, end to end, through to `/finish`.

A spawner exists — `scripts/spawn-claim.sh`, and the `claim` shell function — that runs a ticket in a separate process with its own fresh context and budget. It is **not** the default and this skill does not invoke it. Use it deliberately from a terminal when you want a ticket worked without inheriting a session's context; `/claim-status` reports on anything spawned that way.

### UI work, and tickets that call `/design`

A claimed ticket **can** route into `/design` — that is normal, not an exception. `/design` builds the real page at the real route and then **pauses at the `:3010` worktree URL for PM approval**.

Working interactively you just pause and show the PM the URL. But if you cannot stay alive to serve that page — you were spawned, or the session is ending — hand back something runnable instead. Do not self-approve; the design gate is never self-attested. Do not push on and hope. Do not settle for screenshots: the standing preference is a URL you can click, not an image you have to trust.

### An approval covers the render Dom saw — nothing later

Dom, 2026-09-23: the One Desk design pass removed the rail's tabs in a critic round AFTER Dom approved
renders that still had them, and the hold was cleared by citing that earlier approval — because a resume
brief told the next agent to. He found out on UAT.

- A pixel approval names the exact evidence it was given against (the PR-body render SHA / file set).
- **Any** later change to what renders — a critic round, a review fix, a rebase that moves pixels — voids
  it. Re-capture, put before/after on the PR, and ask again. Never clear `needs:human-approval` by citing
  an approval of an earlier render.
- A resume brief may carry an approval forward only for commits that change no pixels, and must say so.

`approval-gate` enforces this rather than trusting it (#10609): it reads the sign-off as an approval of
the commit the PR was at when the label came off, and re-applies the hold as soon as this PR pushes
anything that changes what a user sees. So a brief that carries a stale approval forward does not
unblock the merge — it just wastes the next agent's round.

```bash
CL=~/.claude/socialhub-tickets/scripts/claim-lock.sh
```

**Park it — do not hold the claim while a human thinks.** A claim waiting on a
person is a slot no other agent can use and a ticket nobody can see in the
queue. Holding it costs everyone else the ticket; releasing it costs you only
the context, and the resume brief is what buys that back.

1. Commit and push. The branch is the handover, so it must exist on origin
   before anything else — everything below assumes the work is recoverable
   without your worktree.
2. Open a **draft PR**. It is what makes the work visible to the reconciler:
   a ticket with an open PR is classified `in-review` and never released back
   to `ready`, so no fresh agent will rebuild what you already built.
3. Write the resume brief as an issue comment, label it, then **release the
   ref**:

```bash
gh pr create --draft --base develop --head "$BRANCH" \
  --title "$TICKET: <what this is>" --body "Parked for a design call. See the resume brief on #$TICKET_KEY."

gh issue edit "$TICKET_KEY" --repo mrdombie/maktura --add-label "needs:dom-approval"
gh issue comment "$TICKET_KEY" --repo mrdombie/maktura --body "**Parked — needs a design call.**

Branch \`$BRANCH\` is pushed; draft PR is open. To see it:

\`\`\`
git worktree add \$(mktemp -d)/$TICKET_KEY $BRANCH `# via /claim` && cd \$_
npm run dev -- -p 3010
\`\`\`

Then open <the route> and either approve, or say what to change.

**Built:** <what is done and working>
**Stopped at:** <the exact pause point>
**Needs:** <the specific decision, phrased so a yes/no or a pick answers it>
**Approval carried forward:** <none — or: given at <sha>, and every commit since changes no pixels>
**Resume:** clear this label, then \`/claim $TICKET_KEY\`.

<anything the next agent would otherwise have to rediscover>"

"$CL" release "$TICKET_KEY"
```

The worktree may be swept once the branch is pushed — that is fine and
expected. The `git worktree add` line in the brief recreates it in one command
from the branch, which is why step 1 is non-negotiable: **an unpushed branch is
the only thing a park can actually lose.**

The user sees this on the board and via the `needs:dom-approval` label. Whoever
resumes clears the label and re-claims normally, reading the brief for context.

A UI park carries a rendered concept (artifact URL, our tokens, current behaviour first) plus 2–3 NUMBERED questions Dom can answer in a line — the label alone is not a park.

What a spawned agent still handles alone: the `/ui-gate` frontend review at `/finish` — that is an agent, not a person — and attaching the branch and route to the PR so evidence waits for the PM rather than blocking on them.

**Never spawn `/design` itself.** Invoked directly, it is an interactive two-phase flow and needs a human present from the start.

---

You are a Maktura dev agent picking up a ticket.

The queue lives **outside the repo** at `$HOME/.claude/socialhub-tickets/`. Updating it does NOT require git operations.

## Multi-agent contract (read first — this is why the workflow is shaped the way it is)

Multiple Claude windows work the Maktura queue concurrently. Three rules keep them from trampling each other:

1. **The main repo clone (the `maktura` path recorded in `~/.claude/socialhub-tickets/config.json`) is a git object store, not a workspace.** Nobody works in it: every claim gets its own worktree, and `/finish` refuses outright to run from a main repo clone. Never run `git checkout -b sh-NNN/...` there.

   **Its working tree is therefore stale and must never be read.** Step 1 only ever `fetch`es, which updates `origin/develop` without touching the files on disk — correct for `git worktree add`, but it means the checked-out files sit at whatever commit the clone was last checked out at. On 2026-08-03 that was 22 July: `/claim` had been executing a `recover-stale-claims.sh` 144 lines behind develop, and nothing surfaced it, because worktrees are cut from `origin/develop` and worktrees are where the visible work happens.

   So **never invoke `$MAIN_REPO/scripts/…`**. Materialise the scripts from the ref instead (see "Running repo scripts" below). Then the tree genuinely doesn't matter, and no one has to remember to sync it.
2. **Every claim works in its own worktree at a unique path.** The path includes a 6-char hash so two agents claiming the same ticket can't collide. The branch name stays deterministic (`sh-NNN/<slug>`).
3. **The claim is a git ref on origin** — `refs/claims/<issue>`, taken with `claim-lock.sh acquire`. The push carries `--force-with-lease=<ref>:` (expect-absent), so the server itself rejects the second writer. Atomic, cross-machine, and one `ls-remote` lists every live claim. The old `mkdir` lock was atomic only on one machine, which is why it needed a comment-scanning race detector bolted on top of it.

## Running repo scripts

Every skill that runs a script out of the repo (`/claim`, `/finish`, `/release-stale`, `/sweep-worktrees`) uses this three-line preamble, then calls `"$TOOLS/scripts/<name>.sh"`:

```bash
TOOLS_SHA=$(git -C "$MAIN_REPO" rev-parse --short origin/develop)
TOOLS_BASE="${TMPDIR:-/tmp}"; TOOLS="${TOOLS_BASE%/}/maktura-tools-$TOOLS_SHA"
[ -d "$TOOLS" ] || { mkdir -p "$TOOLS" && git -C "$MAIN_REPO" archive origin/develop scripts | tar -x -C "$TOOLS"; }
```

`git archive` reads the ref, never the working tree, so the scripts are always exactly what's on develop. The path is keyed by the develop SHA, so it self-invalidates when develop moves and costs nothing when it hasn't. Scripts keep normal `${BASH_SOURCE[0]}` semantics, so siblings can call each other (`queue-health-report.sh` calls `reconcile-claims.sh` this way).

Nothing is deleted and the main repo's working tree is never written to — it's simply not consulted.

## Programme state — read BEFORE claiming a programme child

If the ticket you're claiming references a programme parent (e.g. body says "Child of #N" or title mentions a programme issue), read the matching state file FIRST:

```bash
CONFIG="$HOME/.claude/socialhub-tickets/config.json"
MAIN_REPO=$(jq -r '.repos.maktura // empty' "$CONFIG")
TOOLS_SHA=$(git -C "$MAIN_REPO" rev-parse --short origin/develop)
TOOLS_BASE="${TMPDIR:-/tmp}"; TOOLS="${TOOLS_BASE%/}/maktura-tools-$TOOLS_SHA"
[ -d "$TOOLS" ] || { mkdir -p "$TOOLS" && git -C "$MAIN_REPO" archive origin/develop scripts | tar -x -C "$TOOLS"; }

TICKET_BODY=$(gh issue view <NUMBER> --repo mrdombie/maktura --json body -q .body)
PROGRAMME=$(echo "$TICKET_BODY" | grep -oE "Child of #[0-9]+" | head -1 | grep -oE "[0-9]+")
[ -n "$PROGRAMME" ] && "$TOOLS/scripts/programme-state-brief.sh" "$PROGRAMME"
```

**Read the brief, not the whole file.** State files are append-only and grow for as long as the programme stays open. `state-2831.md` is 44KB, of which 63 of 184 lines are a shipped ledger and most of the rest is dated narrative. Across all 41 state files, ~77% of the bytes are history.

An agent that reads all of it designs from the programme's past rather than from its own ticket — reproducing a decision that was right in June for a ticket written in August. That is the mechanism behind "it made weird choices and designed things based on previous work."

The brief gives you:
- Locked design decisions, open questions, blockers, next up — in full, because these bind you
- A count of everything shipped plus the five most recent, so you won't rebuild something that already exists
- Nothing else

Use `--full` when you genuinely need the whole ledger — epic close-out AC walks (E6) and decomposition (E2). Nothing is hidden; the file is unchanged and still hand-curated.

If the state file is missing, that's fine — proceed; the parent issue body has the same info, just less curated.

When you /finish, **update the state file** with the new shipped child + refresh the "Next up" list. /finish skill enforces this automatically.

Never hand-write the shipped / in-flight / next-up block — `programme-status.sh` regenerates everything between the `<!-- GENERATED -->` markers; only the curated half is yours.

## Atomic-claim architecture (the queue redesign)

**The claim is a git ref on origin. Nothing else is the claim.**

```
origin refs/claims/<issue>   # exists = claimed. THE lock.
                             # points at a parentless commit whose message is
                             # the claim record (agent, pid, host, branch,
                             # worktree, claimed_at, attestations)
~/.claude/socialhub-tickets/
  INDEX.tsv         # DERIVED mirror, regenerated from GitHub. Never the truth.
  scripts/
    claim-lock.sh        # acquire | release | update | list | show | holds
    reconcile-claims.sh  # put GitHub's status:claimed back in line with reality
```

Acquiring is `git push --force-with-lease=refs/claims/<issue>:` — an empty
expect-value meaning "this ref must not exist". That is a server-side
compare-and-swap: the first writer creates it, every other writer is rejected
with "stale info" and exits 10. There is no window between winning and
announcing, because winning *is* the announcement.

This replaced a local `mkdir` lock plus a comment-scanning cross-machine race
detector. That scheme posted a claim comment and then re-read the issue's
comments to see whose landed first — so two agents could both post, both read,
and both conclude they had won. It also required matching prose ("Releasing my
claim", "Claim recovered") to decide whether an old claim still counted. On
2026-08-07 the result was 15 tickets marked claimed against 4 real locks.

The GitHub label and assignee are a **derived mirror**, written after the ref
succeeds. Never read them to decide whether a ticket is claimed.

`INDEX.tsv` is tab-separated with one ticket per line:

```
ticket_id  priority  status  area  blocker_tag  title  spec_file  repo  mode
```

Column 9 (`mode`, #3572) is `epic` on every epic/programme-labelled row, empty otherwise. A row that is BOTH `claimable` AND `mode=epic` is a run-ready epic — claiming it enters **epic mode** (see the "Epic mode" section below) instead of the normal single-ticket flow.

Column 8 (`repo`) is the short repo name: `social-hub` (default) or `socialhub-support`. The rebuild script writes it from a `repo:<name>` GH label. Without that label, defaults to `social-hub`. /claim and /finish read column 8 to pick which sister repo to spawn the worktree from + which origin to push to. Cross-repo tickets (e.g. support-portal features filed in social-hub but built in socialhub-support) ship through one queue.

The bash blocks in this skill compute three helpers from column 8. Clone locations are machine-specific, so `REPO_PATH` resolves from `~/.claude/socialhub-tickets/config.json` (written by `scripts/bootstrap-queue.sh`; the main repo path appears under BOTH `maktura` and `social-hub` keys because legacy INDEX rows + lockfiles say `social-hub`):

```bash
REPO_NAME=<col 8>                                            # social-hub | socialhub-support
CONFIG="$HOME/.claude/socialhub-tickets/config.json"
REPO_PATH=$(jq -r --arg r "$REPO_NAME" '.repos[$r] // empty' "$CONFIG")
REPO_FULL="mrdombie/$REPO_NAME"
```

Both sister repos share the `develop` trunk and `sh-NNN/<slug>` branch convention. `/finish` ships every repo to its `develop` only — `develop → uat` promotion is owned by the review gate (or `/push-to-uat`), not `/finish`. (socialhub-support has no `uat` branch at all; its develop merge is the deploy.)

`blocker_tag` classifies WHY a ticket isn't claimable — saves you from re-reading the spec to find out:

- `claimable` — engineering work shippable solo
- `claimed` — agent already owns it (lockfile present OR queue says claimed)
- `human-blocked` — UAT walkthrough / PM eyeball / lawyer / third-party review
- `pr-blocked` — waiting on another PR to land first
- `pm-time-gated` — PM has to choose timing (migration window, etc)
- `pm-decision` — PM has to confirm a list / decision
- `pm-track` — discovery / spec / strategy work; humans drive output, not coding agents (#787)
- `external-blocked` — waiting on external party (Stripe, lawyer, customer, third-party API review). Includes paid subscriptions / DNS / OAuth re-registration.
- `dependency-blocked` — spec is COMPLETE; waiting on a prerequisite ticket (Phase 0 / Phase 1 / sister) to ship before claiming makes sense. Lands in INDEX.tsv when GH label is `status:gated`.
- `epic-gated` — epic/programme umbrella that is NOT cleared for single-agent end-to-end execution (#3572). An epic only becomes `claimable` (with `mode=epic`) when the PM attaches BOTH `epic:run-ready` and `status:ready`.
- `needs-human` — a previous claim died without shipping and `reconcile-claims.sh` escalated it. **Never auto-claim these.** The cause has to be understood first; whoever does that flips it back to `status:ready` deliberately.
- `xxl-multi-phase` — too big for the ship-whole rule
- `parked` / `drafting` / `in-review` / `reverted` / `blocked` — out of scope for /claim

**Only `claimable` rows are valid /claim targets.** Everything else is either someone else's, blocked on a human, or already in flight.

**Status taxonomy clarification (locked 2026-05-06; expanded by #787 on 2026-05-09 — see `feedback_status_taxonomy.md`):**
- `status:drafting` on GH = PM still writing/deciding the spec → INDEX `drafting` blocker_tag → not claimable
- `status:gated` on GH = spec is COMPLETE; waiting on prereq ticket to ship → INDEX `dependency-blocked` blocker_tag → not claimable, but the spec is good to read while waiting
- `status:pm-track` on GH (#787) = discovery / spec / strategy work; humans drive output, not coding agents → INDEX `pm-track` blocker_tag → not claimable
- `status:external-blocked` on GH (#787) = waiting on external party (Stripe, lawyer, customer, third-party API review) → INDEX `external-blocked` blocker_tag → not claimable until the external item resolves
- `status:ready` on GH = claim away → INDEX `claimable` blocker_tag → /claim's only valid target
- `status:needs-human` on GH = a claim died mid-flight without shipping → INDEX `needs-human` blocker_tag → not claimable until a human works out why and flips it back
- `epic`/`programme` label WITHOUT `epic:run-ready` (#3572) = umbrella, never claimable regardless of status → INDEX `epic-gated` blocker_tag
- `epic` + `epic:run-ready` + `status:ready` (#3572) = PM has cleared this epic for single-agent end-to-end execution → INDEX `claimable` + `mode=epic` → /claim enters epic mode

If a dev sees N tickets in `gated`, that's NOT "PM hasn't done their job." It's "PM has done their job; these become claimable when their prereq ships." Read the spec's "Depends on" section to see what's gating each one.

## Ship-whole contract

A `/claim` is a commitment to ship the **entire** ticket end-to-end in one go. Memory: `feedback_ship_whole_features.md`.

### Sizing + spec-completeness check (gate before committing the claim)

After the lockfile mkdir wins, **read the spec file in full** and check:

1. **Can `superpowers:writing-plans` turn this into a plan with no placeholders?**
   That is the only question, and it is not about headings. `writing-plans` names
   "TBD", "add appropriate error handling", "handle edge cases" as plan
   *failures* — a plan can only be that concrete if the spec was. So read the
   ticket and ask:

   - Is there a single clear goal, and an approach — not just a complaint?
   - Are the required outcomes checkable, so a task can be mapped to each?
   - Is there a way to verify it — commands, or a manual step someone can follow?
   - Constraints and anything not to touch, stated rather than assumed?
   - **Bugs only:** a reproduction. You cannot spec a fix for a failure you
     cannot reproduce.

   Any of those missing → don't proceed; release the claim (`claim-lock.sh
   release <issue>`) and flag back: *"#NNNN can't be planned as written — no
   [reproduction / verifiable outcome / …]. Needs a pass through `/file` before
   it's claimable."*

   This replaced a check for five fixed headings ("What it does" / "Files to
   touch" / …) on 2026-08-08. Those headings appeared in **none** of the last 25
   tickets, so the gate was demanding a shape nobody wrote and passing only
   because it was prose an agent interpreted rather than a real check. Worse,
   "Files to touch" asked the PM to guess upfront what `writing-plans` derives
   properly later, per task.

2. **Can you ship the whole AC list in this single claim, without pausing for user input?** Each AC: do you know how to do it from the spec, or would you need to ask "what do you want here?" mid-build? If pause-required → release the claim and flag back.

3. **File-touch estimate reasonable for one focused worktree session?** 30+ files across many independent surfaces → too big; release + flag.

False negatives (refusing a fine ticket) cost a 30-second clarification. False positives (claiming a half-baked ticket) cost the slice-mistakes the ship-whole rule was written to eliminate.

An XL ticket is not 'too big to start' — take it, push a draft PR early (that satisfies the anti-zombie rule) and park the remainder; refuse only on a spec that fails check 1.

**Record the verdict on the claim** — Step 11 and `/finish` both read it:

```bash
"$CL" update "$TICKET_KEY" spec_usable=true   # writing-plans can consume it
```

Only write `true` when every question in check 1 answers yes — plus the
reproduction, on a bug. **Not "the five headings are present";** that check was
replaced on 2026-08-08 and 0 of the 10 tickets sampled on 2026-09-09 carried
them. This is the fact
Step 11 leans on to let the ticket stand in for a design, and `/finish` refuses
a merge where the two disagree. Writing it without checking removes the only
cross-check in the chain.

## Repo guard (run first)

```bash
test -f "$HOME/.claude/socialhub-tickets/INDEX.tsv" || { echo "INDEX.tsv missing — run scripts/rebuild-index.sh first." >&2; exit 1; }
CONFIG="$HOME/.claude/socialhub-tickets/config.json"
test -f "$CONFIG" || { echo "config.json missing — re-run scripts/bootstrap-queue.sh from your maktura clone." >&2; exit 1; }
MAIN_REPO=$(jq -r '.repos.maktura // empty' "$CONFIG")
[ -n "$MAIN_REPO" ] && [ -d "$MAIN_REPO/.git" ] || { echo "config.json has no valid maktura path — re-run scripts/bootstrap-queue.sh." >&2; exit 1; }
SUPPORT_REPO=$(jq -r '.repos["socialhub-support"] // empty' "$CONFIG")
{ [ -n "$SUPPORT_REPO" ] && [ -d "$SUPPORT_REPO/.git" ]; } || echo "WARN: sister repo (socialhub-support) not in config.json — cross-repo claims will fail. Clone it next to the maktura repo and re-run scripts/bootstrap-queue.sh." >&2
```

The socialhub-support guard is a soft warn (no exit). Claims targeting only social-hub still work without the sister repo.

## How this gets entered

**`/claim` in a session is the normal entry point.** It claims and builds right there, inheriting that session's context and whatever budget is left in it.

There is also a spawner, off by default:

```
claim            # next ready ticket, in a separate process
claim 7897       # that ticket
claim --fg       # interactive, in the foreground
```

`claim` runs `scripts/spawn-claim.sh`, which starts a **fresh `claude` process** — new context, its own budget cap, its own worktree — and that process runs this skill. A context window cannot clear itself (no hook event can do it), so a new process is the only way to get a genuinely clean context per ticket. Worth reaching for when a session has drifted a long way from the ticket in hand; not something to do reflexively.

A spawned claim records `run_id` in its lockfile, which lets the watchdog tell "the agent died" from "the agent is thinking". A `/claim` typed into a session leaves no run record and falls back to artifact freshness — still covered, just less precisely.

## Workflow

### Step 0 — Refresh INDEX.tsv + ensure programme state files + reconcile open claims

Three cheap idempotent prep steps before picking a candidate:

```bash
CONFIG="$HOME/.claude/socialhub-tickets/config.json"
test -f "$CONFIG" || { echo "config.json missing — re-run scripts/bootstrap-queue.sh from your maktura clone." >&2; exit 1; }
MAIN_REPO=$(jq -r '.repos.maktura // empty' "$CONFIG")
[ -n "$MAIN_REPO" ] && [ -d "$MAIN_REPO/.git" ] || { echo "config.json has no valid maktura path — re-run scripts/bootstrap-queue.sh." >&2; exit 1; }

# 0a — refresh INDEX.tsv from current GH issue state
node ~/.claude/socialhub-tickets/scripts/rebuild-index-from-github.js >/dev/null

# 0b — auto-generate state files for any new programmes; archive state files for closed programmes
~/.claude/socialhub-tickets/scripts/ensure-programme-state.sh

# 0c — reconcile every open claim against a live process and a real artifact.
# Fetch first: the scripts below are read from origin/develop, so that ref has
# to be current before it's used as a source.
git -C "$MAIN_REPO" fetch -q origin develop
TOOLS_SHA=$(git -C "$MAIN_REPO" rev-parse --short origin/develop)
TOOLS_BASE="${TMPDIR:-/tmp}"; TOOLS="${TOOLS_BASE%/}/maktura-tools-$TOOLS_SHA"
[ -d "$TOOLS" ] || { mkdir -p "$TOOLS" && git -C "$MAIN_REPO" archive origin/develop scripts | tar -x -C "$TOOLS"; }
"$TOOLS/scripts/reconcile-claims.sh"

# 0d — keep the SHARED clone's loose manifests in step with develop (#10047).
# That clone is bare, so its package.json / package-lock.json are untracked
# files nothing updates. `npm install` there reads them, so a stale pair means
# the shared node_modules is installed from an old lockfile while every worktree
# carries the current one — measured 254 commits behind on 2026-09-04, which put
# check:node-modules-fresh red in EVERY worktree at once. No-ops in under a
# second when the blobs already match, which is the common case.
"$TOOLS/scripts/refresh-shared-manifests.sh" || {
  echo "🛑 the shared clone's manifests could not be refreshed — a worktree cut now" >&2
  echo "   would inherit a node_modules installed from a stale lockfile." >&2
  exit 1
}

# The migration's second reconciler is gone. #8716 taught reconcile-claims.sh to
# read refs/claims directly, so 0c now answers both questions on its own and
# reconcile-claim-refs.sh was retired. Calling it here would fail on a missing
# file at the head of every claim.
```

INDEX.tsv is a local cache of GitHub Issue state. PMs flip labels in the GH UI, /finish closes issues, batch-actions happen — all of those land on GitHub but don't touch INDEX.tsv until something refreshes it. Running the sync at /claim time guarantees you're picking from the current state.

The `ensure-programme-state.sh` step is a no-op when nothing has changed — it just creates a stub state-NNN.md for any new `programme`-labelled issue and archives state files for closed programmes. Zero PM action required when filing new programmes.

The `reconcile-claims.sh` step checks every open claim against three things that must agree: the lockfile, the process that made it (`meta.run_id` → `runs/<id>.json`, alive?), and a real artifact (branch commits, PR state, `MERGED.tsv` row). **Claim age is not a staleness signal** — a ticket claimed three days ago whose branch was pushed an hour ago is being worked on, and one claimed this morning by a process that died is not.

Verdicts: `WORKING` leaves the lock alone. `ORPHAN` (already shipped) releases it quietly. `FAILED` and `MALFORMED` move the lock to `claims/.recovered/<TICKET>-<verdict>-<timestamp>` and flip the GH issue to **`status:needs-human`** with the agent's own last words — deliberately *not* `status:ready`, because a ticket that failed for a real reason must be seen rather than silently re-queued into the next agent that will fail the same way. Override the idle window with `STALE_HOURS` (default 4). Typical no-op run takes <1s.

It exits 0 even when it escalates something — an escalation is a normal outcome, not a broken script, and must never block a fresh claim.

If any script errors (network down, gh auth expired), surface it to the user and stop — better to refuse a claim than pick from a known-stale list.

### Step 1 — Refresh `develop` on every repo we might claim into

```bash
CONFIG="$HOME/.claude/socialhub-tickets/config.json"
test -f "$CONFIG" || { echo "config.json missing — re-run scripts/bootstrap-queue.sh from your maktura clone." >&2; exit 1; }
MAIN_REPO=$(jq -r '.repos.maktura // empty' "$CONFIG")
[ -n "$MAIN_REPO" ] && [ -d "$MAIN_REPO/.git" ] || { echo "config.json has no valid maktura path — re-run scripts/bootstrap-queue.sh." >&2; exit 1; }
SUPPORT_REPO=$(jq -r '.repos["socialhub-support"] // empty' "$CONFIG")

git -C "$MAIN_REPO" fetch origin develop
{ [ -n "$SUPPORT_REPO" ] && [ -d "$SUPPORT_REPO/.git" ] && git -C "$SUPPORT_REPO" fetch origin develop; } || true
```

Don't `git checkout develop` in either main repo — another agent may be using it. The socialhub-support fetch is best-effort; absence is OK if the row turns out to target social-hub.

### Step 2 — Pick a candidate from GitHub

**If `$ARGUMENTS` names a ticket, that IS the candidate — skip the picking, keep the gates.**

`/claim 9822` claims #9822. Everything after this step is unchanged: the atomic
claim, the spec gate, the anti-orphan gates, the worktree, the attestations. One
path to shipping code, whether the ticket was chosen by you or handed to you.

`scripts/spawn-claim.sh` has always built `PROMPT="/claim $TICKET"`, so it has been
passing a number this command ignored — it picked its own ticket instead, and a
caller that asked for a specific one silently got a different one.

Validate before claiming, and **refuse rather than substitute** — a caller that
named a ticket wants that ticket or an error, never a surprise:

```bash
TICKET="${ARGUMENTS//[^0-9]/}"
if [ -n "$TICKET" ]; then
  META=$(gh issue view "$TICKET" --repo mrdombie/maktura --json number,state,labels,title 2>/dev/null)     || { echo "🛑 #$TICKET does not resolve. NOTE: gh issue view resolves PULL REQUESTS too — check you were given an issue." >&2; exit 1; }
  [ "$(jq -r .state <<<"$META")" = OPEN ] || { echo "🛑 #$TICKET is closed." >&2; exit 1; }
  LBL=$(jq -r '[.labels[].name]|join(" ")' <<<"$META")
  case " $LBL " in
    *" needs:dom-approval "*) echo "🛑 #$TICKET is parked on Dom. Not claimable." >&2; exit 1 ;;
    *" status:gated "*)       echo "🛑 #$TICKET is gated — the PM flips that, not you." >&2; exit 1 ;;
  esac
  "$CL" holds "$TICKET" >/dev/null 2>&1 && { echo "🛑 #$TICKET is already claimed. Back off — never adopt a peer's lock." >&2; exit 1; }
  # candidate = $TICKET; go to Step 3.
fi
```

**With no argument, pick one — the original behaviour, unchanged:**

**Read the queue from GitHub, not from INDEX.tsv.** The mirror is regenerated and
lags: on 2026-08-07 it held 792 rows against 878 open issues, so 86 open tickets
could not be claimed because nothing had told the mirror they existed. Selecting
from GitHub makes that class of miss impossible rather than rare.

**Pass A — claimable issues, minus anything already held.**

One `ls-remote` gives you every live claim in the system, across every machine.
This is the whole reason the lock moved onto a ref: the old filter stat'd a
local `claims/` directory, so a ticket claimed on another machine looked free.

```bash
CL=~/.claude/socialhub-tickets/scripts/claim-lock.sh
HELD=$("$CL" list --json | jq -r '.[].issue')

# TWO claimable states, not one.
#
#   status:ready      — never started. Build it.
#   status:in-review  — ORPHANED. reconcile-claims.sh parks a ticket here when
#                       the agent holding it died with a PR open, so that a
#                       fresh agent would not rebuild finished work. That was
#                       right, but nothing in the system ever removed the label
#                       again, so the ticket became held by nobody and offered
#                       to nobody. 24 accumulated this way by 2026-08-11.
#
# in-review carries two meanings and the discriminator is `needs:dom-approval`:
# a ticket genuinely waiting on Dom has it (PRODUCTION-MANAGER.md — "PR open,
# waiting on human"), an orphan does not. A live claim ref means the holder is
# still working, and HELD already filters those out below.
#
# An epic is claimable ONLY with epic:run-ready (#3572); annotate it so epic
# mode is entered knowingly. An epic is NEVER a resume candidate — it does not
# ship as one PR, so in-review on an epic is a category error, not an orphan.
# repo: labels route cross-repo tickets.
for STATE in status:ready status:in-review; do
  ORPHAN=$([ "$STATE" = "status:in-review" ] && echo true || echo false)
gh issue list --repo mrdombie/maktura --state open --limit 300 \
  --label "$STATE" --json number,title,labels \
  -q '.[] | . as $i
      | ([$i.labels[].name] | index("epic")) as $is_epic
      | ([$i.labels[].name] | index("epic:run-ready")) as $run_ready
      | ([$i.labels[].name] | index("needs:dom-approval")) as $needs_dom
      | '"$ORPHAN"' as $orphan
      | select(($is_epic == null) or (($run_ready != null) and ($orphan | not)))
      | select(($orphan | not) or ($needs_dom == null))
      | [ ($i.number|tostring),
          ([$i.labels[].name | select(startswith("P"))] | first // "P?"),
          ([$i.labels[].name | select(startswith("area:"))] | first // "area:UNFILED" | ltrimstr("area:")),
          ([$i.labels[].name | select(startswith("repo:"))] | first // "" | ltrimstr("repo:")),
          (if $run_ready != null then "[EPIC MODE]" elif $orphan then "[RESUME PR]" else "" end),
          $i.title
        ] | @tsv'
done \
  | sort -t $'\t' -k2,2 -k1,1 \
  | while IFS=$'\t' read -r id pri area repo mode title; do
      grep -qx "$id" <<<"$HELD" || printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$pri" "$area" "${repo:-social-hub}" "$mode" "$title"
    done
```

**A `[RESUME PR]` row is not a fresh build.** There is already work on a branch
and an open PR. Pass B below will print it. Read the PR's commits and the
ticket's handover comment against the AC *before* writing anything: the correct
move is usually to merge develop in, re-gate and finish it. Rebuilding from
scratch is the failure this label exists to prevent. If the premise no longer
holds against develop — after 80–170 commits some of these describe code that
no longer exists — say so on the ticket and stop, rather than forcing a resume.

That premise check is **no longer resume-only**: Gate 3 in Step 4.5 runs it on every
claim, fresh builds included. A resume row carries the extra risk that its own branch
has aged too, so read the branch as well as the ticket — but the "is this still true"
question is now asked of every candidate, not just this one.

**Pass B — refuse a candidate that duplicates work already in flight.** This is
the check that was missing when two agents shipped the same change twice. A
ticket is not free just because nobody holds its claim: the work may already
exist on a branch or in an open PR filed under a *different* number.

```bash
CAND=<the number you are about to claim>

# Anything open that already names this ticket, or whose branch is keyed to it.
# Both branch conventions are in use, anchored so #857 never matches sh-8571/.
gh pr list --repo mrdombie/maktura --state open --limit 200 \
  --json number,headRefName,title,body \
  -q ".[] | select((.headRefName | test(\"(^|/)(sh-)?${CAND}[-/]\"))
                or (.body // \"\" | test(\"#${CAND}\\\\b\"))) 
      | \"OPEN PR #\(.number)  \(.headRefName)  \(.title)\""

git ls-remote --heads origin | grep -E "refs/heads/(sh-)?${CAND}[-/]|/${CAND}-" || true

# The checks above key on the ticket NUMBER, so they only see the same ticket
# claimed twice. They are blind to the shape that actually costs us: two
# DIFFERENT tickets that land on the same file. #8764 and #8776 were filed and
# built against work already in flight under #8627 and #8629 because nothing
# compared the files. This compares them — the paths named in the candidate's
# body against every open PR's diff and every live claim's branch.
~/.claude/socialhub-tickets/scripts/overlap-check.sh "$CAND"

# Merged in the last 7 days — the ticket may already be shipped under another id.
gh pr list --repo mrdombie/maktura --state merged --limit 50 \
  --search "merged:>=$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d)" \
  --json number,title -q '.[] | "recent: #\(.number) \(.title)"'
```

If any of those hit, **stop and read before claiming**. An open PR on the ticket
means resume that PR, not rebuild it. A merged PR covering the same change means
the ticket wants closing or re-scoping, and claiming it produces a second
implementation of something that already shipped.

On a code-health/lint ticket also grep open + recently-merged PR diffs for its files — a lint-heal often rides inside a feature PR and silently supersedes the ticket.
On a batch/sweep ticket, re-measure the live finding set immediately before starting and after every develop merge; when develop wins a race on a file, take develop's version whole.

If there are zero rows after filtering: invoke the queue-health reporter (#788) so the PM gets actionable structure instead of just "stop":

```bash
CONFIG="$HOME/.claude/socialhub-tickets/config.json"
test -f "$CONFIG" || { echo "config.json missing — re-run scripts/bootstrap-queue.sh from your maktura clone." >&2; exit 1; }
MAIN_REPO=$(jq -r '.repos.maktura // empty' "$CONFIG")
[ -n "$MAIN_REPO" ] && [ -d "$MAIN_REPO/.git" ] || { echo "config.json has no valid maktura path — re-run scripts/bootstrap-queue.sh." >&2; exit 1; }
TOOLS_SHA=$(git -C "$MAIN_REPO" rev-parse --short origin/develop)
TOOLS_BASE="${TMPDIR:-/tmp}"; TOOLS="${TOOLS_BASE%/}/maktura-tools-$TOOLS_SHA"
[ -d "$TOOLS" ] || { mkdir -p "$TOOLS" && git -C "$MAIN_REPO" archive origin/develop scripts | tar -x -C "$TOOLS"; }
"$TOOLS/scripts/queue-health-report.sh"
```

The report buckets every non-claimable row (programme parents, pm-track, external-blocked, dependency-blocked, drafting, in-review, claimed, stale lockfiles) and renders 5 PM-actionable next steps when the engineering count is zero. Surface the report verbatim to the user, then stop — the PM picks one of the suggested actions.

**Pass B — apply the area lock.** A ticket's area is locked when another claimable / partial / in-review ticket in the same area is currently claimed (i.e. has a lockfile). Cross-cutting areas never lock. Walk the candidate list and pick the first whose area is unlocked.

If every candidate's area is locked: take the highest-priority anyway, but warn the user explicitly: *"Heads up — every candidate's area is currently active. Claiming SH-NNN may collide with [other tickets in same area]."*

**Pin override:** if QUEUE.md has a `🔥 PINNED` block at the top, that ticket bypasses area-lock.

**Epic-mode candidates:** if the picked row is tagged `[EPIC MODE]` (INDEX column 9 = `epic`), run Step 3 (atomic claim + cross-machine hardening) as normal, then jump to the **"Epic mode"** section below instead of Steps 4–10 — the spec gate, decomposition, and build loop all differ.

### Step 3 — Atomic claim (one compare-and-swap)

Branch and worktree are computed in Step 5/6, but the claim must be taken
FIRST — a claim you take after doing setup work is a claim you can lose after
doing setup work. Pass the branch you intend to use.

```bash
TICKET_KEY=$(echo "$TICKET" | tr -d '#' | sed 's/^SH-//')   # bare digits
CL=~/.claude/socialhub-tickets/scripts/claim-lock.sh

# No --pid. The script records the session's own pid by walking up to the
# `claude` ancestor. Passing `$$` here overrode that with the pid of a tool-call
# shell that exits immediately, so the reconciler read every fresh claim as
# abandoned and released tickets out from under the agent still working them.
"$CL" acquire "$TICKET_KEY" \
  --branch "$BRANCH" --worktree "$WORKTREE"
case $? in
  0)  : ;;                                    # won it — carry on
  10) echo "Lost the race on #$TICKET_KEY — next candidate."; exit 0 ;;
  *)  echo "Claim failed for #$TICKET_KEY — do NOT proceed." >&2; exit 1 ;;
esac
```

Exit 10 is the only non-fatal failure and it means exactly one thing: a peer
holds it. Go back to Step 2 and take the next candidate. **Never** retry the
same ticket, and never `--force`; adopting a live peer's claim is how two
agents end up on one branch.

**Record the develop SHA this ticket was claimed at — the rules freeze here (#10548).**

```bash
CONFIG="$HOME/.claude/socialhub-tickets/config.json"
MAIN_REPO=$(jq -r '.repos.maktura // empty' "$CONFIG")
"$CL" update "$TICKET_KEY" claimed_at_sha="$(git -C "$MAIN_REPO" rev-parse origin/develop)"
```

A required check or skill rule that lands on develop *after* that SHA does not apply to this
ticket: it finishes under the rules it started with, and `/finish` copies the SHA into the PR
body. Three new required checks landed midway through #10521 and each cost it a round. This
freezes the rules, never the quality bar.

Then mirror the state onto GitHub for human visibility. This is bookkeeping,
not the claim — if it fails, you still own the ticket:

```bash
gh issue edit "$TICKET_KEY" --repo mrdombie/maktura \
  --remove-label "status:ready" --add-label "status:claimed" 2>/dev/null || true

# Record it in the session ledger. `/project --session` and `/standup` both read
# this to work out what the session has been on, and neither can see a claim any
# other way — a ledger nothing writes makes both of them report nothing while
# looking like they ran.
grep -qx "$TICKET_KEY" ~/.claude/socialhub-tickets/.session-tickets 2>/dev/null \
  || echo "$TICKET_KEY" >> ~/.claude/socialhub-tickets/.session-tickets
```

No claim comment. The old flow posted one because comments were how the
cross-machine race was arbitrated; the ref does that now, so the comment is
pure noise. The issue's comment budget is spent on things a human needs: the
design (Step 11), a resume brief if you park, and the close-out.

**You own the ticket.**

### Step 4 — Read the spec + sizing gate

`~/.claude/socialhub-tickets/<spec-file>` (the path from INDEX.tsv column 7).

Run the ship-whole sizing gate above. If the spec fails, release the claim:

```bash
"$CL" release "$TICKET_KEY"
```

Then flag back to the user with the specific issue.

### Step 4.5 — Anti-orphan gates (#2485)

PM-mandated 2026-05-24. Dev-AIs kept building from spec verbiage without opening the mockup file, and shipping UI without the backing endpoints. Gates 1 and 2 refuse the claim at pickup-time so a half-spec'd ticket can't slip through. **Gate 3 (added 2026-09-01) asks the other question: not "is this ticket well written" but "is it still true".**

**The gates live HERE — between the sizing-gate and the worktree create — so they refuse cheaply.** A failure releases the lockfile + exits with a named-failure error message; the next /claim attempt can re-pick after the spec is tightened.

| Gate | Refuses | Decides |
|---|---|---|
| 1 — mockup visibility | a mockup referenced but never rendered | automatically, `exit 1` |
| 2 — backend contract | UI-shaped ticket with no endpoint list | automatically, `exit 1` |
| 3 — premise | a ticket whose defect no longer exists | **you do** — it gathers, you judge |

Run all three before continuing. A Gate 1 or Gate 2 failure releases the lockfile and stops:

```bash
ISSUE_NUM="$TICKET_KEY"   # ticket ids ARE issue numbers; .gh-issue-map.json is the retired SH-NNN table
ISSUE_META=$(gh issue view "$ISSUE_NUM" --repo mrdombie/maktura --json body,labels)
ISSUE_BODY=$(jq -r '.body' <<<"$ISSUE_META")
ISSUE_LABELS=$(jq -r '.labels[].name' <<<"$ISSUE_META")   # one per line; Gate 2 reads it

# Gate 1 — Mockup-visibility check. If the body references a mockup
# file (.html under maktura-design/) but doesn't embed a rendered
# screenshot inline, refuse. Building from CSS/HTML alone is the
# pattern that produced the 2026-05-24 mockup-parity incident.
if echo "$ISSUE_BODY" | grep -qiE 'mockup.*\.html|maktura-design'; then
  if ! echo "$ISSUE_BODY" | grep -qE '!\[.*\]\(https?://[^)]+\.(png|jpg|jpeg|webp|gif)\)|<img[^>]+src='; then
    echo "❌ /claim REFUSED: $TICKET references a mockup file but doesn't embed a rendered screenshot." >&2
    echo "   Either:" >&2
    echo "   - PM: render the mockup to PNG + push to the maktura-mockups CDN + embed inline" >&2
    echo "   - Dev-AI: STOP and flag this back so the ticket gets tightened" >&2
    "$CL" release "$TICKET_KEY"      # give the ticket back — you did not build it
    exit 1
  fi
fi

# Gate 2 — Backend-contract check. UI tickets MUST include the API
# contract so the claimant knows up-front which endpoints they have
# vs need to build (avoids orphan UI shipping without its backend).
#
# EXEMPTION (2026-08-20, Dom): a `code-health` ticket is debt work on code that
# already exists — a lint batch, a compiler flag, a gate. It ships no surface
# and consumes no endpoint, so there is no contract for it to carry. The trigger
# below is a path grep, so every batch that merely NAMES `apps/web/src/hooks/...`
# in its file table tripped it: 58 of the 90 ready code-health tickets on the day
# this was written, none of them UI work.
#
# Why a label and not a smarter trigger. The obvious fix is to narrow the grep to
# tickets that "describe a new surface" — that was tried and it is worse. Prose
# vocabulary is not a reliable discriminator: the narrowed version cleared all 58
# batches but ALSO stopped firing on #9023 `design(access): the workspace chrome`,
# a real UI ticket, because "chrome" was not in the noun list. A gate that misses
# a UI feature fails in the expensive direction; one that over-fires on debt work
# merely annoys. So the trigger stays broad and the exemption is structural.
#
# The label is PM-controlled and means "code cleanup, standards, and tooling debt".
# Measured when added: ZERO `type:feature` issues carry it, so this cannot let a
# feature through. If that ever stops being true, this exemption is wrong and the
# fix is to stop labelling features `code-health`, not to widen this.
#
# SECOND EXEMPTION (2026-08-30): `flow-gap` + `type:bug`. A flow-gap bug is an
# ABSENCE found by /flows in a flow that already ships — an unhandled state, a
# step that cannot be resumed, a failure with no copy. The surface exists and the
# endpoints it consumes exist, so there is no EXISTS/NET-NEW list to write; the
# contract would restate the status quo. Note the tickets name `apps/web` paths in
# their *repro commands*, which is what trips the grep.
#
# Measured on the day this was added: 21 flow-gap tickets, 19 `type:bug`, ZERO
# naming a net-new endpoint, and 5 had already shipped THROUGH this gate — so it
# was refusing a class it has never once caught anything in.
#
# `type:bug` is load-bearing and is NOT redundant: #9828 and #9830 carry flow-gap
# AND `type:feature`, and those two genuinely can ship new surface. They keep the
# gate. Widening this to bare `flow-gap` would let them through and is wrong.
#
# THIRD EXEMPTION (2026-09-01, Dom): every `type:bug`, not only the flow-gap ones.
# The second exemption was the right shape drawn too small. A bug is a defect in a
# surface that ALREADY SHIPS, so its endpoints already exist and the contract would
# restate the status quo — the reasoning above never depended on `flow-gap`, only
# on `type:bug`.
#
# Measured before widening. Proxy named: `type:bug` issues, not already exempt,
# whose body matches the Gate-2 trigger grep and carries no contract section —
# a stand-in for "bug tickets this gate refuses".
#
#   113  tripped the gate
#     1  (#8910) named anything net-new
#
# So it was refusing 112 tickets in a class it had caught once. #9609 and #8707
# were both blocked by it on 2026-08-30 — a stale navigation route and a run row
# rendering a clickable blank line, neither adding or consuming an endpoint. The
# trigger is a path grep, and these tickets name `apps/web` paths in their REPRO
# COMMANDS, which is what trips it.
#
# The `net-new` escape below is why this is not a blanket skip: #8910 is a real bug
# that does need an endpoint built, and it keeps the gate. That is the one row the
# measurement found, so it is the one row the exemption declines to cover.
#
# `type:feature` is untouched and still gated — that is where orphan UI comes from.
if echo "$ISSUE_LABELS" | grep -qx 'code-health'; then
  echo "ℹ️  Gate 2 skipped — code-health ticket (debt work on existing code, ships no surface)."
elif echo "$ISSUE_LABELS" | grep -qx 'type:bug' \
     && ! echo "$ISSUE_BODY" | grep -qiE 'NET-NEW|net-new|new endpoint|does not exist yet|needs building'; then
  echo "ℹ️  Gate 2 skipped — bug on a surface that already ships (no net-new endpoint named)."
elif echo "$ISSUE_BODY" | grep -qiE 'apps/web|dashboard|page\.tsx|ui surface'; then
  if ! echo "$ISSUE_BODY" | grep -qE '## Backend contract|## API contract'; then
    echo "❌ /claim REFUSED: $TICKET looks UI-shaped but has no '## Backend contract' section." >&2
    echo "   PM: add the contract listing every API endpoint the UI consumes + its EXISTS/NET-NEW status." >&2
    echo "   See feedback_no_orphan_features.md for the template." >&2
    "$CL" release "$TICKET_KEY"      # give the ticket back — you did not build it
    exit 1
  fi
fi

# Gate 3 — Premise check. Is this STILL a real issue?
#
# Until 2026-09-01 the premise check existed only on `[RESUME PR]` rows — work that
# already had a branch. A never-claimed `status:ready` ticket went from queue to build
# with nothing asking whether it was still true. Measured that day: 465 ready tickets,
# 210 of them filed over a month earlier, ZERO carrying a premise check.
#
# THIS GATE DOES NOT EXIT ON ITS OWN. That is deliberate and measured, not laziness.
# The obvious mechanical version — "the ticket cites a path, check the path still
# exists" — was tested on a 40-ticket sample of the ready queue before this was
# written. 25 cited a concrete repo path. Against origin/develop:
#
#     24  path still present
#      1  path missing  (#8626 scripts/rebuild-index-from-github.js)
#      0  genuinely deleted — the one miss had MOVED to onboarding-templates/,
#         with no deletion commit anywhere in the log
#
# Zero true positives, one false alarm. A gate with that record trains you to ignore
# it, so this one gathers evidence and hands you the verdict instead of faking one.
#
# Rot in this repo is not "the file vanished". It is "the code changed and the bug is
# already gone" — which no grep can see.
echo "── Gate 3: premise check ──"
# The gate reads origin/develop, NOT the working tree — $MAIN_REPO is a shared clone
# and its checkout runs behind (measured 225 commits on 2026-09-01). That is fine:
# origin/develop after a successful fetch IS the live remote. It is only fine while
# the fetch SUCCEEDS, so say so when it doesn't rather than reporting stale refs as
# current — a silent `|| true` here would print confident ✅/❌ lines about a tree
# that is months old.
if git -C "$MAIN_REPO" fetch origin develop -q 2>/dev/null; then
  GATE3_FRESH=1
else
  GATE3_FRESH=0
  echo "   ⚠️  fetch FAILED — origin/develop may be stale. Treat every line below as"
  echo "      unverified and re-run before trusting an ABSENT."
fi
CITED=$(echo "$ISSUE_BODY" \
  | grep -oE '(apps|packages|scripts)/[A-Za-z0-9._/-]+\.(ts|tsx|js|sql|md)' \
  | sort -u | head -8)
if [ -z "$CITED" ]; then
  echo "   no repo path cited — judge the premise from the body alone."
else
  while read -r p; do
    [ -z "$p" ] && continue
    if git -C "$MAIN_REPO" cat-file -e "origin/develop:$p" 2>/dev/null; then
      echo "   ✅ present  $p"
    else
      # Missing is AMBIGUOUS. Resolve moved-vs-deleted before saying a word about it.
      alt=$(git -C "$MAIN_REPO" ls-tree -r --name-only origin/develop \
            | grep -F "/$(basename "$p")" | head -3)
      if [ -n "$alt" ]; then
        echo "   ↪️  MOVED    $p"
        echo "$alt" | sed 's/^/                 now: /'
      else
        echo "   ❌ ABSENT   $p  (no same-named file anywhere on origin/develop)"
      fi
    fi
  done <<< "$CITED"
fi

# Gates 1 and 2 passed — set attestation flags for Step 7's meta.json
# (the dev-AI is asserting it has read the mockup + backend contract).
# Gate 3 is NOT attested here: it has no automatic verdict, so a flag set by the
# script would attest a judgement nobody made. Its verdict goes in the Step 10
# summary, in the agent's own words, naming the file:line it confirmed against.
export PULSE_GATES_PASSED=1
```

**Gate 3 is a read, and you owe it a verdict.** The block above only gathers; it never
decides. Before writing a line of code, open the cited code on `origin/develop` and hold
it against what the ticket claims is wrong. A `✅ present` line means the file exists —
**not** that the defect does.

State the verdict out loud, in one of three forms:

| Verdict | What you do |
|---|---|
| **Still true** — you can see the defect in the current code | say so, name the file:line you confirmed it at, and build |
| **Already fixed** — the code no longer does what the ticket describes | `"$CL" release "$TICKET_KEY"`, comment on the issue with the commit or code that fixed it, close it, pick another |
| **Changed shape** — the area was rewritten and the ticket half-applies | release, comment what still holds and what doesn't, flag for a re-spec. Do **not** silently rescope and build your own version |

`↪️ MOVED` is the common false alarm and is **not** evidence of anything — the file was
refactored, and the ticket's premise may be perfectly intact at the new path. Read it there.
`❌ ABSENT` is a genuine signal and usually means already-fixed, but it is still a prompt to
look, not a verdict: a ticket can cite a path that never existed, most often a typo or a
path invented from memory when the ticket was filed.

If you hit Gate 1 or Gate 2 as a dev-AI: that's the system catching a spec gap. Don't try to bypass — release the claim, comment back on the ticket explaining what's missing, and pick a different candidate.

A design source the ticket names but you cannot open (artifact, Figma, file) is a STOP — park and tell Dom; never reconstruct it from the ticket's prose.

### Step 5 — Compute branch, worktree path, and repo routing

```bash
SLUG="<2-4-word-slug-from-title>"
HASH=$(openssl rand -hex 3)
TMP_BASE="${TMPDIR:-/tmp}"; TMP_BASE="${TMP_BASE%/}"
WORKTREE="$TMP_BASE/${TICKET,,}-${SLUG}-${HASH}"
BRANCH="${TICKET,,}/${SLUG}"
# Repo routing — read column 8 from the ticket's INDEX row, default to social-hub.
REPO_NAME=$(awk -F'\t' -v t="$TICKET" '$1==t {print $8}' ~/.claude/socialhub-tickets/INDEX.tsv)
[ -z "$REPO_NAME" ] && REPO_NAME="social-hub"
# Resolve the clone location from config.json (written by bootstrap-queue.sh;
# carries both "social-hub" and "maktura" keys for the main repo).
CONFIG="$HOME/.claude/socialhub-tickets/config.json"
test -f "$CONFIG" || { echo "config.json missing — re-run scripts/bootstrap-queue.sh from your maktura clone." >&2; exit 1; }
REPO_PATH=$(jq -r --arg r "$REPO_NAME" '.repos[$r] // empty' "$CONFIG")
[ -n "$REPO_PATH" ] && [ -d "$REPO_PATH/.git" ] || { echo "config.json has no valid path for repo '$REPO_NAME' — re-run scripts/bootstrap-queue.sh." >&2; exit 1; }
REPO_FULL="mrdombie/$REPO_NAME"
```

(`,,` is bash lower-case expansion — `SH-181` → `sh-181`. `$TMP_BASE` derives from `$TMPDIR` so worktrees land in the OS temp dir on any machine — don't hardcode `/private/tmp`.)

### Step 6 — Create the worktree off freshly-fetched develop in the right repo

```bash
: "${REPO_PATH:?REPO_PATH unset — run Step 5 resolution block first}"
git -C "$REPO_PATH" worktree add "$WORKTREE" -b "$BRANCH" origin/develop
ln -sfn "$REPO_PATH/node_modules" "$WORKTREE/node_modules"
# Husky's shims live in .husky/_ — generated at `npm install`, gitignored.
# A symlinked worktree never gets them, so git runs ZERO hooks, silently
# (sh-9538, 2026-08-28: every commit skipped gitleaks, lint-staged and the
# .deploy-trigger stamp; the push skipped all 29 pre-push legs, with
# --no-verify never typed). Copy the main repo's shims; refuse to continue
# without them. `core.hooksPath=.husky/_` is relative, so it resolves
# inside the worktree once the directory exists.
if [ -d "$REPO_PATH/.husky/_" ]; then
  mkdir -p "$WORKTREE/.husky" && cp -R "$REPO_PATH/.husky/_" "$WORKTREE/.husky/_"
else
  (cd "$WORKTREE" && npx --no-install husky >/dev/null)
fi
[ -x "$WORKTREE/.husky/_/pre-push" ] || { echo "🛑 husky shims missing — git hooks would not run in this worktree" >&2; exit 1; }
cd "$WORKTREE"
# Generate the Prisma client BEFORE any gate runs. The generated client
# is not in git, so a fresh worktree reports ~24 phantom typecheck
# errors (TS2307 "Cannot find module '@/generated/prisma/client'" +
# cascading implicit-anys) that look exactly like a trunk regression.
# Stash-baseline diffing CANNOT catch it — the artifact sits on both
# sides of the diff (burned: #3537 false alarm, 2026-06-10). The
# pretypecheck:web/api npm hooks also run this, but generating here
# means tests + editors see a typed client from minute one. Idempotent.
npx prisma generate >/dev/null
```

- A fresh worktree has no `.env` (no `AUTH_SECRET`) and no local Redis — ~45 failures across 7 test files are baseline; prove it against a pristine origin/develop worktree before blaming the branch.
- Never `npm install` inside a worktree — it rewrites the shared `node_modules/@maktura/*` links to absolute paths into your tree, and every worktree gets TS2307 once it is swept.
- Shared `node_modules` is a SNAPSHOT: a red typecheck/test in a file you never touched = a dep develop added since; prove it with a pristine origin/develop control worktree on the same symlink.
- A test naming an installed-vs-locked version mismatch = shared tree behind package-lock; the fix is `npm install` at the MAIN repo root (touches every agent — say so), not your branch.
- TS2305 'no exported member' from `@maktura/X` after merging develop = stale workspace-symlink phantom — `readlink -f node_modules/@maktura/X`; repoint it at `~/maktura-dev`, CI resolves your branch fine.
- Before diagnosing any red tsc/vitest mid-ticket, `ls -ld $WORKTREE/node_modules` — a swept symlink makes npx fall back to a global cache; relink and `npx prisma generate` first.
- Editing `packages/ui` in a worktree: `@maktura/ui/X` imports in repros/tests load the MAIN repo's copy — test via a relative import or co-locate the test inside the package.

If `git worktree add` fails with "branch already exists" — stale branch. Only delete if INDEX.tsv shows the ticket as `ready` or `partial`:

```bash
: "${REPO_PATH:?REPO_PATH unset — run Step 5 resolution block first}"
git -C "$REPO_PATH" branch -D "$BRANCH" 2>/dev/null
git -C "$REPO_PATH" worktree add "$WORKTREE" -b "$BRANCH" origin/develop
```

### Step 7 — Record the attestations on the claim

Step 3 already wrote branch, worktree, agent, pid, host and claimed_at into the
claim record. What is not known until now is whether Step 4.5's gates passed,
so write that back:

```bash
"$CL" update "$TICKET_KEY" \
  repo="$REPO_NAME" \
  mockup_viewed=true \
  backend_contract_acknowledged=true \
  run_id="${CLAIM_RUN_ID:-}" \
  run_log="${CLAIM_RUN_LOG:-}"
```

`update` is itself a compare-and-swap against the ref's current sha, so a
concurrent writer cannot be silently clobbered. Exit 10 means the record moved
under you — re-read with `show` before retrying.

The two attestation booleans record that the claimant was forced through the
mockup-visibility + backend-contract checks at pickup time. `/finish` reads
them back and **refuses the merge if either is missing or false**. Setting them
by hand without passing the gates is falsifying the accountability trail.

`CLAIM_RUN_ID` / `CLAIM_RUN_LOG` are exported by `spawn-claim.sh` and empty
when `/claim` was typed into a live session. With `pid` and `host` already in
the record, `reconcile-claims.sh` can tell "the agent died" from "the agent is
thinking" without them; they remain useful for finding the run log.

`/finish` reads `repo` to know where to push.

### Step 8 — Update INDEX.tsv (status `ready`/`partial` → `claimed`)

Don't hand-write the row. The label flip in Step 3 already moved the truth;
INDEX.tsv is a mirror of GitHub, so regenerate it from GitHub:

```bash
node ~/.claude/socialhub-tickets/scripts/rebuild-index-from-github.js >/dev/null
```

Hand-editing column 3 is how the mirror drifts from the thing it mirrors. On
2026-08-07 INDEX.tsv held 792 rows against 878 open issues and listed 15
tickets as claimed when 4 were — every one of those a hand-written cell that
GitHub never agreed with. A derived file is only safe if it is *only* ever
derived.

(This whole step goes away when INDEX.tsv does. It exists so `/queue` and the
dashboards keep working until they read GitHub directly.)

### Step 9 — GitHub Issue already updated (Step 3)

The label flip + claim comment happened in Step 3, immediately after the local lockfile win — that ordering is what makes the cross-machine race detectable. **Do NOT post a second comment here** with the worktree/branch details; the comment-noise policy (CONTRIBUTING.md) allows exactly one claim comment. Worktree, branch, and repo routing live in the lockfile's `meta.json` (Step 7) — that's the claim record peers and `/finish` read.

(Cross-repo note: issues that route to socialhub-support still LIVE in mrdombie/maktura — the queue is single-source — which is why Step 3 always targets `mrdombie/maktura` regardless of `$REPO_FULL`.)

### Step 10 — Summarise the spec

5-10 bullets to the user: problem, build, key files, AC, expected effort.

Mention worktree path: *"Working in `$WORKTREE` on branch `$BRANCH`."*

**Record the scope**, so `/standup` and the sign-off banner can name the area. Resolve the
ticket's primary `project:` label, or its `area:` label when it carries no programme:

```bash
. ~/.claude/hooks/lib/claude-session.sh   # one definition of "which session am I"
printf '%s\t%s\n' "$SCOPE" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
  > ~/.claude/socialhub-tickets/.session-label
claude_session_pid > ~/.claude/socialhub-tickets/.session-label.owner
```

Truncate-write, never append — one line, and it is the current scope or nothing. A
`/work` loop already wrote its label here; overwriting with the ticket's own is correct,
because the ticket is what this session is on now.

Mention primary area + adjacent active areas (other claimed/in-review tickets) so the user knows where collision risk lives if you wander outside scope.

### Step 11 — Hand off to the build chain

The ticket is claimed, the worktree exists, the spec is read. Everything from
here to `/finish` is the superpowers chain, in order. Do not improvise around
it and do not skip a link because the ticket looks small — the links exist
because skipping them is what produced the incidents the gates below encode.

**No step is optional, and "this one is simple" is never a reason.** That
judgement is made by the agent that wants to skip, and it always resolves the
same way. If you catch yourself reasoning toward an exemption, that is the
signal the step applies.

| Step | Skill | Output |
|---|---|---|
| 1 | `superpowers:brainstorming` | a design, agreed before any code |
| 2 | `superpowers:writing-plans` | an implementation plan |
| 3 | `superpowers:executing-plans` | the build, plan-driven |
| 4 | `superpowers:test-driven-development` | red before green, per change |
| 5 | `superpowers:verification-before-completion` | evidence, before any claim of done |
| 6 | `superpowers:requesting-code-review` | review before `/finish` |

`superpowers:subagent-driven-development` replaces step 3 when the ticket is a
sweep across many independent sites rather than one coherent change.

**Step 2 reads the current docs before it names a library call.** The plan
cites Context7 (`resolve-library-id` → `query-docs`) for every external API it
touches — Next.js 16, Prisma 7, NextAuth v5, BullMQ, Tailwind 4, Playwright.
Training data is behind every one of them; the repo CLAUDE.md says so for Next
and it is true of the rest. A plan written from memory bakes the old API in,
and the gates cannot see it: an outdated call compiles, passes lint, and
fails on a shape only the current docs describe.

**Step 2 inventories the outside-service home before it plans a call to one.**
The kit rule — `ls packages/ui/src/` before building a control — has a backend
twin, and until 2026-09-20 nothing wrote it down: before the plan names any call
to LinkedIn, X, YouTube, Instagram, TikTok, Facebook, Canva, Slack, Outlook,
WordPress or any other outside API, `ls apps/api/src/lib/platforms/<service>/`
and extend what is there. One home per service. Measured that day: six YouTube
clients, six LinkedIn, five Instagram — one per programme, each agent reading
only its own area. A plan whose `Create:` list adds a second client for a
service that already has one is wrong before a line is written; `Modify:` the
existing home instead, and route the call through `callExternal` (#10032). If
the ticket itself names a second home, that is the filing error `/file` step 8
now refuses — release the claim and flag it, do not build it.

**`superpowers:systematic-debugging` replaces steps 1–2 on a bug.** A bug ticket
inverts the order: you cannot design a fix for a failure you have not
reproduced, and a plan written before the root cause is fiction. Reproduce,
isolate the variable, prove it red, then fix and prove it green. `using-superpowers`
says this outright — *"Fix this bug" → systematic-debugging first, then domain
skills* — and this chain omitted it until 2026-08-07, which is why the honest
answer for #8629 and #8634 was "neither of the two options fits".

Do not reach for this on a feature because a feature feels investigative. The
test is whether there is an observed failure to reproduce. No failure, no
debugging path.

**Steps 1–2 may be satisfied BY THE TICKET — and only that way.** Step 4 above
already refuses any ticket that `writing-plans` could not turn into a plan with
no placeholders — no clear goal, no checkable outcome, no way to verify, no
stated constraints, or (on a bug) no reproduction — and *releases the claim*
when one is missing. So a ticket reaching this point is **plannable**, and
re-deriving the same argument produces the same artifact twice.

**Plannable is not the same as planned.** The gate asks whether a plan could be
written, not whether one was. A ticket can pass it and still name no files, no
component boundaries and no interfaces — #10113 said "extract the page into a
hook + presentational components" and named none of them. On a UI surface that
gap is closed by the design skill's Step 4.8 build plan; on anything else,
writing the plan is still yours, and "the ticket is detailed" is not evidence
the decomposition exists.

State which applies, in one line, before you write code — **and record it on the
claim, because `/finish` refuses to merge without it**:

```bash
# the ticket is plannable as written and IS the design
"$CL" update "$TICKET_KEY" design_source=ticket-body

# the ticket was thin, so you ran steps 1–2 and posted the design on the issue
"$CL" update "$TICKET_KEY" design_source=brainstormed

# a bug: you ran systematic-debugging, reproduced it red, and the fix followed
"$CL" update "$TICKET_KEY" design_source=debugged
```

`/finish` cross-checks this against `spec_usable` from Step 4:
claiming `ticket-body` on a ticket the spec gate did not mark complete is a
contradiction it refuses. So this is not a self-attestation you can wave
through — the two facts are written at different times by different gates and
have to agree.

Do this BEFORE writing code, not at `/finish` time. Recorded afterwards it is a
memory of what you meant to do; recorded first it is a decision you then have to
live with.

This is not discretion. A ticket is either plannable as written or it is not,
and the gate that decides is upstream of you and already enforced. What it
removes is duplicated work on a well-specced ticket; what it keeps is the full
chain on a badly-specced one, which is exactly where designs get invented
mid-build.

It also puts the cost in the right place. An underspecified ticket buys its
claimant a full brainstorm — which is the incentive to spec properly at filing
time rather than discover the gap at merge time.

**Build to the reviewers' rules — they are yours too (Dom, 2026-09-26).** Measured over
24 One Desk tickets: 207 review send-backs, a median of 7 rejections per ticket, and most of
them for rules the reviewers apply but no builder was ever told. Check each one yourself,
on the rendered screen, before you call a reviewer:

1. **Say each fact once, in one wording.** Before adding a line of copy, look at the whole
   composed screen: if the masthead, a band, a chip, a toast or the rail already says it,
   do not say it again, and never say it differently. The line never narrates a control
   ("pick people in the masthead") — the control is the instruction. (74 reports.)
2. **A state change updates every surface that shows it.** Before you finish, grep for every
   place the state is turned into words or colour (masthead, bands, chips, toasts, recent
   list, rail, approver line) and change them together. Missing "the third surface" is the
   code reviewer's most repeated catch.
3. **A failed read never looks empty, loading or finished.** Every fetch has three visible
   outcomes: loading, failed (says so, offers a retry), loaded — and "nothing here" is only
   ever the loaded-and-empty state. (9 reports.)
4. **A test must go red when the bug comes back.** Plant it by deleting the fix, not by
   mistyping it. A test that reads a source file, counts classes or asserts a string is in a
   file is NOT a test of behaviour, and the code reviewer will spit it back (its lens 9).
   Test the wiring at the call site, not a copy of it.
5. **Text reaches contrast AA:** 4.5:1 for body text, 3:1 for large text and for a control's
   visible boundary, measured on the rendered pixels in both themes. A pressed, selected or
   held state must differ from rest and hover by more than a hairline.
6. **The decision the screen is asking for is the most prominent thing on it.** Whatever
   blocks Publish, or needs the author's choice, sits above the fold and is marked; it is not
   below an optional field or a large preview.
7. **No coloured edge rails** — the 3px ember accent bar down the side of a card or row. Dom
   banned it (AGENTS.md); it shipped three times anyway.
8. **Build to what Dom approved.** Before a PR, put your render next to the approved
   prototype or sketch and list every difference. A difference is either fixed, or named on
   the PR with the reason.

**Review is one step, and it runs early (#10548).** `/critic` and `/ui-gate` run together
on the first version that renders, their findings batched into one fix list, capped at two
rounds — after which any non-blocker is a follow-up ticket and the PR ships. A blocker is a
dead control, a broken flow, or a data-honesty failure. Ship in PRs of about six fixes.

**Steps 4, 5 and 6 are never satisfied by anything but doing them.** No ticket
body can stand in for red-before-green, for evidence that the thing runs, or
for a review. Those are the three that caught real defects on 2026-08-07.

`coding-standards` is the standard steps 4 and 6 hold the work to. Read it once
per claim, not per file.

**Where the design goes.** `brainstorming` writes its spec to
`docs/superpowers/specs/` by default. Override that: post the design as a
comment on the issue instead. GitHub is the single source of truth for ticket
state, the comment survives the worktree being swept, and it is the same
channel a resume brief uses if you later park. Do not commit per-ticket design
docs into the product repo.

**If you hit something only a human can resolve** — a design call, an approval,
a merge the classifier refuses — do not sit on the claim waiting. Park it:
push the branch, open a draft PR, comment a resume brief (branch, PR, what is
done, what it needs, how to continue), add the `needs:*` label, and release the
ref. A held claim that is waiting on a human is a slot nobody can use and a
ticket nobody can see. Releasing it costs you the context; holding it costs
everyone else the ticket.

Park only the human residual: first decompose the ticket and ship every slice code and gates can prove — a blocked/decision label rarely covers the whole ticket.

## Epic mode (#3572 — single-entry epic runner)

When the claimed row has `mode=epic`, you are claiming an ENTIRE epic for end-to-end autonomous execution. There is no separate command — `/claim` IS the entry point. The epic is the lock unit: one lockfile (Step 3, unchanged) covers the whole run, and it is held until the epic closes.

### E1 — Autonomy contract gate (replaces the Step 4 sizing gate)

Read the epic body in full. It MUST contain a `## Autonomy contract` section carrying: the AC list, embedded mockups (rendered screenshots inline, where the epic has UI), **decision defaults** ("when ambiguous about X, choose Y"), and the **escalation bar** (what justifies stopping). Missing or incomplete → release the claim + flag back, same pattern as the spec-completeness gate:

```bash
ISSUE_NUM="$TICKET_KEY"   # ticket ids ARE issue numbers; .gh-issue-map.json is the retired SH-NNN table
ISSUE_BODY=$(gh issue view "$ISSUE_NUM" --repo mrdombie/maktura --json body -q .body)
if ! echo "$ISSUE_BODY" | grep -q '## Autonomy contract'; then
  echo "❌ /claim REFUSED: epic $TICKET has epic:run-ready but no '## Autonomy contract' section." >&2
  echo "   PM: add the contract (AC + embedded mockups + decision defaults + escalation bar)" >&2
  echo "   as a /file brainstorming spec (Verify + Constraints blocks), or remove the epic:run-ready label." >&2
  "$CL" release "$TICKET_KEY"
  exit 1
fi
```

The anti-orphan gates (Step 4.5) still apply — run them against the epic body.

### E2 — Decompose into slices (state file, NOT child issues)

Write the slice checklist into `<worktree>/docs/programmes/state-NNN.md` (NNN = the epic's issue number) — **in the repo**, which is where `programme-status.sh` reads and writes. `~/.claude/socialhub-tickets/programme-state/` is a per-machine shadow that nothing regenerates; editing it looks like it worked and changes nothing. `ensure-programme-state.sh` creates the stub for `epic:run-ready` epics — run it if the file is missing. Each slice = one PR-sized unit of work (the normal ship-whole sizing applies per slice). **Do NOT file child GH issues.**

**Adopt-existing-children rule:** if the epic ALREADY has open child issues (filed pre-v3 — e.g. pilot epic #3408's #3553–#3558), those children ARE the slices. List them in the state file by issue number, do not duplicate their bodies, and close each child issue as its slice ships. Only decompose fresh when no children exist.

The state file is also where EVERY decision goes. When you hit an ambiguity covered by a decision default, apply the default and log one line under "Recent decisions". When it's not covered but falls below the escalation bar, decide, log it, move on. Decisions do NOT go in GH comments.

### E3 — Claim record + the FIRST of two comments

Write `meta.json` as in Step 7, plus `"mode": "epic"` (this is what tells `/finish` it's finishing a slice, not a ticket). Update INDEX.tsv as in Step 8. The Step 3 claim comment for an epic should read: `**Claimed** … running autonomously (state: docs/programmes/state-NNN.md)`. That is comment 1 of exactly 2 this epic will ever receive from you.

### E4 — The slice loop

For each unshipped slice, in state-file order:

1. Fresh worktree off freshly-fetched `origin/develop` (Steps 5–6 mechanics; branch `sh-NNN/slice-k-<slug>`, worktree path gets its own hash). One worktree per slice — never reuse the previous slice's tree; each slice builds on the develop that already contains the prior slices' merges.
2. Implement the slice to its AC.
3. Invoke `/finish` — it detects epic mode from `meta.json` and ships the slice as a PR titled `#NNNN slice k/M: <slice title>`, merged to develop, with NO issue close and NO per-slice comment (see finish.md "Epic-mode finishes").
4. Update the state file: move the slice to Shipped (merge SHA + date), log decisions made, refresh "Next up". If the slice was an adopted child issue, close that child (its close comment is the child's outcome record, not epic noise).
5. Next slice.

### E5 — Escalation bar

Stop and surface to the PM ONLY for: a genuine scope change (the epic is wrong/too big as specced), a third-party blocker, a destructive action (data loss, prod mutation), or a repeated gate failure you cannot fix. Everything else: decide, log in the state file, keep moving. Do NOT stop to ask "should I continue?" between slices — the claim was the authorization.

If you DO stop mid-epic: keep the lockfile (the epic is still yours), record the blocker in the state file, and surface. Release the lockfile only if you're abandoning the run entirely.

### E6 — Close-out: final AC walk + the SECOND comment

After the last slice merges, walk the FULL Autonomy-contract AC list against develop — every box, with evidence (commands run, screenshots for UI). Only when every box ticks:

1. Post the completion digest on the epic (comment 2 of 2): slices shipped (PR links), decisions made (from the state file), the AC walk with evidence, screenshots.
2. Close the epic (`gh issue close` — and since `/finish` never closed it, the SH-2571 auto-reopen guard won't fight you; the epic label reopen logic only triggers on GitHub's PR-link auto-close).
3. Release the lockfile, drop the INDEX row, archive nothing — `ensure-programme-state.sh` archives the state file on the next run after close.

If any AC box can't tick, the epic is NOT done — keep working or escalate per E5.

## What you do not do

- **Don't `git checkout -b` in the main repo.** Always `git worktree add`.
- **Don't reuse a worktree path** from a previous claim.
- **Don't claim a ticket whose lockfile already exists.** mkdir fails → next candidate.
- **Don't re-read QUEUE.md to claim** — INDEX.tsv is the source of truth for /claim. QUEUE.md is the human-readable view, regenerated by /finish.
- **Don't open a PR yet** — that's `/finish`.
- **Don't auto-merge anything.**
- **Don't claim a bare `epic-gated` row** — only `claimable` + `mode=epic` rows enter epic mode; the PM's `epic:run-ready` label is the authorization.
- **Don't file child GH issues from epic mode** — slices live in the state file (existing pre-v3 children are adopted, not duplicated).
- **Don't narrate an epic run in GH comments** — exactly two comments per epic: claim + completion digest. Everything else goes in the state file.
- **Don't ship a stub duplicate of a feature a peer landed mid-build** — reconcile against develop, keep only the additive part, file the remainder.

## After claim

You're now responsible for the ticket until you `/finish` it. **Stay in the worktree (`$WORKTREE`) for every subsequent edit, run, commit.** If you find yourself in any other directory, `cd "$WORKTREE"` first.

## Chain straight into the work — and through to /finish — without stopping

**`/claim` is not "claim and wait for instructions."** Claiming a ticket = committing to ship it end-to-end in the same session. Once the spec is summarised:

1. Read every AC checkbox + the "How to verify" section.
2. Implement until every AC is met. Run lint/typecheck/tests as you go.
   - Gate with `npm run typecheck`, never `npx tsc` — in a worktree `npx tsc` can fetch a DECOY package that prints 'not the tsc command' and exits 0.
   - Raw `tsc -p apps/api/...` on a fresh worktree reports ~30 phantom `RouteContext` TS2304s in untouched files; `npm run typecheck` materialises the type.
   - Removing a Prisma model/enum/worker symbol: `npx prisma generate` then `npm run typecheck:root` too — callers hide in `scripts/` + `worker.ts` and a stale client masks them.
   - A 'sweep the class' ticket enumerates a SUBSET — grep the whole class (every token variant, preview/production twins) and re-grep after every develop merge.
3. **When you believe the AC is fully met, immediately invoke `/finish`.** Do NOT stop and ask the user "should I finish?" — that's the question the AC list already answered.
4. `/finish` will gate-check (re-walks every AC + runs gates + AC catches mistakes), so if you're wrong about being done, `/finish` refuses and surfaces back. That's the safety net.
5. Only stop for the user when:
   - An AC is genuinely impossible without a PM call (clarification on intent, missing assets, third-party blocker)
   - A non-trivial scope change is needed (the ticket is wrong / out of scope / too big)
   - A gate fails repeatedly and you can't fix it
6. Otherwise: **claim → code → /finish → done. One session. No mid-flow check-ins.**
7. **Every one of those stops ends with the sign-off banner** — and so does the ordinary
   finish. Read `~/.claude/shared/agent-signoff.md`. The scope is the ticket's primary
   `project:` or `area:` label, written to disk in Step 10 below:

   ```
   🏷️ Working on: Content Lab (project:content-lab)
      Paused on: you — the AC needs a call on whether drafts expire
      Also running: 2 agents on Welcome Flow
      Resume: answer here and I carry on — the worktree stays claimed
   ```

   Line 2 is the one that matters when you stop early. "Paused on: you — <the actual
   question>" is what stops Dom starting a second agent on the same ticket; "blocked"
   is what makes him start one.

The PM should never have to type `/finish`. If you're a coding agent that finished the work, run `/finish` yourself. Stopping at "I think I'm done, want me to finish?" defeats the entire workflow — the user has been burned by features that landed on develop but never made it to UAT because someone forgot to type the next command.

If you hit a blocker, release the claim (`"$CL" release "$TICKET_KEY"`) and surface it — don't squat on a ticket you aren't building. If the blocker needs a human, park it properly instead: push, draft PR, resume brief, label, release.
