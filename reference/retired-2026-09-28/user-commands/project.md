---
description: "Maktura — everything for one subject: the tickets, the order they get done in, who holds what, and how far through it actually is. Works on a programme or an area. Read-only — use /work <subject> to actually ship them. Usage: /project (lists both) | /project <programme> | /project <area> | /project --session (what THIS session has been on)"
---

You are reporting on **one subject** — every ticket for it, wherever it lives on the board, in the
order it will actually be worked, with an honest figure for how far along it is.

A subject is one of two things, and **which one changes Step 1 and Step 4**:

| Mode | Label | It is | Finish line? |
|---|---|---|---|
| **PROGRAMME** | `project:*` | a named push that ends and retires | yes → report **% complete** |
| **AREA** | `area:*` | a permanent shelf of the product | **no** → report **% runnable** |

| Invocation | Mode |
|---|---|
| `/project` | list programmes and areas, then stop |
| `/project <subject>` | **read-only** status board (Steps 0–5). Takes nothing. |
| `/project --session` | the subject **this session has been working on**, with what the session did to it, then its board |
| `/work <subject>` | **work it** — a separate command that ships the tickets. This one only reports. |

`/queue` renders every area at once, one ticket-line each, and it buckets a ticket under its
**first** `area:` label only — so a dual-tagged ticket appears under one of its two areas there.
This command is the single-subject cut: full depth on one label, dependencies resolved, and it
finds dual-tagged tickets correctly because it queries `--label` directly.

For a programme that is also the orthogonal cut across areas: ER spans `area:FEED`,
`area:WATCH` and `area:AI-INFRA`, and no area view can show it whole.

## Two traps that will silently give you a wrong answer

**1. Query `mrdombie/maktura`. Never `mrdombie/social-hub`.**
The repo was renamed. Unfiltered calls follow the redirect fine, so `gh issue list --repo
mrdombie/social-hub` returns all ~900 issues and looks healthy — but **`--label` filtering through
the redirect silently returns `0`**. Measured 2026-08-27: `project:watch-monitoring` returned 0 via
`social-hub` and 13 via `maktura`. A zero here means the query is broken, not that the label is
unused. Always use the canonical name.

**2. Never read `INDEX.tsv`.** It is a stale derived mirror. On 2026-08-07 it held 792 rows against
878 open issues, and listed 15 tickets as claimed when 4 were. GitHub is the queue.

**3. `gh issue view <N>` resolves pull requests too.** A PR number in a ticket list is accepted
silently, takes the label, and then never appears in `gh issue list` — so the set you labelled and
the set you counted differ by one and nothing errors. Measured 2026-08-27: #9640 is a PR; 35
tickets took the label and 34 came back. **Reconcile what you labelled against what the query
returns, and investigate any gap** rather than trusting the second number.

## Guard

```bash
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated — run: gh auth login" >&2; exit 1; }
REPO=mrdombie/maktura
```

## Step 0 — resolve the subject to a label

**One call, then group locally.** Never loop `--label` per label — that is 35+ calls and minutes of
latency for a board you already hold:

```bash
gh issue list --repo "$REPO" --state open --limit 1000 --json number,labels \
  -q '.[] | [([.labels[].name]|join(","))] | @tsv' > /tmp/board.tsv
```

With no argument, print **both** tables from that one read — programmes with open/closed, areas with
ready/open — then stop. Do not pick a subject yourself.

### `/project --session` — the subject THIS session has been on

`--session` is a flag, not a subject — it resolves to no label. It means *work out which subject I
have been on and report that*. Resolve it from what the session actually did, in this order, and **say which
signal you used** — the inference is a stand-in, so it has to be checkable rather than magic.

| Order | Signal | Use it when |
|---|---|---|
| 1 | `.session-label` | it exists AND was written in the last 12 hours — `/work` wrote it, so it is an explicit scope |
| 2 | the tickets this session touched | otherwise |
| 3 | nothing | say so in one line and print the two tables instead — never guess a subject |

