---
name: claim
description: "claim a ticket and build it end to end. With no argument it picks the next ready one; give it a number to claim that specific ticket. Usage: /agent-harness:claim | /agent-harness:claim 9822"
---

You are a dev agent picking up a ticket. **Claim it and build it in this session**, end to end, through to `/agent-harness:finish`.

A spawner exists — `scripts/spawn-claim.sh`, and the `claim` shell function — that runs a ticket in a separate process with its own fresh context and budget. It is **not** the default and this skill does not invoke it. Use it deliberately from a terminal when you want a ticket worked without inheriting a session's context; `/agent-harness:claim-status` reports on anything spawned that way.

### UI work, and tickets that call `/design`

A claimed ticket **can** route into `/design` — that is normal, not an exception. `/design` builds the real page at the real route and then **pauses at the `:3010` worktree URL for PM approval**.

Working interactively you just pause and show the PM the URL. But if you cannot stay alive to serve that page — you were spawned, or the session is ending — hand back something runnable instead. Do not self-approve; the design gate is never self-attested. Do not push on and hope. Do not settle for screenshots: the standing preference is a URL you can click, not an image you have to trust.

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
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

gh issue edit "$TICKET_KEY" --repo "$REPO_SLUG" --add-label "$HOLD_LABEL"
gh issue comment "$TICKET_KEY" --repo "$REPO_SLUG" --body "**Parked — needs a design call.**

Branch \`$BRANCH\` is pushed; draft PR is open. To see it:

\`\`\`
git worktree add \$(mktemp -d)/$TICKET_KEY $BRANCH `# via /claim` && cd \$_
npm run dev -- -p 3010
\`\`\`

Then open <the route> and either approve, or say what to change.

Where the repo has Railway PR environments (#10479), the PR body carries a
`## Preview` URL the moment the bot reports it — hand THAT over instead: it
opens from any machine, not only the one this worktree lives on.

**Built:** <what is done and working>
**Stopped at:** <the exact pause point>
**Needs:** <the specific decision, phrased so a yes/no or a pick answers it>
**Resume:** clear this label, then \`/agent-harness:claim $TICKET_KEY\`.

<anything the next agent would otherwise have to rediscover>"

"$CL" release "$TICKET_KEY"
```

The worktree may be swept once the branch is pushed — that is fine and
expected. The `git worktree add` line in the brief recreates it in one command
from the branch, which is why step 1 is non-negotiable: **an unpushed branch is
the only thing a park can actually lose.**

The user sees this on the board and via the hold label (`$HOLD_LABEL`). Whoever
resumes clears the label and re-claims normally, reading the brief for context.

What a spawned agent still handles alone: the `/agent-harness:ui-gate` frontend review at `/agent-harness:finish` — that is an agent, not a person — and attaching the branch and route to the PR so evidence waits for the PM rather than blocking on them.

**Never spawn `/design` itself.** Invoked directly, it is an interactive two-phase flow and needs a human present from the start.

---

You are a dev agent picking up a ticket.

The queue lives **outside the repo** at `$STATE_DIR/`. Updating it does NOT require git operations.

## Multi-agent contract (read first — this is why the workflow is shaped the way it is)

Multiple Claude windows work the queue concurrently. Three rules keep them from trampling each other:

1. **The main repo clone (`$MAIN_REPO` from `scripts/toolkit-env.sh`) is a git object store, not a workspace.** Nobody works in it: every claim gets its own worktree, and `/agent-harness:finish` refuses outright to run from a main repo clone. Never run `git checkout -b ${BRANCH_PREFIX}NNN/...` there.

   **Its working tree is therefore stale and must never be read.** Step 1 only ever `fetch`es, which updates `origin/develop` without touching the files on disk — correct for `git worktree add`, but it means the checked-out files sit at whatever commit the clone was last checked out at. On 2026-08-03 that was 22 July: `/agent-harness:claim` had been executing a `recover-stale-claims.sh` 144 lines behind develop, and nothing surfaced it, because worktrees are cut from `origin/develop` and worktrees are where the visible work happens.

   So **never invoke `$MAIN_REPO/scripts/…`**. Materialise the scripts from the ref instead (see "Running repo scripts" below). Then the tree genuinely doesn't matter, and no one has to remember to sync it.
2. **Every claim works in its own worktree at a unique path.** The path includes a 6-char hash so two agents claiming the same ticket can't collide. The branch name stays deterministic (`${BRANCH_PREFIX}NNN/<slug>`).
3. **The claim is a git ref on origin** — `refs/claims/<issue>`, taken with `claim-lock.sh acquire`. The push carries `--force-with-lease=<ref>:` (expect-absent), so the server itself rejects the second writer. Atomic, cross-machine, and one `ls-remote` lists every live claim. The old `mkdir` lock was atomic only on one machine, which is why it needed a comment-scanning race detector bolted on top of it.

## Running repo scripts

