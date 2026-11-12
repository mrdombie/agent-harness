# Report template

Coverage first, gaps second, method's-own-verdict last. Tables over prose throughout.

````markdown
# Flow-coverage audit — <surface or sequence name>

**Job audited:** <the one line handed to the cartographer, verbatim>
**Screens in scope:** <routes, as one sequence>
**Pinned at:** `<integration branch>` @ `<sha>` · <YYYY-MM-DD>
**Method:** blind derivation → static check. Reachability not verified (no rendered leg).

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
| **Total** | | | | | | |

<One line: what the shape of that table says. Which axis is thinnest, and whether the
thin axis is thin because the screen is good there or because nobody looked.>

## The gaps

Severity order — STRANDS, then LIES, then SILENT, then ROUGH.

### GAP-01 · STRANDS · <short name>
**Axis:** <N Axis-name (sub-case)> · <[CORE] | [EDGE]>
**The move:** <concrete steps a person takes, from a state that is easy to reach>
**What happens now:** <observable outcome, with proof>
**What should happen:** <one sentence>
**Evidence:** `path:line`, `path:line`

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
- **"Did the method work" is not optional.** It is what stops a bad run being read as a clean
  surface.