**Signal 2 is the one that needs care, because the ledger outlives the session.**
`~/.claude/socialhub-tickets/.session-tickets` is append-only and nothing clears it — it held 95 rows
from earlier sessions on 2026-09-05, so its raw contents are *not* this session's work. Filter it by
what GitHub says actually moved:

**Use `issueOrPullRequest`, never `issue`.** The ledger carries PR numbers as well as issue numbers,
and `issue(number:)` on a PR is an *unresolvable node*: GraphQL returns partial data plus an error,
`gh` prints that error onto **stdout** mixed into the JSON, and the whole read fails to parse. Measured
2026-09-07 — three PR numbers in the ledger broke the entire query. The inline fragment simply skips
anything that is not an Issue.

```bash
LEDGER=~/.claude/socialhub-tickets/.session-tickets
ALIASES=$(tail -40 "$LEDGER" 2>/dev/null | sort -un | awk '{printf " i%d:issueOrPullRequest(number:%s){... on Issue{number title updatedAt labels(first:20){nodes{name}}}}", NR-1, $1}')
[ -n "$ALIASES" ] && gh api graphql -f query="query{repository(owner:\"mrdombie\",name:\"maktura\"){$ALIASES}}"
```

A PR alias comes back as `{}` — drop empties before counting, or a PR number inflates nothing but
still reads as a row.

Keep only the issues whose `updatedAt` is inside the last 12 hours. **Name the substitution out loud
in the output**: *ledger rows GitHub says moved in the last 12h* is standing in for *what this session
touched*, and they are not the same thing — a peer agent editing the same ticket lands in the set too.
That is why the basis line prints the tickets, not just the conclusion.

The subject is then the most common `project:` label across those issues, falling back to the most
common `area:`. `project:` wins a tie, same rule as an explicit argument.

**One ticket is enough.** A session that shipped a single thing has a subject; do not require a
quorum and do not average two unrelated areas into a third.

**When the session spans two subjects**, report the one with the most touched tickets and name the
other in one line — never merge them, and never silently drop it:

```
Also touched: Platforms (1 ticket) — /project platforms
```

### The context block — what makes `--session` worth running

The board alone is not the answer here: the ask is the *context*, which is what the session did to
this subject. Print this block **above** the Step 5 header, then the normal board:

```
🧭 THIS SESSION — Ops (area:OPS)
   Picked from: 2 tickets in the ledger GitHub says moved in the last 12h
                · area labels take the product's own names (10105, merged)
                · the runner keychain hang (10001, in flight)

   Shipped 1 · in flight 1 · filed 1
```

- **The basis line is mandatory.** A subject inferred without showing its evidence is a guess wearing
  a confident face, and this command's whole job is to be checkable.
- **Name the thing, not the number** — the ticket's plain-English description, its number in brackets.
- Omit `Also touched:` when there is only one subject. Omit a zero count rather than printing `0`.

With an argument, resolve it case-insensitively and on substrings, **`project:` first**:

| Argument | Resolves to | Mode |
|---|---|---|
| `ER`, `event registry` | `project:event-registry` | PROGRAMME |
| `welcome-flow` | `project:welcome-flow` | PROGRAMME |
| `ops`, `OPS` | `area:OPS` | AREA |
| `notifications` | `area:NOTIFICATIONS` | AREA |

`project:` wins a tie, because a programme is the more specific claim on the same word.

**If nothing matches either namespace**, the subject has never been defined. Do not invent a file.
Go to Step 1, run the discovery search, present the proposed set, and offer to create a
`project:` label and apply it. Creating the programme IS the first run.

**If the argument matches an `area:` label, set `MODE=AREA`** and carry it to Steps 1 and 4 — it
changes what those steps do. Everything else in the command is identical.

## Step 1 — the ticket set, and keeping it honest

**a. Everything already labelled** (open and closed — closed tickets are the numerator):

