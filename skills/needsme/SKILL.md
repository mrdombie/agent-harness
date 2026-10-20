---
name: needsme
description: Everything genuinely blocked on a human, sorted from everything that only LOOKS blocked on them — and WHO can clear each. Prints the board, then walks them through their items one at a time and runs the full motion on each answer. Usage: /agent-harness:needsme | /agent-harness:needsme --watch (ask as items arrive, idle between) | /agent-harness:needsme --board (no walk) | /agent-harness:needsme --tier1 (skip the rest)
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

Before printing any count, confirm all six ran:

| # | Channel | Where it hides | Section |
|---|---|---|---|
| 1 | PRs carrying the hold label (`$HOLD_LABEL`) — with a **Who** column (the rule is under 1a) | open PRs | 1a–1c |
| 2 | **ISSUES carrying it, with no PR** | design calls, concept posted, never answered | **1c-bis** |
| 3 | Dead claims | the claim ref, not the label | 1d |
| 4 | Falsely-parked `$LBL_GATED` (gated) | the `**Blockers:**` field | 1e |
| 5 | `$LBL_IN_REVIEW` (in-review) with no PR | unreachable tickets | 1f |
| 6 | **The coordinator's needs-you file** | lines the unattended coordinator wrote while nobody was watching | **1g** |

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
| `carries no screenshot` | — | 🟡 AGENT'S | CI has not pinned shots: the PR needs `## Evidence routes` and to be ready — the agent waits on CI, never captures locally |
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

**Only a concept the critic passed reaches the operator.** The comment carrying the link
must also say `KIT: MATCH`, the `design-critic` agent's **picture mode** verdict against
the project's `design.reference`. Without it, run picture mode on the link first. On
`KIT: DRIFT` the row is not the operator's: the concept goes back to be redrawn, and the
row moves to the agents' list as "picture drifted from the kit". The same holds for
`REAL DATA: MISSING` and for a picture `scripts/picture-evidence.py lint` refuses
(`shared/picture-rules.md`: every frame a named evidence region, laptop and phone,
duplicate names, the longest names, the empty state, scrolled): it goes back to be
redrawn as "picture drawn from tidy data".

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

### 1g · The coordinator's needs-you file

The coordinator tick never asks a question. When a full batch of held pixel PRs
is green apart from the hold, or a judgement names a choice only the owner can
make, it pings the desktop and appends one keyed line here (`<!-- key:… -->`).
Repairs, a red integration branch and stuck agents never land here — they go to
`agent-work.log` beside it:

```bash
cat "$STATE_DIR/coordinator/needs-you.md" 2>/dev/null | grep '^- \[ \]'
```

Each unticked line is a candidate 🔴 row — but tier it like any other: re-read
the PR or ticket it names first, because the line was true when written and
may have been cleared since (a sign-off on GitHub clears the hold, not the
line). When the item is resolved, tick its line (`- [x]`) so the next run does
not offer it again — except a `decision:<ticket>:<slug>` line: its ticket waits
on the owner-decision label, and only the answer helper frees it. Never tick one
by hand:

```bash
bash "$KIT_ROOT/scripts/needsme-watch.sh" answer "<key>" "<the answer, in the owner's words>"
```

It takes the label off, comments the answer, requeues the ticket and ticks the
line; a step that fails leaves the line open and is retried. A line whose ticket
no longer wears the label was answered on the ticket, and the next sync ticks it. An absent file means the coordinator is not installed or
has raised nothing — say which only if `$STATE_DIR/coordinator/` exists.

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

   Part of        card N of M of the new <screen>; the rest of the page is the old
                  version. Compare only <region>. Live: <siblings>. Pending: <siblings>.
                  (only when the PR body has a part block — see below)
   What changed   One or two lines on what a user will now see differently.
   Look at it     <region shot, or the preview at the region's anchor — then the full page>
   Approved       <the approved picture, opened at the region's anchor>
   Held by        $HOLD_LABEL, live on the PR and issue #NNNN
   Who clears it  <from the 1a rule: remove the label / approve it / a peer's review>
   PR             https://github.com/$REPO_SLUG/pull/NNNN
   If you say yes I comment the record, clear the label on the PR and the
                  issue, rerun the gate and merge to develop.

   approve · no · skip · stop — or just tell me what's wrong with it.
```

Rules for the card:

- **A part of a screen says so first.** When the PR rebuilds one region of a screen
  other tickets are also rebuilding, `bash "$KIT_ROOT/scripts/needsme-watch.sh" card <pr>`
  prints `banner`, `region`, `picture` and one `sibling` row each (closed issue =
  live). The `Part of` line is that banner, word for word, ahead of everything else,
  and the evidence leads with the region, the full page after it. Without it the
  owner judges the whole page — old cards included — against the new design: on
  2026-10-16 a new card shown on a page still mostly old was rejected as "doesn't
  look like the original design", and approved once explained.
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
`$SHOWN_SHA` is the head the operator was shown: the `sha` line of `needsme-watch.sh card <pr>`.

```bash
# One motion, shared with /agent-harness:bug: a review on a peer's PR when the operator is an
# approver (the gate clears the label on seeing it), else comment → issue → PR.
# --sha: the head whose shots the operator was shown; a PR that moved since is refused, not cleared.
"$KIT_ROOT/scripts/clear-hold.sh" "$P" --sha "$SHOWN_SHA"
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
| `--watch` | No scan. Ask what is new as clickable choices, then idle on a shell watcher — see below. |

