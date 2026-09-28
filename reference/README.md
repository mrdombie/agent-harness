# reference/

Copies of things this plugin replaced, kept so nothing is lost and so a reader
can see what the live version was reconciled FROM. **Nothing here is loaded.**
Claude Code reads `skills/`, `agents/` and `hooks/`; this directory is inert.

## retired-2026-09-28 — the copies removed when the plugin became the only source

Before this, the same commands, agents and hooks existed two and three times
over, in places Claude Code loads from independently and does not deduplicate.
Measured on 2026-09-27:

| Thing | Copies | Worst drift between them |
|---|---|---|
| `/claim` | 3 | 474 lines, user copy vs repo copy |
| `/finish` | 3 | 654 lines |
| the three review agents | 3–4 each | — |
| five guard hooks | 3 registrations each | three different versions firing in order |

An agent could not tell which one it had just run, and neither could a reader.

| Folder | Was loaded from | Now |
|---|---|---|
| `user-commands/` | `~/.claude/commands/*.md` | the plugin's `skills/`, except the five a project owns |
| `repo-skills/` | the consuming repo's `.claude/skills/<n>/SKILL.md` | the plugin's `skills/` |
| `repo-agents/` | the consuming repo's `.claude/agents/*.md` | the plugin's `agents/` |
| `repo-hooks/` | the consuming repo's `.claude/hooks/*` | the plugin's `hooks/`, registered once in `hooks/hooks.json` |

Five of the user commands are NOT superseded — `critic`, `design`, `flows`,
`push-to-uat`, `release-notes-draft` are one project's own and belong in that
repo's `.claude/skills/`, not on one machine. They are archived here as a record
of what still has to move; the kit ships no copy of them.

`scripts/check-single-source.sh` is what fails when any of this comes back, and
`scripts/retire-duplicates.sh` is what clears a machine that still carries it.