```bash
for st in open closed; do
  gh issue list --repo "$REPO" --state $st --label "$LABEL" --limit 300 \
    --json number,title,labels,state,closedAt,body \
    -q '.[] | [(.number|tostring), .state,
               ([.labels[].name|select(startswith("P"))]|first // "P?"),
               ([.labels[].name|select(startswith("status:"))]|first // "status:none"|ltrimstr("status:")),
               ([.labels[].name|select(startswith("effort:"))]|first // ""|ltrimstr("effort:")),
               .title] | @tsv'
done
```

An epic's children table is lettered (A/B/C) but the tickets exist under numbers and say `Child of #N` in their bodies — search for that, never the letters; 'never filed' is usually wrong.

**b. Candidates that look like they belong but carry no label.** This is what stops the programme
decaying between runs. Search title AND body — most tickets name the subject in the body only.

> **MODE=AREA — skip b entirely.** An area is exhaustive by construction: every open ticket carries
> exactly one, and the count that proves it is `0 tickets with no area:` (measured 2026-09-01, 888
> of 888 covered). There is nothing to discover, and a title search would only surface tickets whose
> *subject* is elsewhere — `fix(settings): PlatformAnalyticsCard lies about YouTube` matches
> "settings" and belongs to DESIGN-SYSTEM. **Proposing those is how a good area taxonomy gets
> wrecked.** Go straight to Step 2.

**`OR` does not work in `gh search issues` — it silently returns `0`.** Union single-term searches
instead. (Measured 2026-08-27: `'event registry OR eventregistry'` → 0 results; each term alone →
dozens.)

```bash
: > /tmp/cand.tsv
for term in "eventregistry" "event registry" "concept sweep" "IntelMention" "er-concepts"; do
  gh search issues --repo "$REPO" --limit 100 "$term" --json number,title,state \
    -q '.[] | [(.number|tostring), .state, (.title[0:70])] | @tsv' 2>/dev/null \
    | sed "s/\$/\t$term/" >> /tmp/cand.tsv
done
awk -F'\t' '!seen[$1]++' /tmp/cand.tsv | sort -t$'\t' -k1,1n
```

**Tier the results before showing them.** A raw match list is unusable — ER returns 149 tickets,
most of which merely mention it in passing:

| Tier | Signal | What to do |
|---|---|---|
| **1** | Subject in the **title**, or body cites the subject's own files (`er-*.ts`, `eventregistry.ts`, `mention-sync.ts`) | Propose for labelling |
| **2** | Multiple distinct terms matched, or the term appears in the **Description** block | Show with the matched term, ask |
| **3** | One incidental mention | Suppress — report only as a count |

Tier 3 is where the false positives live: a readability-batch ticket matches `eventregistry`
because a file path appears in a list of 60 files; a rate-limit ticket matches because ER is one of
17 adapters. Show the matched term so the user can see *why* it surfaced.

**If tier 1+2 comes back very large (≳40), the subject is more than one programme.** ER has had at
least three: #7114 "ER becomes the sole intelligence engine" (closed, complete), the #8461 Watch
programme, and the current feed-builder push. Say so and ask which one is being asked about, rather
than averaging a finished programme into a live one and reporting a meaningless percentage.

**Apply only on confirmation.** Never auto-apply — one false positive joins the programme and skews
the percentage silently.

```bash
gh issue edit <N> --repo "$REPO" --add-label "$LABEL"
```

Report what you added. If nothing new turned up, say so in one line — a quiet run is a real result.

## Step 2 — who actually holds what

**The claim ref is the claim. The `status:claimed` label is a mirror and it goes stale.**

```bash
~/.claude/socialhub-tickets/scripts/claim-lock.sh list     # ISSUE  AGENT  BRANCH  CLAIMED_AT
```

Cross the refs, the labels, the PRs and the branches. **Four states are all "held by nothing", and
each looks like progress until you check:**

