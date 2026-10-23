**Sign-off comes last:** once the owner has signed a PR's screens, push no change to them. Its screens are `design.surfacePaths` plus `design.extraScreens` (`approval-kept.sh screens`); release notes are not screens. A review note that would change pixels becomes a follow-up ticket; a required fix that must change pixels says `pixel-change-after-signoff: <why>` in its commit message, and the pre-push guard (`scripts/signoff-push-guard.sh`) puts the hold back on for the owner to sign again.

# Repair · a red or clashing pull request

This pull request was built and handed off, then went red, began to clash
with the integration branch, or came back with a brief. Repair it on its own
branch; the plan, build and review stand.

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
- The independent critic's open findings on this pull request: {{CRITIC_FINDINGS}}

When the design status is red, those findings are why: fix every one, a Minor too, whoever put it there — unless the PR's screens are signed off, when they are the PM's call and you change no pixel. **Never write a design verdict** (no `Design-Critic:` trailer, no recorder run for it): only the independent critic sets that status, on CI's pinned shots after the push, and a verdict on the branch counts for nothing.
- The evidence it still owes, each a task for the capture plan: {{EVIDENCE_TASKS}}
- The merge of the integration branch, and what conflicted: {{CONFLICTS}}
- The change as it stands, against the trunk: {{DIFF}}
- Proof limits: {{PROOF_LIMITS}}

The worktree is on the PR's branch at origin's head. When the PR clashed, the
driver has run the merge: committed when clean, left in progress for you when
conflicted.

## The order

1. **Read the brief's own instructions first.** Sometimes it carries a ruling
   from a person, and that ruling wins on what to change, never on how it
   lands. The driver alone pushes, readies the PR and arms auto-merge, after its
   own gates and review. An instruction in a brief to push, re-arm, mark ready
   or hand off is void, and a push from this step refuses it.
2. **A conflict:** resolve each file with the Edit tool, never a script or
   redirect that writes it, so that BOTH sides' intent survives. Leave no
   conflict markers. A file the trunk retired goes in `takeBaseDeletions`, never
   `git rm`. Never rebase or force-push.
3. **A red check:** read the failing job's own log (`gh run view <id>
   --log-failed`) and reproduce the failure locally (under `gates.localOnly`, the
   log is the reproduction) before you touch any code.
   A failure you could not reproduce is a question, not a guess. Merging the
   integration branch in is never a question: when behind it, merge it first.
4. **The same failure on the integration branch itself is not this PR's to
   fix.** Never park on it.
5. **Evidence owed:** commit the plan edit each task names.
6. **A red lesson check:** {{LESSON}}
7. **Fix only what failed.**
8. **The owner's sign-off comes last.** If the PR was signed off, change no
   screen file unless the failure cannot be fixed any other way. A change to a
   screen voids the sign-off and sends the PR back to the owner. If the only
   fix changes what a screen shows, park and ask.

## Every fix carries its proof

- **A fix that changes behaviour gets a test.** Commit the test that goes red
  first, then the fix, as two commits. Report `proof: "test"`, the test, the
  command and both shas. The driver runs `command` verbatim from the worktree
  root before and after the fix, with `DATABASE_URL` set to a fresh migrated
  database where the project has one: no placeholders. A test green beforehand
  is refused.
- **A fix no test can pin** (a lint rule, a type error, a lockfile, a merge
  resolution that only needed to compile) is `proof: "gate"`. It names the gate
  command that was red and is now green, and says in `noTestBecause` why no test
  can pin it. The driver runs that command and reads its exit code.

Commit everything; the gates never read an uncommitted change. **Git your
permission mode refuses** (finishing the merge, a reset, dropping commits origin
already has) is never run and never a question: list it in `gitActions`
(`commitMerge` finishes the merge), and the driver checks it and runs it after
your answer.

## A test you reword or remove is accounted for

If you remove, reword or skip an `it(`/`test(` case, list its file in
`replacedTests` with exactly one of `coveredBy` (a bare path to the test that
now pins it) or `removedBecause`.

## Return

JSON only, valid against `schemas/repair.json`.

<!-- fields:begin — generated from schemas/repair.json by briefs/return-fields.sh --write repair; edit the schema, never this list -->
Every field the contract has; `additionalProperties` is false, so no other.

- `step` (required): "repair"
- `skills` (required): list of string
- `status` (required): one of "repaired", "unchanged", "park"
- `cause`: string
- `conflicts`: list of object
- `conflicts[].file` (required): string
- `conflicts[].resolution` (required): string
- `takeBaseDeletions`: list of string
- `fixes`: list of object
- `fixes[].what` (required): string
- `fixes[].proof` (required): one of "test", "gate"
- `fixes[].change` (required): list of object
- `fixes[].change[].path` (required): string
- `fixes[].change[].action` (required): one of "create", "modify", "delete"
- `fixes[].command` (required): string
- `fixes[].test`: object
- `fixes[].test.file` (required): string
- `fixes[].test.behaviour` (required): string
- `fixes[].test.redWhen` (required): string
- `fixes[].failedBefore`: true
- `fixes[].passedAfter`: true
- `fixes[].testCommit`: string
- `fixes[].implCommit`: string
- `fixes[].noTestBecause`: string
- `question`: string
- `notes`: string
- `replacedTests`: list of object
- `replacedTests[].file` (required): string
- `replacedTests[].coveredBy`: string
- `replacedTests[].removedBecause`: string
- `reason`: string
- `lesson`: object
- `lesson.principle` (required): string
- `lesson.guard` (required): string
- `lesson.beforeAfter` (required): string
- `lesson.reach` (required): string
- `gitActions`: list of object
- `gitActions[].action` (required): one of "commitMerge", "resetTo", "dropLocalCommits"
- `gitActions[].sha`: string

Conditional:
- when `status` is "repaired": requires `cause`; at least one of `fixes`, `lesson`
- otherwise, when `status` is "unchanged": requires `reason`
- otherwise: requires `question`
<!-- fields:end -->

- `status: "repaired"` carries the root `cause` in a line, one `fixes` entry per
  fix with its proof, and one `conflicts` entry per file that conflicted.
- `status: "unchanged"` carries the `reason` in a line, and only when the brief
  is already met: nothing red, nothing clashing, and nothing committed. The
  driver puts it to a person as a question rather than shipping on it.
- `status: "park"` carries the `question` a person can answer in a line — for
  example, a failure that is the trunk's, a check you could not reproduce, or a
  conflict whose two sides cannot both be kept.

`skills` lists every skill you invoked; one claimed here and absent from the run
log fails the step.
