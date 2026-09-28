---
description: "Maktura — flow-coverage audit. Derives the flows a screen SHOULD have from its job, blind to the code, then hunts each one and reports what's missing. Finds absences a MANIFEST/ui-gate/critic structurally cannot. Usage: /flows <route> | /flows <route> --discover (also derive fresh rows and append the new ones) | /flows <route> <route> ... (a sequence, audited as one unit)"
---

Run a flow-coverage audit over `$ARGUMENTS`.

Invoke the `screen-flow-audit` skill and follow it. `TAXONOMY.md`, `REPORT-TEMPLATE.md` and the
method live in `~/.claude/skills/screen-flow-audit/`.

## Step 0 — pin the tree

```bash
# Resolve the repo the way /claim and /work do. `~/maktura-dev` is NOT on this
# machine — `needsme.md` recorded its absence on 2026-08-30 and `work.md` again on
# 2026-09-09, but this command went on hardcoding it in three places, so Step 0 died
# on `cd` before any audit began. The only clone here is bare, which is fine: a bare
# repo serves `worktree add` exactly as well as a working one.
REPO=$(jq -r '.repos.maktura // empty' ~/.claude/socialhub-tickets/config.json)
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "❌ no maktura repo in config.json" >&2; exit 1; }
git -C "$REPO" fetch origin develop -q || { echo "❌ fetch FAILED — every ABSENT below would be unverified" >&2; exit 1; }
SHA=$(git -C "$REPO" rev-parse origin/develop)
echo "develop @ ${SHA:0:9}  (repo: $REPO)"
```

The fetch is checked, not `|| true`-d. A silent fetch failure makes the audit read a stale
tree and report shipped flows as ABSENT — confident, wrong, and indistinguishable from a real
finding.

Audit a **read-only worktree pinned at that SHA**, never the local checkout — local clones in
this estate run far behind and a stale tree makes a live flow look absent:

```bash
WT="${TMPDIR:-/tmp}/flows-${SHA:0:9}"
git -C "$REPO" worktree add --detach "$WT" "$SHA" -q 2>/dev/null || true
```

Record the SHA. Every verdict in the report is stamped with it.

## Step 0.5 — is there already an instrument for this route?

```bash
SLUG=$(echo "$ARGUMENTS" | tr -d '/' | tr ' ' '+' | sed 's/^dashboard/dashboard-/')
INSTRUMENT=~/.claude/socialhub-tickets/programme-state/flows-${SLUG}.md
[ -f "$INSTRUMENT" ] && echo "instrument: $INSTRUMENT ($(grep -c '^- `[A-Z]-[0-9][0-9]`' "$INSTRUMENT") rows)" || echo "no instrument — this run derives one"
```

**If the file exists, its rows are the row set.** Hand them to the checkers unchanged and
append this run's column to its verdict history. Step 2 runs only in `--discover` mode (below).

### `--discover` — keep asking new questions without losing the old ones

`/flows <route> --discover` runs Step 2 as well: a fresh blind cartographer writes a new list,
and you **append only the rows it found that the instrument does not already ask**, dated.
Nothing is reworded, renumbered or removed. The instrument grows; it is never rewritten.

Dom, 2026-09-19: "we don't want to stop asking questions." Correct — the 19 Sep fresh pass
found rows the 17 Sep pass had not (alt text is asked for per image and no publisher sends it;
Send for approval has no withdraw). The fix is not to stop deriving, it is to stop
*replacing*. Re-check is the progress meter; discover is how the meter gets new dials.

Matching a fresh row to an existing one is a judgement, not a grep: two rows are the same
question if the same code change would move both. When unsure, append — a duplicate row costs
one redundant verdict; a dropped row costs a blind spot. Give appended rows the next free id in
their axis and the date they were added in the row line.

