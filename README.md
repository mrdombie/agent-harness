# agent-harness

A project-agnostic agentic development harness. One installable Claude Code plugin holding the skills, agents, hooks and scripts that take a ticket from filed to merged — and **one config file per project** holding everything that differs between repos.

Extracted from [Maktura](https://github.com/mrdombie/maktura), where it ran for six months against ~900 tickets. The README is the one place the origin project is named — `scripts/check-project-agnostic.sh` reads the list below and fails CI if anything else in the repo matches it.

```
origin-names: maktura|socialhub|social-hub|mrdombie
```

## The idea

| Lives in the plugin | Lives in your repo |
|---|---|
| the skills, agents, hooks, scripts | `.claude/harness.json` — your facts |
| the mechanics of claiming, gating, shipping | your own gate scripts and CI |
| the git-safety guard rails | your project-specific rules |

The kit names no project. When it needs a project fact it reads the config, and when the config lacks one it **refuses with the key name** rather than falling back — a silent fallback is how a kit keeps working on the repo it was born in and quietly breaks everywhere else.

## Install

The repo is its own marketplace. In the consuming repo's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "agent-harness": { "source": { "source": "github", "repo": "mrdombie/agent-harness" } }
  },
  "enabledPlugins": { "agent-harness@agent-harness": true }
}
```

Or per machine: `claude plugin marketplace add mrdombie/agent-harness && claude plugin install agent-harness@agent-harness`.

**Depends on [superpowers](https://github.com/obra/superpowers)** — `writing-plans`, `systematic-debugging`, `subagent-driven-development`, `test-driven-development`, `verification-before-completion`, `requesting-code-review`, `receiving-code-review`. The kit's build chain invokes them by name and does not vendor them; [`briefs/facts.json`](briefs/facts.json) is the machine-readable list — and it is the list the driver READS, not prose. The driver parks the ticket when a step's transcript shows none of the skills that file declares for it, and again when the answer claims a skill the transcript never shows.

`brainstorming` is deliberately NOT in that list. It waits on a person, so an unattended step cannot invoke it — the approved spec stands in for it, and `briefs/facts.json` records that under `notInvoked`.

Also needed on the machine: `gh` (authenticated), `jq`, `node`, `python3` (hook self-tests only).

## The config

`.claude/harness.json` in the consuming repo. Every key below except `legacyEnvPrefix`, `sisterRepos`, `design`, `uat` and `law` is required; a missing one refuses by name.

```json
{
  "repo": "you/your-repo",
  "integrationBranch": "develop",
  "branchPrefix": "tkt-",
  "stateDir": "~/.claude/your-tickets",
  "sisterRepos": [],
  "legacyEnvPrefix": "",
  "labels": {
    "drafting": "status:drafting",
    "ready": "status:ready",
    "claimed": "status:claimed",
    "inReview": "status:in-review",
    "gated": "status:gated",
    "partial": "status:partial",
    "blocked": "status:blocked",
    "externalBlocked": "status:external-blocked",
    "parked": "status:parked",
    "needsHuman": "status:needs-human",
    "pmDecision": "status:pm-decision",
    "pmTrack": "status:pm-track",
    "hold": "needs:human-approval",
    "decision": ["status:pm-track", "status:pm-decision", "needs:human-approval"]
  },
  "law": "docs/design/design-philosophy.md",
  "standards": "docs/CODING_STANDARDS.md",
  "gates": {
    "local": ["npm run gates"],
    "changed": ["npm run lint:changed", "npm run typecheck:changed", "npm run test:changed"],
    "formatChanged": "npm run format:changed",
    "requiredChecks": ["Typecheck + Unit tests", "Code gates"]
  },
  "review": {
    "rounds": 2,
    "attest": {
      "ui-gate": {
        "owed":   "npm run check:ui-gate-attested --silent -- --base origin/develop --head HEAD",
        "review": "<a command that runs your reviewer and prints its verdict>",
        "record": "scripts/record-verdict.sh ui-gate --sha {{SHA}} --base {{BASE}}"
      }
    }
  },
  "worktreeRoot": "~/your-worktrees",
  "worktree": { "prepare": ["npx prisma generate"], "scratch": ["docs/notes"] },
  "commit": { "parkType": "chore" },
  "design": {
    "kit": "@you/ui",
    "tokens": "packages/ui/src/tokens.ts",
    "surfacePaths": ["apps/web/**", "packages/ui/**"],
    "render": "npm run -s renders"
  },
  "programmes": { "brief": "scripts/programme-state-brief.sh {{EPIC}}" },
}
```

- `gates.changed` — the CHANGED-ONLY checks an agent runs locally, in order. This is what `/agent-harness:finish` and the `gate-runner` agent run; the whole-app form is CI's job. Measured 2026-09-28 before this existed: load sat at 32-40 on 10 cores because every agent ran a whole-app typecheck and a full suite that the push hook and CI then ran again. `no-repo-wide-format.sh` refuses the whole-app form from an unattended run, so this is enforced rather than asked for.
- `review.attest` — one entry per reviewer the project attests, and **one entry is all there is**: an interactive `/agent-harness:finish` and the unattended driver ask different questions of the same reviewer, so they read the same row rather than two keys that can disagree about which reviewers exist. A row may name an `agent` in place of a `review` command (the driver then runs that reviewer itself), and `"needsRenders": true` marks a reviewer that judges pictures: with no render on the record it refuses by name instead of running.
  - `owed` — the command that says whether that reviewer is owed on this diff and prints the fingerprint its trailer must carry. `/agent-harness:finish` Step 3.5 runs them all together. A bare string in place of the object is read as this, which is the shape that shipped first.
  - `review` — a command that runs the reviewer and prints its verdict. The driver runs it in the ticket worktree and keeps the output verbatim.
  - `record` — a command that reads that output **on stdin** and writes the trailer, with `{{SHA}}` (the commit reviewed) and `{{BASE}}` (the trunk) substituted. **The driver never writes a verdict**: your recorder reads the reviewer's own words and decides whether there is one to write, which is the whole point of an attestation. A recorder that refuses parks the ticket carrying its message.

  A row with `owed` alone is advisory to the driver and enforced by `/agent-harness:finish`. A row with `review` and `record` is what lets the driver push at all on a project whose pre-push demands a trailer — measured on 2026-09-28, a ticket built test-first with two proved tasks lost 9 commits to exactly that. Absent entirely, the reviewers are advisory and nothing fails when one is skipped — which is the state that let 46 pixel-changing tickets ship with zero verdicts.
- `owns.skills` / `owns.agents` — kit names this project deliberately shadows. Everything else under its `.claude/` that the kit also ships is a duplicate and fails the gate.
- `review.rounds` — how many review rounds before non-blocking findings become follow-up tickets. Two.
- `gates.formatChanged` — the diff-only formatter, quoted back when a whole-folder format is refused.
- `stateDir` — per-machine state (the claims cache, the session label, the auto-skip list). One per project; two projects on one machine must not share it.
- `legacyEnvPrefix` — if your fixtures already pin env vars under an older prefix (`FOO_STATE_DIR`), declare `"FOO"` and the kit reads `HARNESS_X`, then `FOO_X`. The kit itself names no prefix.
- `gates.local` is the list of LOCAL gate commands, and it is the only part of `gates` anything runs. `group` names a gate group inside your own runner and `requiredChecks` names the CI checks a pull request waits on — neither is a shell line, and the driver never treats them as one. A flat `{ "<name>": "<command>" }` map is read too; a key whose value is not a string counts as an empty command, so it is named in the "nothing ran" refusal rather than dropped in silence.
- `standards` is the coding-standards document a change is held to, handed to the build step as its own fact. It has **no fallback**: without it the build agent is told there is none, and is told so in a sentence. It used to fall back to `law`, which meant a project with a design philosophy and no `standards` key had its build step told the design philosophy IS the coding standard — a wrong document, which cannot be seen from inside a prompt, where an absence can.
- `worktreeRoot` is optional (default `$TMPDIR`): where the driver cuts its ticket worktrees. `~` is expanded. Name one — on macOS `$TMPDIR` is a `/var/folders` directory the system prunes, and between the build and the push the worktree is the only copy of the work.
- `worktree.scratch` is optional: extra paths a step's own tooling writes into the worktree that are NOT the change. The driver moves them out into the run record after every model step, so neither the park's `git add -A` nor the ship step's clean-tree check ever sees them. `docs/superpowers` is always swept; a path git TRACKS is never touched, because there it is the change.
- `changelog.branchTrailer` is optional: the commit-message line this project's changelog gate accepts ONCE for a whole branch as a reasoned skip (e.g. `no-changelog-branch`). When every build answer reported `changelog: {skipped}` and no commit on the branch carries the line, self-check adds one empty commit with `<trailer>: <reason>` — no history is rewritten.
- `design.surfacePaths` is optional: the globs this project calls a screen. The compare step matches the branch diff against them to decide whether there is a screen to render at all; without it that step says so and compares nothing. Entries are git pathspecs, so `":(exclude)**/*.test.ts"` takes test files out; a list of only excludes is refused, because git reads it as every other file. With a renderer but no approved picture for the change, compare takes the renders for review and makes no parity check.
- `design.render` is optional: a command run in the ticket worktree that prints one render per line as `name<TAB>path<TAB>light|dark<TAB>route`. Its output becomes the renders the compare step holds beside the approved design, and the renders the review step is given. Absent is an absence the reviewer and the pull request are TOLD about in those words; declared and producing nothing is a refusal, because a measurement that could not be made is not a screen that is fine. Exit 3 is the one exception: it means the renderer knows no screen this change touches, and is recorded as an absence in the renderer's own words, exactly as a project with no renderer.
- `programmes.brief` is optional: a command that prints the BRIEF of a programme's state file, with `{{EPIC}}` and `{{FILE}}` substituted. These files are append-only and grow for as long as the programme is open, and a step handed the whole thing designs from the programme's history rather than from its own ticket. The driver finds the file by **what it says** — the state file whose content names the ticket's programme label — never by its filename: on the project this was measured on all 29 files are named for the epic and the label lives in the body, so a filename glob matched none of them.
- `review.diffBytes` is optional (default 400000): how much of the branch diff the review step hands the reviewer. Past it the diff is cut and the cut is STATED beside the file list, because a reviewer handed a silently-shortened diff reviews a change it cannot see the rest of.
- `worktree.prepare` is optional: commands run in every fresh worktree the driver cuts, and in the two trees its red-before-green proof checks out. This is for whatever your repo generates per checkout and gitignores — a generated database client, a build artifact a hook imports. Absent is normal and skipped. Three things are refusals, because a tree that cannot pass your pre-push is better discovered before the build than after it: a command that **fails**, a `prepare` that is **not a list** (a bare string prepares nothing and used to report success), and a **list entry that is not a command**.
- `commit.parkType` is optional (default `chore`): the conventional-commit type the driver's park uses for its work-in-progress commit. Your commitlint enum decides; `wip` is not in most of them, and a park whose commit is refused is a park that loses the work.
- `tests.patterns` is optional (default `["*.test.ts", "*.test.tsx", "*.spec.ts"]`): the globs, matched against the whole path, that name a test file for `scripts/check-deleted-tests.sh`. `HARNESS_TEST_PATTERNS` (space-separated) overrides it. A value that is not a list is a refusal, not the default.
- `design` is optional: a backend-only project has none, and the design skills refuse on its absence rather than inventing one.
- `panel` is optional and only `/agent-harness:panel` reads it: `dir` (where your rooms live, e.g. `.claude/panel`, required for the panel), `bar` (the gate, default 70), `browser` (a Playwright install for click-checks), `builderPrompts` (your spec-review prompts). The rooms — one file per product area, the people who'd use it — are yours and live in `dir`; the kit ships only the method and the five screen reviewers. Memory and runs stay per machine under `stateDir/panel`.

Read a value with `toolkit_cfg <dotted.key>` after sourcing `scripts/toolkit-env.sh`. Arrays join on spaces, so `for l in $(toolkit_cfg labels.decision)` reads naturally.

Env overrides always win over the config: `HARNESS_STATE_DIR`, `HARNESS_REPO_ROOT`, `HARNESS_MAIN_REPO`, `HARNESS_SISTER_REPO`, `HARNESS_CFG_PATH`, `HARNESS_LOGIN`, `HARNESS_KIT_ROOT`.

## What is here

```
skills/    file claim finish release release-stale queue needsme standup
           work auto bug ui-gate cheatsheet claim-status sweep-worktrees project
           panel (+ its five screen reviewers)
