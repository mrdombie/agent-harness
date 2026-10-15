# Non-stop — one window works an area until it is finished

The operator types, in a window:

```
/loop 30m /agent-harness:work <area> --nonstop
```

Any number of windows may run it on the same area at once. The loop ends only
with `Stopped: area finished` — nothing in the area is ready, drafting or fixable,
and nothing this window owns is in flight — or when the operator says stop.

**Why a fixed 30m and not a self-paced `/loop`.** A fixed interval is a recurring
cron, and a cron keeps firing after a turn dies on the plan's usage limit. A
self-paced loop schedules its next wake from inside the turn, so a turn killed by
a 429 schedules nothing and the loop is over — which is how agents died at
"resets 2:30am" and never came back. The 30 minutes is only the fallback:
finished agents and shell watchers wake the window the moment they end.

`S="${CLAUDE_PLUGIN_ROOT}/scripts"` below. Every agent is Opus: never pass a
model override when starting one (the operator's call).

## Every wake: one call, one move

```bash
"$S/nonstop.sh" wake
```

It prints a short board ending in one `NEXT:` line. Do what it says, then end the
turn with the status block. Do not run anything else to "check": the board is the
check.

| NEXT | Do |
|---|---|
| `START` | First wake only. Resolve the area to its label (`/agent-harness:work` Step 1), then `"$S/nonstop.sh" start <label>`, then `wake` again. |
| `HOLD` | The plan's usage limit is in force. End the turn. The first tick after the reset resumes everything. |
| `RESUME` | One background agent per `RESUME` line, briefed with that line (below). `agent done <old id>`, `agent add <new id> …`. |
| `FIX` | `"$S/fix-lock.sh" acquire <pr>`. Exit 10 means another window has it: `wake` again. Exit 0: one background agent fixes the PR (merge the integration branch in, fix the red, push). `agent add <id> <ticket> --kind fix --pr <pr>`. |
| `CLAIM` | One background agent per free place, each given a DIFFERENT ticket from the `ready:` line: `/agent-harness:claim <n>`, built through `/agent-harness:finish`. `agent add <id> <n> --branch … --worktree …` once the agent names them. |
| `PM` | Product-manager work on one listed ticket: write the missing spec, draw the picture for a screen ticket and put it in front of the operator, or move a ticket whose spec is complete and whose picture (if it changes pixels) the operator approved from gated to ready. Never apply `design-exempt` or remove the human-approval hold: those are the operator's alone. A picture now waiting on the operator goes in `.auto-skip`, so the next wake does not draw it again. |
| `WAIT` | Agents or watchers are running. End the turn: their notifications wake you. |
| `FINISHED` | `"$S/nonstop.sh" stop "area finished"`, delete this loop's cron job (CronDelete), print `Stopped: area finished` and the sign-off. |

## When a notification arrives

- **An agent finished.** `agent done <id>`. If it left a PR armed, start the
  watcher in the background — `"$S/pr-watch.sh" <pr>` with `run_in_background` —
  and `agent add <task id> <ticket> --kind watch --pr <pr>`. Never watch a PR by
  asking gh from the window.
- **An agent failed on the usage limit** ("hit your session limit · resets …"):
  `"$S/nonstop.sh" agent cut <id> "<the failure text>"`, then end the turn. The
  Stop-failure hook records the window's own wall the same way.
- **A watcher fired.** `agent done <task id>`. `RED` or `CONFLICT` is a `FIX` on
  the next `wake`; `GREEN` behind a sign-off goes to the operator per the batch
  rule; `MERGED` is announced. Release a fix lock once its PR is green or merged:
  `"$S/fix-lock.sh" release <pr>`.

Then `wake` again in the same turn and act on it.

## Briefing an agent

Agents start fresh, so they are cheap; the window is not. Every brief says:

- the one ticket or PR, the worktree and branch when they exist;
- for a `RESUME`: "continue from `git log` and `git status` in that worktree; do
  not redo committed work; read the transcript named only if the git state leaves
  the next step unclear";
- **report in five lines or fewer**: ticket, PR number and state, what is left,
  any decision for the operator. No diffs, no logs.

## What keeps it cheap

Measured 2026-10-15 over the eight loop windows of the previous three days: 76%
of all tokens were the window's, not its agents'; each window call re-read a
context of 150k-546k tokens; 13% of window calls were the model asking gh about a
PR or a run. So:

- **The window dispatches; agents build.** No ticket is built in the window.
- **Waits are shell.** `pr-watch.sh` in the background for PRs; `nonstop.sh wake`
  for everything else. No `sleep`, no polling loop in a model turn.
- **Event-driven wakes.** Under `/loop 30m` nothing else is needed; never schedule
  a wakeup shorter than 20 minutes.
- **Read once.** Do not re-read a skill, a spec or a large file already in the
  conversation. After compaction the session-start hook puts the board back; trust
  it rather than re-reading.
- **Short reports.** An agent's report is five lines.

## Several windows on one area

Safe by construction: a ticket is taken through `claim-lock.sh` (one winner per
ticket), a red PR through `fix-lock.sh` (one fixer per PR, per window, with an
expiry), each window keeps its own agent list, and the agent places are the
machine's — `NONSTOP_MAX_AGENTS`, default 4, shared by every window. A window
that dies leaves its agents to the first live window that wakes, which resumes
them.
