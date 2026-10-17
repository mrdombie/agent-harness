# Repair · a red or clashing pull request

This pull request was built, pushed and handed off, and it then went red, began
to clash with the integration branch, or came back with a brief (an owner's
answer, a merge lane's note). You are repairing it on its own branch. You
are not rebuilding the ticket: the plan, the build and the earlier review stand,
and this step changes only what the failure needs.

## Invoke the skill — do not work from this file

Run **`superpowers:systematic-debugging`** on the failure before you change
anything, and **`superpowers:test-driven-development`** for any fix that changes
behaviour. Those skills own the method. This brief owns what the driver needs back
and the traps this project keeps falling into.

## What you are given

- The ticket: {{TICKET}}
- Why this repair was sent, verbatim from whoever sent it: {{BRIEF}}
- The pull request and its branch: {{PR}}
- The checks that settled red: {{FAILING}}
- The merge of the integration branch, and what conflicted: {{CONFLICTS}}
- The change as it stands, against the trunk: {{DIFF}}

The worktree is already on the PR's branch at origin's head. When the PR
clashed, the driver has already run the merge. A clean merge is committed. A
conflicted merge is left in progress for you, with the conflicted files listed
above.

## The order

1. **Read the brief's own instructions first.** Sometimes it carries a ruling
   from a person, and that ruling wins.
2. **A conflict:** resolve each file so that BOTH sides' intent survives. The
   trunk's change and this PR's change are both wanted. Leave no conflict
   markers, then finish the merge with `git commit --no-edit`. Do not rebase and
   do not force-push. The driver pushes a plain fast-forward of this branch.
3. **A red check:** read the failing job's own log (`gh run view <id>
   --log-failed`) and reproduce the failure locally before you touch any code.
   A failure you could not reproduce is a question, not a guess.
4. **The same failure on the integration branch itself is not this PR's to
   fix.** Park and say so.
5. **Fix only what failed.** Do not refactor, rename or improve anything nearby.

## Every fix carries its proof

- **A fix that changes behaviour gets a test.** Commit the test that goes red
  first, then the fix, as two commits. Report `proof: "test"`, the test, the
  command and both shas. The driver re-runs that test at the fix's parent and at
  the fix. A test that is green before the fix is refused.
- **A fix no test can pin** (a lint rule, a type error, a lockfile, a merge
  resolution that only needed to compile) is `proof: "gate"`. It names the gate
  command that was red and is now green, and says in `noTestBecause` why no test
  can pin it. The driver runs that command and reads its exit code, and every
  local gate runs after this step.

Commit everything. An uncommitted change is a change the gates never read.

## A test you reword or remove is accounted for

If you remove, reword or skip an `it(`/`test(` case, list its file in
`replacedTests` with exactly one of `coveredBy` (a bare path to the test that
now pins it) or `removedBecause`.

## Return

JSON only, valid against `schemas/repair.json`.

- `status: "repaired"` carries the root `cause` in a line, one `fixes` entry per
  fix with its proof, and one `conflicts` entry per file that conflicted.
- `status: "unchanged"` carries the `reason` in a line, and only when the brief
  is already met: nothing red, nothing clashing, and nothing committed. A red
  check or a conflict is never answered unchanged.
- `status: "park"` carries the `question` a person can answer in a line — for
  example, a failure that is the trunk's, a check you could not reproduce, or a
  conflict whose two sides cannot both be kept.

`skills` lists every skill you invoked. The driver reads the run log too, so a
skill claimed here and absent there fails the step.
