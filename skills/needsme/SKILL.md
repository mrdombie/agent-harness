---
name: needsme
description: Everything genuinely blocked on a human, sorted from everything that only LOOKS blocked on them — and WHO can clear each. Prints the board, then walks them through their items one at a time and runs the full motion on each answer. Usage: /agent-harness:needsme | /agent-harness:needsme --board (no walk) | /agent-harness:needsme --tier1 (skip the rest)
---

You are clearing the operator's blocking queue. Read `${CLAUDE_PLUGIN_ROOT}/shared/operator.md` first: the operator is whoever runs this; how a hold is cleared is the 1a rule below.

**Output tables. No narrative.** The only prose permitted is the per-item card
and the closing line. No preamble, no recap of what you scanned, no explanation
of the gate.

---

## The one question that tiers everything

> **Can any agent resolve this without a human?**

If yes it is not the operator's, however loudly the label says otherwise. This is the whole
value of the command — see the trap below.

---

## THE TRAP THIS COMMAND EXISTS TO AVOID

Measured 2026-08-30: five open PRs carried a red `approval-gate`. **Three of the
five were not waiting on a human at all.** The gate's own runtime log said:

```
✗ This PR changes what a user sees and carries no screenshot.
```

That is an agent that skipped its evidence step. A version of this command that
tiers on the red check — or on the hold label (`$HOLD_LABEL`) — hands the operator three
items they cannot action, and they stop reading the list. That is exactly how the
queue of 86 died (#9174).

**So: never tier a PR on its check colour or its label. Tier it on the gate's
RUNTIME REASON.** Read the reason before you place the row.

State the substitution before any count reaches the operator:

> I am using *<what the query matched>* as a stand-in for *<what I am claiming>*.

If the halves differ, the number does not get printed.

---

## EVERY CHANNEL, OR THE LIST IS A LIE

The operator asked for **everything** that needs them. A sweep that covers four of five channels
does not report "I checked four" — it reports a confident, short number. That is the
failure mode, and it happened: **2026-09-01 this said "1 item yours" with three
waiting.**

Before printing any count, confirm all five ran:

| # | Channel | Where it hides | Section |
|---|---|---|---|
| 1 | PRs carrying the hold label (`$HOLD_LABEL`) — with a **Who** column (the rule is under 1a) | open PRs | 1a–1c |
| 2 | **ISSUES carrying it, with no PR** | design calls, concept posted, never answered | **1c-bis** |
| 3 | Dead claims | the claim ref, not the label | 1d |
| 4 | Falsely-parked `$LBL_GATED` (gated) | the `**Blockers:**` field | 1e |
| 5 | `$LBL_IN_REVIEW` (in-review) with no PR | unreachable tickets | 1f |

**If a channel's probe fails, say the channel failed.** An empty table needs the scan
to have provably run — a probe returning 0 may be broken, not clean.

**When the operator names an item this scan missed, that is a HOLE, not a one-off.** Find the
channel it lives in, add it here, and state the substitution that hid it.

## Step 1 — collect (parallel; do not loop `gh` per ticket)

Repo is `$REPO_SLUG`. **Never pass `--label`** — it redirects from
the repo's old, pre-rename name and returns 0 rows silently. Filter labels client-side with `jq`.

### 1a · Open PRs — one call

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
OPERATOR=$(toolkit_login)
toolkit_is_approver "$OPERATOR" && I_REVIEW=yes || I_REVIEW=no   # am I in HUMAN_APPROVERS?
gh pr list --repo "$REPO_SLUG" --state open --limit 100 \
  --json number,title,labels,isDraft,headRefName,updatedAt,url,author \
  -q '.[] | [(.number|tostring),(.labels|map(.name)|join(",")),(.isDraft|tostring),.headRefName,(.updatedAt[0:10]),(.author.login),(.title)] | @tsv'
```

The **Who** column comes from the author and `$I_REVIEW`, and says only what the gate accepts:
a PR authored by someone else → `you — remove the label` (any human's removal counts), plus
`or approve it` when `$I_REVIEW` is yes; a PR authored by `$OPERATOR` → `a peer's review, or
you remove the label`. Never promise a review that `HUMAN_APPROVERS` does not include.

`mergeStateStatus` from a LIST call is `UNKNOWN` — GitHub computes it lazily.
Get it per-PR in 1b, not here.

### 1b · Per-PR state — only for PRs that matter

```bash
gh pr view "$P" --repo "$REPO_SLUG" \
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

gh pr view "$P" --repo "$REPO_SLUG" --json statusCheckRollup \
  -q '.statusCheckRollup[]? | select((.conclusion=="FAILURE" or .conclusion=="ACTION_REQUIRED") and (.name|test("approval"))) | "\(.name)\t\(.conclusion)\t\(.detailsUrl)"' \
| while IFS=$'\t' read -r NAME CONC URL; do
    RID=$(printf '%s' "$URL" | grep -oE 'runs/[0-9]+' | cut -d/ -f2)
    [ -n "$RID" ] && gh run view "$RID" --repo "$REPO_SLUG" --log-failed 2>/dev/null \
      | strip_source | grep -E '✗|PR labels:|Linked issue' | sed 's/^.*Z //'
  done
```

### The tier table — read the reason AND the CURRENT label

| Runtime reason | Label still on PR **or** issue? | Tier | Why |
|---|---|---|---|
| `carries no screenshot` | — | 🟡 AGENT'S | An agent must capture evidence first |
| `carries $HOLD_LABEL` | **yes** | 🔴 YOURS | Nobody has looked yet — the **Who** column (rule under 1a) says how you clear it |
| `carries $HOLD_LABEL` | **no** | ⚪ STUCK | **Already approved** — see below |
| *(no PR exists)* | on the **issue** | 🔴 YOURS | A design call — show the CONCEPT link, see 1c-bis |
| no `✗` found in any red run | — | ⚪ STUCK | Gate never reached its check — verify, do not assume |

### The already-shipped trap

Measured 2026-09-30 on **#10685**: an open, held, clashing PR with evidence —
a textbook 🔴 row. The operator approved it. Its ticket **#10598 had closed as
completed three days earlier**; the work had shipped in another PR, and the one
shown was a leftover. The scan read open *issues*, so a closed ticket never
reached it.

Before placing any PR row, read the state of the ticket it closes:

```bash
gh issue view "$ISSUE" --repo "$REPO_SLUG" --json state,stateReason -q '"\(.state) \(.stateReason)"'
```

`CLOSED COMPLETED` → ⚪ STUCK, "ticket already shipped — close this PR?". Never 🔴.

### The already-approved trap

Measured 2026-08-30 on **#9845**: red `approval-gate`, plus an `ACTION_REQUIRED`
check named `approval-gate — waiting for sign-off`, and **two evidence links** in the
body. It reads exactly like a Tier-1 row. It is not — the label was **already
cleared on both the PR and issue #9842**. The red run was from an older SHA.

Always re-read the CURRENT labels before placing a hold-label (`$HOLD_LABEL`) row:

```bash
gh pr view "$P" --repo "$REPO_SLUG" --json labels -q '.labels|map(.name)|join(",")'
ISSUE=$(gh pr view "$P" --repo "$REPO_SLUG" --json body -q .body | grep -oE '#[0-9]{3,5}' | head -1 | tr -d '#')
gh issue view "$ISSUE" --repo "$REPO_SLUG" --json labels -q '.labels|map(.name)|join(",")'
```

(Extraction verified: on #9768 this returns `#8872`, the same issue the gate
itself resolved.)

