**Sign-off comes last:** once the owner has signed a PR's screens, push no change to them. Its screens are `design.surfacePaths` plus `design.extraScreens` (`approval-kept.sh screens`); release notes are not screens. A review note that would change pixels becomes a follow-up ticket; a required fix that must change pixels says `pixel-change-after-signoff: <why>` in its commit message, and the pre-push guard (`scripts/signoff-push-guard.sh`) puts the hold back on for the owner to sign again.

# Quick change · one session

This ticket was sized **quick**: a change to one or a few files, stated in the
ticket, that is config, copy, docs or one small code edit. You make it in this one
session. There is no separate plan, build or proof step after you: the driver runs
this project's fast local gates on your commits, one code review reads the diff,
and the driver opens the pull request.

## Invoke the skill — do not work from this file

Run **`superpowers:verification-before-completion`** before you answer. It owns
how a change is seen to work before anyone says it does.

## What you are given

- The ticket: {{TICKET}}
- Why it was sized quick, and the files it named: {{SIZE}}
- This project: {{PROJECT_FACTS}}

## Make the change the ticket states

1. Make exactly the change the ticket states, in the files it names. Nothing
   beside it: no refactor, no tidy-up in a file you were not sent to.
2. Check it the cheapest way that is still an observation: parse the JSON you
   edited, run the one command the change is about, read the rendered text back.
   Record that command and what it printed in `checked`.
3. Commit it on the branch you are on, with this project's commit and changelog
   convention from the facts above. The driver alone pushes and opens the pull
   request; a push from here is refused.

**If the change is bigger than its size, say so and stop editing.** It needs more
files than it named, a test of its own, a screen, a schema or a migration: commit
what you have and answer `edited` anyway. The driver reads the real diff and moves
the ticket to the full route, with your work kept. Do not stretch a quick change to
cover a full one.

**If the ticket cannot be done as written** (the file or the key it names is not
there, two of its statements disagree), answer `park` with the question, and say
who answers it.

## Return

JSON only, valid against `schemas/quick.json`.

<!-- fields:begin — generated from schemas/quick.json by briefs/return-fields.sh --write quick; edit the schema, never this list -->
Every field the contract has; `additionalProperties` is false, so no other.

- `step` (required): "quick"
- `skills` (required): list of string
- `status` (required): one of "edited", "park"
- `summary`: string
- `changed`: list of string
- `checked`: string
- `changelog`: object
- `changelog.file`: string
- `changelog.skipped`: string
- `question`: string
- `questionFor`: one of "owner", "pm"

Conditional:
- when `status` is "edited": requires `summary`, `changed`, `checked`, `changelog`
- otherwise: requires `question`
<!-- fields:end -->

`changed` lists every file your commits change. `changelog` carries exactly one
key: the entry file you wrote, or the reason this change has none.

A question names who answers it in `questionFor`: `owner` for pixels, a product or
commercial call, or the data model; `pm` for the ticket's shape. Unsure is `owner`.

`skills` lists every skill you invoked; one claimed here and absent from the run
log fails the step.
