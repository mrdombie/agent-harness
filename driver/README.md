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
│                   reenter · repair (the repair order)
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
| 5 | `self-check` | driver | every gate run as its own command, read by exit code — the project's `gates.changed` list when it has one (what the change touches; CI runs the rest), else `gates.local` — then the push's own checks: `gates.prePush`, or the tree's pre-push hook run as `git push` runs it |
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
pull request, resume brief, the question, labels, release the claim — in that
order, because an unpushed branch is the only thing a park can lose and a claim
released early is a ticket a peer can take against a branch that is not there.
A question only a person can answer goes through `scripts/owner-question.sh`
(`DRIVER_OWNER_QUESTION`): the owner's label and channel, and the answer back on
the queue as a brief the driver carries. The hold label goes on only when the
question could not be asked. A driver-caused park asks nobody.

**A requeue is not a park.** Two stops go back on the queue instead (exit 28),
because nobody has to answer them and the next run clears them:

- **The plan's usage limit.** A step's transcript carries the CLI's rejection. The
  reset goes into `$STATE_DIR/usage-hold`, and the coordinator spawns nothing until
  then.
- **A GitHub read that failed in `start`, `reenter` or `ship`.** It is retried
  `DRIVER_LOOKUP_TRIES` times first. After `DRIVER_MAX_GH_REQUEUES` requeues in a
  row, it parks.

A requeue adds no label, opens no pull request and asks no question. The record and
the worktree are kept, so the next run resumes at the step that stopped. The reason
goes on the run log and the record.

## A repair: `build-ticket <ticket> --repair <brief>`

A pull request that was built, pushed and handed off can go red or start to
clash with the integration branch. When that happens a watcher sends it back
with a brief. The repair is done on that PR's branch. The ticket is not built
again, so a repair has its own order (`DRIVER_REPAIR_STEPS`):

| # | Step | Who | What it produces |
|---|---|---|---|
| 1 | `reenter` | driver | the ticket's one open PR, on its own branch at origin's head, under a claim |
| 2 | `repair` | driver, then model | the trunk merged in for a clash, the red checks read, one model call when there is something to fix, and each fix proved |
| 3–7 | `fix` · `self-check` · `review` · `record` · `ship` | as above | the same gates, the same two review rounds, the same verdict |

- **`reenter` replaces `start` and is the always step.** It refuses by name in
  these cases:
  - the ticket is closed or held
  - it has no open PR on a `<prefix><ticket>` branch
  - it has more than one
  - a peer holds the claim
  - the local branch has diverged from origin
  - the PR list could not be read
- **`start` never cuts a branch for a ticket that has an open PR.** It refuses
  by name and points at `--repair`. Building a second branch beside the PR's
  own is duplicate work and a push the PR never sees.
- **The brief is never dropped.** It is copied onto the record. A missing or
  empty brief is a refusal (exit 2). A healing run with no note is
  `--repair-class <class>`, which writes a brief naming the class.
  `--brief <file>` is a repair when the ticket has an open PR, and otherwise a
  build with the brief handed to every AI step (`run_brief` on the record).
- **The record outranks the PR.** If the ticket's record is an unshipped build,
  then `--brief`, `--repair` and `--repair-class` all resume that build from the
  step that parked, with the brief as `run_brief`. A build that parks on a
  question opens a draft PR, so its answer comes back looking like a repair.
  Treated as one, it would skip the design compare and the build's own proof,
  then ship. `owner-question.sh` requeues such a ticket as `new` for the same
  reason. Only a shipped ticket, or one with no driver record, is repaired on its
  PR.
- **A round is the brief, the PR head and whether it shipped.** The same brief on
  an unmoved PR resumes. A new round starts when any of these holds:
  - the brief changed
  - the round already shipped
  - the PR's head moved since the round began

  A new round moves the last round's step answers to `steps/archive/` and starts
  the review and fix counters again.