agents/    gate-runner frontend-gate design-critic
hooks/     hooks.json + the scripts it runs, each with a .test.sh beside it
scripts/   toolkit-env.sh (the resolver) · claim-lock.sh · reconcile-claims.sh
           overlap-check.sh · spawn-claim.sh · claimable-issues.sh · clear-hold.sh
           check-project-agnostic.sh (CI) · panel-report.py (the panel's report)
           check-deleted-tests.sh (a deleted test is accounted for — see below)
driver/    build-ticket: one ticket, seven fixed steps, the model called only for
           the thinking · facts.sh fills the briefs' placeholders and refuses when
           one has no value · prompt-schema.jq derives the shape the model is
           bound to from the contract — see driver/README.md
swarm/     agents that run with no session open: scheduler · queue · repair-watch
           live-view · report · install — see swarm/README.md
rules/     standing-rules.md — put in front of every session by a hook, so a
           second machine behaves like the first
shared/    operator.md · agent-signoff.md
reference/ the copies this plugin replaced, kept for history. Loaded by nothing.
```

Invoke a skill as `/agent-harness:<name>` — plugin skills are namespaced by Claude Code. Agents are `agent-harness:<name>` in the Agent tool.

### Hooks

| Event | Hook | Does |
|---|---|---|
| SessionStart | `standing-rules.sh` | puts `rules/standing-rules.md` in front of the session |
| SessionStart | `precedence.sh` | one line per kit skill this repo overrides |
| PreToolUse (Bash) | `block-push-no-verify.sh` | refuses `git push --no-verify` |
| PreToolUse (Bash) | `block-hookify-rules.sh` | the git-safety rules: hand-released claims, `commit -a`, `commit --no-verify`, `reset --hard`, `git add -A`, `npm install` in a worktree, hand-rolled PRs, hand-rolled ticket branches |
| PreToolUse (Bash) | `no-repo-wide-format.sh` | refuses a formatter over a whole folder, and a whole-app check from an unattended run |
| PreToolUse (Bash) | `no-broad-kill.sh` | refuses a `pkill`/`killall` pattern that would hit a peer agent |
| PreToolUse (Write\|Edit) | `block-write-traps.sh` | a phantom worktree path, an edit in the shared clone, a credential in a memory file, a new command or skill born outside the kit |
| SessionEnd | `session-end-cleanup.sh` | drops the session's own scratch state |
| Stop | `signoff-backstop.sh` | refuses a hand-back without the sign-off banner while work is live |
| Stop | `ask-dont-narrate.sh` | refuses a hand-back that narrates a decision instead of asking it |
| Stop | `keep-working.sh` | refuses a hand-back mid-loop while the scope still has runnable tickets |

The git-safety rules are hooks, not hookify rules, on purpose: hookify loads rules with a relative glob on `.claude/hookify.*.local.md`, so every rule is inert unless the session started inside a checkout. A hook reads the command text before bash does and does not care about cwd. **A consuming repo that carried these as hookify rules removes them**, or they fire twice.

### Scripts the skills expect in the consuming repo

The kit's own scripts live here and are addressed from the plugin root. A few repo-side conventions are read from the consuming repo's `scripts/` (materialised from `origin/<integrationBranch>` by `toolkit_tools`) when present, and skipped when not: `programme-status.sh`, `programme-state-brief.sh`, `sweep-orphan-worktrees.sh`, `refresh-shared-manifests.sh`, `auto-promote-gated-children.sh`, `queue-health-report.sh`. Child 4 of the extraction (the gates contract) turns those into config.

## Adding a skill

Every new skill, command, agent or hook starts **here**, not in a personal `~/.claude` folder: `skills/<name>/SKILL.md`, project facts read from `.claude/harness.json` (refusing by key name when one is missing), a test beside any script, a version bump, a PR. Then update the plugin on each machine. Something only one project needs goes in that project's `.claude/skills/` instead. A skill that exists only in one person's `~/.claude` is one machine away from being lost.

## A deleted test says what replaced it

A pull request that deletes a test file, or deletes `it(` / `test(` cases from
one, fails until its body accounts for each file:

```markdown
## Deleted tests
- `src/desk.test.ts` → covered by `src/desk/one-desk.test.ts`
- `src/export.test.ts` → removed on purpose: CSV export was retired
```

"covered by" must name a test file that exists at head with a live case;
"removed on purpose" must give a reason. A file git sees as **renamed** is not a
deletion, but its cases are compared across the rename, and a case turned into
`it.skip` counts as lost. The diff is two dots, base..head, read from the two
commits — never the working tree — and anything the trunk added after the branch
was cut is excluded. Written after a rebuild on the origin project deleted eleven
test files in one merge: one pinned a behaviour the new screen dropped, nothing
went red, and a real user was blocked for a week.

It runs in three places, so skipping a skill does not skip it:

- **CI** — `.github/workflows/deleted-tests.yml` is a reusable workflow. The
  consuming repo calls it on `pull_request` (with `edited` in the types, so fixing
  the body re-runs it) and makes `Deleted tests are accounted for` a required
  check. It reads the pull request's merge commit, so `HEAD^1..HEAD` is exactly
  what merging changes. While this repo is private the caller passes a token that
  can read it as `harness_token`, and the repo's Actions access setting must allow
  the caller's workflows. The kit runs it on itself through
  `kit-deleted-tests.yml`, with `*.test.sh` as its pattern.
- **`/agent-harness:finish`** — Step 5.6, before the merge.
- **The driver's ship step** — its body carries no such section, so a branch that
  deletes a test stays a draft and parks with the files named.

## Building one ticket

`driver/build-ticket <ticket>` walks a ticket through seven fixed steps —
start · plan · build · self-check · review · record · ship — calling a model only
for the four that need thinking, one step at a time. It refuses to skip a step,
resumes from the last one that finished, proves each new test red before green
with its own hands, and parks the ticket with the question whenever a step asks
one. Full description, the guarantees and every seam:
[`driver/README.md`](driver/README.md).

It is the replacement for the two hand-copied build commands, not an addition to
them: `docs/design/claim-finish-inventory.md` maps all 178 of their rules to a
driver step, a brief, a hook, a required check, or a named retirement.

## Running without a session open

`swarm/install.sh` puts four timers on the machine: the live view everything
else reads, a scheduler topping each programme up to three agents, a watcher
that brings one agent back to a broken pull request and stops after three, and
a reporter. `swarm/queue.sh add <ticket> --brief <file>` is how a ticket joins
the queue — it replaces writing a launcher by hand. Full description, the rules
it holds to and every setting: [`swarm/README.md`](swarm/README.md).

## What it costs

`scripts/usage-report.sh [--since YYYY-MM-DD] [--by ticket|operator|week]` — spend per
spawned run from the records the spawner already leaves (`runs/<id>.json` + the log's
`result` line): ticket, operator, turns, cost, outcome (done / budget / error / died).
Reads records only, never an API. A window writes no run record, so the total is a
floor and the footer says so. `/standup` prints today's line; `/project` shows it per
programme.

## One copy, and it is this one

**The plugin is the only source.** A consuming repo carries no copy of a skill,
agent or hook the plugin ships, and neither does a machine's own `~/.claude`.

This is not tidiness. Claude Code loads from all three places and **does not
deduplicate across them**, so a second copy is a second live version. Measured
2026-09-27 on the estate this kit came from: `/claim` existed three times at
1,268 / 1,118 / 1,052 lines with 474 lines differing between the first two,
`/finish` differed by up to 654 lines across its copies, the review agents had
three and four copies each, and five hooks were registered three times over as
three different versions — firing in order, each one's verdict overwritten by
the next. No agent could say which version it had just run.

Two things keep it that way:

```bash
scripts/check-single-source.sh [<repo>]   # fails when a second copy appears
scripts/retire-duplicates.sh  [--check]   # clears a machine that still carries one
```

`retire-duplicates.sh` **refuses to run before the plugin can take over.** It
compares against the INSTALLED plugin, not the checkout, and stops when that
install does not yet register a hook it is about to remove — otherwise the
machine has no guard at all until the next update. Measured by doing exactly
that on 2026-09-28: ten registrations became one while the running install
registered six of the nine.

**A declared override is not a duplicate.** A project may legitimately shadow a
kit skill — most often because the kit has not extracted that layer yet and the
project's copy carries wiring the kit's does not. It says so in `harness.json`:

```json
"owns": { "skills": ["finish", "claim"], "agents": ["design-critic.md"] }
```

Both this gate and the project's own read that one key, because two gates with
two hardcoded lists is the same defect one level up — they drift, and the one
that drifts low stops failing.

`check-single-source.sh` belongs in a consuming repo's CI. It fails on a repo
copy; it reports a machine copy and only fails on it under `--strict`, because a
repo's CI cannot fix somebody's home directory.

**Precedence, when a copy does exist.** Plugin skills are namespaced, so a repo's
own `.claude/skills/<name>` never collides with the kit's: the repo's is invoked
bare (`/claim`), the kit's is always `/agent-harness:claim`. A per-user
`~/.claude/commands/<name>.md` shadows the same way. That shadow is silent, so
`precedence.sh` prints one line at session start for every kit skill the repo
overrides — a deliberate project override is legitimate; an accidental stale
copy is what the gate above is for.

## Running the tests

```bash
for t in hooks/*.test.sh hooks/lib/*.test.sh scripts/*.test.sh swarm/tests/*.test.sh driver/tests/*.test.sh; do bash "$t"; done
bash scripts/check-project-agnostic.sh
```

CI runs all of them on every push, and fails by name on a tracked suite no glob
reached — a suite nothing runs reports green by never reporting at all. `check-project-agnostic.sh` reports a control alongside its count — a zero from a strictness probe means clean, suppressed, or never ran, and the control tells you which.

## Not here yet

- The design layer (`/design`, `/critic`, `/flows`, the on-theme reminder hook) still reads its origin repo's kit and law by path. Child 3 of the extraction puts it behind `design.*` in the config. Those five commands are the ones `retire-duplicates.sh` leaves alone and reports rather than moving — the kit ships no copy of them yet, so removing them would lose them.
- The gates contract: `/finish` reads `gates.changed` for the local run, but the rest of the gate shape is still the consuming repo's. Child 4.

## Licence

MIT.
