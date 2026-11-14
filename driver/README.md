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
├── git-actions.sh  the git steps a model may not run, and driver_keep_ref (work kept under refs/stale/)
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

## The ten steps

| # | Step | Who | What it produces |
|---|---|---|---|
| 1 | `start` | driver | the claim, the worktree, the refusal gates |
| 1b | `size` | driver | the ticket's size and route (below); one short model call only when its rules cannot tell |
| 2 | `plan` | model | a plan the driver can enforce, or a question |
| 3 | `build` | model | commits whose test the driver proves red then green |
| 4 | `fix` | model | the review's Criticals and Majors cleared, each proved the same way; a self-check red is handed on only at the head it was read on, never a command `gates.localOnly` keeps for CI, and never one red on the merged trunk commit too (base-red: noted for the one develop-red ticket) |
| 5 | `self-check` | driver | first, with no model, what the ticket names (`driver/ticket-parts.sh`): each file it names in backticks under its change or acceptance headings (or on a split part's `**Files:**` line) is on the branch or in its diff, and each numbered change item and acceptance item is in a passing feature's `covers` or named by its id in the list's `outside` (a `note` there names no item); a miss goes to fix once, named, and a second parks named. Then every gate run as its own command, read by exit code. When `gates.local` holds every `gates.changed` command (or there is none) it is the local set: that list alone, and CI runs the rest once. Otherwise the project's `gates.changed` list when it has one (what the change touches; CI runs the rest), else `gates.local` — then the push's own checks: `gates.prePush`, or the tree's pre-push hook run as `git push` runs it. A red also red on the trunk commit the branch merged (`driver/base-red.sh`, run there once per check and commit) is base-red: not counted, never parked, one develop-red ticket. A database or transaction timeout in test files the branch did not change is run again once, file by file alone: all green, the red was the load's, not counted |
| 6 | `compare` | model | this run's renders held beside the approved design |
| 7 | `review` | model | `SHIP`, or findings with a file, a line, a grade, a tag and the panel's votes, from Claude Code's own `code-review` (finders in parallel, a verifier vote on each). Only agreed findings are kept; a pre-existing one goes to the sweep queue. Once per change: a later pass calls the model only when the fix round touched a file the first review never saw, graded Critical and Major only, and never past `review.maxRounds` |
| 8 | `record` | driver | the verdict, off the reviewer's own file |
| 9 | `ship` | driver | push, draft pull request carrying its proof, ready, auto-merge, hand off |

The kit ships one gate a project can list in `gates.local` as it is:
`bash "$KIT_ROOT/scripts/check-changed-shell.sh"`. It reads only the shell scripts
the change touches (`.sh`, or a bash/sh shebang) and refuses, by file:line and rule,
a shellcheck error (the project's `.shellcheckrc` applies) or an added `curl`, `wget`,
`gh api`, `git fetch`, `npm`, `npx` or `docker` with no timeout or bounded wrapper.
No shellcheck on the machine is a log line, not a failure.

## The quick route: `start → size → quick → review → ship`

`size` reads the ticket before anything is planned (`steps/size.sh`): its labels, its
body, the file paths it names, and whether it states the change (a fenced snippet or
diff, a "set/change/rename … to …" line).

- **quick**: 1 to `driver.quick.maxFiles` (3) named files, and the change is config,
  copy or docs, or a small code edit the ticket states. **A fix sized small is quick
  too** (owner, 2026-11-09: the quick route is the default for small fixes). A fix is
  a ticket wearing one of `driver.quick.fixLabels` (`type:bug`, `bug`) or whose title
  matches `driver.quick.fixTitle` (`fix…`, `bug…`, `hotfix…`, `develop is red`). One
  naming 1 to `driver.quick.fixMaxFiles` (5) files, or naming code on the trunk without
  stating the change (no size call: the call answered quick or small for 37 of 41 such
  fixes), goes quick; a size call that answers small for a fix goes quick too. An effort
  label, `type:feature`, a schema or a screen still keep it off. Measured 23 Oct-9 Nov:
  26 of 325 fix tickets went quick and 136 sized small walked plan and build (median
  40 min claim to PR, 6.0 sessions) against the quick route's 9 min and 3.5.
- **small**: a few named files (up to `driver.quick.smallMaxFiles`, 8), no schema, no
  new screen.
- **project**: anything else. That means a schema, data-model or migration change
  (never quick), a new or redesigned screen, `needs:design` or a picture label, a
  never-quick file, or a ticket that names no file and states no change.

Named code files with no stated change, or a stated change naming no file, is
undecided. Only then is one short model call made: small prompt, read-only tools,
three turns. It can answer quick, small or project; no answer means the full route.
The route, the size and the reason go on the record and the run log (`size:
route=… size=…`).

A **quick** ticket walks `DRIVER_QUICK_STEPS`. The `quick` step is one agent session
(`briefs/quick.md`): it edits and commits, and cannot push. The driver then reads the
real diff (a fix may touch `driver.quick.fixMaxFiles`, 5) and runs the same gates `self-check` runs (`gates.local` under
`gates.localOnly`, else the changed list, plus the changelog skip line). `review`
runs once: only Critical and Major block, and a Minor is dropped. Then
the unchanged `ship` step pushes, opens the PR, readies it and arms auto-merge. No
plan, build, fix, compare, separate self-check or record step runs.

**A fix brings its test.** The session finds the cause, makes the smallest fix and
commits a test that fails without it. A fix whose diff changes code (anything but
config and docs) with no test file (`driver.quick.testPattern`: `*.test.*`, `*.spec.*`,
`test/`, `tests/`, `__tests__/`, `e2e/`, `*_test.*`, `test_*.py`) is sent back to the
session once, naming it; still none, it moves up to the full route, whose build proves
its test red first.

**Bigger than its size moves up.** A real diff over `maxFiles`, or touching a
never-quick file, moves the ticket up to the full route from `plan`. Never-quick files
are the project's screen files, a route page, `*migrations/*`, `*.sql`, `*.prisma`,
lockfiles, and `driver.quick.neverGlobs`. Red gates do the same. The quick commits
are kept at `refs/driver/quick/<ticket>` and the branch goes back to its cut, so the
build can still prove its test red first. The plan step is told where the attempt
is. A review that blocks a quick change goes to the full route's `fix` step. A record
that was already planned keeps the full route.

**One change, worked through by behaviour** (owner, 2026-11-05; replaces splitting every
list of two or more items, 2026-11-02). Why: Anthropic's long-running harness has one agent
work through a feature list in one codebase, not separate tickets, and parts waited a median
18 h to reach a PR against 2.9 h unsplit with no smaller changes (about 350 lines either way).
The plan writes a feature list for every ticket
that changes what a person sees or does: `F<n>: <behaviour>` items, each with test steps
run as a fast component or logic test in the required test run (never a browser check),
all failing. `driver/feature-list.sh` checks how the plan builds it (every task names its
item; each item's test is written by its own tasks; a foundation names its reason), sends
the plan back once with what is wrong, then refuses. The list is kept in the run record
(`<ticket>/features.json`); once an item passes or a part is filed, a later plan that
edits or removes an item or its steps is refused, and only `passes` ever changes. Before
then a later plan replaces it, the old list kept as `features.prev.json`. A ticket wearing one of `driver.split.featureLabels`
(default `type:feature`) with no list is sent back once, then refused.

The ticket builds here as one change. The plan's tasks run foundation, F1, F2…, clean-up,
one session and one red-then-green proof each, and the session is given its item's behaviour,
steps and test. The list is posted on the ticket. An item passes once every task of it is
proved and one proved its test file; the same commits naming another item's test are proved
again rather than merged. An item whose test never ran sends its last task back on the build's
own tries. The list is posted again when every item passes. `refactor` and `hidden-backend`
foundations ship in the same change as their behaviours.

It splits in two cases: past `driver.split.planMaxFiles` (50; 0 never) distinct files named by
the plan (4 of 5 changes over 100 files clashed, about 20% at 20-100, 6% under 10), and, whatever
its file count or that setting, with an `expand-contract` foundation, so the new shape deploys
before the old one is removed. That split is always in two: the change, whole and in list
order, then its clean-up, gated on it; with `release.mergeFirst` on, it builds here as one
change with the clean-up last. Past the file limit: one part per
item, each carrying its behaviour, its test steps and a
`<!-- harness:feature-item parent=… id=F<n> test=… -->` marker, all ready at once. A
foundation (`expand-contract`, `refactor` or `hidden-backend`) goes first, and only the items
with `needsFoundation` wait for it; a clean-up part goes last, gated on every item part. The
list, with its parts, is posted on the parent, which closes as split. A part's file list leaves
out the parent's own changelog entry unless it is the last part.
`scripts/feature-close.sh` (a coordinator housekeeping pass) marks an item passing once
its part closed as completed with its test file on the integration branch, and the
feature done (closed as completed) once every item passes and the clean-up part merged.
A mechanical change (`units`, 5-30) fans out like Claude Code's /batch: one part a unit,
all ready, no list, whatever its size. A branch that already has commits, and a part of an
earlier split (" — part N of M: " in its title) build as before; a part's plan must run its
item's test file. A plan can undercount (a 211-file change once planned as 7), so a finished
build is never stranded for its size: ship counts the branch two-dot and, over
`driver.split.maxFiles`, says so in a "## Size" section on the PR, and ships.

`driver.quick.enabled: false` turns the route off (sizes are still read and logged).
The run's last line, the coordinator's `runs.log` line (`route= size= claim_to_pr=`)
and the live view's run row ("Quick change" / "Full build") all say the route. Only
quick changes the route; small and project both walk the full order (a fix sized
small reads quick).

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
A pull request already open for the branch loses auto-merge and goes back to
draft (`scripts/driver-draft.sh`), with a comment marking the conversion as the
driver's own, so a parked run never lands by itself and a person's stop still
tells the driver's draft from a person's.
A question only a person can answer goes through `scripts/owner-question.sh`
(`DRIVER_OWNER_QUESTION`): the owner's label and channel, and the answer back on
the queue as a brief the driver carries. The hold label goes on only when the
question could not be asked. A driver-caused park asks nobody.

**A requeue is not a park.** Four stops go back on the queue instead, because
nobody has to answer them and a later run clears them:

- **The plan's usage limit** (step exit 27, run exit 28). A step's transcript carries
  the CLI's rejection. The reset goes into `$STATE_DIR/usage-hold`, and the
  coordinator spawns nothing until then.
- **A session the API refused** (a result with `is_error` and an `api_error_status`, or
  `terminal_reason: api_error`): the model never ran, so it is never read as a skipped
  Skill and never reaches the skill check's record. The call is made again
  `DRIVER_API_REFUSAL_TRIES` (4) times, after 1, 3, 5 and 7 times
  `DRIVER_API_REFUSAL_BASE_SEC` (60). A 401 or 403 that outlasts them is the account's:
  it goes into the same hold file for `DRIVER_API_REFUSAL_HOLD_SEC` (3600), naming the
  status and code, the hold's own re-check clears it early, and the ticket requeues
  (step exit 27, run exit 28). Any other status parks as a machine fault (exit 33).
- **A GitHub read that failed in `start` or `ship`** (exit 26). It is
  retried `DRIVER_LOOKUP_TRIES` times first.
- **A claim another run on this host holds** (step exit 29, run exit 28), met by
  `start`, or by a step before it hands over to the model. A step's question that names a claim a peer or
  another run holds is read the same way, never as a question for the PM or the
  owner. That run's claim is left alone.

The last two park, with the step's own reason, after `DRIVER_MAX_REQUEUES` (3)
requeues in a row, so a ticket that does not exist cannot loop. "In a row" means no step
newly finished in between: `start` re-running on every pass is not progress.

- **The approved picture is not readable on this machine** (plan, run exit 28). The
  first miss requeues; `driver.maxPictureMisses` (2) in a row park it for the PM,
  naming the file. A run after a miss looks for the picture before it plans.
- **A half-built ticket** (`labels.partial`: a run ended and left a branch with no pull
  request). `start` takes it like a ready one and cuts its tree from that branch on
  origin, not the trunk. `driver.maxPartialResumes` (3) resumes in a row, each ending
  stranded again with no ship between, park it for the PM, naming the branch.

A record that says `ship` finished while the ticket has no open pull request and none
merged (one closed to rebuild fresh, or by hand) is a fresh build: it is set aside as a
`Rebuild:` note's is, never read as "nothing left to do". And the coordinator parks for
the PM any ticket whose last `coordinator.noProgressRuns` (3) runs each ended inside
`coordinator.noProgressSec` (300) with the same exit and result line.

A requeue adds no label, opens no pull request and asks no question. The record and
the worktree are kept, so the next run resumes at the step that stopped. The reason
goes on the run log and the record.

## A red or clashing PR is rebuilt, never repaired

There is no repair route. A pull request that goes red on a required check or clashes
with the integration branch and cannot merge within `coordinator.rebuildAfterMin`
(default 60) is closed by the coordinator (`scripts/rebuild.sh`), its head kept at
`refs/stale/<ticket>/pr-<n>`, and its ticket queued at the front as a new build from the
trunk, with the reviewed plan and what the last build learned as its brief. A red only
the trunk has too waits for the trunk, and a PR a person holds is never closed.

- **`--brief <file>` is a build with the brief handed to every AI step** (`run_brief` on
  the record). A missing or empty brief is a refusal (exit 2).
- **The record outranks the PR** (agent-harness#675). If the ticket's record is an
  unshipped build, a run with a brief resumes that build from the step that parked. A
  build that parks on a question opens a draft PR, so its answer comes back as a brief on
  a ticket with a PR; the design compare and the build's own proof still run before ship.
  A record a person or `/claim` moved on from (another branch, the PR made ready, a head
  the record never saw) is moved aside, and the run does not build over the live PR.
- **`start` never cuts a branch for a ticket that has an open PR it did not build.** It
  ends the run with exit 31: no park, no requeue, nothing built. The PR merges, or the
  coordinator rebuilds it. Its own parked draft whose tree was swept is cut again from
  origin's copy of its branch and the build resumes. Several open PRs are a person's call.
- **A "Rebuild:" note starts fresh on any host.** This host's worktree for the ticket is
  set aside (its commits kept at `refs/stale/<t>/local-<host>-<epoch>`), its driver state
  is moved aside, and `start` cuts a new tree from the trunk (`DRIVER_FRESH`). A record
  that says it shipped with no PR open or merged is a fresh build the same way.
- **A "Fix: PR #<n>" note continues that open PR.** It is the coordinator's fix round
  (`coordinator.fixRounds`, `scripts/rebuild.sh`) for a PR red on its own code. A shipped
  record of the ticket on this host is moved aside, `start` cuts the tree from origin's
  head of the PR's branch instead of ending with exit 31, and `ship` pushes to that branch
  and rewrites the PR it has: no second PR is opened. Any other brief still ends with 31.
- **Nothing resumes from `refs/stale/`.** Work a push could not hand over (a park's refused
  push, a branch tip left on this machine, a dead branch tip at ship) is kept there by
  `driver_keep_ref` so it is never only on one disk, for a person to read.
- **A step never pushes.** Origin's head for the branch is read before and after
  every AI step, and a step it moved under refuses and parks. That is the
  guarantee. Inside steps, `git push` and `gh pr ready`/`merge`/`create` are also
  refused (a PATH shim), and every brief carries a preface saying a brief's
  push, ready, arm or hand-off instruction is void.
- **No conflict marker survives an interruption.** A park never commits a merge
  in progress, and `ship` refuses markers read from the branch's own diff.

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
- **Every pull request carries its proof** (`scripts/pr-proof.sh`). Each red/green
  proof keeps its command and the tail of what each half printed on the task's
  `.proved` record, and self-check keeps each green gate's command and output
  (`self-check.gates.jsonl`). Ship writes them under `## Proof`, with a `Screens:` line
  for a screen change, and two lines: `How it was tested:` and `How to undo it:` (a
  migration the branch adds is named there, since a revert leaves it applied). A body
  that lacks any of them is never opened, rewritten or pushed onto. The review step is sent the ticket as filed
  and the approved picture beside the diff, in its own session, before the PR opens.
- **The named Skill actually ran.** Each brief's front matter names one Skill.
  The driver reads the run's transcript and parks the ticket when that Skill call
  is absent. Inside a ticket Superpowers does the work; the driver never starts
  several agents on one ticket itself.
- **Every gate runs, and its exit code is the verdict.** One gate, one command,
  never batched — a gate batched with anything else reports on the shell reaching
  that line. Nothing configured is a refusal, not a pass. Gates and proofs run as
  CI runs them, with the kit's `HARNESS_*` pins stripped from their environment.
- **A red gate gets one fix round.** The first red self-check on a run goes back
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
- **The review reads the written rules.** The hunter is handed `RULES`: the root
  `CLAUDE.md` and `AGENTS.md` and the instruction file nearest each changed file,
  every line numbered, cut at `review.rulesMaxBytes` (default 40000) with the cut
  said. A `breaks-rule` finding cites its rule as `file:line` and is graded as any
  finding; a `stale-rule` finding never blocks and is listed in the PR under
  "Rules to update". A rule finding with no citation, or one citing a file `RULES`
  did not carry, is refused. Cost: no extra agents; up to `review.rulesMaxBytes`
  (40000 bytes, ~10k tokens) more prompt per review, ~85 reviews a day.
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
  stopped it — what a review graded critical, major or minor —
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
| 30 | rework: the build step's own retry goes back to `build`; a review's Critical or Major, or a red self-check's first fix round, goes back to `fix` |
| 31 | start found an open pull request for the ticket that this run did not build: nothing is built beside it, no park, no requeue — it merges, or the coordinator rebuilds it fresh (`scripts/rebuild.sh`) |
| 32 | a step found nothing owed (a ticket split before it built): the run exits 0, with no park |
| 33 | machine fault: a model call failed at the API (an API Error, overloaded, rate-limited, a safeguards flag, a 5xx, an empty transcript) and failed again on the one retry — a driver park, never a question, left ready for the coordinator |
| 35 | the quick change is bigger than its size (more files than `driver.quick.maxFiles`, a never-quick file, or red gates): the run goes on along the full route from `plan`, with the quick commits kept at `refs/driver/quick/<ticket>`. Never a run's exit; `build-ticket` handles it |
| 36 | start read a `repo:<name>` label naming a repo this project does not build: nothing is claimed, no worktree is cut, no model is called, no park, no requeue — the ticket stays ready, and the coordinator starts it in a clone of `<name>` when this host has one |

A gate that outruns its limit (25) is tried once more after the machine quietens, its
limit scaled by load per core (1x to `DRIVER_GATE_TIMEOUT_MAX_SCALE`, 3x); a second
timeout on a loaded machine goes back on the queue (29), on a quiet one it parks.

A proof (the test run without the change, then with it) that runs out of time waits for
the machine's gate and is taken once more, alone in a gate slot, with twice the limit.
Out of time again it parks (25), and the park note names the command, the limit and what
each half took. A proof runs its command twice inside that limit, so it runs the case, not
the suite: a test file that carries a `# case-filter: <VAR>=… <command>` line in its first
40 lines is proved with that variable set, and a proof command that runs the whole file is
refused before any tree is built, with the command to give. Every step's project facts name
the files that take one. The kit's own suites take `SUITE_ONLY='<case title or pattern>'`
(`suite_case` in `tests/lib/suite.sh`): a case runs when its title matches, and a filter
that matches no case fails the suite.

`build-ticket` itself exits 0 when the walk completes, 20 when it parked, and 2
when the call or the configuration was wrong (an unreadable `--brief` brief
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
| `DRIVER_STEP_BUDGET_USD` | unset by default. When set, every step runs with `--max-budget-usd` at that figure — a runaway stop per step. `scripts/spawn-claim.sh` sets it to the run's `CLAIM_BUDGET_USD`, since it starts this driver for every named-ticket build |
| `DRIVER_TOOLS` | the tools a step loads, as an allowlist (`driver.tools`; default: `Bash Read Edit Write Grep Glob Skill Agent`, the eight any step of trial 3 called; a step may narrow it with `steps.<step>.tools` in `briefs/facts.json`; `default` loads Claude Code's whole set and falls back to the block list above). Every schema loaded is re-sent on every call — ~14k tokens a call measured (#11172) |
| `DRIVER_PROJECT_INSTRUCTIONS` | `on-demand` (default): the tree's CLAUDE.md / AGENTS.md are excluded by path (`claudeMdExcludes`) and named in the system prompt rather than preloaded; every setting source still loads, so the project's skills, agents and hooks are unchanged — ~17k tokens a call on the origin project. `preload` restores auto-loading (`driver.projectInstructions`) |
| `DRIVER_USER_MEMORY` | `skip` (default): the operator's user-level CLAUDE.md (`$CLAUDE_CONFIG_DIR` or `~/.claude`) is excluded by path (`claudeMdExcludes`) from every step and the size call, also under `preload`; user settings still load, so the user-scope plugin, its SessionStart rules and its guard hooks are unchanged — 19,526 → 8,502 starting tokens measured. `load` restores it (`driver.userMemory`) |
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
