# Report template

Coverage first, gaps second, method's-own-verdict last. Tables over prose throughout.

````markdown
# Flow-coverage audit — <surface or sequence name>

**Job audited:** <the one line handed to the cartographer, verbatim>
**Screens in scope:** <routes, as one sequence>
**Pinned at:** `<integration branch>` @ `<sha>` · <YYYY-MM-DD>   (a built screen)
**Pinned at:** the story `<http(s)://.../iframe.html?id=...>` · <YYYY-MM-DD>   (a picture)
**Method:** blind derivation → static check. Reachability not verified (no rendered leg).
**Method:** blind derivation → the picture clicked by `flow-checker`. Reachability is what was clicked.

Keep the one **Pinned at** and the one **Method** line that fit, and delete the other.

## Coverage

| Axis | Rows | PRESENT | PARTIAL | WRONG | ABSENT | UNVERIFIED |
|---|--:|--:|--:|--:|--:|--:|
| 1 Entry | | | | | | |
| 2 Actor | | | | | | |
| 3 Intent | | | | | | |
| 4 Data state | | | | | | |
| 5 Failure | | | | | | |
| 6 Repeat & race | | | | | | |
| 7 Exit & aftermath | | | | | | |
| 8 Continuity | | | | | | |
| **Total** | | | | | | |

<One line: what the shape of that table says. Which axis is thinnest, and whether the
thin axis is thin because the screen is good there or because nobody looked.>

## The gaps

Severity order — STRANDS, then LIES, then SILENT, then ROUGH.

### GAP-01 · STRANDS · <short name>
**Axis:** <N Axis-name (sub-case)> · <[CORE] | [EDGE]>
**Rows:** <the ledger row ids this gap is, e.g. X-02>
**The move:** <concrete steps a person takes, from a state that is easy to reach>
**What happens now:** <observable outcome, with proof>
**What should happen:** <one sentence>
**Evidence:** `path:line`, `path:line` — or, on a picture, the clicks and the screenshot that showed it
**Fixed:** <what changed, one line — leave the line out until it is fixed>

<repeat per gap>

## Unverified

Rows where code exists but static reading cannot prove a control reaches it. Each names what
would settle it.

| Row | Claim | What would settle it |
|---|---|---|
| | | |

## Full row ledger

Every expected row and its verdict, including the PRESENT ones — they are the denominator.

| # | Axis | Expected flow | Verdict | Evidence |
|---|---|---|---|---|
| E-01 | 1 Entry | | | |

## Did the method work

<Stated either way, honestly.>

- **Contamination:** <did the expected list contain rows naming behaviour absent from the
  surface? name two. If not, the run is void and say so.>
- **Against the existing inventory:** <did the audit find anything the screen's control inventory
  (where the project keeps one) does not already name? If it only re-found the inventory's own contents, the derivation was
  not blind enough and the taxonomy needs work.>
- **Plant test:** <handler removed, row that moved to ABSENT — or "not run".>
- **Where the taxonomy fell short:** <the axis that produced weak rows, and why.>

## Not covered

<What this audit deliberately did not look at, so nobody reads the coverage number as
totality: no rendered/reachability leg, any route excluded, any actor not modelled.>
````

## Notes on filling it in

- **Do not round the coverage table into a percentage.** A percentage invites a target;
  `ABSENT` counts invite a fix.
- **Keep the PRESENT rows.** Deleting them turns coverage into a list of complaints and makes
  the next run incomparable.
- **The gap row is a test, not a conclusion.** If `The move` is missing, downgrade the row to
  `UNVERIFIED` — a finding nobody can reproduce is a suspicion with formatting.
- **An open STRANDS or LIES gap holds the picture.** `flow-audit.sh gate <report.md>` exits 1
  naming each STRANDS or LIES gap that is not closed. A gap closes only when it has a filled
  `**Fixed:**` line AND every row on its `**Rows:**` line reads `PRESENT` in the ledger. That
  verdict comes from re-running `flow-checker` on the redrawn picture with just those rows
  (`flow-audit.sh brief checker ... --only <ids>`), never from the builder's own note. A gap
  naming no row stays open. SILENT and ROUGH never hold it. A report with no ledger row
  exits 3 — void, never green.
- **"Did the method work" is not optional.** It is what stops a bad run being read as a clean
  surface.
