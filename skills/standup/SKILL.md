---
name: standup
description: What's happening in THIS session: tickets touched, what's in flight, what's stuck. Ends by asking which thing to do first, then does it. Usage: /agent-harness:standup | /agent-harness:standup all | /agent-harness:standup access
---

You are giving the operator a status board for **this session**.

**Output tables. No narrative.** No preamble, no recap of what you did, no
explanation of the programme. If a fact does not fit in a cell it does not go in
this report. The only thing that is not a table is the **NEXT** block at the end,
which is what the whole report exists to produce.

## Scope — this is the part that was wrong before

**Default (no argument) = the tickets THIS session touched.** Not the board. The operator
asked for "what's happening in this context window"; a whole-repo scan answers a
question they did not ask and takes two minutes.

- `/agent-harness:standup` → this session's tickets
- `/agent-harness:standup all` → whole board (slow; only when explicitly asked)
- `/agent-harness:standup access` → one area

## Speed budget — 3 API calls, under ~10 seconds

**Never run `gh issue view` or `gh pr list` inside a loop.** That is what made
the first version unusable: ~100 sequential calls. One batched query returns the
same data.

## Step 0 — what is this session scoped to (no API call)

`/agent-harness:work <label>` records its resolved scope here; `/agent-harness:auto` clears it:

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
cat "$STATE_DIR/.session-label" 2>/dev/null
```

One line, two tab-separated fields — the scope and the **local** time it was set,
carrying its offset:

```
project:welcome-flow	2026-08-30T14:05:22+0100
```

Read it and age it. `%z` is what makes both halves work — a bare `Z` is parsed by
macOS `date -jf` as local time, which silently shifted the displayed clock by the
whole BST offset:

```bash
IFS=$'\t' read -r SCOPE SET_AT < "$STATE_DIR/.session-label"
AGE_H=$(( ( $(date +%s) - $(date -jf '%Y-%m-%dT%H:%M:%S%z' "$SET_AT" '+%s') ) / 3600 ))
```

`${SET_AT:11:5}` is the clock time and `${SET_AT:0:10}` the date — no reformatting
needed.

Missing or empty is the normal case for a session that never ran `/agent-harness:work`. It is
not an error and it is not worth a line of output.

## Step 1 — which tickets

Session ledger, written as you work:

```bash
LEDGER="$STATE_DIR/.session-tickets"
```

One number per line. **Append to it the moment you file, claim, amend or ship a
ticket** — that is what makes this command instant. If it is missing or empty,
fall back to one search (still a single call):

```bash
gh search issues --repo "$REPO_SLUG" --involves @me --updated ">=$(date -u -v-2d +%Y-%m-%d)" \
  --limit 40 --json number -q '.[].number'
```

## Step 2 — hydrate them in ONE call

GraphQL batches N issues into a single request. Build the alias list from the
ledger, then:

**Build the alias list with `awk`, not a shell `for` loop.** The operator's shell may be zsh,
and zsh does not word-split an unquoted `$NUMS` — the old loop ran **once** with
every number glued together, producing `issue(number:8175 8580 9340 ...)` and
`gh: Expected NAME, actual: INT`. awk is shell-agnostic:

```bash
ALIASES=$(sort -un "$LEDGER" | awk '{printf " i%d:issue(number:%s){number title state stateReason labels(first:20){nodes{name}} timelineItems(last:1,itemTypes:CROSS_REFERENCED_EVENT){nodes{__typename}}}", NR-1, $1}')
gh api graphql -f query="query{repository(owner:\"${REPO_SLUG%/*}\",name:\"${REPO_SLUG#*/}\"){$ALIASES}}" \
  > /tmp/standup.json
```

Parse locally with jq. **No further per-ticket calls.**

`sort -un | wc -l` under-counts the ledger by one when the last line has no
trailing newline — count the hydrated aliases instead, not the file.

## Step 3 — live claims (1 call, local script)

The ref is the claim; `$LBL_CLAIMED` (claimed) is a mirror that goes stale in both
directions — a ticket can hold a live ref with no label, and carry the label with
no ref.

```bash
"$KIT_ROOT/scripts/claim-lock.sh" list --json \
  | jq -r '.[] | [(.issue|tostring),(if .mine then "mine" else (.agent//"?") end),(.branch//"?"),(.claimed_at//"")[0:16]] | @tsv'
