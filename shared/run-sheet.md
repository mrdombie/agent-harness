# The run sheet — "where is this work up to?"

Every reporting flow renders this block. **One list, every ticket, in the order it gets
done, with its state on the left.** It replaces the bucket-per-state render — `NEXT UP`,
`IN FLIGHT`, `WAITING ON A HUMAN`, `BLOCKED BY ANOTHER TICKET`, `DONE` — that those flows
printed before.

WHY: the buckets held all the same information and made the operator reassemble the running order
in his head from five lists. He asked for the order itself, chose this shape on
2026-09-13, and the ask was explicitly about presentation, not about missing data.

## The block

```
📋 PROGRAMME NAME — 5 of 16 done · 18% by effort · 4 unestimated

 ✅ ┬ Verdict-grain guard stopped covering the refactor        8580
 ✅ ├ The hourly split-test pass loads every running test      8175
 ✅ ├ Index the split-test lineage column                      8729
 ✅ ├ Auto-fork spawns orphan running split-tests              7191
 ✅ ├ Dead-controls test asserts wiring by name only           8307
 🔨 ├ Split-test stage navigates to a hardcoded route          9609  ◀ here
 ⬜ ├ Relocate variant rules and hypothesis tags into the lab   5478
 ⬜ ├ A run row starting with a blank line renders empty        8707
 ⬜ ├ Fire auto-fork lineage from the UI                        4685
 🚧 ├ Variant tree rich interactions                           278   ◀ waits on 5478
 🙋 ├ Image analysis in the split-test rail                     9003  ◀ needs a spec from you
 🙋 ├ A persona selector on the lab home                        8818  ◀ needs pixels approved
 🙋 ├ An above/below-median filter on the lab home              8817  ◀ needs pixels approved
 🙋 ├ Variant rules are authorable but never enforced           5268  ◀ enforce or relocate?
 🙋 ├ Compose and variant lab analysis                          408   ◀ no spec, never scoped
 🙋 ┴ What the lab still needs before it is sellable            5065  ◀ no spec, never scoped
```

## The order — this is the whole point of the block

Top to bottom is the order the work happens in. Build it once, then render it:

| Band | Contains | Sorted by |
|---|---|---|
| 1 | **done** | `closedAt` ascending — the real history, oldest first |
| 2 | **now** | claimed on this machine, or an open PR |
| 3 | **next** | the dependency order from `/project` Step 3 — topological, then P0→P3, then effort ascending |
| 4 | **held** | what each waits on |
| 5 | **you** | what each needs from the operator |

Bands 1 and 2 are history and present; they are not re-sorted by priority. **A ticket
appears exactly once.** Its band is its state, so there is nothing left to put in a
second list.

## The glyphs

Fixed set, fixed meaning, and every one of them is a **double-width emoji** — mixing in a
narrow glyph or a variation-selector one (`▫️`, `⏸️`) shifts every column to its right by a
cell and the rail stops being a rail.

| Glyph | State | Means |
|---|---|---|
| ✅ | done | merged and closed |
| 🔨 | now | a live claim ref, or an open PR — being built |
| ⬜ | next | runnable, in dependency order |
| 🚧 | held | blocked by another ticket |
| 🙋 | you | waiting on the operator — gated, drafting, pm-track, needs-approval |

## The rail and the marker

- `┬` on the first row, `┴` on the last, `├` on everything between. One column, never
  branching — this is a sequence, not a graph. Dependencies are said in the marker.
- **`◀ here` sits on the 🔨 row** and nowhere else. It is the "you are here" and there is
  at most one; two live claims on one subject is a finding, not a render — say so in
  `NEEDS ATTENTION`.
- **Every 🚧 and 🙋 row carries a marker saying what it waits on**, in plain English.
  `◀ waits on 5478` for a ticket, `◀ needs pixels approved` for the operator. A held row with no
  marker is the bucket render with worse layout — it is exactly the question the operator would
  have to ask next.
- ✅ and ⬜ rows carry no marker. Their state is the marker.

## The rows

- **Plain English, what the ticket does.** Strip `feat(x):` / `fix(x):` / `design(x):` /
  `chore(x):`, strip a leading `Watch:` / `Feed hero:` area restatement, strip the
  trailing `(#8461 D3)` provenance. Same rule as every other table in the estate.
- **Cut at 54 characters on a word boundary, ending `…`.** The column has to hold or the
  rail breaks. A title that cannot survive 54 characters is usually a title that never
  said what the ticket does — worth fixing at the ticket, not here.
- **The reference goes last and is bare** — `8580`, never `#8580`, never a URL. It is a
  lookup key, not the content.
- **Never a bare ticket number anywhere else in the block.** Prose above and below it
  names the work.

## Show all of them

**Every ticket in the set, every time. No cap, no window, no collapsed tail.** the operator chose
this on 2026-09-13 over collapsing the done rows: a 36-row programme scrolls, and that is
the correct cost. A truncated run sheet is the thing this block exists to stop — he is
reading it precisely to see how much is behind and how much is ahead.

The one exception is **MODE=AREA** in `/project`: an area has no finish line and 261
closed rows help nobody. There, band 1 is a count on the header line and the rail starts
at 🔨. Say so on the header: `261 closed all-time`.

## The header line

```
📋 <SUBJECT IN CAPS> — <done> of <total> done · <N>% by effort · <N> unestimated
```

The figures come from `/project` Step 4 and its rules hold unchanged: effort-weighted,
never a bare ticket count, and **never a percentage without the unestimated count beside
it**. For MODE=AREA it is `<N>% of open work runnable`, never a completion figure.

## A code block, not a markdown table

The rail is fixed-width, so it ships inside a fenced block. A markdown table re-wraps the
title column at the terminal's width and the rail turns into ragged pipes.

## Who renders it

| Command | Where | Scope |
|---|---|---|
| `/project <subject>` | replaces Step 5's five sections | the whole subject |
| `/work` | its close, and every pause for a decision | the resolved label |
| `/auto` | its close | the labels it took from this run |
| `/standup` | replaces its four state tables | this session's tickets |

`NEEDS ATTENTION` survives underneath it in `/project` and `/auto` — zombie claims and
orphan branches are not a state a ticket is in, they are a thing to run a command about.
The sign-off banner still comes last, per `~/.claude/shared/agent-signoff.md`.

## Reading the states honestly

- **🔨 comes from the claim ref, never from `status:claimed`.** The label is a mirror and
  goes stale in both directions.
- **`claim-lock.sh list` lies by default.** Outside a git repo it writes the reason to
  stderr and still exits 0 with an empty list, so every 🔨 row silently disappears. Always
  hand it the repo:

  ```bash
  CLAIM_REPO="$MAIN_REPO" "$KIT_ROOT/scripts/claim-lock.sh" list --json
  ```

  Measured twice: a bare call returned `no live claims` against **nine** live ones
  (2026-09-09), and a call made from inside another checkout returned **none against
  four** (2026-09-24). The resolver now prefers an explicit `CLAIM_REPO` over the
  directory you happen to be standing in, and a bare repository no longer stops it —
  but the reading rule outlives either fix: **an empty list you did not ask a named
  repo for is UNKNOWN, never zero.**
- **Query the slug in `harness.json`, never an old name.** A renamed repo still answers
  unfiltered calls through its redirect, but `--label` through that redirect returns `0`
  silently — which renders as a programme with no tickets rather than as an error.
- **Every row comes from a read taken in THIS turn.** The session's own merges are what
  make the sheet stale, so the rows most likely to be wrong are the ones you just moved.
