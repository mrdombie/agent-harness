# driver/ — the script drives, the model thinks

`build-ticket <ticket>` runs one ticket from the claim to the hand-off. It walks
seven fixed steps in order and calls a model only for the steps that need
thinking, one step at a time, each with its own short brief.

```
driver/
├── build-ticket    the walk: in order, resumable, parks at any refusal
├── driver-env.sh   where things are, the seams, and the exit codes
├── state.sh        the run record — what has to survive the process that wrote it
├── ai-step.sh      the one place control is handed to a model, and checked after
├── steps/          start · plan · build · self-check · review · record · ship · park
└── tests/          every step and every refusal
```

## Why this exists

Measured on the project this was extracted from, 2026-09-26:

| | |
|---|---|
| Words of instruction before an agent writes a line | 49,657 |
| Runs that used the "mandatory" build steps | 3 of 161 |
| Runs that wrote a test first | 0 |
| Review rejections per screen fix (median) | 7 |

Not one of those is a comprehension failure. Deciding what came next was the
model's job, and a model under pressure decides to get on with it. So the
decision moved into a list in code, and what the model is asked shrank to the
thinking inside one step.

## The seven steps

| # | Step | Who | What it produces |
|---|---|---|---|
| 1 | `start` | driver | the claim, the worktree, the refusal gates |
| 2 | `plan` | model | a plan the driver can enforce, or a question |
| 3 | `build` | model | commits whose test the driver proves red then green |
| 4 | `self-check` | driver | every gate run as its own command, read by exit code |
| 5 | `review` | model | `SHIP`, or blockers with a file and a line |
| 6 | `record` | driver | the verdict, off the reviewer's own file |
| 7 | `ship` | driver | push, draft pull request, ready, auto-merge, hand off |

`park` is not in the order. It is the exit from every other step: push, draft
pull request, resume brief, hold label, release the claim — in that order,
because an unpushed branch is the only thing a park can lose and a claim
released early is a ticket a peer can take against a branch that is not there.

## What the driver guarantees with its own hands

- **Test-first is proved, not asked.** The build step reports, per item, the
  commit that added the test and the commit that made it pass. The driver checks
  out the change's parent with that test copied in, runs it, and requires it to
  **fail**; then runs it at the change and requires it to **pass**. A test whose
  selector matches nothing, whose assertion is true of any tree, or which reads a
  file instead of running the code is green at the parent, and all three fail here.
- **The named Skill actually ran.** Each brief's front matter names one Skill.
  The driver reads the run's transcript and parks the ticket when that Skill call
  is absent. Inside a ticket Superpowers does the work; the driver never starts
  several agents on one ticket itself.
- **Every gate runs, and its exit code is the verdict.** One gate, one command,
  never batched — a gate batched with anything else reports on the shell reaching
  that line. Nothing configured is a refusal, not a pass.
- **At most two review rounds.** Then the pull request ships and whatever is left
  becomes its own ticket, carrying the finding verbatim.
- **Verdicts are the reviewer's.** `record` reads the review step's own file and
  takes no verdict from an argument. A trailer an agent writes for itself is
  indistinguishable from one a reviewer earned.
- **Nothing is lost on a stop.** Each finished step is written to the record
  before the next one starts, so a killed run resumes at the one after it.
- **It asks rather than guesses.** Any step may answer with a question instead of
  an answer; that parks the ticket with the question on it.

## The briefs

The AI steps read `briefs/<step>.md` at the kit root — a separate deliverable, so
`DRIVER_BRIEFS` points there rather than inside this folder. A brief is our
project facts, the Superpowers skill to invoke, and the JSON it must hand back.
The driver validates that answer against `briefs/schemas/<step>.json` **when that
file exists**; absent is normal and not an error.

Superpowers is **called, never copied**. A brief that restates a skill's content
is a copy that drifts and loses every upgrade.

## Exit codes

They are the whole control flow, so they are named once, in `driver-env.sh`:

| | |
|---|---|
| 0 | the step finished |
| 20 | the step asked a question — the ticket parks with it |
| 21 | the brief named a Skill and the transcript does not show it |
| 22 | the answer did not match its schema |
| 23 | there is no brief for this step |
| 24 | a refusal gate said no |
| 30 | the reviewer found blockers — back to the build step |

`build-ticket` itself exits 0 when the walk completes, 20 when it parked, and 2
when the call or the configuration was wrong.

## Seams

Every call out of the process is overridable, for the same reason the swarm
layer's are: eight scripts that shelled out inline could not be tested at all.

| | |
|---|---|
| `DRIVER_CLAUDE` | the agent runner (default `claude`) |
| `DRIVER_STEPS` | the order, one name per step |
| `DRIVER_STEPS_DIR` | where the step files are found |
| `DRIVER_BRIEFS` · `DRIVER_SCHEMAS` | the briefs and their schemas |
| `DRIVER_MAX_BUILD_TRIES` · `DRIVER_MAX_REVIEW_ROUNDS` | the two ceilings |
| `SWARM_GH` · `SWARM_NOW` | inherited: the GitHub CLI and the clock |

This layer sits **on** `swarm/swarm-env.sh` rather than beside it. The swarm
already resolves the state directory, the project's labels, the GitHub seam and
the clock; a second copy of that resolution is a second thing to keep in step,
which is the drift this whole change exists to remove.

## Running the tests

```bash
for t in driver/tests/*.test.sh; do bash "$t"; done
```

The suite tests the orchestrator twice over: against recorded steps, which is how
a control-flow question gets a clean answer, and against the real seven for one
whole pass — a real repository, a real origin, real commits whose test goes red
then green, with a transcript standing in only for the model. A suite full of
replicas proves the kit and never the product.
