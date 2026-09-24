---
name: panel
description: "Blind customers, screen reviewers and builders check an idea, sketch, spec or live page before it is built — is it the right product, can people use it, is it built right — and stop the build below a bar. Usage: /agent-harness:panel <area> | <area> --shape | --fix | --screens | --review | --all | --use-it | --not-blind | --bar 80 | --may sketch|tickets | --room \"A, B\" | --add \"<one sentence>\" | <preset>"
---

Run the Panel over `$ARGUMENTS`.

A standing group of reviewers checks something **before** it is built. Customers and screen
reviewers write their questions **blind** — from the area's job alone, never the design — and the
design is then checked against every question. Builders read a spec cold. Below the bar, the build
stops until each gap is fixed, planned, or left out by the operator.

## Where things live

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
CFG="$REPO_ROOT/.claude/harness.json"
PANEL_DIR="$REPO_ROOT/$(jq -r '.panel.dir // empty' "$CFG")"
[ "$PANEL_DIR" != "$REPO_ROOT/" ] || { echo "harness.json has no panel.dir — refusing (the rooms live in your repo, not the kit)"; exit 1; }
BAR=$(jq -r '.panel.bar // 70' "$CFG")
PSTATE="$STATE_DIR/panel"; mkdir -p "$PSTATE/memory" "$PSTATE/runs"
```

| What | Where | Why there |
|---|---|---|
| The rooms — one file per area | `$PANEL_DIR/areas/<area>.md` (committed) | a project's people are project facts |
| Saved presets | `$PANEL_DIR/presets.md` (committed) | shared across the team |
| The screen reviewers | `$KIT_ROOT/skills/panel/screens.md` | the same five lenses everywhere |
| The builders' prompts | `panel.builderPrompts` in harness.json | the repo's own review rule; `--review` refuses without it |
| Reviewer memory | `$PSTATE/memory/<name>.md` | per machine, written only from the operator's marks |
| Runs | `$PSTATE/runs/<date>-<area>-<mode>/` | per machine: asks, scores, report |
| Browser for click-checks | `panel.browser` in harness.json (a Playwright install) | screen checks refuse without it |
| The report | `python3 "$KIT_ROOT/scripts/panel-report.py" <run> --bar <bar>` | every number counted from the files |

An area file holds: **the job in one line** (all a blind reviewer is told — plain words, no
design), the default subject, asks per person, then one short paragraph per person who would use
that area, and a **Past runs** list. If the area file does not exist, write one before running,
show the operator the room in one line, and go on.

## Honesty rules — read them every run

- **Blind means blind.** A writer gets the job line, their own profile and the "marked noise" lines
  from their memory — never the design, the code, a ticket, past scores or this conversation. Every
  writer's completion reports `tool_uses`; **above 0 is contaminated** — re-run once, then drop and
  say so.
- **Never retype.** Extract each writer's list from its output file with `jq`; count from files.
- **Two scorers** for customer asks, independent. Where they disagree, take the stricter verdict and
  list both for the operator.
- **An answer counts only where that person can see it** — a member's question answered on an
  admin-only screen is not answered.
- **A plain "no" counts** when the question was "does it?". A button that only shows a message is
  partly answered at most.
- **Name the stand-in** before quoting a number: "answered" means a scorer found a screen that
  answers it as asked, not that a real user succeeded — unless `--use-it` ran.
- Verdicts: `ANSWERED` · `PARTIAL` · `MISSING` · `NOT_IN_SCOPE` (sparingly).

## Step 0 — the run

| Argument | Means | Default |
|---|---|---|
| first word | an area file, or a preset | ask |
| `--shape` `--fix` `--screens` `--review` `--all` | the mode | audit |
| `--use-it` | customers' top asks become jobs the checker performs | off |
| `--not-blind` | writers may see the design | blind |
| `--bar N` | the gate | `panel.bar`, else 70 |
| `--may sketch` / `--may tickets` | what the panel may change | nothing |
| `--room "A, B"` | exactly who is in the room | the mode's default |
| `--add "<one sentence>"` | add a person to this area first (profile + memory file) | — |
| `--on <path or URL>` | what is judged | the area's default subject |

| Mode | Customers | Screens | Builders | Result |
|---|---|---|---|---|
| shape | ✓ | | Principal | the asks are the output; no scoring |
| **audit** | ✓ | | Principal | asks scored against the design |
| fix | ✓ | ✓ | Principal | audit, change the sketch copy, re-check, before → after |
| screens | | ✓ | Principal | questions written blind, a checker clicks through each |
| review | | | all four | the builders' prompts, cold, none sees another |
| all | ✓ | ✓ | all four | one run, one report |

Make `$PSTATE/runs/<date>-<area>-<mode>/`, write `subject.md` with every setting, and save a local
copy of the subject — checkers click the copy, so a later edit cannot change what was scored.

## Step 1 — memory

Read each reviewer's memory. Pass only their **Marked noise** lines in. Never past asks or scores.

## Step 2 — writing, blind

All writers **in one message, in parallel, in the background**. Each prompt begins:

> Do not open any file, repository or website. Work only from what is below.

- **Customer:** their profile, the area's job line, then "Write down everything you would ask it,
  look for or need to do over six months, in your own voice, as one-line entries. Aim for about N
  lines. Numbered list only." In `--shape`, add a WOULD MAKE ME SAY NO list of up to 10.
- **Screen reviewer:** their lens from `screens.md`, "The screen's job:" + the job line, then
  "Write 40–60 questions you'd need this screen to answer, one line each, first person, numbered."
- **Builders:** the repo's prompts verbatim, on the spec.

Check `tool_uses`, extract to `asks-<name>.txt`, and state the total before going on.

## Step 3 — checking

- **Customer asks:** two scorer agents, given the asks, the saved design (read **all** of it,
  including its code) and the area's open tickets. Scorer A assigns 15–25 plain-English clusters
  (the shape of answer an ask needs); B scores verdicts only against A's clusters.
- **Screen questions:** one checker per screen reviewer, driving the saved design in headless
  Chromium from `panel.browser`. Phone lens: a phone viewport (390 and 320), touch, measured tap
  targets and overflow. Keyboard lens: keyboard only, the accessibility tree, measured contrast and
  focus. Every verdict records **what was clicked** in its evidence.
- **Merge** to `scores.tsv`: `panel reviewer n cluster verdict_a verdict_b verdict ticket ask evidence`.

## Step 4 — the principal

One agent reads the scores, the missing list and any builder reviews, and answers in at most five
lines: is this the right thing at all, the pattern under the misses, and the one change that moves
it most — split into what a real build fixes for free and what is a real design gap. Save it as
`principal.md`; the report puts it at the top.

## Step 5 — fix (`--fix` or `--may sketch`)

Change **only a copy** of the sketch. Never the live product, never the repo. A product decision the
fix needs (privacy, retention, who sees what) is made the cautious way and listed as a question.
Test the copy by clicking through it before re-checking. Keep the first scores as
`scores-before.tsv`, re-check with the **same** checkers and the **same** clusters.

**Re-check after every fix round** — a fix creates bugs, and only the re-check finds them. Fix
those, re-check again, and stop when a round finds nothing new. Anything fixed after the last
re-check is said to be verified by a test, not re-scored.

`--may tickets` drafts one ticket per unplanned gap cluster into the run folder and files none.

## Step 6 — report and gate

```bash
python3 "$KIT_ROOT/scripts/panel-report.py" "$RUN" --bar "$BAR"
```

Publish the report and open it. Below the bar the verdict is **stops the build**: do not start
building that area until each big gap is planned, fixed, or left out by the operator — record which
in `subject.md`. When the subject is a live route, run the repo's existing screen checks last.

## Step 7 — learn

Ask the operator (multi-select, up to four) which reviewer calls were **useful**; the unticked are
**noise**. Append each to that reviewer's memory with the date, and append the run to the area
file's **Past runs**. A second run with the same area, mode and room is offered as a preset.

## Never

- Show a writer the design, the code, a ticket, past scores or this conversation.
- Retype a list or a count. Call one scorer two.
- Count an answer on a screen the asker cannot see.
- Change the live product or the repo — the panel changes sketch copies and drafts tickets.
- Write to a reviewer's memory without the operator's mark.
