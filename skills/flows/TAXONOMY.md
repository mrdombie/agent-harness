# The flow taxonomy — eight axes

This is a **generator**, not a checklist. You walk each axis and emit one expected-flow row
per case that applies to the screen's job. A checklist is something you tick; a generator is
something that produces rows you had not thought of. That difference is the whole method.

You are working from the screen's **job** alone. You have not read its code and must not.
Every row you write is a claim about what the job requires, and it stays a claim until
somebody hunts for it in the implementation.

Worked examples below are deliberately from unrelated surfaces (an invoice list, a team
settings page). Do not pattern-match your screen onto them.

---

## How to write a row

Each row is one line, phrased as a **testable claim about behaviour**:

> `E-04` · **Entry** · Somebody opens a bookmark of step 3 having never done steps 1–2 →
> the screen either does the job with what it has, or says what is missing and offers the way
> to get it. It does not render blank, and it does not bounce them somewhere they did not ask
> to go.

Rules for the phrasing:

- **State the move, then the required outcome.** Never "handle the empty state" — that is a
  category, not a claim. Write what the person did and what they must end up with.
- **One row, one move.** If a row needs "and also", it is two rows.
- **Never name a component, file, endpoint or prop.** You do not know them. If you find
  yourself writing one, you are reasoning from an implementation you were not given.
- **Prefer the outcome a person can observe** over the mechanism that produces it.
- Mark the row `[CORE]` if the job is not done without it, `[EDGE]` otherwise. Severity is
  assigned later, from what the checker finds; `[CORE]`/`[EDGE]` is about the job only.

Emit rows even when you strongly suspect they are handled. The report is a **coverage** table
— a row that comes back `PRESENT` is not wasted, it is the denominator. Suppressing rows you
assume are fine is how a coverage number becomes a compliment.

---

## Axis 1 — ENTRY

*Every way a person can arrive.* Screens are built for the front door and break at the others.

Emit one row per arrival that the job makes possible:

| Case | What to ask |
|---|---|
| Direct navigation | Typed, or from in-product nav. Baseline. |
| Deep link with parameters | A URL carrying state — an id, a filter, a tab, a token. What if the parameter is missing, malformed, repeated, or names something the person may not see? |
| Redirect in | Anything that sends people here without them asking. Under what condition does it stop firing? Can it fire again after they have left? |
| Back button | Arriving backwards, after having gone forward. Is what they see still true? |
| Refresh mid-task | Reload with work half-done. Kept, or lost silently? |
| Bookmark of an inner step | A step that is not step one, opened cold. |
| Return from an external round-trip | Any journey that leaves the product and comes back — payment, OAuth, an email confirmation. **Both outcomes: it worked, and it did not.** The failure return is the single most commonly missing flow in this axis. |
| Invite / email / shared link | Arriving as somebody who was sent here, possibly not signed in yet. |

> **Worked example (team settings):** `E-07` · Somebody clicks an invite link while signed in
> as a *different* account → the screen says which account it is acting as and offers to switch,
> rather than silently joining the wrong person to the team. `[CORE]`

---

## Axis 2 — ACTOR

*Who arrives.* One row per actor whose experience of this screen should differ.

| Case | What to ask |
|---|---|
| Each role the product has | What can each do here, and what does a role that cannot do the main thing see instead? |
| Not signed in | Sent to sign in — and afterwards, do they land back here or somewhere generic? |
| Signed in, no workspace/org | The hollow account. Rare, and it strands people when it happens. |
| Wrong workspace | Holds a link to something in a workspace they are not in. Refused, and is the refusal legible or a blank? |
| Already done this | Arrives having already completed the job. Does the screen repeat itself as if new? |
| Part-way done | Arrives with some of the job done. Does it recognise that, or restart? |

> **Worked example (invoice list):** `A-03` · A member without billing permission opens a
> shared invoice link → they are told this needs billing access and who to ask, not shown an
> empty table that reads as "there are no invoices". `[CORE]`

---

## Axis 3 — INTENT

*The jobs the screen exists for.* First name them — usually one to three. Then emit five rows
per job:

