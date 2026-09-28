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
  "gates": {
    "local": ["npm run gates"],
    "requiredChecks": ["Typecheck + Unit tests", "Code gates"]
  },
  "worktree": { "prepare": ["npx prisma generate"] },
  "commit": { "parkType": "chore" },
  "design": { "kit": "@you/ui", "tokens": "packages/ui/src/tokens.ts" }
}
```

- `stateDir` — per-machine state (the claims cache, the session label, the auto-skip list). One per project; two projects on one machine must not share it.
- `legacyEnvPrefix` — if your fixtures already pin env vars under an older prefix (`FOO_STATE_DIR`), declare `"FOO"` and the kit reads `HARNESS_X`, then `FOO_X`. The kit itself names no prefix.
- `gates.local` is the list of LOCAL gate commands, and it is the only part of `gates` anything runs. `group` names a gate group inside your own runner and `requiredChecks` names the CI checks a pull request waits on — neither is a shell line, and the driver never treats them as one. A flat `{ "<name>": "<command>" }` map is read too; a key whose value is not a string counts as an empty command, so it is named in the "nothing ran" refusal rather than dropped in silence.
- `worktree.prepare` is optional: commands run in every fresh worktree the driver cuts, and in the two trees its red-before-green proof checks out. This is for whatever your repo generates per checkout and gitignores — a generated database client, a build artifact a hook imports. Absent is normal and skipped; **present and failing is a refusal**, because a tree that cannot pass your pre-push is better discovered before the build than after it.
- `commit.parkType` is optional (default `chore`): the conventional-commit type the driver's park uses for its work-in-progress commit. Your commitlint enum decides; `wip` is not in most of them, and a park whose commit is refused is a park that loses the work.
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
driver/    build-ticket: one ticket, seven fixed steps, the model called only for
           the thinking · facts.sh fills the briefs' placeholders and refuses when
           one has no value · prompt-schema.jq derives the shape the model is
           bound to from the contract — see driver/README.md
swarm/     agents that run with no session open: scheduler · queue · repair-watch
           live-view · report · install — see swarm/README.md
shared/    operator.md · agent-signoff.md
```

Invoke a skill as `/agent-harness:<name>` — plugin skills are namespaced by Claude Code. Agents are `agent-harness:<name>` in the Agent tool.

### Hooks

| Event | Hook | Does |
|---|---|---|
| SessionStart | `precedence.sh` | one line per kit skill this repo overrides |
| PreToolUse (Bash) | `block-push-no-verify.sh` | refuses `git push --no-verify` |
| PreToolUse (Bash) | `block-hookify-rules.sh` | the seven git-safety rules: hand-released claims, `commit -a`, `reset --hard`, `git add -A`, `npm install` in a worktree, hand-rolled PRs, hand-rolled ticket branches |
| SessionEnd | `session-end-cleanup.sh` | drops the session's own scratch state |
| Stop | `signoff-backstop.sh` | refuses a hand-back without the sign-off banner while work is live |
| Stop | `ask-dont-narrate.sh` | refuses a hand-back that narrates a decision instead of asking it |

The git-safety rules are hooks, not hookify rules, on purpose: hookify loads rules with a relative glob on `.claude/hookify.*.local.md`, so every rule is inert unless the session started inside a checkout. A hook reads the command text before bash does and does not care about cwd. **A consuming repo that carried these as hookify rules removes them**, or they fire twice.

### Scripts the skills expect in the consuming repo

The kit's own scripts live here and are addressed from the plugin root. A few repo-side conventions are read from the consuming repo's `scripts/` (materialised from `origin/<integrationBranch>` by `toolkit_tools`) when present, and skipped when not: `programme-status.sh`, `programme-state-brief.sh`, `sweep-orphan-worktrees.sh`, `refresh-shared-manifests.sh`, `auto-promote-gated-children.sh`, `queue-health-report.sh`. Child 4 of the extraction (the gates contract) turns those into config.

## Adding a skill

Every new skill, command, agent or hook starts **here**, not in a personal `~/.claude` folder: `skills/<name>/SKILL.md`, project facts read from `.claude/harness.json` (refusing by key name when one is missing), a test beside any script, a version bump, a PR. Then update the plugin on each machine. Something only one project needs goes in that project's `.claude/skills/` instead. A skill that exists only in one person's `~/.claude` is one machine away from being lost.

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

## Precedence

Plugin skills are namespaced, so a repo's own `.claude/skills/<name>` never collides with the kit's copy: **the repo's is invoked bare (`/claim`), the kit's is always `/agent-harness:claim`.** The repo's copy is that project's override. Because the shadow is silent, `precedence.sh` prints one line at session start for every kit skill the repo shadows.

The same holds for a per-user `~/.claude/commands/<name>.md`: bare `/<name>` resolves to it, `/agent-harness:<name>` to the kit.

## Running the tests

```bash
for t in hooks/*.test.sh hooks/lib/*.test.sh scripts/*.test.sh swarm/tests/*.test.sh driver/tests/*.test.sh; do bash "$t"; done
bash scripts/check-project-agnostic.sh
```

CI runs all of them on every push, and fails by name on a tracked suite no glob
reached — a suite nothing runs reports green by never reporting at all. `check-project-agnostic.sh` reports a control alongside its count — a zero from a strictness probe means clean, suppressed, or never ran, and the control tells you which.

## Not here yet

- The design layer (`/design`, `/critic`, `/flows`, the on-theme reminder hook) still reads its origin repo's kit and law by path. Child 3 of the extraction puts it behind `design.*` in the config.
- The gates contract: `/finish` still expects the consuming repo's `npm run gates` shape. Child 4.

## Licence

MIT.