- **A clash is merged, never rebased.** A clean merge needs no model. A
  conflicted one is handed over, and must come back resolved: no unmerged path,
  no merge in progress, no conflict marker, and the trunk an ancestor of the
  head.
- **Every fix carries its proof.** A behaviour fix brings a test, re-run red
  then green on two of this repair's own commits, by the same proof as `build`
  and `fix`. A fix no test can pin (a lint rule, a type error, a lockfile) names
  the gate command that was red. The driver runs that command at the head and
  reads its exit code, and `self-check` runs every gate after it.
- **The model is called for a conflict, a red check, an unreadable rollup, or
  a caller's brief.** For example, an owner's answer on a ticket that has a PR is
  read even when the PR is green. It may answer `unchanged`, with a reason, but
  only when nothing is red, nothing clashes, and it committed nothing.
  `unchanged` parks with a question for a person, never a ship, and it asks once
  per PR head: the answer, coming back as a new brief at the same head, is acted
  on. A note-less healing run on a green, clean PR makes no model call. The gates
  and the review still run, so an approved merge sent here is judged like any
  other.
- **A caller's brief reaches every step.** In repair mode the brief goes to fix,
  self-check and review as well as repair, so the reviewer can judge whether it
  was met. In a build it goes to every AI step as `run_brief`, and it ends when
  the ticket ships or a repair round starts.
- **A step never pushes.** Origin's head for the branch is read before and after
  every AI step, and a step it moved under refuses and parks. That is the
  guarantee. Inside steps, `git push` and `gh pr ready`/`merge`/`create` are also
  refused (a PATH shim), and every brief carries a preface saying a brief's
  push, ready, arm or hand-off instruction is void.
- **No conflict marker survives an interruption.** A park never commits a merge
  in progress. `reenter` resumes a recorded tree whose merge of the trunk is
  unfinished. `repair` and `ship` refuse markers read from the branch's own diff,
  on every pass.
- **`ship` lands on the same PR and leaves its words alone.** It does not open a
  PR or rewrite a title or body. It reports the repair in a comment. The
  verdict is read before the push, because the PR usually has auto-merge armed,
  and on it the push is the merge. For the same reason a park in repair mode
  commits locally and bundles, and does not push.

What a repair does not do:
- force-push
- re-run a flaky job
- repair a PR that does not exist. `--repair` and `--repair-class` refuse by
  name; a `--brief` on a ticket with no PR builds it instead.

The park's push carries the project's park escape (`PARK_PUSH=1`, or the name in
`driver.parkPushEnv`) so a pre-push that honours it lets a draft through checks
work in progress fails. Never on a trunk, never on any other push: ship strips it
even when inherited. A push still refused falls back to a bundle under
`<worktreeRoot>/backups`.

## What the driver guarantees with its own hands

- **Test-first is proved, not asked.** The build step reports, per item, the
  commit that added the test and the commit that made it pass. The driver checks
  out the change's parent with that test copied in, runs it, and requires it to
  **fail**; then runs it at the change and requires it to **pass**. A test whose
  selector matches nothing, whose assertion is true of any tree, or which reads a
  file instead of running the code is green at the parent, and all three fail here.
  Green under the runner is not enough: the tree with the change also runs the
  project's typecheck (`driver.proofTypecheck`, else the typecheck among its
  `gates`), because a runner that strips types passes a test the compiler rejects.
  A test that does not compile goes back to `build`, and the retry is told why.
- **The named Skill actually ran.** Each brief's front matter names one Skill.
  The driver reads the run's transcript and parks the ticket when that Skill call
  is absent. Inside a ticket Superpowers does the work; the driver never starts
  several agents on one ticket itself.
- **Every gate runs, and its exit code is the verdict.** One gate, one command,
  never batched — a gate batched with anything else reports on the shell reaching
  that line. Nothing configured is a refusal, not a pass. Gates and proofs run as
  CI runs them, with the kit's `HARNESS_*` pins stripped from their environment.
