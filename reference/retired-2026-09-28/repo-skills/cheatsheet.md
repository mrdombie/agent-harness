---
name: cheatsheet
description: "Show the commands and skills we built here — grouped, one line each. Usage: /cheatsheet | /cheatsheet <name> (full detail for one) | /cheatsheet <partial> (search)"
---

You are printing a reference card for the commands and skills **this repo
carries** under `.claude/skills/` — the ones the team built. Not Claude Code's
builtins, not the plugin commands, not the marketplace skill installs.

Read the tree every time. A hard-coded list goes stale the day a command is
added, and a cheatsheet that silently omits a command is worse than no
cheatsheet.

## The read

One call gets every name and description. Commands and skills live in the same
tree, one directory each; the description is the first `description:` line,
not a fixed line number, because frontmatter is not uniform:

```bash
cd "$(git rev-parse --show-toplevel)"
for f in .claude/skills/*/SKILL.md; do
  printf '%s\t%s\n' "$(basename "$(dirname "$f")")" \
    "$(sed -n '/^description:/{s/^description: *//p;q;}' "$f" | sed 's/^"\(.*\)"$/\1/; s/\\"/"/g')"
done
```

## Turning a stored description into a row

The stored descriptions are long. Derive both columns mechanically — never
hand-write a gloss, or a description edit stops showing up here:

| Column | Rule |
|---|---|
| **What it does** | Strip a leading `<project> — ` prefix if one is present. Take the text up to the first `. ` or the first `Usage:`, whichever comes first. |
| **Call it** | The `Usage:` segment if the description has one, with the `Usage: ` prefix dropped. Otherwise just `/name`. |

Trim to roughly 70 characters. A row that wraps in a terminal defeats the table.

## Groups

Membership is fixed here on purpose — deriving it from the descriptions gives
different groupings run to run.

| Group | Commands |
|---|---|
| **Ticket lifecycle** | `file` `claim` `finish` `release` `release-stale` `queue` `project` `work` `auto` `bug` |
| **Design & review gates** | `design` `ui-gate` `critic` `flows` `reinvented` |
| **Ops & housekeeping** | `push-to-uat` `release-notes-draft` `sweep-worktrees` `standup` `claim-status` `cheatsheet` |

**Anything on disk and not in those three lists prints under `Other`.** This is
the part that stops this file rotting. Do not drop an ungrouped command, and do
not guess which group it belongs in — print it under `Other` so someone can file
it deliberately.

## Skills

Three directories in the tree are skills a command wraps, not commands in their
own right: the design skill `/design` invokes (named in its SKILL.md),
`reimplementation-audit`, `screen-flow-audit`.
Print them in their own table, and `review-gate` (run on a loop, not typed)
alongside them.

A directory in none of these lists goes under `Other` for the same reason.

Three commands are thin shells over a skill with a different name, which is not
guessable from either name. Always print this map:

| Command | Skill it runs |
|---|---|
| `/reinvented` | `reimplementation-audit` |
| `/flows` | `screen-flow-audit` |
| `/design` | the skill named in `.claude/skills/design/SKILL.md` ("Invoke the … skill") |

## Arguments

`$ARGUMENTS` decides which of three things you print.

**Empty** → the full board: the three grouped tables (plus `Other` if it has
rows), then the skills table, then the wrapper map.

**An exact command or skill name** → just that one:

- its full frontmatter description, verbatim and untruncated
- the skill it wraps, if it is in the map above
- its file path

**Anything else** → substring-match it against every command and skill name and
print the matches as a table. No matches: say so in one line. Do not fall back
to printing the whole board, and do not guess at what they meant.

## Output rules

- **Tables. No prose paragraphs, no preamble, no closing summary.** Print the
  board and stop.
- No counts, no file sizes, no "I found N commands".
- One row per command, always three columns: name, what it does, how to call it.
