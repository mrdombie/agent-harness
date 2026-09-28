# driver/ — the script drives, the model thinks

`build-ticket <ticket>` runs one ticket from the claim to the hand-off. It walks
nine fixed steps in order and calls a model only for the steps that need
thinking, one step at a time, each with its own short brief.

```
driver/
├── build-ticket    the walk: in order, resumable, parks at any refusal
├── driver-env.sh   where things are, the seams, and the exit codes
├── state.sh        the run record — what has to survive the process that wrote it
├── ai-step.sh      the one place control is handed to a model, and checked after
├── push-requires.sh  the reviews this project's own pre-push insists on
├── steps/          start · plan · build · fix · self-check · compare · review · record · ship · park
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

## The nine steps

| # | Step | Who | What it produces |
|---|---|---|---|
| 1 | `start` | driver | the claim, the worktree, the refusal gates |
| 2 | `plan` | model | a plan the driver can enforce, or a question |
| 3 | `build` | model | commits whose test the driver proves red then green |
| 4 | `fix` | model | the review's Criticals and Majors cleared, each proved the same way |
| 5 | `self-check` | driver | every gate run as its own command, read by exit code |
| 6 | `compare` | model | this run's renders held beside the approved design |
| 7 | `review` | model | `SHIP`, or findings with a file, a line and a grade |
| 8 | `record` | driver | the verdict, off the reviewer's own file |
| 9 | `ship` | driver | push, draft pull request, ready, auto-merge, hand off |

`fix` and `compare` are in the order on every pass and are no-ops with nothing to
do — `fix` when no review has found anything, `compare` when the change touches no
screen. Neither is conditionally skipped, because a step that is skipped reports
exactly like a step that passed.

**A rework goes back to `fix`, not to `build`.** Only `fix` reads the review's
answer; rewinding to `build` re-ran the original plan task blind to what the
reviewer had just found, so the two-round ceiling bounded a loop that could not
act. The build step sending ITSELF back is the other case and goes back to
`build`, because `fix` is later in the order and the task is not built yet.

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
- **At most two review rounds.** Then the reviewer stops sending the work back.
  What is **non-blocking** leaves as its own ticket, carrying the finding verbatim
  and the parent's programme label. A **Critical or Major** — a dead control, a broken flow or
  a data-honesty failure — does not ship and does not leave: the ship step refuses
  and names it, so the finding is owned in one place rather than two.
- **Verdicts are the reviewer's.** `record` reads the review step's own file and
  takes no verdict from an argument. A trailer an agent writes for itself is
  indistinguishable from one a reviewer earned.
- **Nothing is lost on a stop.** Each finished step is written to the record
  before the next one starts, so a killed run resumes at the one after it.
- **It asks rather than guesses.** Any step may answer with a question instead of
  an answer; that parks the ticket with the question on it. A step that knows what
  stopped it — what a review graded critical or major, a leftover that could not be filed —
  leaves the text on the record, and that becomes the question the park brief asks
  rather than an exit code.
- **Nothing runs unbounded.** Every gate and every test command has a ceiling
  (`DRIVER_CMD_TIMEOUT`, 900s). The build step's command comes from the model, so a
  reported watch-mode runner would otherwise hang the run for ever — no park, no
  refusal, the claim held.
- **A hand-off is verified, not announced.** The pull request is confirmed to exist,
  and marking it ready and arming auto-merge are read by their exit codes. An expired
  token or a protected base otherwise reads exactly like a completed hand-off.

## The briefs

The AI steps read `briefs/<step>.md` at the kit root — a separate deliverable, so
`DRIVER_BRIEFS` points there rather than inside this folder. A brief is our
project facts, the Superpowers skill to invoke, and the JSON it must hand back.
The driver validates that answer against `briefs/schemas/<step>.json` **when that
file exists**; absent is normal and not an error.

**The placeholders are filled, and an unfilled one stops the step.** `facts.sh`
gathers each `{{FACT}}` a brief declares in `briefs/facts.json`, writes it to
`<state>/steps/<slot>.facts/<NAME>`, and substitutes. Every gatherer returns either
a value or a sentence saying there is none and why, so nothing resolves to empty by
accident — and a placeholder with no value at all is a refusal. Until 2026-09-28
nothing substituted: the plan prompt was byte-identical for two different tickets
and six placeholders reached the model as the characters `{{TICKET}}`.

**The model is bound to the answer's shape, not asked for it.** `--json-schema` gets
a copy of the contract derived by `prompt-schema.jq`, because the API's tool-input
path refuses keywords a draft-07 validator accepts — `allOf` at the top level 400s.
The answer is then read from `structured_output` rather than the last message, which
is the only field a `Stop` hook cannot rewrite, and the driver exports
`HARNESS_DRIVER_RUN` so the kit's own two Stop hooks stand down. Both halves: on the
2026-09-27 trial the sign-off backstop replaced the entire final message with its
banner and every AI answer was unreadable.

**The skills come from `briefs/facts.json`.** A step must show at least one of the
skills that file declares for it, and every skill its ANSWER claims must appear in
the transcript. A brief may also pin one in `skill:` front matter; none of the
shipped briefs does, which is why the front-matter-only read left all three AI steps
ungated while the fixture wrote that line into briefs of its own.

The check is one call to `briefs/validate.sh`, which reads the whole schema through
ajv. It is not re-derived here, and the strictness is the reason: it lives in
`additionalProperties: false`, in nested `required`, in `failedBefore` pinned to
`true`, and in the `if`/`then` that refuses `SHIP` beside an open Critical or Major. A checker
reading only top-level `required` and top-level property types accepted **19 of the
24 invalid examples** in `briefs/examples` — among them a build whose test passed
before the change, and a review that ships with a Critical or a Major open, which are the two
guarantees the driver exists to make.

`validate.sh` exit 2 — the contract could not be read at all — parks the ticket just
as exit 1 does, because a validator answering 0 when it validated nothing reads
exactly like one that validated everything. So does a contract that could not be
REACHED: a `DRIVER_SCHEMAS` naming a directory that is not there, a schema path that
is a directory or a dead symlink, or a validator that could not be fetched. Only a
genuinely missing `<step>.json` inside an existing schemas directory is the normal
absence that passes.

Superpowers is **called, never copied**. A brief that restates a skill's content
is a copy that drifts and loses every upgrade.

## Exit codes

They are the whole control flow, so they are named once, in `driver-env.sh`:

| | |
|---|---|
| 0 | the step finished |
| 20 | the step asked a question — the ticket parks with it |
| 21 | a declared or claimed Skill is not in the transcript |
| 22 | the answer did not meet its contract, or the contract could not be read |
| 23 | there is no brief for this step |
| 24 | a refusal gate said no |
| 25 | a command outran its time limit — a hang is not a failure to retry |
| 30 | the reviewer found a Critical or a Major — back to the build step |

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
| `DRIVER_VALIDATE` | the contract checker (default `briefs/validate.sh`) |
| `DRIVER_MAX_BUILD_TRIES` · `DRIVER_MAX_REVIEW_ROUNDS` | the two ceilings |
| `DRIVER_CMD_TIMEOUT` | how long a gate or test command may run |
| `DRIVER_ALWAYS_STEPS` | steps that re-run on every pass (`start`, the re-entry check) |
| `HARNESS_DRIVER_RUN` | exported per step; the kit's Stop hooks stand down on it |
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

`real-briefs.test.sh` is the third reading and the one the others cannot give: the
briefs, the contracts and the answers are the files that SHIP, and only the model is
stubbed. Every other suite here points `DRIVER_BRIEFS` at a directory the fixture
wrote — which is how five Criticals lived in the seam between the driver and the
briefs while `ai-step.test.sh` exited 0. If you change a contract, a brief, or what
a step reads out of one, that is the suite that will notice.

## One note for anyone editing the step files

**Never put `${var:-<literal text>}` inside a `case` arm** — or anywhere the text may
contain an apostrophe.

In bash 3.2, the stock macOS shell this has to run on, an apostrophe inside a `${var:-…}`
default opens a single-quote context even within double quotes. **One** of them is a loud
unterminated-quote error that `bash -n` catches. **Two** of them balance each other, so
`bash -n` returns 0 and everything between the pair is swallowed. That is how a `case`
lost the arms between two such defaults, including `*)`: the dispatch then matched
nothing for a refusal, the walk neither parked nor advanced, and the step ran for ever —
measured at 573 calls, on a file the syntax check accepted.

Bisected, so the rule is narrow and true: `$( )` inside a default in an arm is fine, one
apostrophe fails loudly, two fail silently. `build-ticket`'s arms therefore only assign
two variables, and the park happens once after the `esac`.
