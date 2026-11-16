**Sign-off comes last:** once the owner has signed a PR's screens, push no change to them. Its screens are `design.surfacePaths` plus `design.extraScreens` (`approval-kept.sh screens`); release notes are not screens. A review note that would change pixels becomes a follow-up ticket; a required fix that must change pixels says `pixel-change-after-signoff: <why>` in its commit message, and the pre-push guard (`scripts/signoff-push-guard.sh`) puts the hold back on for the owner to sign again.

# Step 4b · Simplify, once

The change is built and its gates are green. Before review, clean it up once.
You are in the session that built it, so you already know it.

## Invoke the skill

Run **`simplify`** through the Skill tool, once, on this change's diff against
{{TARGET}}. It owns the clean-up; this brief owns the limits.

## What it may change

- Only files this change already touches. Nothing outside the diff.
- Reuse, simplification and efficiency. Never behaviour: what the code does,
  returns, prints or writes stays the same.
- Never a test's assertions, and never delete a test. A test file may be tidied
  only where its cases still check the same things.
- Never a screen after its sign-off (the rule at the top).

Found nothing worth changing? Change nothing. That is a good answer.

## How the driver takes it

Commit each clean-up on the branch. Push nothing. The driver then runs the fast
gates on the new head: green, the commits stay; red, every commit from this step
is dropped and the change goes to review as it was. Run nothing yourself but
what the skill runs.

## Return

JSON only, valid against `schemas/simplify.json`.

<!-- fields:begin — generated from schemas/simplify.json by briefs/return-fields.sh --write simplify; edit the schema, never this list -->
Every field the contract has; `additionalProperties` is false, so no other.

- `step` (required): "simplify"
- `skills` (required): list of string
- `changes` (required): list of object
- `changes[].file` (required): string
- `changes[].what` (required): string
- `notes`: string
<!-- fields:end -->

One entry in `changes` per clean-up committed: the file, and one line on what
was removed or simplified there. Empty when nothing changed. `skills` lists
every skill you invoked.