What actually holds an already-approved PR is the `approval-gate — waiting for
sign-off` check-run: `ACTION_REQUIRED`, pinned to the head SHA. The gate PATCHes
it to success on the next run after a sign-off (including a run left under the
check's previous name), so a nudge (`gh pr edit --body`) frees it; a **new commit** also does. If the PR is also conflicted, one `develop` merge
fixes both at once — dispatch that, do not show it to the operator.

**Showing the operator a PR they have already approved is the same failure as showing them one
with no screenshot. Both burn the list's credibility.**

### 1c-bis · ISSUES carrying `needs:human-approval` — the miss that started this

**Measured 2026-09-01: this scan reported "1 item yours" while THREE were waiting.**
Two of them (#9283, #9900) are **issues with no PR at all** — design calls where a
concept was posted and nobody answered. A PR-only sweep cannot see them.

> The substitution that failed: I used *open PRs carrying the hold label* as a
> stand-in for *everything waiting on a human's approval*. **Issues carry the label too.**

```bash
gh issue list --repo "$REPO_SLUG" --state open --limit 400 --json number,title,labels \
  | jq -r --arg h "$HOLD_LABEL" '.[]|select(.labels|map(.name)|index($h))|"\(.number)\t\(.title)"'
```

For each, decide whether a PR already covers it:

```bash
PR=$(gh pr list --repo "$REPO_SLUG" --state open --limit 100 \
      --search "$N in:body" --json number -q '.[0].number')
```

| PR found | Tier | Why |
|---|---|---|
| yes | tier it on the **PR's** runtime reason, as normal | it is the PR row, not a second row |
| **NONE** | 🔴 **YOURS** | a decision with nothing built — usually a design call |

**A design-call row needs the CONCEPT LINK, not an evidence blob.** Nothing is built,
so there is no `docs/evidence/` shot to show. Pull the artifact URL from the comments:

```bash
gh issue view "$N" --repo "$REPO_SLUG" --json comments \
  -q '.comments[]|.body' | grep -oE 'https://claude\.ai/[^ )]*' | tail -1
```

Take the **last** one — later comments supersede earlier concepts. Say plainly that a
pasted Artifact link does nothing in VSCode and offer to `open` it.

### 1d · Claims vs live processes

The ref is the claim; `$LBL_CLAIMED` (claimed) is a mirror that goes stale both ways.

```bash
"$KIT_ROOT/scripts/claim-lock.sh" list --json \
 | jq -r '.[] | [(.issue|tostring),(.branch//"-"),(.claimed_at//"-")[0:16],(.pid|tostring)] | @tsv' \
 | while IFS=$'\t' read -r iss br at pid; do
     kill -0 "$pid" 2>/dev/null && a=ALIVE || a=DEAD
     echo -e "$iss\t$br\t$at\t$a"
   done
```

For each DEAD claim, does the branch hold work? **Ask GitHub, not a clone** —
the only local checkout measured **194 commits
behind develop** on 2026-08-30, and no persistent dev checkout existed. A stale clone
reports a live branch as missing.

```bash
AHEAD=$(gh api "repos/$REPO_SLUG/compare/develop...$BR" -q '.ahead_by' 2>/dev/null)
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
gh issue list --repo "$REPO_SLUG" --state open --limit 400 \
  --json number,title,labels \
  | jq -r --arg g "$LBL_GATED" '.[] | select(.labels|map(.name)|index($g)) | [(.number|tostring),.title] | @tsv'
```

`$LBL_GATED` (gated) means **gated behind a dependency, not gated on a human** — never put one
in 🔴 on the label alone. The repo does not use native sub-issues
(`subIssues.totalCount` = 0), so blockers are text-only.

**Read the ticket template's own `**Blockers:**` field. Do NOT free-text regex.**
The old regex (`blocked by|depends on|after` + `#NNNN`) matched **6 of 34**. Reading
the template field classifies **23 of 34**, and the ones it cannot classify it *names*
instead of burying.

```bash
classify_blocker() {   # $1 = issue number -> "STATE|detail"
  local N="$1" B REFS OPEN st r
  B=$(gh issue view "$N" --repo "$REPO_SLUG" --json body -q .body 2>/dev/null \
      | grep -ioE '\*\*Blocke(rs?|d on):\*\*.{0,200}' | head -1)   # BOTH spellings — see below
  # older tickets predate the template field — fall back to the prose form
  [ -z "$B" ] && B=$(gh issue view "$N" --repo "$REPO_SLUG" --json body -q .body 2>/dev/null \
      | grep -oiE '(blocked by|gated (on|behind)|depends on:?|after)[^.]{0,40}#[0-9]{3,5}' | head -1)
  [ -z "$B" ] && { echo "NO-FIELD|"; return; }
  echo "$B" | grep -qiE '\*\*Blocke(rs?|d on):\*\*[[:space:]]*none' && { echo "NONE|nothing blocks it"; return; }
  REFS=$(echo "$B" | grep -oE '#[0-9]{3,5}' | tr -d '#' | sort -u)
  [ -z "$REFS" ] && { echo "PROSE-ONLY|$B"; return; }
  OPEN=""
  for r in $REFS; do
    st=$(gh issue view "$r" --repo "$REPO_SLUG" --json state -q .state 2>/dev/null)
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
less — it gets a row, with its blocker text quoted so the operator can resolve it in one read.

Measured 2026-09-01 across 34 gated tickets: **5 `NONE` · 3 `ALL-CLOSED` · 4
`PROSE-ONLY` · 11 `BLOCKED` · 11 `NO-FIELD`.** Twelve rows are worth showing where
the old sweep surfaced three.

### The blocker field has TWO spellings, and one of them hid a human-blocked item

`**Blockers:**` is the template. `**Blocked on:**` is not, and **#9329 uses it** —
*"Blocked on: a Semgrep login."* A pattern matching only `Blockers?:` classifies that
ticket `NO-FIELD` and drops it into the silent summary row. It sat there while the
Semgrep hook failed on every single tool call of the session with
`No SEMGREP_APP_TOKEN found, please login to Semgrep`.

**A `PROSE-ONLY` blocker naming an ACCOUNT, LOGIN, PURCHASE or PERMISSION is 🔴 YOURS,
not ⚪ stuck.** No agent can log the operator into anything. Read the blocker text and ask: is
the thing it names something only they can do? If yes, it is a Tier-1 row with the
action as its call — not a parked ticket.

### 1f · Held by nothing

`$LBL_IN_REVIEW` (in-review) with no linked PR is an unreachable ticket → ⚪ STUCK.

**Search the PR TITLE as well as the body.** Measured 2026-09-01: `--search "$N in:body"`
reported #9039 as PR-less. Its PR **#9043 exists** — the number is in the title
(`#9039: notification preferences…`) and nowhere in the body. That is a **false STUCK
row**, the mirror of the false 🔴 this command exists to prevent.

```bash
gh pr list --repo "$REPO_SLUG" --state open --limit 100 --json number,title,body \
  -q '.[]|select((.title|test("'"$N"'")) or (.body|test("'"$N"'")))|.number' | head -1
```

With title included, all four in-review tickets resolve to a PR and the channel is
empty — correctly. `gh issue view` silently resolves PR numbers too, so confirm any
survivor is really an issue.

`$LBL_IN_REVIEW` (in-review) with no linked PR is an unreachable ticket → ⚪ STUCK.
`gh issue view` silently resolves PR numbers too — confirm it is an issue.

---

## Step 2 — the board

Print counts first so they know the size of the job. **Omit any empty table.**
Never print a "none" row. Never two tables touching — headed block, rule, gap.

**The description is the column that matters. The number goes LAST.** A row
leading with `#9768` tells them nothing they can act on.

```
🚦 NEEDS YOU — <YYYY-MM-DD HH:MM>

   🔴 yours: N        🟡 dispatched: N        ⚪ stuck: N

────────────────────────────────────────────────────────

🔴 YOURS — waiting on a human

| What it is | Who clears it | The call | # |
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

🟡 is **one line, never a table.** The operator does not act on it.

---

## Step 3 — dispatch Tier 2 immediately

Spawn these the moment the scan finishes, before the walk — they run while they
reads. One agent each, in a single message so they go concurrently:

| Reason | Agent's job |
|---|---|
| `carries no screenshot` | Render the route, commit shots to `docs/evidence/<issue>/`, add SHA-pinned links to the body, rerun the gate |
| Real conflict | Merge `develop` in, resolve, push. **Merge FIRST, prune suppressions SECOND, gate LAST** — merging voids a `/agent-harness:ui-gate` fingerprint |
| Dead claim holding commits | Verify not superseded, then adopt and take to `/agent-harness:finish` |

Report the count in the 🟡 line. **Do not report their progress** — they did not
ask and they will notify.

---

## Step 4 — the walk, one 🔴 at a time

**The link on a pixel card is the preview URL when it ANSWERS (#10479).** Read the
body's `<!-- preview:begin/end -->` block; `curl -sfL -m 8` its web URL. If it answers,
that is the link — it opens from any machine. If it does not (previews are torn down
on merge and on idle), the card shows the SHA-pinned screenshot; never a dead link.

Present item 1 with everything needed to decide. Then act, then item 2 — **do
not re-ask permission to continue.**

```
────────────────────────────────────────────────────────

🔴 1 of N  ·  <what the change does, in their language>  (#NNNN)

   What changed   One or two lines on what a user will now see differently.
   Look at it     <SHA-pinned docs/evidence blob URL — required>
   Held by        $HOLD_LABEL, live on the PR and issue #NNNN
   Who clears it  <from the 1a rule: remove the label / approve it / a peer's review>
   PR             https://github.com/$REPO_SLUG/pull/NNNN
   If you say yes I comment the record, clear the label on the PR and the
                  issue, rerun the gate and merge to develop.

   approve · no · skip · stop — or just tell me what's wrong with it.
```

Rules for the card:

- **Show the picture.** The operator approves by looking. A 🔴 pixel row with no evidence
  link is a bug in the scan — it belonged in 🟡.
- **Show the `Held by` line.** It is the proof the row is really the operator's: the label
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
# One motion, shared with /agent-harness:bug: a review on a peer's PR when the operator is an
# approver (the gate clears the label on seeing it), else comment → issue → PR.
"$KIT_ROOT/scripts/clear-hold.sh" "$P"
# The gate re-runs itself on the review or the unlabeled event; re-read the labels
# to confirm, because a still-labelled ISSUE makes it re-apply the hold at open.
gh pr view "$P" --repo "$REPO_SLUG" --json labels -q '.labels|map(.name)|join(",")'
```

**Why the comment is not the forbidden thing:** AGENTS.md forbids an agent
clearing its own blocker unasked. Every agent acts through the operator's token, so
GitHub cannot tell their click from ours — the timeline comment is the only record
of which it was.

**If it still will not auto-merge:** see 1b — the `approval-gate — waiting for
sign-off` check-run is pinned to the head SHA and the gate patches it on its next
run, so nudge the body (`gh pr edit --body`); a new commit also works. Do not thrash.

### A falsely-parked ticket

Decision (Dom, 2026-09-01): every falsely-parked ticket is shown before release — a closed blocker does not always mean the work
is unblocked. Show the blocker, its title and when it closed. Release only the
ones they name:

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; . "$KIT_ROOT/scripts/toolkit-env.sh" || exit 1
OPERATOR=$(toolkit_login)
gh issue edit "$N" --repo "$REPO_SLUG" \
  --remove-label "$LBL_GATED" --add-label "$LBL_READY"
gh issue comment "$N" --repo "$REPO_SLUG" \
  --body "Released to ready — blocker #$B closed on <date>. Confirmed by @$OPERATOR in the agent window."
```

### `no` / free text

The operator's words are the decision. Comment them onto the ticket verbatim, apply the
label that follows, move on. **Feedback on how work should be done is a RULE,
not a ticket** — write it to memory, never file it.

### `skip` — next item, no comment. `stop` — print what is left, exit.

---

## Step 6 — close

One line. What they cleared, what is still theirs, what the agents are doing.

```
Cleared 2 · 1 still yours (the workspace chrome, #9023) · 4 agents running.
```

---

## Flags

| Flag | Effect |
|---|---|
| *(none)* | Board, dispatch Tier 2, walk the 🔴 |
| `--board` | Board only. Still dispatches Tier 2. No walk. |
| `--tier1` | Only their items. Skips the ⚪ table. |
| `--dry` | Scan and print. Dispatches nothing, changes nothing. |

---

## Rules

- **Tables only.** The item card and the closing line are the exceptions.
- **Never tier on a label or a check colour.** Tier on the runtime reason.
- Every reference carries a plain-English description of what it does; the
  number is the reference, not the label.
- If a scan step fails, say the step failed. **A probe returning 0 may be
  broken, not clean** — an empty 🔴 table needs the scan to have provably run.
- Do not narrate the scan. They asked what needs them, not how you found it.