```

Cross-reference against the hydrated set. Report both directions of drift.

## Step 3.5 — spend this session

One line, from the run records (spawned agents only — a window writes none):

```bash
KIT=$(bash "$(git rev-parse --show-toplevel)/scripts/harness-kit.sh" 2>/dev/null || echo "${CLAUDE_PLUGIN_ROOT:-}")
"$KIT/scripts/usage-report.sh" --since "$(date -u +%Y-%m-%d)" | tail -3 | head -1   # total  N  $X.XX
```

## Step 4 — render

Omit any table with no rows. Never print an empty table or a "none" row.

**The description is the column that matters. The number is a reference, and it
goes LAST.** A row that leads with `#9015` tells the operator nothing they can act on.

```
🏷️ WORKING — project:welcome-flow · set 14:05

📊 THIS SESSION — <YYYY-MM-DD HH:MM>   ·   N touched · N shipped · N open

🔨 IN FLIGHT
| What | Branch | Since | State | # |
|---|---|---|---|---|

⚠️ STALLED
| What | Why it isn't moving | # |
|---|---|---|

✅ OPEN — READY
| What it does | P | # |
|---|---|---|
| Invites land in the wrong workspace | P1 | 9019 |

📦 SHIPPED THIS SESSION
| What shipped | # |
|---|---|
| Three roles — Owner, Admin, Member | 9014 |

▶️ NEXT
| Who | What to do | Run |
|---|---|---|
| **You** | Approve the welcome sequence — nothing else is holding a merge | github.com/$REPO_SLUG/pull/9922 |
| **You** | Decide whether variant rules get enforced before they get relocated | — |
| Agent | Ship the next Content Lab ticket | `/agent-harness:work content-lab` |
| Agent | A merged ticket is still holding its claim | `/agent-harness:release-stale` |
```

## The `NEXT` block — this is what the report is FOR

Everything above `NEXT` is the state. `NEXT` is the only part that tells the operator what
to do with it, so it is the one section that is never omitted: when there is
genuinely nothing, say so in one row rather than dropping the heading.

- **Three columns, always: `Who` · `What to do` · `Run`.**
- **`Who` is `You`, `Agent`, or a peer's login — `claim-lock.sh list --json` says `mine: true` for the operator's own claims (the one rule, with the older host-only claims covered) and carries `agent` for the rest — and the operator's rows sort FIRST.** They are the bottleneck;
  the agent work can start any time.
- **`What to do` is the WORK in plain English** — same rule as every other table.
  "Approve the welcome sequence", never "review #9816". No ticket number, no
  `fix(x):` prefix, no file path, no gate name.
- **`Run` is a literal thing they can act on** — a slash command in backticks, or a
  URL they can click. Never a description of a command ("re-run the gate"); print
  the command. When the row is a decision with nothing to run, use `—`.
- **A `You` row must name the DECISION, not the ticket.** "Decide whether variant
  rules get enforced before they get relocated" is actionable; "look at #5478" is
  not.
- **Cap it at ~5 rows.** This is what to do next, not a backlog. If there are
  more, the extra ones were not next.
- **Do not re-list what the tables above already showed.** A row earns its place
  by naming an ACTION, not by repeating a status.
- **Every row must come from a read taken in THIS turn.** Not from earlier in the
  session, however recent it feels. A `NEXT` row is the one thing the operator is asked to
  act on, so it is the worst place to be stale — and the session's own work is
  exactly what makes it stale, because the fixing happens while the number sits
  in context.

  Burned 2026-08-30: the alert list was read at 15:45 and the row printed at
  16:28. The operator had dismissed the advisory themselves at 15:59, so the top row of the
  report — and the option they then picked — was work they had already done. Every
  other row that turn came from a live query; this one came from memory, and that
  is the only reason it was wrong.

  **The test:** for each row, name the command whose output you are holding, and
  when it ran. If it did not run in this turn, re-run it or drop the row.

`NEEDS YOU` used to sit at the top of this report. It is gone — `/agent-harness:needsme` is the
command for that, it sorts genuinely-blocked from merely-labelled, and two views
of the same thing drift apart. What the operator needs from `/agent-harness:standup` is the one line they
would have had to work out themselves: what now.