| Sub-case | What to ask |
|---|---|
| **Start** | Can they begin? Is the way in obvious from a cold start with nothing set up? |
| **Complete** | Can they finish? What tells them it is done — and is that a claim the screen can actually back? |
| **Abandon** | Can they leave part-way? What happens to the partial work — kept, discarded, or left in a state that is neither? |
| **Resume** | Can they come back and carry on, or does leaving cost them the work? |
| **Change / redo** | Can they alter what they did, or do it a second time? A job you can only ever do once is a claim worth making explicitly. |

Then, for the screen as a whole:

- Is there a job the person plausibly arrives wanting to do here that this screen **does not
  offer at all**? Name it. This is the row most likely to be `ABSENT`, because nothing in the
  code can suggest it.

> **Worked example (invoice list):** `I-04` · Somebody starts an export, navigates away, comes
> back → the export is either still running and visible, or finished and reachable. It has not
> vanished with the page that started it. `[CORE]`

---

## Axis 4 — DATA STATE

*For each thing the screen renders from data*, emit rows across the range. Name the collection
generically ("the list of things they have"), never by its variable.

| State | What to ask |
|---|---|
| None | The true empty. Does it explain and offer the first action, or just say "no results"? |
| Exactly one | Layouts tuned for many often read wrongly at one. |
| Many | The normal case. |
| Far too many | Hundreds, thousands. Paged, capped, or does it just get slower and slower? A cap that exists must be **said**. |
| Too long | One item with a very long name/body. Overflow, truncation, or layout break? |
| Loading | Is there a state at all, and does it distinguish "loading" from "empty"? |
| Stale | Data fetched a while ago and possibly wrong now. Is its age visible? |
| Partial | Some of it arrived, some did not. Is the shortfall stated, or does partial render as complete? |
| Unknown — the read failed | **The one that gets collapsed into "empty".** A failed read and a genuine zero must not look the same. Ask it of every read on the screen. |

> **Worked example (invoice list):** `D-09` · The invoice fetch fails → the screen says it could
> not load them, not "You have no invoices". The two are opposite facts and must never share a
> rendering. `[CORE]`

---

## Axis 5 — FAILURE

*For every read and every write the job implies* — you do not know the endpoints, so reason
from the job: "this screen must fetch X", "this button must save Y".

Two questions per failure, and **both** must be answered by a row:

1. **Is it said?** Does the person learn it failed, in words about this specific thing?
2. **Is there a way out?** Retry, an alternative route, or an honest "this cannot work right
   now, here is what to do instead". A message with no exit is half a flow.

| Case | What to ask |
|---|---|
| Refused (4xx) | Not allowed, not valid, not found. Does the copy say which, and is it actionable? |
| Broke (5xx) | Our fault. Retryable? |
| Timed out | Slow, no answer. **Did the write land anyway?** A timeout on a write is the ambiguous case — pressing again may buy a second one. |
| Offline / network gone | Distinguished from a server error, or one generic shrug? |
| Rate-limited | Told to wait, and told roughly how long? |
| **Partial success** | Three of five saved. Which three? Is the remainder recoverable, or lost with the page? |

Plus, per write:

- **Failed after the write landed.** The row exists, the response did not arrive. If pressing
  again would create a second one, the control must not stay pressable — and the person needs
  a way to reach what was made.

> **Worked example (team settings):** `F-06` · Inviting five people, two of the addresses are
> rejected → the screen names the two, keeps the three that worked, and lets the two be fixed
> without retyping the three. `[CORE]`

---

## Axis 6 — REPEAT & RACE

*The same person, more than once, or in more than one place.*

| Case | What to ask |
|---|---|
| Double press | Two clicks in the round-trip window. Two of the thing, or one? |
| Two tabs | The same screen open twice. Does acting in one leave the other lying? |
| Navigate away mid-flight | A request in the air when the page changes. Does its outcome reach anybody? |
| Return and press again | Comes back later and repeats the action. Duplicate, or recognised as done? |
| Browser-back after a write | Back onto a screen whose state the write has invalidated. |
| Two people, one workspace | Where the job is shared, a colleague doing it at the same time. |

> **Worked example (team settings):** `R-01` · The invite button is pressed twice inside the
> round trip → one invitation is sent. The guard is on the press, not on the reader noticing. `[CORE]`

---

## Axis 7 — EXIT & AFTERMATH

*Leaving, and what is true afterwards.*