Every skill that runs a script out of the repo (`/agent-harness:claim`, `/agent-harness:finish`, `/agent-harness:release-stale`, `/agent-harness:sweep-worktrees`) uses this three-line preamble, then calls `"$TOOLS/scripts/<name>.sh"`:

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
TOOLS=$(toolkit_tools) || exit 1
```

`git archive` reads the ref, never the working tree, so the scripts are always exactly what's on develop. The path is keyed by the develop SHA, so it self-invalidates when develop moves and costs nothing when it hasn't. Scripts keep normal `${BASH_SOURCE[0]}` semantics, so siblings can call each other (`queue-health-report.sh` calls `reconcile-claims.sh` this way).

Nothing is deleted and the main repo's working tree is never written to — it's simply not consulted.

## Programme state — read BEFORE claiming a programme child

If the ticket you're claiming references a programme parent (e.g. body says "Child of #N" or title mentions a programme issue), read the matching state file FIRST:

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
TOOLS=$(toolkit_tools) || exit 1

TICKET_BODY=$(gh issue view <NUMBER> --repo "$REPO_SLUG" --json body -q .body)
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

When you /agent-harness:finish, **update the state file** with the new shipped child + refresh the "Next up" list. /agent-harness:finish skill enforces this automatically.

## Atomic-claim architecture (the queue redesign)

**The claim is a git ref on origin. Nothing else is the claim.**

```
origin refs/claims/<issue>   # exists = claimed. THE lock.
                             # points at a parentless commit whose message is
                             # the claim record (agent, pid, host, branch,
                             # worktree, claimed_at, attestations)
$STATE_DIR/
  scripts/
    claim-lock.sh        # acquire | release | update | list | show | holds
    reconcile-claims.sh  # put GitHub's $LBL_CLAIMED back in line with reality
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

A ticket labelled `epic` + `epic:run-ready` + `$LBL_READY` (ready) is a run-ready epic — claiming it enters **epic mode** (see the "Epic mode" section below) instead of the normal single-ticket flow.

A `repo:<name>` label names a sister repo (one listed under `sisterRepos` in `.claude/harness.json`); without it a ticket is the main repo. /agent-harness:claim and /agent-harness:finish read that label to pick which repo to spawn the worktree from + which origin to push to. Cross-repo tickets (e.g. features filed in the main repo but built in a sister repo) ship through one queue.

`scripts/toolkit-env.sh` resolves the clone locations from the checkout you are in (`MAIN_REPO`, and `SUPPORT_REPO` when a sister-repo clone sits beside it):

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
REPO_NAME="${REPO_SLUG##*/}"   # or the value of the ticket's repo: label
REPO_PATH=$(toolkit_repo_path "$REPO_NAME") || exit 1
REPO_FULL="${REPO_SLUG%/*}/$REPO_NAME"
```

Both sister repos share the `develop` trunk and `${BRANCH_PREFIX}NNN/<slug>` branch convention. `/agent-harness:finish` ships every repo to its `develop` only — `develop → uat` promotion is owned by the review gate (or `/push-to-uat`), not `/agent-harness:finish`. (The sister repo has no `uat` branch at all; its develop merge is the deploy.)

The status labels classify WHY a ticket isn't claimable — saves you from re-reading the spec to find out:

- `claimable` — engineering work shippable solo
- `claimed` — agent already owns it (lockfile present OR queue says claimed)
- `human-blocked` — UAT walkthrough / PM eyeball / lawyer / third-party review
- `pr-blocked` — waiting on another PR to land first
- `pm-time-gated` — PM has to choose timing (migration window, etc)
- `pm-decision` — PM has to confirm a list / decision
- `pm-track` — discovery / spec / strategy work; humans drive output, not coding agents (#787)
- `external-blocked` — waiting on external party (Stripe, lawyer, customer, third-party API review). Includes paid subscriptions / DNS / OAuth re-registration.
- `dependency-blocked` — spec is COMPLETE; waiting on a prerequisite ticket (Phase 0 / Phase 1 / sister) to ship before claiming makes sense. That is the gated label (`$LBL_GATED`).
- `epic-gated` — epic/programme umbrella that is NOT cleared for single-agent end-to-end execution (#3572). An epic only becomes `claimable` (with `mode=epic`) when the PM attaches BOTH `epic:run-ready` and `$LBL_READY`.
- `needs-human` — a human has to work out what happened before this is claimable again. **Never auto-claim these.** Whoever does that flips it back to `$LBL_READY` (ready) deliberately. (`reconcile-claims.sh` does NOT set it: a dead claim is judged on evidence — see Step 0c.)
- `xxl-multi-phase` — too big for the ship-whole rule
- `parked` / `drafting` / `in-review` / `reverted` / `blocked` — out of scope for /agent-harness:claim

**Only `$LBL_READY` (ready) tickets (and run-ready epics) are valid /agent-harness:claim targets.** Everything else is either someone else's, blocked on a human, or already in flight.

**Status taxonomy clarification (locked 2026-05-06; expanded by #787 on 2026-05-09 — see `feedback_status_taxonomy.md`):**
- `$LBL_DRAFTING` (drafting) on GH = PM still writing/deciding the spec → not claimable
- `$LBL_GATED` (gated) on GH = spec is COMPLETE; waiting on prereq ticket to ship → not claimable, but the spec is good to read while waiting
- `$LBL_PM_TRACK` (pm-track) on GH (#787) = discovery / spec / strategy work; humans drive output, not coding agents → not claimable
- `$LBL_EXTERNAL_BLOCKED` (external-blocked) on GH (#787) = waiting on external party (Stripe, lawyer, customer, third-party API review) → not claimable until the external item resolves
- `$LBL_READY` (ready) on GH = claim away → /agent-harness:claim's only valid target
- `$LBL_NEEDS_HUMAN` (needs-human) on GH = a claim died mid-flight without shipping → not claimable until a human works out why and flips it back
- `epic`/`programme` label WITHOUT `epic:run-ready` (#3572) = umbrella, never claimable regardless of status → never claimable
- `epic` + `epic:run-ready` + `$LBL_READY` (#3572) = PM has cleared this epic for single-agent end-to-end execution → /agent-harness:claim enters epic mode

If a dev sees N tickets in `gated`, that's NOT "PM hasn't done their job." It's "PM has done their job; these become claimable when their prereq ships." Read the spec's "Depends on" section to see what's gating each one.

## Ship-whole contract

A `/agent-harness:claim` is a commitment to ship the **entire** ticket end-to-end in one go. Memory: `feedback_ship_whole_features.md`.

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
   [reproduction / verifiable outcome / …]. Needs a pass through `/agent-harness:file` before
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

**Record the verdict on the claim** — Step 11 and `/agent-harness:finish` both read it:

```bash
"$CL" update "$TICKET_KEY" spec_usable=true   # writing-plans can consume it
```

Only write `true` when all five sections are genuinely there. This is the fact
Step 11 leans on to let the ticket stand in for a design, and `/agent-harness:finish` refuses
a merge where the two disagree. Writing it without checking removes the only
cross-check in the chain.

## Repo guard (run first)

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
```