- **A red gate gets one repair round.** The first red self-check on a run goes back
  to `fix` with each red gate's output as the finding, inside the two-round fix
  ceiling; the fixer answers it in `gateFixes`, and self-check re-running every gate
  is the proof. A second red, a gate that could not run at all (126/127), or no fix
  round left parks — with the red gates' names, exit codes and lines in the park
  comment. Nothing is pushed past a red gate.
- **The push is a formality.** Self-check's last gate is the push verification
  (`gates.prePush`; absent, the pre-push hook; `false`, off), so a check only the
  push runs is a finding for `fix`, not a park after review. While a reviewer the
  push demands (`review.attest`) is still owed it waits for the push, and a push its
  pre-push refuses goes to `fix` once with the output as the finding, inside the
  same ceiling. A refusal by the remote or the network still parks, and so does a
  sign-off refusal: that is the owner's call, never a finding. The trial skips while
  a configured gate is red, runs `gates.prePushOwed` while a verdict is owed, and
  carries `SIGNOFF_GUARD_DRYRUN=1`.
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
- **A question goes to whoever owns its answer.** The step names that in
  `questionFor`. `pm` is the ticket's shape — which repo, how it splits, the order,
  the wording of its acceptance — and parks with the PM's label (`labels.pmDecision`,
  default `status:pm-decision`), which the PM clears. Everything else — pixels, a
  picture, a product or commercial call, the data model, or a question left
  unclassified — is the owner's and gets the hold label. `start` refuses a ticket
  wearing either.
- **A resume re-plans when the ticket changed.** The ticket body read when `plan`
  ran is hashed onto the record. A resume that finds a different body reopens `plan`
  and every step after it, so tasks the PM removed are not built from a stale plan.
  `--restart` still re-runs everything.
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
| 30 | rework: the build step's own retry goes back to `build`; a review's Critical or Major, or a red self-check's first repair round, goes back to `fix` |

`build-ticket` itself exits 0 when the walk completes, 20 when it parked, and 2
when the call or the configuration was wrong (an unreadable `--repair` brief
included).

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
| `DRIVER_PERMISSION_MODE` | the `--permission-mode` every step runs with (default `auto`; `driver.permissionMode`) |
| `DRIVER_DISALLOWED_TOOLS` | tools left out of every step (`driver.disallowedTools`; default: the ask/plan/schedule/notify tools a headless step never calls). Every step also runs with no connectors (`--strict-mcp-config`). Each step's cost, turns, context size and brief length are recorded under `.usage` in `state.json`, and `.spend` is their sum — measured, not capped |
| `DRIVER_STEP_BUDGET_USD` | unset by default. When set, every step runs with `--max-budget-usd` at that figure — a runaway stop per step. `scripts/spawn-claim.sh` sets it to the run's `CLAIM_BUDGET_USD`, since it starts this driver for every named-ticket build and repair |
| `DRIVER_TOOLS` | the tools a step loads, as an allowlist (`driver.tools`; default: `Bash Read Edit Write Grep Glob Skill Agent`, the eight any step of trial 3 called; a step may narrow it with `steps.<step>.tools` in `briefs/facts.json`; `default` loads Claude Code's whole set and falls back to the block list above). Every schema loaded is re-sent on every call — ~14k tokens a call measured (#11172) |
| `DRIVER_PROJECT_INSTRUCTIONS` | `on-demand` (default): the tree's CLAUDE.md / AGENTS.md are excluded by path (`claudeMdExcludes`) and named in the system prompt rather than preloaded; every setting source still loads, so the project's skills, agents and hooks are unchanged — ~17k tokens a call on the origin project. `preload` restores auto-loading (`driver.projectInstructions`) |
| `DRIVER_ALWAYS_STEPS` | steps that re-run on every pass (`start`, the re-entry check; `reenter` under `--repair`) |
| `DRIVER_REPAIR_STEPS` | the order under `--repair` (default `reenter repair fix self-check review record ship`) |
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