## Step 5 — offer the pick, then DO it

Printing `NEXT` and stopping makes the operator retype something the report already
worked out. So after the table, put the same rows to the operator as a choice, and act on
the answer in the same turn.

**Ask with `AskUserQuestion`. One question, header `Do first`.**

- **Options are the `NEXT` rows, verbatim in meaning** — the `What to do` text is
  the label. Do not re-word them between the table and the question; if the two
  disagree, one of them is wrong.
- **Cap at 4** — the tool's limit. `NEXT` may hold 5 rows; the question takes the
  top 4 in the same order (the operator's rows first). Never silently reorder to fit.
- **Each option's description says what happens if they pick it** — which command
  runs, or what they will be looking at. That is the thing they are actually choosing
  between.
- **Plain language, same as the table.** No ticket numbers, no file paths, no gate
  names in a label or a description.
- **Do not add a "do nothing" option.** The tool always offers `Other`, which
  covers it, and a decline option invites the loop to stall.

**Skip the question entirely when there is nothing to choose between:**

- **0 rows** — say so in one line. Nothing to ask.
- **1 row** — there is no choice; just do it, and say that is what you are doing.
  A two-option question with one real option is ceremony.

**Then act on the answer, in the same turn — do not report back and wait.**

| Row type | What acting means |
|---|---|
| `Agent` | Run the command in the `Run` column. It was chosen; it does not need confirming again. |
| `You` — has a URL | Print the link on its own line so it is one click. Do not summarise the page instead. |
| `You` — a decision | Ask the decision itself, properly, with `AskUserQuestion`. Do not restate it as prose and stop. |

The speed budget (≤3 API calls) covers the REPORT. Work that follows the pick is
the work — it is not counted against it and must not be trimmed to fit it.

## Rules

- **Tables only.** The `NEXT` block and the `WORKING` line are the sole exceptions.

### The `WORKING` line

- **No `.session-label`, or an empty one → omit the line entirely.** Same rule the
  tables already follow: never print an empty row to say there is nothing.
- **Always print the set-time**, straight from the stamp — same calendar day →
  `set 14:05`, an earlier day → `set 2026-08-29 14:05`. The age is then something
  the operator can check rather than take on trust.
- **Stale marker.** Set more than **4 hours** ago, or on an earlier date, appends the
  age:

  ```
  🏷️ WORKING — project:welcome-flow · set 2026-08-29 14:05 · ⚠️ STALE (27h ago)
  ```

  **Word it as the age, never as "no `/agent-harness:work` this session".** A file timestamp is a
  stand-in for the label's freshness, not evidence of what ran in this window — the
  hour count is the measurement, and it is the only claim to make.
- Print it in every mode — `/agent-harness:standup`, `/agent-harness:standup all`, `/agent-harness:standup <area>`. It describes
  the session's scope, not the report's, so `all` does not suppress it.
- **Never a bare ticket number.** Every reference carries a plain-English
  description of what it does; the number is the reference, not the label.
  "Replace the grant table with one manage edge (#9015)" — never "#9015".
- **Cell text is what the ticket DOES**, not its commit-style title — "Invites
  land in the wrong workspace", never "fix(access): Team and Access resolve
  orgs[0]…". Strip the `feat(x):` / `fix(x):` prefix always.
- **Never call something "in flight" without a live ref.** `in-review`, a
  label-only `claimed`, and a stale PR all go under STALLED with the reason.
- **The REPORT is read-only — everything up to and including `NEXT`.** Report
  mislabels; offer the fix as a `NEXT` row with the command to run. Never relabel
  while building the board. What happens after the operator picks is ordinary work and is
  not bound by this: they chose it.
- **Say what you did not check.** If the ledger was empty and you fell back to
  the search, say so in the header — the two are not the same set.
- No emoji beyond the section markers. No "great progress". No recap of the work.

## Keeping the ledger honest

The ledger is the whole reason this is fast. During normal work, append on:
file · claim · amend · comment · ship. One line:

```bash
echo "9015" >> "$STATE_DIR/.session-tickets"
```

It is per-machine and disposable — a new session starts a new one. Clear it with
`: > "$STATE_DIR/.session-tickets"` when starting fresh work.
