---
description: Maktura — reconcile claims/ against live processes and real artifacts on demand, escalating any that died without shipping. Companion to /claim's Step 0c.
---

You are running an on-demand reconciliation of open claim lockfiles.

The queue lives **outside the repo** at `$HOME/.claude/socialhub-tickets/`. Source of truth: `INDEX.tsv` + `claims/` lockfile dirs.

This is the same sweep `/claim` Step 0c runs automatically — on demand, optionally with a tighter idle window.

## Argument

Optional: a number of hours overriding the default 4h idle window. Examples:
- `/release-stale` — sweep with the 4h default
- `/release-stale 1` — escalate anything idle more than an hour
- `/release-stale --dry-run` — report verdicts, change nothing

## Workflow

```bash
CONFIG="$HOME/.claude/socialhub-tickets/config.json"
test -f "$CONFIG" || { echo "config.json missing — re-run scripts/bootstrap-queue.sh from your maktura clone." >&2; exit 1; }
MAIN_REPO=$(jq -r '.repos.maktura // empty' "$CONFIG")
[ -n "$MAIN_REPO" ] && [ -d "$MAIN_REPO/.git" ] || { echo "config.json has no valid maktura path — re-run scripts/bootstrap-queue.sh." >&2; exit 1; }

# Optional: tighter idle window for this sweep (default 4h)
TOOLS_SHA=$(git -C "$MAIN_REPO" rev-parse --short origin/develop)
TOOLS_BASE="${TMPDIR:-/tmp}"; TOOLS="${TOOLS_BASE%/}/maktura-tools-$TOOLS_SHA"
[ -d "$TOOLS" ] || { mkdir -p "$TOOLS" && git -C "$MAIN_REPO" archive origin/develop scripts | tar -x -C "$TOOLS"; }
STALE_HOURS="${1:-4}" "$TOOLS/scripts/reconcile-claims.sh"

# Refresh INDEX.tsv so /claim sees the new state
node ~/.claude/socialhub-tickets/scripts/rebuild-index-from-github.js >/dev/null

# Forensic trail
ls -lt ~/.claude/socialhub-tickets/claims/.recovered/ 2>/dev/null | head -10
```

**One reconciler runs here.** #8716 taught `reconcile-claims.sh` to read
`refs/claims` directly, so it now answers both questions itself — is the holder's
process alive, and if not, what did the claim leave behind? — and
`reconcile-claim-refs.sh` was retired. Two commands went on calling the retired
path for a day after it moved.

Crucially it will **not** release a ticket that has an open PR or a pushed
branch back to `ready`. On 2026-08-07 that distinction mattered 6 times out of
11: those tickets looked abandoned but held real work, and releasing them would
have had fresh agents rebuild all six from scratch.

It has one blind spot left, so keep it in mind when reading a verdict: a claim
taken minutes ago that has no branch yet has no evidence to fall back on, so it
rests entirely on the recorded pid being right. That pid used to be a tool-call
shell's `$$`, which is dead by the next call — the reason live tickets were
being handed to other agents mid-build.

**Run `--dry-run` first** whenever you're sweeping with a tightened window. It prints the same verdicts and changes nothing, so you can see what a `STALE_HOURS=1` sweep would escalate before it does.

## What reconciliation does

For each `claims/<TICKET>.lock/`, it checks three sources that must agree:

1. **the lock** — does `meta.json` exist with a `ticket` and `claimed_at`?
2. **the process** — `meta.run_id` → `runs/<id>.json`; is that pid alive, and is there a `runs/<id>.ended` marker?
3. **the artifact** — commits on the remote branch, PR state, a row in `MERGED.tsv`

| verdict | meaning | action |
|---|---|---|
| `WORKING` | process alive, or artifact touched inside the window | left alone |
| `ORPHAN` | already shipped, lock left behind | released quietly |
| `FAILED` | process died without shipping, or artifact idle past the window | escalated |
| `MALFORMED` | `meta.json` missing or has no `claimed_at` | escalated immediately |

**Claim age is not a staleness signal.** A ticket claimed three days ago whose branch was pushed an hour ago is being worked on; one claimed this morning by a dead process is not. Only artifact freshness and process liveness separate them.

Escalation moves the lock to `claims/.recovered/<TICKET>-<verdict>-<timestamp>` (forensic trail; **never deleted**) and flips the GH issue to `status:needs-human` with the agent's own last words pulled from its run log.

A `FAILED` claim whose PR reads `DIRTY` or `cancelled` usually holds a finished, unpushed develop-merge in its worktree — check it is not superseded, then push it rather than rebuild.

`MALFORMED` exists because a lock with no usable `meta.json` could never be aged out by the old `recover-stale-claims.sh` — it read `claimed_at` from a file that wasn't there and skipped the lock forever. Those tickets stayed claimed permanently.

## Why `needs-human` and not `ready`

The old recovery flipped straight back to `status:ready`, so the next agent picked the ticket up and — if the cause was the ticket rather than the agent — failed exactly the same way. `status:needs-human` stops that loop. Someone reads the escalation comment, works out the cause, and flips it back deliberately.

## What it does NOT do

- **Doesn't touch a claim whose process is alive** — pid liveness beats every other signal
- **Doesn't delete worktrees** — they stay in `${TMPDIR:-/tmp}/...` so a recovering agent can still `/finish`
- **Doesn't escalate an already-merged ticket** — that's `ORPHAN`, released without noise
- **Doesn't fail the run when it escalates** — it always exits 0, so a stale claim never blocks a fresh one

## When to use it

- A claim has been sitting with no PR and you want it surfaced now rather than at the next sweep
- After a machine restart or a crash, to reconcile everything that was in flight
- Before a big claiming session, to clear out anything that died overnight

## Output

One line per lock with its verdict, then a summary count. Surface the escalations to the user; `WORKING` lines are noise unless they asked for the full picture.