Why. Until 2026-09-19 every run spawned a fresh cartographer who derived a fresh row set from
the same job sentence — 132 rows on 2 Sep, 110 on 17 Sep, 141 on 19 Sep. Different rows each
time, so the numbers were never comparable and "how much is left" had no fixed answer. Measured
on the 19 Sep run: roughly two-thirds of its 48 PARTIAL rows were the 17 Sep run's un-picked
partials under new numbers. The PARTIAL count sat at 48 → 46 → 48 across a fortnight in which
ABSENT fell 44 → 20 → 10, and the flat number was read as neglect when it was the ruler being
redrawn.

Blind derivation is the right tool to BUILD the instrument — a list read off the code inherits
the code's blind spots. It is the wrong tool to READ the instrument twice. Derive to build,
re-check to measure, and derive again only to *extend*.

**Never reword, merge, split or renumber a row in the instrument.** Retire a row (strike it
through, with date and reason) only if the job itself changed. Append new rows with the date
they were added. The file's own header carries these rules.

## Step 1 — name the job, and only the job

**Skip if an instrument exists** — its header carries the job sentence, verbatim. Reuse it. A
re-worded job produces a subtly different row set and breaks comparability the same way a fresh
cartographer does.


Write **one sentence** describing what the screen is for: what state somebody arrives in, what
state they should leave in, and the constraint that matters. No component names, no endpoints,
no step counts, no mention of what is currently built.

If `$ARGUMENTS` names several routes, treat them as **one sequence** and write one job for the
whole thing. The interesting gaps cross screens; a per-screen audit cannot see them.

Show the job line to the PM before spawning. A wrong job produces a confidently wrong audit,
and it is the cheapest thing to correct.

## Step 2 — cartographer (blind) — when no instrument exists, or in `--discover` mode

With no instrument, its output becomes the instrument; in `--discover` mode, only its genuinely new rows are appended (see Step 0.5). First-run format: write the rows to
`$INSTRUMENT` in the format the One Desk file uses (`flows-dashboard-create.md` is the model —
header with the job sentence and the editing rules, a verdict-history table, then one line per
row under its axis heading). Every later run re-checks that file.

Spawn a **fresh** subagent — `general-purpose`, no repo reading. Give it exactly:

- the job sentence
- the full text of `~/.claude/skills/screen-flow-audit/TAXONOMY.md`
- this instruction: *"You have no access to the implementation and must not seek it. Walk each
  of the eight axes and emit numbered expected-flow rows. Do not name any file, component,
  prop, endpoint or variable. Return the rows and nothing else."*

Do **not** write the rows yourself if this session has read any of the surface's code, its
`MANIFEST.md`, or its tickets. That contamination is the one thing the method cannot survive.

## Step 3 — checker

Spawn subagent(s) with the expected rows — from the instrument if one exists, else from Step 2 — and the pinned worktree path. Instruct:

- One verdict per row: `PRESENT` / `PARTIAL` / `WRONG` / `ABSENT` / `UNVERIFIED`, each with
  `path:line` evidence. `PARTIAL` must say which branch.
- **Reach beyond the route folder.** The flows leave it — follow them into the API routes,
  OAuth callbacks, redirects, `next.config.ts` rewrites and shared hooks they touch. A flow
  handled in `apps/api` is `PRESENT`; grepping only `apps/web` and calling it absent is the
  classic false finding here.
- **Never add, merge, split or reword a row.** The row set is the measurement instrument.
- `UNVERIFIED` where code exists but no control can be shown to reach it. Never round that up
  to `PRESENT`.
- Where the verdict rests on "the component probably handles this", the verdict is `ABSENT`.
- Axis 8 continuity: for each thing a step leaves behind, check EVERY route that writes it produces what the read looks for; a dead join never hides as a caveat on a `PRESENT` row.

## Step 4 — report

**First, write back to the instrument.** Append a row to its verdict-history table for this
run (date · pinned SHA · the five counts), and update each row's `**VERDICT** (date) · evidence`
line to this run's verdict. The instrument is the record; the report is a view of it. A run
that publishes a report and does not write back leaves the next run comparing against stale
verdicts.


Fill `REPORT-TEMPLATE.md`. Write it to the scratchpad, publish as an Artifact, then **open the
local file** — a pasted Artifact URL does nothing in VSCode:

