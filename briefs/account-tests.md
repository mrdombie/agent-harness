**Sign-off comes last:** once the owner has signed a PR's screens, push no change to them. Its screens are `design.surfacePaths` plus `design.extraScreens` (`approval-kept.sh screens`); release notes are not screens. A review note that would change pixels becomes a follow-up ticket; a required fix that must change pixels says `pixel-change-after-signoff: <why>` in its commit message, and the pre-push guard (`scripts/signoff-push-guard.sh`) puts the hold back on for the owner to sign again.

# Step 7b · Account for the deleted tests

This branch deletes tests, or drops cases from them, and nothing on the record
says why. The pull request cannot ship until each file has one line. You edit
nothing, run nothing and start nothing in this step: you only say, per file,
what now pins its behaviour or why the behaviour is gone.

## What you are given

- What the deleted-tests check refused, file by file, with the cases each lost: {{FILES}}
- The change's test files, and its shape: {{DIFF}}

## One row per file the check names

For each file the check lists, give its path exactly as the check prints it and
exactly one of:

- `coveredBy`: a bare repo-relative path to a test file at head with a live case
  that now pins the same behaviour. Open it with Read, Grep or Glob and find that
  case before you name it.
- `removedBecause`: one line on why the behaviour is gone, from the diff or the
  code. "Obsolete" alone is not a reason; say what went.

When you cannot find a test that pins a lost case, the answer is `removedBecause`
saying so, never a guess at `coveredBy`. A file with no row stops the ship: the
ticket parks with that file named.

## Return

JSON only, valid against `schemas/account-tests.json`.

<!-- fields:begin — generated from schemas/account-tests.json by briefs/return-fields.sh --write account-tests; edit the schema, never this list -->
Every field the contract has; `additionalProperties` is false, so no other.

- `step` (required): "account-tests"
- `skills` (required): list of string
- `replacedTests` (required): list of object
- `replacedTests[].file` (required): string
- `replacedTests[].coveredBy`: string
- `replacedTests[].removedBecause`: string
<!-- fields:end -->

`skills` is empty: this step runs no skill.
