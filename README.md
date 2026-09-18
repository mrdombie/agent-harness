# agent-harness

A project-agnostic agentic development harness. One installable Claude Code plugin holding the commands, agents, hooks, skills and scripts that take a ticket from filed to merged — and **one config file per project** holding everything that differs between repos.

> **Status: empty shell.** The manifest and directory structure exist. Nothing has moved in yet. See *What is not here*.

## The idea

The harness this comes from works for any developer, but only on one repo: the GitHub slug, the label names, the branch prefix, the UI kit and the design law were written into 37 of its 94 harness files. That is the only thing standing between "our workflow" and "a workflow anyone can install".

| Lives in the plugin | Lives in your repo |
|---|---|
| the commands, agents, hooks, skills | `.claude/harness.json` — your facts |
| the mechanics of claiming, gating, shipping | your own gate scripts and CI |

The kit names no project. When it needs a project fact it reads the config, and when the config lacks one it **refuses with the key name** rather than falling back — a silent fallback is how a kit keeps working on the repo it was born in and quietly breaks everywhere else.

## The config

`.claude/harness.json` in the consuming repo:

```json
{
  "repo": "you/your-repo",
  "integrationBranch": "develop",
  "branchPrefix": "tkt-",
  "stateDir": "~/.claude/your-tickets",
  "labels": {
    "ready": "status:ready",
    "claimed": "status:claimed",
    "inReview": "status:in-review",
    "hold": "needs:human-approval",
    "decision": ["status:pm-track", "status:pm-decision"]
  },
  "law": "docs/design/design-philosophy.md",
  "gates": {
    "local": ["npm run gates"],
    "requiredChecks": ["Typecheck + Unit tests", "Code gates"]
  }
}
```

Read a value with `toolkit_cfg <dotted.key>`. Arrays join on spaces, so `for l in $(toolkit_cfg labels.decision)` reads naturally.

## Precedence

A repo-defined command shadows the plugin's, and the kit prints one line saying it was shadowed. Silent shadowing is how you spend an afternoon debugging the wrong file.

## What is not here

Everything except the shape. The generic core moves in once the originating repo's harness stops naming itself — a sweep of 407 occurrences across 36 files that has to land first, or this plugin would ship the very coupling it exists to remove.

The acceptance test for that move is blunt: a case-insensitive grep for the origin project's names, outside the docs, must return zero.

## Licence

MIT.
