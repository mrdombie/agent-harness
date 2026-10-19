**Sign-off comes last:** once the owner has signed a PR's screens, push no change to them. Its screens are `design.surfacePaths` plus `design.extraScreens` (`approval-kept.sh screens`); release notes are not screens. A review note that would change pixels becomes a follow-up ticket; a required fix that must change pixels says `pixel-change-after-signoff: <why>` in its commit message, and the pre-push guard (`scripts/signoff-push-guard.sh`) puts the hold back on for the owner to sign again.

# Step 3 · Build, test first

You are building **one** task from the plan. Not the next one, not the ticket.

## Invoke the skill — do not work from this file

Run **`superpowers:subagent-driven-development`** to execute the task, with
**`superpowers:test-driven-development`** inside it. Those two own how the work
is split and how the cycle runs. This brief owns only this project's facts and
what the driver needs back.

The driver runs your new test itself, before your change and after it, and
refuses to continue unless it failed first. It then runs this project's
typecheck on the tree with your change — `driver.proofTypecheck`, else the
typecheck among the `gates` in the project facts below — because a runner that
strips types passes a test the compiler rejects. Run that typecheck yourself
before you answer. That is the enforcement; the rules below are the ones a
passing test can still get wrong.

## What you are given

- The task: {{PLAN_TASK}}
- This project: {{PROJECT_FACTS}}
- The standard a change is held to: {{STANDARDS}}
- The screen rules, when this task touches a screen: {{SURFACE_RULES}}
- Why the last try at this task was sent back: {{LAST_TRY}}
- The screen's polish list: {{POLISH_LIST}}

Read {{STANDARDS}} once for the ticket, not once per file.

## A test that cannot fail is not a test

- **Plant the death, not the typo.** Prove the test by deleting the fix. A test
  proved by mistyping a value measures where a rule lives, not whether it works.
- A test that reads a source file, counts classes, or asserts a string appears in
  a file is not a test of behaviour. It stays green while the feature is dead.
- **Test the wiring at the call site.** A replica of the call proves the kit and
  never the product.

## When the task touches a screen

- **Say each fact once, in one wording.** Look at the whole composed screen before
  adding a line of copy: if a masthead, a band, a chip, a toast or a rail already
  says it, do not say it again — and never say it differently. The most repeated
  review finding in this repo's history, by a wide margin.
- **A state change updates every surface that shows it.** Grep for every place the
  state becomes words or colour and change them together. Missing the third
  surface is the second most repeated finding.
- **A failed read never looks empty, loading or finished.** Every fetch has three
  visible outcomes: loading, failed — which says so and offers a retry — and
  loaded. "Nothing here" is only ever loaded-and-empty.

## The screen's polish list rides along

Fix the items {{POLISH_LIST}} names in this change and record each fixed one with
its command, the item as written. Never tick one: it is ticked when the PR merges.

## A test you reword or remove is accounted for

If you remove, reword or skip an `it(`/`test(` case, list its file in
`replacedTests` (the repo-relative path git shows) with exactly one of `coveredBy`,
a bare path to the test that now pins it, or `removedBecause`. A gate checks them.

## Return

JSON only, valid against `schemas/build.json`.

<!-- fields:begin — generated from schemas/build.json by briefs/return-fields.sh --write build; edit the schema, never this list -->
Every field the contract has; `additionalProperties` is false, so no other.

- `step` (required): "build"
- `skills` (required): list of string
- `status` (required): one of "built", "park"
- `task` (required): string
- `testFirst`: object
- `testFirst.test` (required): object
- `testFirst.test.file` (required): string
- `testFirst.test.behaviour` (required): string
- `testFirst.test.redWhen` (required): string
- `testFirst.command` (required): string
- `testFirst.testCommit` (required): string
- `testFirst.implCommit` (required): string
- `testFirst.failedBefore` (required): true
- `testFirst.redOutput` (required): string
- `testFirst.passedAfter` (required): true
- `testFirst.greenOutput` (required): string
- `changed`: list of object
- `changed[].path` (required): string
- `changed[].action` (required): one of "create", "modify", "delete"
- `surfaces`: list of string
- `changelog`: object
- `changelog.file`: string
- `changelog.skipped`: string
- `question`: string
- `questionFor`: one of "owner", "pm"
- `notes`: string
- `testOnly`: object
- `testOnly.test` (required): object
- `testOnly.test.file` (required): string
- `testOnly.test.behaviour` (required): string
- `testOnly.command` (required): string
- `testOnly.testCommit` (required): string
- `testOnly.break` (required): object
- `testOnly.break.file` (required): string
- `testOnly.break.find` (required): string
- `testOnly.break.replace` (required): string
- `replacedTests`: list of object
- `replacedTests[].file` (required): string
- `replacedTests[].coveredBy`: string
- `replacedTests[].removedBecause`: string

Conditional:
- when `status` is "built": requires `changed`, `changelog`; exactly one of `testFirst`, `testOnly`
- otherwise: requires `question`
<!-- fields:end -->

`testFirst` carries the command, the red output and the green output. Both
`failedBefore` and `passedAfter` are fixed at true in that contract: there is no
shape in it for a change whose test did not fail first, so a task that cannot
produce a red run is a question, not a build.

It also carries `testCommit` and `implCommit`, and they must be two commits. The
driver re-runs your test at the change's parent and at the change, so those two
shas are what make `failedBefore` checkable rather than claimed; one squashed
commit cannot show which came first.

**When the task IS the test** — the code it covers already exists and you change
no production code — return `testOnly` instead of `testFirst`. There is no tree
without the change for such a test to be red at, so the driver proves it by
breaking the code: `break` is a literal `find`/`replace` in the production file
the test covers that deletes the behaviour under test (never the test file, never
a typo). The driver applies it to a copy of `testCommit`, requires the test to
fail, removes it, and requires the test to pass. One of `testFirst` or `testOnly`,
never both.

`changelog` carries exactly one key — the entry file you wrote, or the reason
this change has none. {{PROJECT_FACTS}} names this project's convention. Both
keys, or neither, is refused.

`task` is the title of the plan task you were given, copied as it is written there.
The driver refuses an answer whose title belongs to a DIFFERENT task in the plan,
because a task nobody built is a task that ships unbuilt.

`surfaces` lists every other place that shows the state you changed, and what you
changed there.

A question names who answers it in `questionFor`: `owner` for pixels, a picture,
a product or commercial call, or the data model; `pm` for the ticket's shape —
repo, split, order, acceptance wording. Unsure is `owner`.

`skills` lists every skill you invoked. The driver reads the run log too, so a
skill claimed here and absent there fails the step.