| What you see | What it means | Fix |
|---|---|---|
| `status:claimed`, no live ref | zombie label — `/claim` won't hand it out and nobody is building it | `/release-stale` |
| Live ref, ticket **closed / in `MERGED.tsv`** | shipped but the claim was never released — the ref blocks re-claiming | `/release` |
| Live ref, branch has commits, **no open PR** | the work exists and is reachable by nothing | open the PR |
| Live ref, branch **behind the merged parent** | stacked PR auto-closed when its base was deleted | new PR against `develop` |

The last one is not hypothetical: on 2026-08-27 PR #9703 was stacked on #9701's branch; #9701
merged at 10:57, the base branch was deleted, and GitHub auto-closed #9703 in the same minute. It
cannot be reopened — its base ref is gone. 14 commits, no PR, ticket still reading `claimed`.

For each open ticket, resolve the PR and whether it is actually moving:

```bash
gh pr list --repo "$REPO" --state all --search "<N> in:title,body" \
  --json number,state,mergedAt,baseRefName,headRefName,mergeStateStatus,statusCheckRollup
git ls-remote --heads origin "sh-<N>/*"          # branch alive?
git rev-list --count origin/develop..origin/<branch>   # work not yet on develop
```

A red check is not automatically a failure — ask whether it **ran**. `steps: 0` and ~2s across
every job is Actions billing, not your code. A conflicted PR creates zero CI runs, which reads as
"CI is broken".

## Step 3 — the order they get done in

Build a dependency graph, do not just sort by priority.

1. **Parse blockers from each body.** The ticket template has a `**Blockers:**` line; also catch
   `blocked on #N`, `needs #N first`, `#N must land first`, and `Blocked on: #N`.
2. **Read the sequencing comments.** Dependencies are often discovered after filing and recorded in
   a comment, not the body — e.g. #9215 carries "Worth landing #9685 first so any before/after on
   scoping is read against a sweep that actually completes." Fetch comments for tickets in the set.
3. **Topologically sort.** Ties break by priority (P0→P3), then effort ascending — smallest first
   inside a tier, so the tier clears rather than stalling on its biggest ticket.
4. **Flag conflicts explicitly.** Two tickets specifying the same change is a collision, not an
   ordering — #9645 step 2 and #9215 finding 2 are the same work, and one must defer. Say so;
   silently ordering them hides it.
5. `status:gated` and `needs:dom-approval` sort out of the runnable list entirely — they are not
   next, they are waiting on a human. Name what each waits on.

## Step 4 — the headline figure

**Effort-weighted either way, with the count beside it.** A ticket count treats an XL epic and a P3
label rename as equal, which is how you get "23% done" on a programme whose single epic outweighs
its ten ready tickets combined.

| `effort:` | weight |
|---|---|
| S | 1 |
| M | 3 |
| L | 8 |
| XL | 20 |

**Unestimated tickets are reported, never zeroed** — in both modes. A ticket with no `effort:` label
is unknown work, and silently treating it as 0 inflates the percentage. State the count and its
share. Never print a figure without it.

### MODE=PROGRAMME — % complete

- **Numerator:** closed tickets' weight. **Denominator:** every ticket's weight in the set.
- Also state the **runnable** figure. A programme that is 60% done with everything remaining gated
  is not 40% from finished.

```
ER — 14% by effort · 8/26 tickets · 5 unestimated (19% of the set carries no weight)
```

### MODE=AREA — % runnable, and **no completion figure at all**

**An area has no finish line, so "x% done" is not a hard figure — it is a meaningless one.** OPS has
261 closed and 106 open; it will still have open tickets when the company is ten times the size.
Dividing one by the other produces a number that looks like progress and measures nothing.

Report instead **how much of the open work is pickup-able right now**:

- **Numerator:** `status:ready` weight. **Denominator:** all open weight in the area.
- Name the biggest non-runnable bucket, because that is the actionable half — `drafting` and
  `pm-track` are the PM's queue, not an agent's, and an area that is 40% runnable because 103
  tickets sit in `drafting` has a writing problem, not a build problem.