| Case | What to ask |
|---|---|
| Every way out | Enumerate them from the job: finish, skip, cancel, close, leave via nav, leave via back. What persists in each? |
| Leaving mid-task | Is partial work kept, discarded, or left half-written? Whichever it is, is it **said** before or as they leave? |
| Where "done" lands | Does completing land on the thing that was made, or on a generic container that makes them hunt for it? |
| What the person is told | Does the screen state what happened, what happens next, and roughly when? |

**The standing rule — check this one on every screen, always:**

> **Every asynchronous thing this screen starts must be answerable somewhere the person can
> reach.** If pressing a button kicks off work that outlives the screen, then the outcome —
> including the failure — has to surface somewhere they can find. A screen that starts work,
> navigates away, and never mentions it again has shipped a silent failure by design.

Ask it once per async action the job implies. It is the axis most often absent because nothing
on the screen looks broken; the hole is in a place nobody is looking.

> **Worked example (invoice list):** `X-05` · A generated statement is requested and the person
> closes the tab → the finished statement is reachable next time they return, and a failed
> generation is reported, not silently dropped. `[CORE]`

---

## Axis 8 — CONTINUITY

*What each step hands the next, and whether the next step takes it.*

The other seven axes look at one screen at a time. This one looks at the **joins**. It exists
because a sequence can pass every per-screen check and still waste everything somebody gave it:
each screen works, and the second one ignores what the first one produced.

Formally this is **def-use**: a value is *defined* somewhere and *used* somewhere else. An
absent flow here is a definition nothing reads, or a read pointed at a definition that never
fires. Said plainly, it is **the payoff check** — *I gave you X; where does X show up?*

Work it in three passes:

**1. List what each step PRODUCES.** Not what it displays — what it leaves behind that outlives
the screen. An account connected, an address stored, a file uploaded, a preference chosen, a
thing measured, a permission granted.

**2. For each product, name every place downstream that SHOULD consume it.** Emit one row per
pairing. Then ask the two questions that matter:

| Question | Why it catches things |
|---|---|
| Does the later step **change** because the earlier one happened? | If a step looks identical whether or not you did the one before it, the earlier step bought nothing |
| Does it consume the thing itself, or **re-ask** for it? | Re-asking for what you already handed over is the most common form of this defect, and it reads as a normal form field |

**3. Ask the two failure directions.** Both are silent by nature:

- **A product nothing consumes.** You asked for it, stored it, and no screen reads it. The
  person paid a cost for nothing.
- **A consumer whose producer never fires.** The read is built and correct; the write happens
  on a path that is not the path people actually take — a different backend, a different
  callback, a branch behind a flag. This is the nastiest one: both halves look right in
  isolation, both have tests, and the join is dead. **When more than one route produces the
  same thing, ask which route real traffic takes**, and whether every one of them writes what
  the consumer reads.

Also emit a row for each of these, once per sequence:

- **The last step's product.** What did the whole thing produce, and where does the person meet
  it afterwards? A sequence whose output has no home has not finished.
- **A step that can be skipped.** What do the later steps do when the thing they wanted was
  never produced? Degrade honestly, or break?
- **The order claim.** If the steps are numbered, does step N actually depend on step N-1? If
  not, the sequence is claiming a dependency it does not have.

> **Worked example (an expenses tool):** `C-04` · Somebody photographs a receipt in step 1 →
> the amount field in step 2 arrives filled from that receipt, or the step says it could not
> read it. It does not present an empty amount field as though no receipt was ever supplied. `[CORE]`

> **Worked example (an expenses tool):** `C-07` · The receipt is stored by one upload route and
> read by another → **every** route that stores a receipt writes the field the amount step
> reads, including the one that runs on mobile. A read wired to only one of two writers is a
> dead join that tests on both sides will pass. `[CORE]`

Use the prefix `C-` for these rows.

---

## Before you hand the rows over

Self-check the set you produced:

- [ ] Every axis emitted at least one row, or you have written one line saying why it does not
      apply to this job.
- [ ] Axis 5 emitted **both** questions (said / way out) for each failure that matters.
- [ ] Axis 7's standing rule was asked of every async action.
- [ ] Axis 8 listed what EVERY step produces, and asked who consumes each one — in both
      directions (a product nothing reads, and a read whose producer never fires).
- [ ] No row names a file, component, prop, endpoint or variable.
- [ ] Every row states a move and a required outcome, not a category.
- [ ] At least one row describes something you would be *surprised* to find built. If none
      does, the model is tracking the obvious and will only confirm what already exists.