---

## `--watch` — the owner's window

The operator opens one window, types `/agent-harness:needsme --watch`, and leaves
it. Decisions arrive as `AskUserQuestion` choices; between them nothing runs but a
shell loop, so the window costs no model calls while idle. **Skip Steps 1–6.**
The board is one script call; never re-run the six-channel scan here.

```bash
KIT_ROOT="${CLAUDE_PLUGIN_ROOT}"; W="$KIT_ROOT/scripts/needsme-watch.sh"
bash "$W" pending        # <key> \t <kind> \t <text>, one row per item not yet asked
```

### W1 — ask each row

- **`signoff-batch`** — a batch of held pixel PRs, green apart from the hold. The
  whole batch is looked at on **one page** and asked **four at a time**:
  1. `bash "$W" card <pr>` for each PR the text lists. `held no` → already signed
     off: drop it, no question.
  2. `bash "$W" open <pr> <pr> …` — every PR left, in that order, in ONE call. It
     builds one local review page and opens it as one Chrome tab: a numbered
     section per PR with its title, the PR link, the preview and approved-picture
     links, and every shot its description links at the newest commit those links
     pin, grouped by viewport and theme. It prints one row per PR:
     `<n> \t <pr> \t <shown> \t <unloaded> \t <options> \t <title>`. Say in one
     line that the page is open, with its `file://` URL. Never open evidence links
     one by one.
  3. `AskUserQuestion` with **up to 4 questions per call**, one per PR, in page
     order. Header `Sign off <n>`; the question opens with the PR's number on the
     page (`<n> ·`), names what the change does (from the card's title) and ends
     with the PR number. When the card has a `banner`, the question opens with it
     verbatim after the `<n> ·` and names the live and pending siblings from its
     `sibling` rows. More than 4 PRs: the next call takes the next 4. **The options
     are the row's `<options>`, exactly, and no others**: `Approve,Change` when
     shots are shown; `Send back for shots,Skip` when the description links none
     (nothing to approve); `Skip` alone when shots exist but none would load,
     and `Change,Skip` when only some loaded (say so; never approve a page missing
     part of what is approved, never send back on a failed fetch).
  4. **Approve** → `"$KIT_ROOT/scripts/clear-hold.sh" <pr> --sha <sha>` (sha from the card: the head the
     operator was shown). If it refuses because the PR moved, show the new card and ask again. Then re-read the labels
     as Step 5 does. **Change**, or any typed answer → comment the words verbatim on
     the PR; the hold stays. **Send back for shots** → comment on the PR that its
     description links no screenshots and the sign-off waits for them; the hold
     stays. **Skip** → nothing; do not mark it done, so it is asked again. **Never
     clear the hold without "Approve" for that PR in that prompt** — not from a
     batch answer, not from praise, not from an earlier window.
  5. `bash "$W" done pr:<pr>:<sha>` (sha from the card) after each answer except Skip.
  When every PR is answered: `bash "$W" done <batch key>`.
- **`decision`** whose key is `decision:<ticket>:<slug>` — a builder or the judge
  asked about that ticket, and nothing spawns it until it is answered. One
  `AskUserQuestion` with the row's text as the question and the options it names.
  Then `bash "$W" answer <key> "<the answer, in the owner's words>"`: it takes the
  owner-decision label off, comments the answer on the ticket, puts the ticket back
  at the front of the queue with the answer in its note, and ticks the row. Use it
  in place of `done`; a skipped decision gets no `answer` and stays waiting.
- **Any other kind** (`blind`, `disk-low`, a keyless `line`) — one
  `AskUserQuestion` with the row's text as the question and the real choices it
  names, then act on the answer as Step 5 does. `bash "$W" done <key>`.

Mark a row done after it is answered or skipped, never before: a window closed
mid-question asks it again next time, and an answered one never comes back.

### W2 — arm the watcher, then stop

```bash
bash "$W" wait          # Bash, run_in_background: true
```

It exits when a new key lands in `needs-you.md`, or when the forge (read every
five minutes) shows a full batch of green held PRs. End the turn with one line:
`Watching — I'll ask when something needs you.` When it exits, its output is
the new rows: do W1 on exactly those, then W2 again. Exit 3 means another window is
already watching: say which pid, and stop. Never use `/loop` or a timer here.

---

## Rules

- **Tables only.** The item card and the closing line are the exceptions.
- **Never tier on a label or a check colour.** Tier on the runtime reason.
- Every reference carries a plain-English description of what it does; the
  number is the reference, not the label.
- If a scan step fails, say the step failed. **A probe returning 0 may be
  broken, not clean** — an empty 🔴 table needs the scan to have provably run.
- Do not narrate the scan. They asked what needs them, not how you found it.
