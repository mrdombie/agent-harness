# Standing rules

Read at the start of every session, on every machine the kit is installed on.
The kit carries these so a second computer behaves like the first: the rules
travel with the plugin, not with one machine's `~/.claude`.

Project facts live in the consuming repo's `.claude/harness.json` and its own
instruction files. Nothing here names a project.

## Design is approved before it is built

**Picture first.** A ticket that changes what a user sees does not start
building until the owner has approved a picture of the target. The check at the
end is then "does it match what was approved", which is answerable. Measured on
the estate this came from: 9 of the 12 most-rejected tickets had no approved
design, and both agents and reviewers looped on taste because there was nothing
to hold the work against.

Show the rendered thing for a design call, never a bullet list describing it.
Anything graphic gets a rendered artifact, not ASCII.

**An approval covers the render it was given against — nothing later.** A
sign-off names the exact evidence it saw. Any later change to what renders — a
review round, a fix, a rebase that moves pixels — voids it: re-capture, put
before/after on the PR, and ask again. Never clear a hold by citing an approval
of an earlier render. A resume brief may carry an approval forward only for
commits that change no pixels, and must say so. This is written down because it
was broken: a design pass removed a control in a review round AFTER the renders
that still showed it were approved, the hold was cleared by citing that earlier
approval, and the owner found out on the test environment.

**The approved design is the acceptance criterion.** Wiring real data into an
approved surface is a data change, not a design change: the rendered output
afterwards must look identical. If real data genuinely will not fit, say so —
do not restructure to make it fit.

## Every finding carries a grade

Grade a review finding before acting on it, because the grade decides what it
costs:

| Grade | Means | Costs |
|---|---|---|
| Critical | wrong data, a security hole, lost work, an unapproved publish | blocks; fixed in this ticket |
| Major | a user is misled or stuck | blocks; fixed in this ticket |
| Minor | polish | one follow-up, worked when nothing bigger waits |
| Nit | taste | dropped |

An ungraded finding is a finding nobody can prioritise.

**Two rounds, then it ships.** Run every reviewer the work needs TOGETHER, on
the first version that works — not in sequence at the end, or the agent builds
on top of work another reviewer is about to reject. Fix the combined findings as
one batch, run the pair again, and after that second round anything still raised
that is not Critical or Major is filed as its own ticket, linked on the PR, and
the PR merges. A follow-up ticket carries the finding verbatim and the evidence
it was raised against.

**Record the count, do not promise it.** The PR body carries `Review rounds: N
of 2`, so a reader can see the rule was applied rather than take the agent's
word for it. Written down after a design pass spent three and a half hours in a
final review raising one point per round.

## Finish before you start

A red or clashing pull request takes the next free agent slot before any new
ticket. A non-draft PR that has been red for two hours with nothing fixing it is
reported to the owner unprompted.

Bring each sign-off the moment its PR is green, one at a time. Never hold them
for a batch: held PRs clash with the integration branch while they wait, and
each clash costs another agent run.

## Run only what the change touches

Local checks are **changed-only**. CI runs the whole suite before anything
merges, and a red CI brings an agent back — so a local full-suite run is the
same work done twice, at the cost of the machine every other agent is sharing.

Take the commands from `gates.changed` in the repo's `.claude/harness.json`.
Run the whole-app form only when a person asks for it by name, or when CI has
gone red and you are reproducing it.

Measured when this rule landed: load sat at 32-40 on 10 cores because every
agent ran a whole-app typecheck and a full suite that the push hook and CI then
ran again.

## Evidence before assertion

- **A conclusion without a number is the tell.** Run the command before the
  sentence — for every count, every "already fixed", every "this replaces that".
- **Name the proxy.** Before stating any count or comparison, write out: *I am
  using `<what the command actually matched>` as a stand-in for `<what I am
  about to claim>`.* If the two halves are not the same thing, the number is
  wrong and does not get stated. When the substitution is unavoidable, print a
  sample of what matched next to the count.
- **Read the tool before filing its absence.** "X doesn't do Y" is a
  measurement, not an impression.
- **A warning list is not the failure.** Read the exit line and the exit code.
- **A zero from a strictness probe** means one of three things: clean,
  suppressed, or never compiled. Find out which.
- **Plant the death, not the typo.** A guard proved by planting a bad value can
  still pass when the line is deleted. Prove the test can fail.
- **A test that reads the source measures the shape of the code and stands in
  for its behaviour.** That gap is where a green suite hides a dead feature.
- **Copy shown as real must be read out of source first**, and the file named. A
  screen that does not exist cannot be signed off.
- **A re-read is not a re-run**, and a correction carries the same bar as the
  claim it corrects.

## Shell and git craft

- An edit script must assert the substitution landed. A `replace()` that matched
  nothing still prints "ok".
- Quote heredoc delimiters (`<<'PY'`). Unquoted ones expand backticks and
  `$vars` in the calling shell first.
- `zsh` does not word-split `$VAR` in `for x in $VAR`, and `${PIPESTATUS[0]}` is
  empty there. Use bash for loops over command output, and redirect rather than
  pipe when the exit code matters.
- `$?` after a pipeline is the last command's status, so `npm test | tail`
  reports tail's `0`. Exit 143 is SIGTERM — a timeout kill, not a failure.
- Never batch a gate with a push in one command: that batches on the shell
  reaching the line, not on the gate passing.
- `git diff <base> --stat` reads the working tree, not the commit. Verify a
  commit with `git show`. Three-dot diff hides work that already shipped — size
  a branch with two dots.
- Never `reset --hard`, `checkout --` or `clean -f` to undo a plant. Copy the
  file aside BEFORE planting and restore from that copy.
- A test that runs git in a scratch repo must drop every `GIT_*` variable; under
  a hook they aim it at the real repo.
- Kill only processes you started, by a pattern that cannot match a peer's.

## Where tooling lives

Every new command, skill, agent or hook is born in the harness repo, ships as
part of the plugin, and is then installed. Never created first in a machine's
`~/.claude` — a copy that lives on one machine lives nowhere else, and a second
copy of a live thing is drift waiting to happen.

One project's own tooling goes in that repo's `.claude/skills/` through a
ticket. The kit keeps only what any project could use.
