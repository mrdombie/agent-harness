---
description: Maktura — everything genuinely blocked on Dom, sorted from everything that only LOOKS blocked on him. Prints the board, then walks him through his items one at a time and runs the full motion on each answer. Usage: /needsme | /needsme --board (no walk) | /needsme --tier1 (skip the rest)
---

You are clearing Dom's blocking queue.

**Output tables. No narrative.** The only prose permitted is the per-item card
and the closing line. No preamble, no recap of what you scanned, no explanation
of the gate.

---

## The one question that tiers everything

> **Can any agent resolve this without Dom?**

If yes it is not his, however loudly the label says otherwise. This is the whole
value of the command — see the trap below.

---

## THE TRAP THIS COMMAND EXISTS TO AVOID

Measured 2026-08-30: five open PRs carried a red `approval-gate`. **Three of the
five were not waiting on Dom at all.** The gate's own runtime log said:

```
✗ This PR changes what a user sees and carries no screenshot.
```

That is an agent that skipped its evidence step. A version of this command that
tiers on the red check — or on the `needs:human-approval` label — hands Dom three
items he cannot action, and he stops reading the list. That is exactly how the
queue of 86 died (#9174).

**So: never tier a PR on its check colour or its label. Tier it on the gate's
RUNTIME REASON.** Read the reason before you place the row.

State the substitution before any count reaches Dom:

> I am using *<what the query matched>* as a stand-in for *<what I am claiming>*.

If the halves differ, the number does not get printed.

---

## EVERY CHANNEL, OR THE LIST IS A LIE

Dom asked for **everything** that needs him. A sweep that covers four of five channels
does not report "I checked four" — it reports a confident, short number. That is the
failure mode, and it happened: **2026-09-01 this said "1 item yours" with three
waiting.**

Before printing any count, confirm all five ran:

| # | Channel | Where it hides | Section |
|---|---|---|---|
| 1 | PRs carrying `needs:human-approval` | open PRs | 1a–1c |
| 2 | **ISSUES carrying it, with no PR** | design calls, concept posted, never answered | **1c-bis** |
| 3 | Dead claims | the claim ref, not the label | 1d |
| 4 | Falsely-parked `status:gated` | the `**Blockers:**` field | 1e |
| 5 | `status:in-review` with no PR | unreachable tickets | 1f |

**If a channel's probe fails, say the channel failed.** An empty table needs the scan
to have provably run — a probe returning 0 may be broken, not clean.

**When Dom names an item this scan missed, that is a HOLE, not a one-off.** Find the
channel it lives in, add it here, and state the substitution that hid it.

## Step 1 — collect (parallel; do not loop `gh` per ticket)

**The label is `needs:human-approval`.** It was `needs:dom-approval` until the gate
was renamed; measured 2026-09-20 the old name returns 0 rows on PRs AND issues, which
reads as a clean board with 4 items waiting. `gh label list | grep approval` is the
source of truth if it moves again.

Repo is `mrdombie/maktura`. **Never pass `--label`** — it redirects from
`social-hub` and returns 0 rows silently. Filter labels client-side with `jq`.

### 1a · Open PRs — one call

```bash
gh pr list --repo mrdombie/maktura --state open --limit 100 \
  --json number,title,labels,isDraft,headRefName,updatedAt,url \
  -q '.[] | [(.number|tostring),(.labels|map(.name)|join(",")),(.isDraft|tostring),.headRefName,(.updatedAt[0:10]),(.title)] | @tsv'
```

`mergeStateStatus` from a LIST call is `UNKNOWN` — GitHub computes it lazily.
Get it per-PR in 1b, not here.

### 1b · Per-PR state — only for PRs that matter

```bash
gh pr view "$P" --repo mrdombie/maktura \
  --json mergeable,mergeStateStatus,statusCheckRollup,body \
  -q '"\(.mergeable) \(.mergeStateStatus) checks=\(.statusCheckRollup|length) red=\([.statusCheckRollup[]?|select(.conclusion=="FAILURE" or .conclusion=="ACTION_REQUIRED")|.name]|join("|"))"'
```

**Conflict rule** — `DIRTY` alone means nothing; it is usually stale:

| Signal | Means |
|---|---|
| `DIRTY` + `checks == 0` | **REAL conflict** — no CI ran because it cannot merge |
| `DIRTY` + `checks > 0` | Stale merge state — treat as mergeable until proven otherwise |

### 1c · WHY each red gate is red — the load-bearing call

Two things here are easy to get wrong, and both were measured wrong on the first
build of this command.

**Get the run from the CHECK, never from `gh run list --branch`.** That returns
the *latest* run; the red check is pinned to an *older SHA*. Using it returned
"no reason found" on 3 of 5 red PRs.

**Strip echoed workflow source by its ANSI, not by `grep -v 'echo "'`.** GitHub
colours echoed source with `ESC[36;1m`; runtime output carries no ANSI. The `✗`
lines in the source sit on *continuation lines of a multi-line echo*, so the
`echo "` string is on a different physical line and the naive filter cannot see
them — on #9765 it returned a source line as the reason.

`grep` may be `ugrep`, which parses `[36;1m` as a bracket expression — use `-F`.

```bash
strip_source() { grep -vF $'\033[36;1m'; }

gh pr view "$P" --repo mrdombie/maktura --json statusCheckRollup \
  -q '.statusCheckRollup[]? | select((.conclusion=="FAILURE" or .conclusion=="ACTION_REQUIRED") and (.name|test("approval"))) | "\(.name)\t\(.conclusion)\t\(.detailsUrl)"' \
| while IFS=$'\t' read -r NAME CONC URL; do
    RID=$(printf '%s' "$URL" | grep -oE 'runs/[0-9]+' | cut -d/ -f2)
    [ -n "$RID" ] && gh run view "$RID" --repo mrdombie/maktura --log-failed 2>/dev/null \
      | strip_source | grep -E '✗|PR labels:|Linked issue' | sed 's/^.*Z //'
  done
```

### The tier table — read the reason AND the CURRENT label

| Runtime reason | Label still on PR **or** issue? | Tier | Why |
|---|---|---|---|
| `carries no screenshot` | — | 🟡 AGENT'S | An agent must capture evidence first |
| `carries needs:human-approval` | **yes** | 🔴 YOURS | He has not looked yet |
| `carries needs:human-approval` | **no** | ⚪ STUCK | **He already approved it** — see below |
| *(no PR exists)* | on the **issue** | 🔴 YOURS | A design call — show the CONCEPT link, see 1c-bis |
| no `✗` found in any red run | — | ⚪ STUCK | Gate never reached its check — verify, do not assume |

### The already-approved trap

Measured 2026-08-30 on **#9845**: red `approval-gate`, plus an `ACTION_REQUIRED`
check named `approval-gate — waiting for Dom`, and **two evidence links** in the
body. It reads exactly like a Tier-1 row. It is not — the label was **already
cleared on both the PR and issue #9842**. The red run was from an older SHA.

Always re-read the CURRENT labels before placing a `needs:human-approval` row:

```bash
gh pr view "$P" --repo mrdombie/maktura --json labels -q '.labels|map(.name)|join(",")'
ISSUE=$(gh pr view "$P" --repo mrdombie/maktura --json body -q .body | grep -oE '#[0-9]{3,5}' | head -1 | tr -d '#')
gh issue view "$ISSUE" --repo mrdombie/maktura --json labels -q '.labels|map(.name)|join(",")'
```

(Extraction verified: on #9768 this returns `#8872`, the same issue the gate
itself resolved.)

What actually holds an already-approved PR is the `approval-gate — waiting for
Dom` check-run: `ACTION_REQUIRED`, pinned to the head SHA, **never cleared**.
Only a **new commit** frees it. If the PR is also conflicted, one `develop` merge
fixes both at once — dispatch that, do not show it to Dom.

**Showing him a PR he has already approved is the same failure as showing him one
with no screenshot. Both burn the list's credibility.**

### 1c-bis · ISSUES carrying `needs:human-approval` — the miss that started this

**Measured 2026-09-01: this scan reported "1 item yours" while THREE were waiting.**
Two of them (#9283, #9900) are **issues with no PR at all** — design calls where a
concept was posted and Dom never answered. A PR-only sweep cannot see them.

> The substitution that failed: I used *open PRs carrying `needs:human-approval`* as a
> stand-in for *everything waiting on Dom's approval*. **Issues carry the label too.**

```bash
gh issue list --repo mrdombie/maktura --state open --limit 400 --json number,title,labels \
  -q '.[]|select(.labels|map(.name)|index("needs:human-approval"))|"\(.number)\t\(.title)"'
```

For each, decide whether a PR already covers it:

```bash
PR=$(gh pr list --repo mrdombie/maktura --state open --limit 100 \
      --search "$N in:body" --json number -q '.[0].number')
```

| PR found | Tier | Why |
|---|---|---|
| yes | tier it on the **PR's** runtime reason, as normal | it is the PR row, not a second row |
| **NONE** | 🔴 **YOURS** | a decision with nothing built — usually a design call |

**A design-call row needs the CONCEPT LINK, not an evidence blob.** Nothing is built,
so there is no `docs/evidence/` shot to show. Pull the artifact URL from the comments:

```bash
gh issue view "$N" --repo mrdombie/maktura --json comments \
  -q '.comments[]|.body' | grep -oE 'https://claude\.ai/[^ )]*' | tail -1
```

Take the **last** one — later comments supersede earlier concepts. Say plainly that a
pasted Artifact link does nothing in VSCode and offer to `open` it.

### 1d · Claims vs live processes

The ref is the claim; `status:claimed` is a mirror that goes stale both ways.

```bash
~/.claude/socialhub-tickets/scripts/claim-lock.sh list --json \
 | jq -r '.[] | [(.issue|tostring),(.branch//"-"),(.claimed_at//"-")[0:16],(.pid|tostring)] | @tsv' \
 | while IFS=$'\t' read -r iss br at pid; do
     kill -0 "$pid" 2>/dev/null && a=ALIVE || a=DEAD
     echo -e "$iss\t$br\t$at\t$a"
   done
```

For each DEAD claim, does the branch hold work? **Ask GitHub, not a clone** —
the only local checkout (`~/.claude/skills/social-hub`) measured **194 commits
behind develop** on 2026-08-30, and `~/maktura-dev` does not exist. A stale clone
reports a live branch as missing.

```bash
AHEAD=$(gh api "repos/mrdombie/maktura/compare/develop...$BR" -q '.ahead_by' 2>/dev/null)
case "$AHEAD" in
  ''|*[!0-9]*) STATE=GONE ;;      # 404 prints an error object, not a number
  0)           STATE=EMPTY ;;
  *)           STATE=HOLDS ;;
esac
```

| `$STATE` | Tier | Action |
|---|---|---|
| `HOLDS` | 🟡 AGENT'S | Adopt the branch and finish it |
| `EMPTY` | ⚪ STUCK | Release to ready — claimed, nothing built |
| `GONE` | ⚪ STUCK | Branch deleted under a live claim — release the lock |

Measured 2026-08-30 — the four dead claims split cleanly: **#9015** holds 13
commits and **#9215** holds 17 (both adoptable); **#9256** and **#9742** have no
branch at all (both releasable).

A dead agent usually leaves an **unpushed merge**, which reads as `DIRTY`. Check
whether the ticket was superseded before adopting anything.

### 1e · Falsely-parked tickets

```bash
gh issue list --repo mrdombie/maktura --state open --limit 400 \
  --json number,title,labels \
  -q '.[] | select(.labels|map(.name)|index("status:gated")) | [(.number|tostring),.title] | @tsv'
```

`status:gated` means **gated behind a dependency, not gated on Dom** — never put one
in 🔴 on the label alone. The repo does not use native sub-issues
(`subIssues.totalCount` = 0), so blockers are text-only.

**Read the ticket template's own `**Blockers:**` field. Do NOT free-text regex.**
The old regex (`blocked by|depends on|after` + `#NNNN`) matched **6 of 34**. Reading
the template field classifies **23 of 34**, and the ones it cannot classify it *names*
instead of burying.

```bash
classify_blocker() {   # $1 = issue number -> "STATE|detail"
  local N="$1" B REFS OPEN st r
  B=$(gh issue view "$N" --repo mrdombie/maktura --json body -q .body 2>/dev/null \
      | grep -ioE '\*\*Blocke(rs?|d on):\*\*.{0,200}' | head -1)   # BOTH spellings — see below
  # older tickets predate the template field — fall back to the prose form
  [ -z "$B" ] && B=$(gh issue view "$N" --repo mrdombie/maktura --json body -q .body 2>/dev/null \
      | grep -oiE '(blocked by|gated (on|behind)|depends on:?|after)[^.]{0,40}#[0-9]{3,5}' | head -1)
  [ -z "$B" ] && { echo "NO-FIELD|"; return; }
  echo "$B" | grep -qiE '\*\*Blocke(rs?|d on):\*\*[[:space:]]*none' && { echo "NONE|nothing blocks it"; return; }
  REFS=$(echo "$B" | grep -oE '#[0-9]{3,5}' | tr -d '#' | sort -u)
  [ -z "$REFS" ] && { echo "PROSE-ONLY|$B"; return; }
  OPEN=""
  for r in $REFS; do
    st=$(gh issue view "$r" --repo mrdombie/maktura --json state -q .state 2>/dev/null)
    [ "$st" != "CLOSED" ] && OPEN="$OPEN $r"
  done
  [ -z "$OPEN" ] && echo "ALL-CLOSED|$REFS" || echo "BLOCKED|open:$OPEN"
}
```

| State | Tier | Why |
|---|---|---|
| `NONE` | ⚪ STUCK | The field literally says **none**. Parked on nothing. |
| `ALL-CLOSED` | ⚪ STUCK | Every blocker it names has closed. Falsely parked. |
| `PROSE-ONLY` | ⚪ STUCK — **show it, never bury it** | Names a blocker in words with no number. **No query can resolve it, so a human must.** |
| `BLOCKED` | not shown | Genuinely gated. |
| `NO-FIELD` | one summary row | Predates the template. |

**`PROSE-ONLY` is why this rewrite exists.** #9879's field reads *"the vendor-seam
ticket"* — no number, so the old regex could never match, and it sat in the silent
"28 name no blocker" bucket. That ticket **was #9877, closed 2026-08-30.** A ticket
whose blocker cannot be machine-checked is *more* likely to be falsely parked, not
less — it gets a row, with its blocker text quoted so Dom can resolve it in one read.

Measured 2026-09-01 across 34 gated tickets: **5 `NONE` · 3 `ALL-CLOSED` · 4
`PROSE-ONLY` · 11 `BLOCKED` · 11 `NO-FIELD`.** Twelve rows are worth showing where
the old sweep surfaced three.

### The blocker field has TWO spellings, and one of them hid a Dom item

`**Blockers:**` is the template. `**Blocked on:**` is not, and **#9329 uses it** —
*"Blocked on: a Semgrep login."* A pattern matching only `Blockers?:` classifies that
ticket `NO-FIELD` and drops it into the silent summary row. It sat there while the
Semgrep hook failed on every single tool call of the session with
`No SEMGREP_APP_TOKEN found, please login to Semgrep`.

**A `PROSE-ONLY` blocker naming an ACCOUNT, LOGIN, PURCHASE or PERMISSION is 🔴 YOURS,
not ⚪ stuck.** No agent can log Dom into anything. Read the blocker text and ask: is
the thing it names something only he can do? If yes, it is a Tier-1 row with the
action as its call — not a parked ticket.

### 1f · Held by nothing

`status:in-review` with no linked PR is an unreachable ticket → ⚪ STUCK.

**Search the PR TITLE as well as the body.** Measured 2026-09-01: `--search "$N in:body"`
reported #9039 as PR-less. Its PR **#9043 exists** — the number is in the title
(`#9039: notification preferences…`) and nowhere in the body. That is a **false STUCK
row**, the mirror of the false 🔴 this command exists to prevent.

```bash
gh pr list --repo mrdombie/maktura --state open --limit 100 --json number,title,body \
  -q '.[]|select((.title|test("'"$N"'")) or (.body|test("'"$N"'")))|.number' | head -1
```

With title included, all four in-review tickets resolve to a PR and the channel is
empty — correctly. `gh issue view` silently resolves PR numbers too, so confirm any
survivor is really an issue.

`status:in-review` with no linked PR is an unreachable ticket → ⚪ STUCK.
`gh issue view` silently resolves PR numbers too — confirm it is an issue.

---

## Step 2 — the board

Print counts first so he knows the size of the job. **Omit any empty table.**
Never print a "none" row. Never two tables touching — headed block, rule, gap.

**The description is the column that matters. The number goes LAST.** A row
leading with `#9768` tells him nothing he can act on.

```
🚦 NEEDS YOU — <YYYY-MM-DD HH:MM>

   🔴 yours: N        🟡 dispatched: N        ⚪ stuck: N

────────────────────────────────────────────────────────

🔴 YOURS — nobody else can do these

| What it is | The call | # |
|---|---|---|
| Capped totals stop reporting themselves as complete | Approve the pixels | 9768 |

────────────────────────────────────────────────────────

⚪ STUCK — held by nothing

| What it is | Why it stalled | # |
|---|---|---|
| Impressions are null on 95.5% of rows | Blocker #8823 closed 12 days ago | 8786 |

────────────────────────────────────────────────────────

🟡 Dispatched N agents: 2 missing screenshots · 1 conflict · 1 dead claim adopted.
```

🟡 is **one line, never a table.** He does not act on it.

---

## Step 3 — dispatch Tier 2 immediately

Spawn these the moment the scan finishes, before the walk — they run while he
reads. One agent each, in a single message so they go concurrently:

| Reason | Agent's job |
|---|---|
| `carries no screenshot` | Render the route, commit shots to `docs/evidence/<issue>/`, add SHA-pinned links to the body, rerun the gate |
| Real conflict | Merge `develop` in, resolve, push. **Merge FIRST, prune suppressions SECOND, gate LAST** — merging voids a `/ui-gate` fingerprint |
| Dead claim holding commits | Verify not superseded, then adopt and take to `/finish` |

**Before dispatching any of these, `claim-lock.sh show <issue>`** — a live holder means do NOT dispatch; a briefing to 'watch for a peer' does not prevent the collision.

Report the count in the 🟡 line. **Do not report their progress** — he did not
ask and they will notify.

---

## Step 4 — the walk, one 🔴 at a time

Present item 1 with everything needed to decide. Then act, then item 2 — **do
not re-ask permission to continue.**

```
────────────────────────────────────────────────────────

🔴 1 of N  ·  <what the change does, in his language>  (#NNNN)

   What changed   One or two lines on what a user will now see differently.
   Look at it     <SHA-pinned docs/evidence blob URL — required>
   Held by        needs:human-approval, live on the PR and issue #NNNN
   PR             https://github.com/mrdombie/maktura/pull/NNNN
   If you say yes I comment the record, clear the label on the PR and the
                  issue, rerun the gate and merge to develop.

   approve · no · skip · stop — or just tell me what's wrong with it.
```

Rules for the card:

- **Show the picture.** He approves by looking. A 🔴 pixel row with no evidence
  link is a bug in the scan — it belonged in 🟡.
- **Show the `Held by` line.** It is the proof the row is really his: the label
  must be live *right now* on the PR or the issue. If it is not, the row is the
  already-approved trap and belongs in ⚪.
- Name what the change **does**, never the commit title.
- No time estimates, no sequencing language, no demo framing.
- Never a bare ticket number anywhere.

---

## Step 5 — act on the answer

### `approve` on a pixel PR — the full motion, in this order

Approval must **name the PR**. Never infer it from general praise of the work.

```bash
# 1. Record it FIRST — this must survive a race with automerge
gh pr comment "$P" --repo mrdombie/maktura \
  --body "Approved by Dom in the agent window on $(date -u +%Y-%m-%d). \`needs:human-approval\` cleared on his instruction."

# 2. The label lives in TWO places
gh pr edit "$P" --repo mrdombie/maktura --remove-label "needs:human-approval"
ISSUE=$(gh pr view "$P" --repo mrdombie/maktura --json body -q .body | grep -oE '#[0-9]{3,5}' | head -1 | tr -d '#')
gh issue edit "$ISSUE" --repo mrdombie/maktura --remove-label "needs:human-approval" 2>/dev/null

# 3. The gate RE-APPLIES it to the PR if the issue was still labelled — re-check
gh pr view "$P" --repo mrdombie/maktura --json labels -q '.labels|map(.name)|join(",")'

# 4. Neither removal re-triggers the gate (it fires on pull_request only)
RID=$(gh run list --repo mrdombie/maktura --branch "$BR" --workflow dom-approval-gate.yml \
      --limit 1 --json databaseId -q '.[0].databaseId')
gh run rerun "$RID" --repo mrdombie/maktura
```

**Why the comment is not the forbidden thing:** AGENTS.md forbids an agent
clearing its own blocker unasked. Every agent acts through Dom's token, so
GitHub cannot tell his click from ours — the timeline comment is the only record
of which it was.

**If it still will not auto-merge:** the check-run named
`approval-gate — waiting for Dom` is `ACTION_REQUIRED`, pinned to the head SHA,
and never cleared. Only a **new commit** frees it. Say so; do not thrash.

### A falsely-parked ticket

He chose to see each one first — a closed blocker does not always mean the work
is unblocked. Show the blocker, its title and when it closed. Release only the
ones he names:

```bash
gh issue edit "$N" --repo mrdombie/maktura \
  --remove-label "status:gated" --add-label "status:ready"
gh issue comment "$N" --repo mrdombie/maktura \
  --body "Released to ready — blocker #$B closed on <date>. Confirmed by Dom in the agent window."
```

### `no` / free text

His words are the decision. Comment them onto the ticket verbatim, apply the
label that follows, move on. **Feedback on how work should be done is a RULE,
not a ticket** — write it to memory, never file it.

### `skip` — next item, no comment. `stop` — print what is left, exit.

---

## Step 6 — close

One line. What he cleared, what is still his, what the agents are doing.

```
Cleared 2 · 1 still yours (the workspace chrome, #9023) · 4 agents running.
```

---

## Flags

| Flag | Effect |
|---|---|
| *(none)* | Board, dispatch Tier 2, walk the 🔴 |
| `--board` | Board only. Still dispatches Tier 2. No walk. |
| `--tier1` | Only his items. Skips the ⚪ table. |
| `--dry` | Scan and print. Dispatches nothing, changes nothing. |

---

## Rules

- **Tables only.** The item card and the closing line are the exceptions.
- **Never tier on a label or a check colour.** Tier on the runtime reason.
- Every reference carries a plain-English description of what it does; the
  number is the reference, not the label.
- If a scan step fails, say the step failed. **A probe returning 0 may be
  broken, not clean** — an empty 🔴 table needs the scan to have provably run.
- Do not narrate the scan. He asked what needs him, not how you found it.
