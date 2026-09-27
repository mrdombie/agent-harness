# The swarm layer

Agents that run without a session open: one scheduler keeping each programme's
slots full, one queue saying what runs next, one watcher bringing an agent back
to a broken pull request, one live view everything else reads, one reporter,
and one file that installs the timers.

It replaces eight scripts that lived on one machine, six timers installed by
hand, and 58 launchers written into `/tmp` — none of which had a test.

| File | What it does |
|---|---|
| `swarm-env.sh` | Where everything is, and every call out of the process. Sourced by the rest. |
| `time.sh` | The two clock conversions, on either `date`. Shared with the test fixture. |
| `queue.sh` | One queue. `add` · `list` · `next` · `remove` · `clear` · `drain`. |
| `scheduler.sh` | One pass: top each programme's queue up, drain it to the cap. |
| `repair-watch.sh` | Repair a red or clashing pull request · unblock · restart after an outage · raise the alarm. |
| `live-view.sh` + `live-view/` | The page and the snapshot every other part reads. |
| `report.sh` | One screen, one JSON, one push. |
| `status-line.sh` | The line at the bottom of every Claude Code window. `--install` wires it up. |
| `install.sh` | Writes and loads the timers. `status` reads back what is loaded. |
| `detach.sh` | Runs a command in a session of its own. |

## Start it

```sh
swarm/install.sh          # every job this project needs
swarm/install.sh status   # what is actually loaded
swarm/report.sh           # what is happening now
```

`gh` keeps its token in the macOS keychain and a launchd job cannot read it —
the access prompt has nowhere to show, so `gh` hangs and the job logs nothing.
Write the token to a file the jobs can read:

```sh
gh auth token > "$STATE_DIR/swarm/gh-token" && chmod 600 "$STATE_DIR/swarm/gh-token"
```

## The status line

One line at the bottom of every Claude Code window, from the same snapshot the
live view serves plus the pull requests carrying the hold label:

```
3 agents working · 1 needs you
```

```sh
swarm/status-line.sh --install     # point ~/.claude/settings.json at it
swarm/status-line.sh --print       # compute it now, and see what it says
swarm/status-line.sh --uninstall
```

A plugin cannot ship a `statusLine` — the CLI's plugin content list has no such
entry — so `--install` writes the settings entry, refusing a settings file it
cannot parse rather than overwriting one. The command it writes carries this
copy's path, and a plugin's path carries its version, so **re-run `--install`
after a kit update**.

It says `swarm view not answering` rather than a count whenever it could not
see: the view is down, its snapshot is older than `swarm.staleSec`, or the
cached line is older than `SWARM_STATUS_MAX_AGE`. A hold count the forge never
gave reads `approvals unknown`. None of those is zero — an operator who reads
"no agents working" off a line that simply could not see starts more work on a
machine that is already full.

Claude Code runs this on every render, and the parts of the answer measure
170 ms (sourcing `swarm-env.sh`), 95 ms (the live view) and 581 ms (the forge).
So the render path reads one cached line and exits — 34 ms measured — and the
recompute runs detached behind it. No render waits on the forge.

| Variable | Default | What it is |
|---|---|---|
| `SWARM_STATUS_TTL` | 10 | Older than this, the line is refreshed behind you |
| `SWARM_STATUS_MAX_AGE` | 120 | Older than this, the cached line is no answer |
| `SWARM_STATUS_GH_TTL` | 120 | How long one forge answer is reused |
| `CLAUDE_SETTINGS` | `~/.claude/settings.json` | What `--install` writes |

## Queue a ticket with a brief

This is what the hand-written launchers were:

```sh
swarm/queue.sh add 1234 --brief notes.md --front
swarm/queue.sh add 1234 --reset      # release the claim and re-ready it AT DRAIN TIME
swarm/queue.sh list
```

## The rules it holds to

- **The cap is per programme, and it is three.** Eight agents on one programme
  kept every pull request clashing on the same files, and an earlier eight ran
  4h43m with zero merges against a sequential baseline of three. Two programmes
  may run three each; they do not share files.
- **No answer from the live view means BUSY, never room.** A down view used to
  read as zero agents, so the scheduler filled every slot on a full machine.
  A snapshot older than two minutes is discarded and takes the same path. The
  status line answers the same way, in words: `swarm view not answering`.
- **A stop after three repairs is a label, not a count.** The count expired when
  the 24-hour window rolled and sent a fourth agent.
- **Nothing leaves the machine that a person has not seen.** The reporter sends
  step labels; a step whose text is a bare command becomes "Running a command in
  its workspace", and anything token-shaped is replaced behind that.

## Settings

All optional, under `swarm` in `.claude/harness.json`; each is also an
environment variable of the same name in capitals. The defaults name no project.

| Key | Default | What it is |
|---|---|---|
| `swarm.cap` | 3 | Agents at once, per programme |
| `swarm.maxLoad` | 32 | Hold above this one-minute load average |
| `swarm.port` | 4777 | The live view's port |
| `swarm.staleSec` | 120 | A snapshot older than this is no answer |
| `swarm.quietSec` | 1200 | An agent silent this long is stuck |
| `swarm.idleMin` | 20 | Nothing running this long, with work waiting, is a stall |
| `swarm.repairsPerPass` | 2 | Repairs started in one pass |
| `swarm.budgetUsd` | 150 | The runaway guard on a spawn |
| `swarm.alarmLabel` | `swarm:stalled` | The label the one alarm issue carries |
| `swarm.alarmMention` | — | Who the alarm mentions |
| `swarm.reportUrl` | — | Where `report.sh --push` sends; unset means no push job |
| `swarm.statusRepo` | — | A repo to ask for a rebuild when something changes |

## Tests

```sh
for t in swarm/tests/*.test.sh; do bash "$t"; done
```

They run against a throwaway repo and stubs standing in for the forge, the
live view and the spawner, so no suite touches the network or starts an agent.
CI runs every tracked suite and fails by name on one no glob reached.