The sister-repo guard is a soft warn (no exit). Claims targeting only the main repo still work without the sister repo.

## How this gets entered

**`/agent-harness:claim` in a session is the normal entry point.** It claims and builds right there, inheriting that session's context and whatever budget is left in it.

There is also a spawner, off by default:

```
claim            # next ready ticket, in a separate process
claim 7897       # that ticket
claim --fg       # interactive, in the foreground
```

`claim` runs `scripts/spawn-claim.sh`, which starts a **fresh `claude` process** — new context, its own budget cap, its own worktree — and that process runs this skill. A context window cannot clear itself (no hook event can do it), so a new process is the only way to get a genuinely clean context per ticket. Worth reaching for when a session has drifted a long way from the ticket in hand; not something to do reflexively.

A spawned claim records `run_id` in its lockfile, which lets the watchdog tell "the agent died" from "the agent is thinking". A `/agent-harness:claim` typed into a session leaves no run record and falls back to artifact freshness — still covered, just less precisely.

## Workflow

### Step 0 — Ensure programme state files + reconcile open claims

Three cheap idempotent prep steps before picking a candidate:

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1

# 0b — (moved) programme state stubs are written in the WORKTREE at Step 6.5,
#      because docs/programmes/ is committed and this checkout must not be dirtied.

# 0c — reconcile every open claim against a live process and a real artifact.
# Fetch first: the scripts below are read from origin/develop, so that ref has
# to be current before it's used as a source.
git -C "$MAIN_REPO" fetch -q origin develop
TOOLS=$(toolkit_tools) || exit 1
"$KIT_ROOT/scripts/reconcile-claims.sh"

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

The `ensure-programme-state.sh` step is a no-op when nothing has changed — it just creates a stub state-NNN.md for any new `programme`-labelled issue and archives state files for closed programmes. Zero PM action required when filing new programmes.

The `reconcile-claims.sh` step checks every open claim against three things that must agree: the lockfile, the process that made it (`meta.run_id` → `runs/<id>.json`, alive?), and a real artifact (branch commits, PR state, a closed issue). **Claim age is not a staleness signal** — a ticket claimed three days ago whose branch was pushed an hour ago is being worked on, and one claimed this morning by a process that died is not.

**A missing claim is not absent work, so the evidence decides** — the old "every dead claim to `$LBL_NEEDS_HUMAN` (needs-human)" rule would have been wrong 6 times out of 11 on 2026-08-07, because those six had open PRs a fresh agent would have rebuilt from nothing. A live holder on this host is left alone; a holder on another host is reported, never broken; an epic is kept. Then: a **merged PR** → comment and close the ticket; an **open PR** → `$LBL_IN_REVIEW` (in-review), never released to ready; a **branch with no PR** → `$LBL_PARTIAL` (partial), naming the branch; **nothing at all** → `$LBL_READY` (ready). Override the idle window with `STALE_HOURS` (default 4). Typical no-op run takes <1s.

It exits 0 even when it escalates something — an escalation is a normal outcome, not a broken script, and must never block a fresh claim.

If any script errors (network down, gh auth expired), surface it to the user and stop — better to refuse a claim than pick from a known-stale list.

### Step 1 — Refresh `develop` on every repo we might claim into

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1

git -C "$MAIN_REPO" fetch origin develop
{ [ -n "$SUPPORT_REPO" ] && [ -d "$SUPPORT_REPO/.git" ] && git -C "$SUPPORT_REPO" fetch origin develop; } || true
```

Don't `git checkout develop` in either main repo — another agent may be using it. The sister-repo fetch is best-effort; absence is OK if the row turns out to target the main repo.

### Step 2 — Pick a candidate from GitHub

**If `$ARGUMENTS` names a ticket, that IS the candidate — skip the picking, keep the gates.**

`/agent-harness:claim 9822` claims #9822. Everything after this step is unchanged: the atomic
claim, the spec gate, the anti-orphan gates, the worktree, the attestations. One
path to shipping code, whether the ticket was chosen by you or handed to you.

`scripts/spawn-claim.sh` has always built `PROMPT="/agent-harness:claim $TICKET"`, so it has been
passing a number this command ignored — it picked its own ticket instead, and a
caller that asked for a specific one silently got a different one.

Validate before claiming, and **refuse rather than substitute** — a caller that
named a ticket wants that ticket or an error, never a surprise:

```bash
TICKET="${ARGUMENTS//[^0-9]/}"
if [ -n "$TICKET" ]; then
  META=$(gh issue view "$TICKET" --repo "$REPO_SLUG" --json number,state,labels,title 2>/dev/null)     || { echo "🛑 #$TICKET does not resolve. NOTE: gh issue view resolves PULL REQUESTS too — check you were given an issue." >&2; exit 1; }
  [ "$(jq -r .state <<<"$META")" = OPEN ] || { echo "🛑 #$TICKET is closed." >&2; exit 1; }
  LBL=$(jq -r '[.labels[].name]|join(" ")' <<<"$META")
  case " $LBL " in
    *" $HOLD_LABEL "*) echo "🛑 #$TICKET is parked on a human. Not claimable." >&2; exit 1 ;;
    *" $LBL_GATED "*)      echo "🛑 #$TICKET is gated — the PM flips that, not you." >&2; exit 1 ;;
  esac
  "$CL" holds "$TICKET" >/dev/null 2>&1 && { echo "🛑 #$TICKET is already claimed. Back off — never adopt a peer's lock." >&2; exit 1; }
  # candidate = $TICKET; go to Step 3.