- Closed tickets are **context, not a numerator**: print the lifetime count on its own line.

```
OPS — 57% of open work is runnable · 69/107 tickets ready · 31 unestimated (29% carries no weight)
      261 closed all-time · biggest blocked bucket: drafting (19)
```

## Step 5 — render

Only the **header block** differs by mode. Every section below it is identical.

**MODE=PROGRAMME**

```
🎯 PROGRAMME: Event Registry   (project:event-registry)   <YYYY-MM-DD HH:MM>

   14% by effort  ·  8/26 tickets  ·  5 unestimated
   ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
```

**MODE=AREA** — same shape, different question. Label the bar, so it is never misread as progress:

```
📇 AREA: OPS   (area:OPS)   <YYYY-MM-DD HH:MM>

   RUNNABLE  57% of open work  ·  69/107 ready  ·  31 unestimated
   ████████████████████████████░░░░░░░░░░░░░░░░░░░░░░
   261 closed all-time  ·  biggest blocked bucket: drafting (19)
```

Then, in both modes, **the run sheet** — one list, every ticket, in the order it gets done.
Read `~/.claude/shared/run-sheet.md` and follow it exactly. It replaces the five
state-bucket sections this step used to print:

```
📋 EVENT REGISTRY — 8 of 26 done · 14% by effort · 5 unestimated

 ✅ ┬ Concept sweep stops at page 1                            9685
 ✅ ├ Newest articles, not most relevant                       9623
 🔨 ├ Category exclusions across the sweep                     9645  ◀ here
 ⬜ ├ Evidencing sentence dropped by one SELECT                 9053
 ⬜ ├ Sources over-report items per week                        8238
 ⬜ ├ Watch sweeps only the first six tracked parties           9248
 🚧 ├ Variant rules relocate into the lab                       9718  ◀ waits on 9053
 🙋 ┴ Draft cards                                               9222  ◀ needs a mockup
```

Then, underneath it, the section the run sheet does **not** absorb:

```
⚠️ NEEDS ATTENTION
  #8016, #8017  closed and merged but still holding claim refs → /release
  #9645         held by a claim with no PR → open one against develop
  2 candidates found with no project: label → apply?
```

Rules:
- **The run sheet is the answer to "where is this up to"** — it is the body of the report,
  and its order is the deliverable. Never re-group it by state; that is what it replaced.
- Bar is 50 chars. Round the percentage; never show decimals.
- **NEEDS ATTENTION is the point of the command.** A programme that looks 60% done with two
  zombie claims and an orphaned branch is not 60% done. It sits below the run sheet because
  a zombie claim is not a state a ticket is in — it is a command to run. Make each line say
  which one.
- Never report a percentage without the unestimated count next to it.
- **MODE=AREA:** the run sheet starts at 🔨 and the lifetime closed count goes on the header
  line. 261 ✅ rows help nobody, and an area has no history worth replaying.
- **MODE=AREA on a big label still shows every open row.** Group the ⬜ band by the clusters
  actually present and say you did — but never cap it, and never silently trim.


## What you do not do

- Don't query `mrdombie/social-hub`. Don't read `INDEX.tsv`.
- Don't decide "claimed" from a label. The ref is the claim.
- Don't auto-apply a `project:` label without confirmation.
- Don't claim, release, or open PRs yourself — report them and name the command. The one write this
  command makes is applying a confirmed `project:` label.
- Don't invent an effort weight for an unestimated ticket to make the percentage tidier.
- **Don't report a completion % for an area, in any wording.** Not "x% done", not "x of y shipped".
  An area does not finish. Report % runnable and the lifetime closed count.
- **Don't move a ticket between areas from this command.** It is read-only on `area:*` — if a
  placement looks wrong, say so and leave it. The only write is a confirmed `project:` label.