```bash
open "<report path>"
```

Read the surface's own `MANIFEST.md` **now, not earlier** — it is the best check on the
checker's `ABSENT` calls and the worst possible input to the cartographer. Anything the audit
found that the manifest does not already name goes in the "Did the method work" section.

## Step 5 — file the tickets

Dom, 2026-09-19: "Can we automate that please; just ask me if you're in doubt." Until this date
the report was the deliverable and the PM picked rows by hand. On 17 Sep that meant 45 of the
73 non-passing rows were picked and 28 were not, and the 28 came back on the next run under new
numbers. So the picking is now automatic and the PM is asked only where there is genuine doubt.

### 5a — group rows into tickets

One ticket per **root**, not per row. Two rows share a root when the same code change would
move both — the instrument's Entry/Continuity and Intent/Exit pairs usually do (E-07 + C-03,
I-21 + X-04, F-15 + F-16). Measured on the 19 Sep run: 48 partial rows → 35 tickets, 14 gap
rows → 13. Name every row the ticket covers in its body.

### 5b — decide, and only ask where there is doubt

| Row | Action |
|---|---|
| `[CORE]` and ABSENT / WRONG | **file** — it is against the bar; no question |
| `[CORE]` and PARTIAL | **file** — a missing branch on a core flow is work |
| `[EDGE]` and any non-PRESENT verdict | **ask** — one batched `AskUserQuestion`, every EDGE row in it, ticket-or-accept per row |
| any row whose checker note says *by design*, *deliberately removed*, *scoped out*, *the dialog says so truthfully* | **ask** — the code took a position; the PM decides whether it stands |
| any row whose fix needs a product call the note cannot settle (which timezone wins, whether Discard should delete) | **ask** |
| a row that already has an open ticket naming its id | **skip** — link the existing one in the instrument |

"In doubt" means one of those three rows, and nothing else. Do not ask about sizing, wording,
or which label to use — decide those. Do not ask row by row; batch every doubtful row into one
question with one option pair per row.

### 5c — file

For every row group that is not `ask` or `skip`, run `gh issue create` with:

- **Title:** `fix(<area>): <the short name from the gap card, or the missing branch in plain
  English>` — `feat(<area>)` when the row is ABSENT and the behaviour is a capability, not a
  defect.
- **Body:** the shape every flow-gap ticket already uses (see #10232): the first line names
  the run, the pinned SHA, the row ids, the axis, the tier and the report URL; then
  `## Inputs → Repro (the move)`, `## What happens now`, `## What should happen`,
  `## Evidence (develop @ <sha>)`, `## Verify` (the move ends in "what should happen" on the
  real route; the next `/flows` run reads the row as PRESENT; a test pins the branch, planted
  by removing the fix once), `## Not in this ticket` (the other rows, each its own ticket).
- **Labels:** `status:ready` — WITHOUT it the board reads the ticket as unspecced and `/claim`
  and `/work` never pick it (the 2026-09-19 batch of 48 was filed without it; 30 sat looking
  unspecced until Dom asked). Then `type:bug` (or `type:feature` for an absent capability), `area:<AREA>`,
  `project:<programme>` when the route belongs to one, `effort:S|M|L` from your own sizing,
  `P1` for STRANDS and LIES, `P2` for SILENT, `P3` for ROUGH. Add `flow-gap` — it is what
  exempts the ticket from the Gate 2 contract check in `/claim`, and it is how the next run can
  find every ticket this one filed.

For every `accepted` answer, mark the row in the instrument: `· accepted <date> — <reason>`.
Never leave a non-PRESENT row with neither a ticket nor an accepted mark.

### 5d — write back

Append the ticket number to each row's line in the instrument (`· #NNNN`), and put the count
filed / accepted / skipped in the verdict-history row for this run. Then say to the PM, in one
block: how many filed, how many accepted, how many were already open — and the one question
if there was one.

## Housekeeping

Remove the pinned worktree when the report is out:

```bash
git -C "$REPO" worktree remove "$WT" --force
```