fi
```

**With no argument, pick one — the original behaviour, unchanged:**

**Read the queue from GitHub.** The local mirror this used to lag behind (86 unclaimable tickets on 2026-08-07) is gone; selecting from GitHub makes that class of miss impossible.

**Pass A — claimable issues, minus anything already held.**

One `ls-remote` gives you every live claim in the system, across every machine.
This is the whole reason the lock moved onto a ref: the old filter stat'd a
local `claims/` directory, so a ticket claimed on another machine looked free.

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
# ONE definition of claimable, shared with the queue health report:
#   status:ready, plus orphaned status:in-review (an agent died with a PR open —
#   offered as [RESUME PR] unless needs:human-approval says a human holds it), an
#   epic only with epic:run-ready ([EPIC MODE]), plus the ticket behind any open
#   non-draft PR GitHub calls CONFLICTING ([FINISH PR], listed FIRST), minus every
#   live claim.
# Columns: number  priority  area  repo  mode  title
"$KIT_ROOT/scripts/claimable-issues.sh"
```

**A `[FINISH PR]` row comes first, and it is not a fresh build either.** The
ticket's PR is open, out of draft, and GitHub says it cannot merge. The list puts
these above everything else on purpose — finish before start: a clashing PR is
work already paid for, and every hour it waits it falls further behind. The move
is the resume move below: merge the integration branch in, resolve, re-gate, and
finish. If the PR carries the hold label, the merge does not clear it; a merge
that moves pixels voids any approval, so re-capture and leave the hold for a
person.

