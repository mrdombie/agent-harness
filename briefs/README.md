# briefs/ — one short brief per AI step

The driver runs a ticket's steps in a fixed order and calls the AI only for the
steps that need thinking. This directory is what it hands the AI, and what it
checks the answer against.

```
briefs/
├── facts.json        the contract with the driver: per step, its brief, its
│                     schema, the skills it invokes, every placeholder to fill
├── plan.md  build.md  compare.md  review.md  fix.md
├── schemas/<step>.json   the JSON the answer is validated against
├── examples/<step>.valid*.json  ·  <step>.invalid-*.json
├── validate.sh       the one validator; the driver calls it
└── tests/            both suites
```

## What a brief is, and is not

A brief carries three things: **this project's facts**, **which Superpowers skill
to invoke**, and **the JSON contract**. It carries nothing else.

It does not restate a skill's content. Superpowers is called, never copied — a
copy drifts and loses every upgrade the skill gets. `tests/briefs.test.sh`
enforces that two ways: a 900-word ceiling per brief, and a probe that fails when
a brief shares a run of twelve consecutive words with any `SKILL.md` it names.

`superpowers:brainstorming` is not invocable here. It waits on a person, and no
unattended step can. The approved spec stands in for it; `facts.json` records
that under `notInvoked`.

## Sending a brief

For each step, read `facts.json`:

- `brief` — the file to send.
- `facts` — every `{{PLACEHOLDER}}` in that file, with what belongs in it.
  Substitute all of them before sending; only `UPPER_SNAKE` is substituted, and a
  placeholder left unfilled reaches the model literally.
- `skills` — what the brief tells the AI to invoke. Cross-check this against the
  `Skill` calls in the run's log, not only against the answer's own `skills`
  array. A step that returns the right JSON without invoking the skill has not
  run the step.

Project facts come from the consuming repo's `.claude/harness.json`. Nothing in
this directory names a project.

## Checking an answer

```
briefs/validate.sh <step> <answer.json>
```

| Exit | Meaning |
|---|---|
| 0 | the answer meets the contract |
| 1 | it does not — the AI's answer is wrong |
| 2 | the check could not be made: no step, an unknown step, a missing file, a schema that does not parse, a validator that could not be reached |

Two codes would make those last two indistinguishable, and a validator that
answers 0 when it validated nothing reads exactly like one that validated
everything.

`BRIEFS_AJV` overrides the validator, so a machine with the tool installed pays
no download. `BRIEFS_SCHEMAS` overrides where the contracts are read from, which is
how the driver calls this with its own `DRIVER_SCHEMAS` instead of re-deriving it.

`$AJV` is a **launcher** by default, and npm exits 1 for an unfetchable package, an
unreachable registry and a cold `only-if-cached` alike — indistinguishable from
ajv's own "the data is invalid". Measured: all three come back as 1. ajv names the
data file on its verdict line and npm never does, so that line is what separates a
verdict from a failure to reach one, and everything else becomes an exit 2.

### Call this, rather than re-deriving it in the caller

There is no npm dependency to take. `npx --yes ajv-cli@5` is fetched on demand
and nothing is added to any manifest, and `BRIEFS_AJV` points at an installed
copy where one exists. So the reason to hand-roll a checker in the caller — that
the kit cannot depend on a validator — does not apply.

It matters because the strictness is not in `required`. It is in
`additionalProperties: false`, in nested `required`, in `failedBefore` pinned to
`true`, and in the `if`/`then` that refuses `SHIP` beside a blocker. A checker
reading only top-level `required` and top-level types accepts **19 of the 24
invalid examples in `examples/`** — measured, by running one over them — among
them a build whose test passed before the change, and a review that ships with
blockers open. Those two are the guarantees the driver exists to make.

`driver/ai-step.sh` hand-rolled exactly that checker and shipped with it once.
It now calls this script, and `driver/tests/ai-step.test.sh` holds each of the four
rules above as its own case.

## Adding a step

1. `schemas/<step>.json` — draft-07, `additionalProperties: false`, requiring
   `step`, `skills` and `status`. Make the schema refuse the shape the step
   exists to prevent; that is where its value is.
2. `examples/<step>.valid.json` and at least one `examples/<step>.invalid-*.json`.
   The suite demands both by name: a step with no invalid example proves nothing
   about the schema's strictness, and silence would read as a pass.
3. `<step>.md` — the brief, naming the skill and the contract.
4. `facts.json` — the step's entry, with every placeholder the brief uses.

Both suites are run by CI and by `bash briefs/tests/schemas.test.sh` and
`bash briefs/tests/briefs.test.sh`.
