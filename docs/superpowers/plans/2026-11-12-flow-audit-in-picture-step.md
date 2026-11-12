# Plan — the blind flow audit runs in the picture step

**Goal:** port the flow-coverage audit into the kit as a skill, and run it in the design
picture phase for new and redesigned screens only: a blind cartographer (job line +
taxonomy only), then a checker that drives the clickable picture. Every STRANDS and LIES
gap is fixed before the owner sees the picture, in the same pass as the critic's findings.

## F1 — the skill, the blind cartographer, and its brief

| File | Action |
|---|---|
| `skills/flows/SKILL.md` | create — ported, project-agnostic |
| `skills/flows/TAXONOMY.md` | create — the eight axes, verbatim |
| `skills/flows/REPORT-TEMPLATE.md` | create — pinned to the integration branch |
| `agents/flow-cartographer.md` | create — `tools: []` |
| `scripts/flow-audit.sh` | create — `brief cartographer --job "<line>"` |
| `scripts/flow-audit.test.sh` | create |

**Behaviour:** a builder hands the cartographer a screen's job line and it gets only that
line and the taxonomy; a job line carrying a path, file name or URL is refused with exit 2,
and the cartographer agent has no tools to open the repo.

**Test (`scripts/flow-audit.test.sh`):**

| Case | Red when |
|---|---|
| brief is exactly the job line + `TAXONOMY.md`, run inside a repo holding stories | the brief appends a story path or any repo file |
| a path, file name or URL in the job line exits 2 and names it | the job-line refusal is deleted |
| `flow-cartographer.md` declares an empty tools list | Read, Bash, Grep or Glob is added |

## Later items

The checker that drives the clickable picture, the wiring into the picture phase for
`screen:new` / `screen:redesign`, and retiring the machine-local copy follow as their own
items.