**A `[RESUME PR]` row is not a fresh build.** There is already work on a branch
and an open PR. Pass B below will print it. Read the PR's commits and the
ticket's handover comment against the AC *before* writing anything: the correct
move is usually to merge develop in, re-gate and finish it — unless the PR is
merely behind and `scripts/behind-pr-action.sh` says `bot`: then the repo's update
bot catches it up, and merging develop in by hand restarts the PR it is landing
(#79). Rebuilding from scratch is the failure this label exists to prevent. If the premise no longer
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
gh pr list --repo "$REPO_SLUG" --state open --limit 200 \
  --json number,headRefName,title,body \
  -q ".[] | select((.headRefName | test(\"(^|/)(${BRANCH_PREFIX})?${CAND}[-/]\"))
                or (.body // \"\" | test(\"#${CAND}\\\\b\"))) 
      | \"OPEN PR #\(.number)  \(.headRefName)  \(.title)\""

git ls-remote --heads origin | grep -E "refs/heads/(${BRANCH_PREFIX})?${CAND}[-/]|/${CAND}-" || true

# The checks above key on the ticket NUMBER, so they only see the same ticket
# claimed twice. They are blind to the shape that actually costs us: two
# DIFFERENT tickets that land on the same file. #8764 and #8776 were filed and
# built against work already in flight under #8627 and #8629 because nothing
# compared the files. This compares them — the paths named in the candidate's
# body against every open PR's diff and every live claim's branch.
"$KIT_ROOT/scripts/overlap-check.sh" "$CAND"

# Merged in the last 7 days — the ticket may already be shipped under another id.
gh pr list --repo "$REPO_SLUG" --state merged --limit 50 \
  --search "merged:>=$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d)" \
  --json number,title -q '.[] | "recent: #\(.number) \(.title)"'
```

If any of those hit, **stop and read before claiming**. An open PR on the ticket
means resume that PR, not rebuild it. A merged PR covering the same change means
the ticket wants closing or re-scoping, and claiming it produces a second
implementation of something that already shipped.

If there are zero rows after filtering: invoke the queue-health reporter (#788) so the PM gets actionable structure instead of just "stop":

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
TOOLS=$(toolkit_tools) || exit 1
"$TOOLS/scripts/queue-health-report.sh"
```

The report buckets every non-claimable row (programme parents, pm-track, external-blocked, dependency-blocked, drafting, in-review, claimed, stale lockfiles) and renders 5 PM-actionable next steps when the engineering count is zero. Surface the report verbatim to the user, then stop — the PM picks one of the suggested actions.

**Pass B — apply the area lock.** A ticket's area is locked when another claimable / partial / in-review ticket in the same area is currently claimed (i.e. has a lockfile). Cross-cutting areas never lock. Walk the candidate list and pick the first whose area is unlocked.

If every candidate's area is locked: take the highest-priority anyway, but warn the user explicitly: *"Heads up — every candidate's area is currently active. Claiming SH-NNN may collide with [other tickets in same area]."*

**Pin override:** if QUEUE.md has a `🔥 PINNED` block at the top, that ticket bypasses area-lock.

**Epic-mode candidates:** if the picked row is tagged `[EPIC MODE]` (an `epic` labelled `epic:run-ready`), run Step 3 (atomic claim + cross-machine hardening) as normal, then jump to the **"Epic mode"** section below instead of Steps 4–10 — the spec gate, decomposition, and build loop all differ.

### Step 3 — Atomic claim (one compare-and-swap)

Branch and worktree are computed in Step 5/6, but the claim must be taken
FIRST — a claim you take after doing setup work is a claim you can lose after
doing setup work. Pass the branch you intend to use.

```bash
TICKET_KEY=$(echo "$TICKET" | tr -d '#' | sed 's/^SH-//')   # bare digits
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1

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

Then mirror the state onto GitHub for human visibility. This is bookkeeping,
not the claim — if it fails, you still own the ticket:

```bash
gh issue edit "$TICKET_KEY" --repo "$REPO_SLUG" \
  --remove-label "$LBL_READY" --add-label "$LBL_CLAIMED" 2>/dev/null || true
node "$(git rev-parse --show-toplevel)/scripts/sync-project-board.js" >/dev/null 2>&1 || true   # the board mirrors the labels
```

No claim comment. The old flow posted one because comments were how the
cross-machine race was arbitrated; the ref does that now, so the comment is
pure noise. The issue's comment budget is spent on things a human needs: the
design (Step 11), a resume brief if you park, and the close-out.

**You own the ticket.**

### Step 4 — Read the spec + sizing gate

The issue body is the spec: `gh issue view "$TICKET_KEY" --repo "$REPO_SLUG" --json body -q .body`.

Run the ship-whole sizing gate above. If the spec fails, release the claim:

```bash
"$CL" release "$TICKET_KEY"
```

Then flag back to the user with the specific issue.

### Step 4.5 — Anti-orphan gates (#2485)

PM-mandated 2026-05-24. Dev-AIs kept building from spec verbiage without opening the mockup file, and shipping UI without the backing endpoints. Gates 1 and 2 refuse the claim at pickup-time so a half-spec'd ticket can't slip through. **Gate 3 (added 2026-09-01) asks the other question: not "is this ticket well written" but "is it still true".**

**The gates live HERE — between the sizing-gate and the worktree create — so they refuse cheaply.** A failure releases the lockfile + exits with a named-failure error message; the next /agent-harness:claim attempt can re-pick after the spec is tightened.

| Gate | Refuses | Decides |
|---|---|---|
| 1 — mockup visibility | a mockup referenced but never rendered | automatically, `exit 1` |
| 2 — backend contract | UI-shaped ticket with no endpoint list | automatically, `exit 1` |
| 3 — premise | a ticket whose defect no longer exists | **you do** — it gathers, you judge |

Run all three before continuing. A Gate 1 or Gate 2 failure releases the lockfile and stops:

```bash
ISSUE_NUM="$TICKET_KEY"   # ticket ids ARE issue numbers
ISSUE_META=$(gh issue view "$ISSUE_NUM" --repo "$REPO_SLUG" --json body,labels)
ISSUE_BODY=$(jq -r '.body' <<<"$ISSUE_META")
ISSUE_LABELS=$(jq -r '.labels[].name' <<<"$ISSUE_META")   # one per line; Gate 2 reads it

# Gate 1 — Mockup-visibility check. If the body references a mockup
# file (.html under the project's design folder) but doesn't embed a rendered
# screenshot inline, refuse. Building from CSS/HTML alone is the
# pattern that produced the 2026-05-24 mockup-parity incident.
if echo "$ISSUE_BODY" | grep -qiE 'docs/design/source|mockup.*\.html'; then
  if ! echo "$ISSUE_BODY" | grep -qE '!\[.*\]\(https?://[^)]+\.(png|jpg|jpeg|webp|gif)\)|<img[^>]+src='; then
    echo "❌ /agent-harness:claim REFUSED: $TICKET references a mockup file but doesn't embed a rendered screenshot." >&2
    echo "   Either:" >&2
    echo "   - PM: render the mockup to PNG, commit it under docs/evidence/<issue>/ and embed it SHA-pinned" >&2
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
    echo "❌ /agent-harness:claim REFUSED: $TICKET looks UI-shaped but has no '## Backend contract' section." >&2
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

### Step 5 — Compute branch, worktree path, and repo routing

```bash
SLUG="<2-4-word-slug-from-title>"
HASH=$(openssl rand -hex 3)
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
WT_ROOT=$(toolkit_worktree_root) || exit 1
WORKTREE="$WT_ROOT/${TICKET,,}-${SLUG}-${HASH}"
BRANCH="${TICKET,,}/${SLUG}"
# Repo routing — the ticket's repo: label, default to the main repo.
REPO_NAME=$(grep -m1 '^repo:' <<<"$ISSUE_LABELS" | cut -d: -f2)   # ISSUE_LABELS from Step 4.5
[ -z "$REPO_NAME" ] && REPO_NAME="${REPO_SLUG##*/}"
# Resolve the clone location via toolkit-env (MAIN_REPO / SUPPORT_REPO;
# any name not listed under sisterRepos resolves to the main repo).
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
REPO_PATH=$(toolkit_repo_path "$REPO_NAME") || exit 1
REPO_FULL="${REPO_SLUG%/*}/$REPO_NAME"
```

(`,,` is bash lower-case expansion — `SH-181` → `sh-181`.)

**Never the OS temp dir.** macOS deletes files under `$TMPDIR` (`/var/folders/…/T`) that are three days untouched, file by file, so a worktree there rots while keeping its name — 54 of 103 claim worktrees on the origin project had lost `.git` by 2026-09-27. `toolkit_worktree_root` is the one resolver: `$HARNESS_WORKTREE_ROOT`, then `worktreeRoot` in `.claude/harness.json`, then `~/.harness-worktrees/<repo>`, and it refuses a temp path outright.

### Step 6 — Create the worktree off freshly-fetched develop in the right repo

```bash
: "${REPO_PATH:?REPO_PATH unset — run Step 5 resolution block first}"
git -C "$REPO_PATH" worktree add "$WORKTREE" -b "$BRANCH" origin/develop
# The shared install, linked entry by entry into the worktree's OWN node_modules,
# with each workspace package pointed at THIS worktree's copy. One symlink to the
# whole shared node_modules carried the shared checkout's workspace links too, so
# code at the root and the dev server ran the shared clone's stale packages (a
# subpath the branch added could not be resolved; the login page 500'd) and a
# dependency the install left inside one workspace's node_modules never resolved
# here. Symlinks only.
"$KIT_ROOT/scripts/link-node-modules.sh" "$REPO_PATH" "$WORKTREE" || { echo "🛑 the worktree's node_modules could not be linked" >&2; exit 1; }
# Per-workspace links to the worktree's own siblings. With the root node_modules
# above already pointing every workspace home this is belt and braces; it is
# harmless with that layout and stays until it is retired deliberately.
"$KIT_ROOT/scripts/link-workspaces.sh" "$REPO_PATH" "$WORKTREE"
# Without this git finds no hook in a fresh worktree and pushes unchecked. A 🛑 here is a stop: do not continue past it.
"$KIT_ROOT/scripts/ensure-hooks.sh" "$REPO_PATH" "$WORKTREE" || exit 1
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

### Step 6.5 — Programme state stubs, in the worktree

`docs/programmes/` is committed, so the stub/archive writer runs where a commit can land — never in the checkout the session started in:

```bash
"$(git rev-parse --show-toplevel)/scripts/ensure-programme-state.sh"
git add docs/programmes && git commit -q -m "chore(programme): state stubs" -m "no-changelog: programme bookkeeping" 2>/dev/null || true
```

If `git worktree add` fails with "branch already exists" — stale branch. Only delete if the issue is labelled `$LBL_READY` or `$LBL_PARTIAL` and no claim ref exists:

```bash
: "${REPO_PATH:?REPO_PATH unset — run Step 5 resolution block first}"
git -C "$REPO_PATH" branch -D "$BRANCH" 2>/dev/null
git -C "$REPO_PATH" worktree add "$WORKTREE" -b "$BRANCH" origin/develop
```

Then run the rest of the Step 6 block from `link-node-modules.sh` down. `ensure-hooks.sh` is not optional on this path either.

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
mockup-visibility + backend-contract checks at pickup time. `/agent-harness:finish` reads
them back and **refuses the merge if either is missing or false**. Setting them
by hand without passing the gates is falsifying the accountability trail.

`CLAIM_RUN_ID` / `CLAIM_RUN_LOG` are exported by `spawn-claim.sh` and empty
when `/agent-harness:claim` was typed into a live session. With `pid` and `host` already in
the record, `reconcile-claims.sh` can tell "the agent died" from "the agent is
thinking" without them; they remain useful for finding the run log.

`/agent-harness:finish` reads `repo` to know where to push.

### Step 8 — (retired)

There is no local index to update: the label flip in Step 3 IS the state, and every reader asks GitHub.

### Step 9 — GitHub Issue already updated (Step 3)

The label flip + claim comment happened in Step 3, immediately after the local lockfile win — that ordering is what makes the cross-machine race detectable. **Do NOT post a second comment here** with the worktree/branch details; the comment-noise policy (CONTRIBUTING.md) allows exactly one claim comment. Worktree, branch, and repo routing live in the lockfile's `meta.json` (Step 7) — that's the claim record peers and `/agent-harness:finish` read.

(Cross-repo note: issues that route to a sister repo still LIVE in `$REPO_SLUG` — the queue is single-source — which is why Step 3 always targets `$REPO_SLUG` regardless of `$REPO_FULL`.)

### Step 10 — Summarise the spec

5-10 bullets to the user: problem, build, key files, AC, expected effort.

Mention worktree path: *"Working in `$WORKTREE` on branch `$BRANCH`."*

**Record the scope**, so `/agent-harness:standup` and the sign-off banner can name the area. Resolve the
ticket's primary `project:` label, or its `area:` label when it carries no programme:

```bash
printf '%s\t%s\n' "$SCOPE" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
  > "$STATE_DIR/.session-label"
```

Truncate-write, never append — one line, and it is the current scope or nothing. A
`/agent-harness:work` loop already wrote its label here; overwriting with the ticket's own is correct,
because the ticket is what this session is on now.

Mention primary area + adjacent active areas (other claimed/in-review tickets) so the user knows where collision risk lives if you wander outside scope.

### Step 11 — Hand off to the build chain

The ticket is claimed, the worktree exists, the spec is read. Everything from
here to `/agent-harness:finish` is the superpowers chain, in order. Do not improvise around
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
| 6 | `superpowers:requesting-code-review` | review before `/agent-harness:finish` |

`superpowers:subagent-driven-development` replaces step 3 when the ticket is a
sweep across many independent sites rather than one coherent change.

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
already refuses any ticket missing "What it does" / "Acceptance criteria" /
"How to verify" / "Files to touch" / "Out of scope", and *releases the claim*
when one is absent. So every ticket that reaches this point carries a design
and a plan already. Re-deriving them produces the same artifact twice.

State which applies, in one line, before you write code — **and record it on the
claim, because `/agent-harness:finish` refuses to merge without it**:

```bash
# the ticket carried its five sections and they ARE the design
"$CL" update "$TICKET_KEY" design_source=ticket-body

# the ticket was thin, so you ran steps 1–2 and posted the design on the issue
"$CL" update "$TICKET_KEY" design_source=brainstormed

# a bug: you ran systematic-debugging, reproduced it red, and the fix followed
"$CL" update "$TICKET_KEY" design_source=debugged
```

`/agent-harness:finish` cross-checks this against `spec_usable` from Step 4:
claiming `ticket-body` on a ticket the spec gate did not mark complete is a
contradiction it refuses. So this is not a self-attestation you can wave
through — the two facts are written at different times by different gates and
have to agree.

Do this BEFORE writing code, not at `/agent-harness:finish` time. Recorded afterwards it is a
memory of what you meant to do; recorded first it is a decision you then have to
live with.

This is not discretion. A ticket either has the five sections or it does not,
and the gate that decides is upstream of you and already enforced. What it
removes is duplicated work on a well-specced ticket; what it keeps is the full
chain on a badly-specced one, which is exactly where designs get invented
mid-build.

It also puts the cost in the right place. An underspecified ticket buys its
claimant a full brainstorm — which is the incentive to spec properly at filing
time rather than discover the gap at merge time.

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

## Epic mode (#3572 — single-entry epic runner)

When the claimed row has `mode=epic`, you are claiming an ENTIRE epic for end-to-end autonomous execution. There is no separate command — `/agent-harness:claim` IS the entry point. The epic is the lock unit: one lockfile (Step 3, unchanged) covers the whole run, and it is held until the epic closes.

### E1 — Autonomy contract gate (replaces the Step 4 sizing gate)

Read the epic body in full. It MUST contain a `## Autonomy contract` section carrying: the AC list, embedded mockups (rendered screenshots inline, where the epic has UI), **decision defaults** ("when ambiguous about X, choose Y"), and the **escalation bar** (what justifies stopping). Missing or incomplete → release the claim + flag back, same pattern as the spec-completeness gate:

```bash
ISSUE_NUM="$TICKET_KEY"   # ticket ids ARE issue numbers
ISSUE_BODY=$(gh issue view "$ISSUE_NUM" --repo "$REPO_SLUG" --json body -q .body)
if ! echo "$ISSUE_BODY" | grep -q '## Autonomy contract'; then
  echo "❌ /agent-harness:claim REFUSED: epic $TICKET has epic:run-ready but no '## Autonomy contract' section." >&2
  echo "   PM: add the contract (AC + embedded mockups + decision defaults + escalation bar)" >&2
  echo "   per reference_ticket_spec_template.md, or remove the epic:run-ready label." >&2
  "$CL" release "$TICKET_KEY"
  exit 1
fi
```

The anti-orphan gates (Step 4.5) still apply — run them against the epic body.

### E2 — Decompose into slices (state file, NOT child issues)

Write the slice checklist into `docs/programmes/state-NNN.md` in your worktree (commit it with the slice) (NNN = the epic's issue number). `ensure-programme-state.sh` creates the stub for `epic:run-ready` epics — run it if the file is missing. Each slice = one PR-sized unit of work (the normal ship-whole sizing applies per slice). **Do NOT file child GH issues.**

**Adopt-existing-children rule:** if the epic ALREADY has open child issues (filed pre-v3 — e.g. pilot epic #3408's #3553–#3558), those children ARE the slices. List them in the state file by issue number, do not duplicate their bodies, and close each child issue as its slice ships. Only decompose fresh when no children exist.

The state file is also where EVERY decision goes. When you hit an ambiguity covered by a decision default, apply the default and log one line under "Recent decisions". When it's not covered but falls below the escalation bar, decide, log it, move on. Decisions do NOT go in GH comments.

### E3 — Claim record + the FIRST of two comments

Write `meta.json` as in Step 7, plus `"mode": "epic"` (this is what tells `/agent-harness:finish` it's finishing a slice, not a ticket). The Step 3 claim comment for an epic should read: `**Claimed** … running autonomously (state: docs/programmes/state-NNN.md)`. That is comment 1 of exactly 2 this epic will ever receive from you.

### E4 — The slice loop

For each unshipped slice, in state-file order:

1. Fresh worktree off freshly-fetched `origin/develop` (Steps 5–6 mechanics; branch `${BRANCH_PREFIX}NNN/slice-k-<slug>`, worktree path gets its own hash). One worktree per slice — never reuse the previous slice's tree; each slice builds on the develop that already contains the prior slices' merges.
2. Implement the slice to its AC.
3. Invoke `/agent-harness:finish` — it detects epic mode from `meta.json` and ships the slice as a PR titled `#NNNN slice k/M: <slice title>`, merged to develop, with NO issue close and NO per-slice comment (see finish.md "Epic-mode finishes").
4. Update the state file: move the slice to Shipped (merge SHA + date), log decisions made, refresh "Next up". If the slice was an adopted child issue, close that child (its close comment is the child's outcome record, not epic noise).
5. Next slice.

### E5 — Escalation bar

Stop and surface to the PM ONLY for: a genuine scope change (the epic is wrong/too big as specced), a third-party blocker, a destructive action (data loss, prod mutation), or a repeated gate failure you cannot fix. Everything else: decide, log in the state file, keep moving. Do NOT stop to ask "should I continue?" between slices — the claim was the authorization.

If you DO stop mid-epic: keep the lockfile (the epic is still yours), record the blocker in the state file, and surface. Release the lockfile only if you're abandoning the run entirely.

### E6 — Close-out: final AC walk + the SECOND comment

After the last slice merges, walk the FULL Autonomy-contract AC list against develop — every box, with evidence (commands run, screenshots for UI). Only when every box ticks:

1. Post the completion digest on the epic (comment 2 of 2): slices shipped (PR links), decisions made (from the state file), the AC walk with evidence, screenshots.
2. Close the epic (`gh issue close` — and since `/agent-harness:finish` never closed it, the SH-2571 auto-reopen guard won't fight you; the epic label reopen logic only triggers on GitHub's PR-link auto-close).
3. Release the claim, archive nothing — `ensure-programme-state.sh` archives the state file on the next run after close.

If any AC box can't tick, the epic is NOT done — keep working or escalate per E5.

## What you do not do

- **Don't `git checkout -b` in the main repo.** Always `git worktree add`.
- **Don't reuse a worktree path** from a previous claim.
- **Don't claim a ticket whose lockfile already exists.** mkdir fails → next candidate.
- **Don't open a PR yet** — that's `/agent-harness:finish`.
- **Don't auto-merge anything.**
- **Don't claim a bare `epic-gated` row** — only `claimable` + `mode=epic` rows enter epic mode; the PM's `epic:run-ready` label is the authorization.
- **Don't file child GH issues from epic mode** — slices live in the state file (existing pre-v3 children are adopted, not duplicated).
- **Don't narrate an epic run in GH comments** — exactly two comments per epic: claim + completion digest. Everything else goes in the state file.

## After claim

You're now responsible for the ticket until you `/agent-harness:finish` it. **Stay in the worktree (`$WORKTREE`) for every subsequent edit, run, commit.** If you find yourself in any other directory, `cd "$WORKTREE"` first.

## An approval covers the render that was signed off — nothing later

A pixel approval names the exact evidence it was given against — the render SHA
and the file set on the PR body. **Any** later change to what renders — a review
round, a fix, a rebase that moves pixels — voids it. Re-capture, put
before/after on the PR, and ask again. Never clear the hold label
(`$HOLD_LABEL`) by citing an approval of an earlier render.

A resume brief may carry an approval forward only for commits that change no
pixels, and must say so.

Written down because it was broken: a design pass removed a control in a review
round AFTER the renders that still showed it were approved, the hold was cleared
by citing that earlier approval, and the owner found out on the test
environment. Where a project's approval gate enforces this it re-applies the
hold as soon as the PR pushes anything that changes what a user sees, skipping
merge commits so a routine catch-up does not void an approval.

## Chain straight into the work — and through to /agent-harness:finish — without stopping

**`/agent-harness:claim` is not "claim and wait for instructions."** Claiming a ticket = committing to ship it end-to-end in the same session. Once the spec is summarised:

1. Read every AC checkbox + the "How to verify" section.
2. Implement until every AC is met. Run lint/typecheck/tests as you go.
3. **When you believe the AC is fully met, immediately invoke `/agent-harness:finish`.** Do NOT stop and ask the user "should I finish?" — that's the question the AC list already answered.
4. `/agent-harness:finish` will gate-check (re-walks every AC + runs gates + AC catches mistakes), so if you're wrong about being done, `/agent-harness:finish` refuses and surfaces back. That's the safety net.
5. Only stop for the user when:
   - An AC is genuinely impossible without a PM call (clarification on intent, missing assets, third-party blocker)
   - A non-trivial scope change is needed (the ticket is wrong / out of scope / too big)
   - A gate fails repeatedly and you can't fix it
6. Otherwise: **claim → code → /agent-harness:finish → done. One session. No mid-flow check-ins.**
7. **Every one of those stops ends with the sign-off banner** — and so does the ordinary
   finish. Read `${CLAUDE_PLUGIN_ROOT}/shared/agent-signoff.md`. The scope is the ticket's primary
   `project:` or `area:` label, written to disk in Step 10 below:

   ```
   🏷️ Working on: Content Lab (project:content-lab)
      Paused on: you — the AC needs a call on whether drafts expire
      Also running: 2 agents on Welcome Flow
      Resume: answer here and I carry on — the worktree stays claimed
   ```

   Line 2 is the one that matters when you stop early. "Paused on: you — <the actual
   question>" is what stops the operator starting a second agent on the same ticket; "blocked"
   is what makes the operator start one.

The PM should never have to type `/agent-harness:finish`. If you're a coding agent that finished the work, run `/agent-harness:finish` yourself. Stopping at "I think I'm done, want me to finish?" defeats the entire workflow — the user has been burned by features that landed on develop but never made it to UAT because someone forgot to type the next command.

If you hit a blocker, release the claim (`"$CL" release "$TICKET_KEY"`) and surface it — don't squat on a ticket you aren't building. If the blocker needs a human, park it properly instead: push, draft PR, resume brief, label, release.
