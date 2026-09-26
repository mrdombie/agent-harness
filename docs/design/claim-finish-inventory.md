# Inventory: every rule and every script block in both copies of /claim and /finish

Phase 1, child 1 of the script-driven build (epic #10883). It maps what the two
commands say today onto where each part lands once **a driver runs the steps and
the AI is called only for the thinking**. Nothing is dropped silently: every row
has a destination, and a `retired` row carries its reason.

This is a reading, not a change. No code moves here. Children 2 (the driver) and
3 (the AI step briefs) build against these tables.

---

## 1. What was measured, and with what

Four files. Two are the commands an agent is handed; two are the plugin skills
that were extracted from them and have since drifted apart.

| Tag | File | Words | Lines | Fenced blocks | of those, `bash` | Shell lines |
|---|---|---|---|---|---|---|
| **UC** | `~/.claude/commands/claim.md` | 12,930 | 1,268 | 30 | 26 | 447 |
| **UF** | `~/.claude/commands/finish.md` | 10,201 | 1,062 | 29 | 26 | 536 |
| **PC** | kit `skills/claim/SKILL.md` | 10,340 | 1,052 | 28 | 25 | 372 |
| **PF** | kit `skills/finish/SKILL.md` | 8,881 | 934 | 24 | 21 | 514 |
| | **total** | **42,352** | **4,316** | **111** | **98** | **1,869** |

Reproduce the counts. Words and lines are `wc -w -l`. The block enumeration
Section 4 is built from — index, line range, language, whether it is indented,
and its first meaningful line — comes from this, run against each file in turn:

    awk '
      /^[[:space:]]*```/ {
        if (!inb) {
          inb=1; n++; start=NR; first=""
          lang=$0; sub(/^[[:space:]]*```/, "", lang)
          ind=($0 ~ /^[[:space:]]/)
          next
        }
        inb=0
        printf "%-3s L%-5d-%-5d %-6s %-4s %s\n", n, start, NR,
               (lang=="" ? "(none)" : lang), (ind ? "IND" : ""), first
        next
      }
      inb {
        if (first=="" && $0 !~ /^[[:space:]]*(#|$)/) { t=$0; sub(/^[[:space:]]+/,"",t); first=substr(t,1,78) }
      }
    ' FILE

**The leading `[[:space:]]*` is load-bearing, and leaving it out is how the
epic's own figure looked wrong.** Anchoring the fence at column 1 misses exactly
one block in each of the four files — the sign-off banner in the two claim
copies, the programme-decomposition-hint call in the two finish copies — because
each sits indented inside a numbered list. That anchor reports 57 user blocks and
996 body lines; the tolerant one reports 59 and 1,007 — the epic's figure.

### The epic's "59 blocks / 1,007 lines" reproduces exactly

| Proxy | Count |
|---|---|
| Fenced blocks in UC + UF, any language, indentation-tolerant | **59** |
| Body lines inside them | **1,007** |
| of those, `bash` blocks | 52 |
| of those, shell lines | 983 |
| Fenced blocks across all four copies | **111** |

So the epic's figure is precisely *every fenced-block body line across the two
user command files* — not shell lines only, and not one of the four kit copies.
Stated as the substitution: I am using **body lines inside indentation-tolerant
fenced blocks in `claim.md` + `finish.md`** as the stand-in for **"1,007 lines of
shell pasted inside /claim and /finish"**, and the two halves match to the line.
The 24-line difference between 1,007 and the 983 that are really shell is the
**seven** non-`bash` blocks in the two user copies: the claim-ref diagram (9
lines), the local index's column header (1), the spawner usage examples (3), the
sign-off banner shape (4), the sub-agent invocation (1), the banner again in
finish (4) and the changelog line format (2).

**This document inventories all 111 blocks across all four copies**, which is the
superset the ticket asks for.

---

## 2. Where a row can go

| Destination | Meaning |
|---|---|
| `driver:start` | The driver does it before the AI is called at all — picking, locking, the worktree, the refusal gates. |
| `driver:plan` | Driver work bracketing the plan step (posting the design, recording where it came from). |
| `driver:build` | The driver enforces it while the build runs. Test-first lives here. |
| `driver:self-check` | The driver runs the gates and reads exit codes. No AI judgement. |
| `driver:review` | The driver calls the reviewers, collects verdicts, counts rounds. |
| `driver:record` | The driver writes a fact onto the claim record or the issue. |
| `driver:ship` | Push, PR, gates-on-the-PR, merge, verify, close, release, clean up. |
| `driver:park` | The refusal path, from anywhere: push, draft PR, resume brief, label, release. |
| `brief:plan` · `brief:build` · `brief:compare` · `brief:review` · `brief:fix` | The rule is a *judgement*, so it goes in that step's brief — under 3,000 words per step. |
| `hook` | A Claude Code hook enforces it, because it must fire whether or not anyone remembers. |
| `ci` | A required status check in the consuming repo owns it. The driver may satisfy it; it never replaces it. |
| `retired` | Dropped. Every one names its reason. |

Two rules about the vocabulary itself, both already written down in the consuming
repo's own instructions:

- **A checker must measure what the prompt never mentions.** A rule that goes
  into a brief must *not* also be the thing a gate greps for, or the gate is
  marking against its own answer sheet.
- **A protection that depends on somebody choosing to invoke it is not a
  protection.** Anything landing in `brief:*` and nowhere else is advice. Where a
  rule must hold every time it needs a `driver:*`, `hook` or `ci` row as well —
  the `gap` column below says which rules lack one today.

The `in` column uses the four tags. A rule present in only one copy is a
divergence by omission; Section 5 ranks the ones that cost something.

---

## 3. The rules

**178 rules, numbered 1–178 across the twelve sub-tables below.** Each names the
copies it appears in, its destination, and — where it has one — the gap that
means nothing enforces it today. The spread, derived by parsing the tables and
counting each rule once under the **first** destination its row names:

| | Rules | |
|---|---|---|
| `driver:*` | 135 | the driver runs or enforces it |
| `brief:*` | 33 | a judgement: plan 16 · build 6 · fix 5 · review 5 · compare 1 |
| `ci` | 6 | belongs to a required check in the consuming repo |
| `hook` | 4 | must fire whether or not anyone remembers |
| **Total** | **178** | |
| — of which carry a `gap` note | 55 | nothing enforces it today |

A further row names a brief as its *second* destination, so 34 rows reach a
brief in all; three `brief:review` rows are a driver step's judgement half.

**52 of the 178 — 29% — exist in only one of the two copies of their own
command.** Per pair:

| Command | Rules | In both copies | User copy only | Plugin copy only |
|---|---|---|---|---|
| `/claim` (UC ⇄ PC) | 111 | 80 | **29** | 2 |
| `/finish` (UF ⇄ PF) | 77 | 56 | **18** | 3 |

The two rows sum past 178 because ten rules belong to both commands. The
asymmetry is the finding: the drift runs almost entirely one way — 47 rules the
user copies carry and the plugin copies do not, against 5 the other way. Section
5 ranks the omissions that cost something.

### 3.1 Picking and locking a ticket → `driver:start`

| # | Rule | in | Destination | gap |
|---|---|---|---|---|
| 1 | Only a ready-labelled ticket (or a run-ready epic) is a valid target | UC PC | `driver:start` | |
| 2 | A named ticket is validated and **refused, never substituted** | UC PC | `driver:start` | |
| 3 | Refuse a closed ticket | UC PC | `driver:start` | |
| 4 | Refuse a ticket carrying the hold label | UC PC | `driver:start` | |
| 5 | Refuse a gated ticket — the PM flips that, not the agent | UC PC | `driver:start` | |
| 6 | Refuse a ticket whose claim ref already exists; never adopt a peer's lock | UC PC | `driver:start` | |
| 7 | `gh issue view` resolves pull requests too — check you were given an issue | UC PC | `driver:start` | |
| 8 | The claim is a git ref on origin taken by compare-and-swap. Nothing else is the claim | UC PC | `driver:start` | |
| 9 | Exit 10 means a peer holds it: next candidate, never retry, never `--force` | UC PC | `driver:start` | |
| 10 | The label and assignee are a derived mirror — never read to decide claimed-ness | UC PC | `driver:start` | |
| 11 | Reconcile every open claim against a live process *and* a real artifact before picking | UC PC | `driver:start` | |
| 12 | Claim age is not a staleness signal | UC PC | `driver:start` | |
| 13 | A dead claim is judged on evidence: merged PR → close · open PR → in-review · branch only → partial · nothing → ready | PC | `driver:start` | **UC still says every dead claim goes to needs-human** |
| 14 | An escalation is a normal outcome — it must never block a fresh claim (exit 0) | UC PC | `driver:start` | |
| 15 | A script error (network, expired auth) stops the claim rather than picking from a stale list | UC PC | `driver:start` | |
| 16 | Refuse a candidate that duplicates work in flight: open PR on the number, a keyed remote branch, a recent merge | UC PC | `driver:start` | |
| 17 | Also compare **files**, not just numbers — two different tickets landing on one file is the shape that costs | UC PC | `driver:start` | |
| 18 | A resume row is not a fresh build: read the PR and the handover before writing anything | UC PC | `brief:plan` | |
| 19 | Area lock: warn when every candidate's area is already active | UC PC | `driver:start` | |
| 20 | Zero claimable rows → run the queue-health report and stop; the PM picks | UC PC | `driver:start` | |
| 21 | On a debt/sweep ticket, grep open and recently-merged PR diffs for its files — a heal often rides inside a feature PR | UC | `brief:plan` | plugin copy lacks it |
| 22 | On a sweep ticket, re-measure the live finding set before starting and after every trunk merge | UC | `brief:plan` | plugin copy lacks it |

### 3.2 The worktree → `driver:start`

| # | Rule | in | Destination | gap |
|---|---|---|---|---|
| 23 | The main clone is an object store, not a workspace — never `checkout -b` there | UC PC | `driver:start` | |
| 24 | Its working tree is stale and must never be read | UC PC | `driver:start` | |
| 25 | Never invoke a script from the main clone's tree — materialise it from the ref | UC PC | `driver:start` | |
| 26 | Every claim gets its own worktree at a unique hashed path; never reuse one | UC PC | `driver:start` | |
| 27 | The branch name is deterministic: `<prefix>NNN/<slug>` | UC PC | `driver:start` | |
| 28 | Cut from freshly fetched trunk, never from whatever is checked out | UC PC | `driver:start` | |
| 29 | Fetch trunk on every repo a claim might route into | UC PC | `driver:start` | |
| 30 | Never `checkout` the trunk in a shared clone — a peer may be on it | UC PC | `driver:start` | |
| 31 | Symlink the shared `node_modules`; never install inside a worktree | UC PC | `driver:start` | |
| 32 | Copy the git-hook shims into the worktree and **refuse to continue without them** — a symlinked worktree otherwise runs zero hooks, silently | UC PC | `driver:start` | |
| 33 | Generate the ORM client before any gate runs, or a fresh worktree reports phantom type errors | UC PC | `driver:start` | project fact → config |
| 34 | A stale branch is deleted only when the issue is ready/partial and no claim ref exists | PC | `driver:start` | **UC keys this on the retired local index** |
| 35 | Refresh the shared clone's loose manifests or refuse — a stale pair installs the shared tree from an old lockfile | UC PC | `driver:start` | project fact → config |
| 36 | A worktree renders another checkout's workspace packages until they are linked | UC | `brief:fix` | plugin copy lacks it |
| 37 | A fresh worktree has no env file and no local cache — a fixed set of failures is baseline; prove it against a pristine control worktree | UC | `brief:fix` | plugin copy lacks it |

### 3.3 The spec gate → `driver:start`, refusal → `driver:park`

| # | Rule | in | Destination | gap |
|---|---|---|---|---|
| 38 | The question is "could `writing-plans` turn this into a plan with **no placeholders**" — goal, checkable outcomes, a way to verify, stated constraints, and on a bug a reproduction | UC PC | `brief:plan` + `driver:start` | |
| 39 | It is **not** "are the five headings present" — that check was replaced 2026-08-08; those headings appeared in none of the last 25 tickets | UC | `brief:plan` | **PC's gate text agrees but two downstream lines in PC still cite the five headings** |
| 40 | Record the verdict as `spec_usable` on the claim | UC PC | `driver:record` | |
| 41 | Can the whole AC ship without pausing for input? If not, release and flag | UC PC | `driver:start` | |
| 42 | 30+ files across independent surfaces is too big — release and flag | UC PC | `driver:start` | |
| 43 | An XL ticket is not too big to *start*: take it, push a draft PR early, park the remainder. Refuse only on an unplannable spec | UC | `driver:park` | plugin copy lacks it |
| 44 | A false negative costs 30 seconds; a false positive costs the slice mistakes the ship-whole rule exists to stop | UC PC | `brief:plan` | |
| 45 | Release the claim on any refusal — never squat | UC PC | `driver:park` | |

### 3.4 The anti-orphan gates → `driver:start`

| # | Rule | in | Destination | gap |
|---|---|---|---|---|
| 46 | Gate 1: a referenced mockup with no rendered screenshot refuses automatically | UC PC | `driver:start` | |
| 47 | Gate 2: a UI-shaped ticket with no backend-contract section refuses automatically | UC PC | `driver:start` | |
| 48 | Gate 2 exemption — a debt ticket ships no surface and consumes no endpoint | UC PC | `driver:start` | |
| 49 | Gate 2 exemption — a bug on a surface that already ships, unless it names something net-new | UC PC | `driver:start` | |
| 50 | Gate 2's trigger stays broad deliberately: a narrowed one missed a real UI ticket, and missing a feature fails in the expensive direction | UC PC | `brief:plan` | |
| 51 | Gate 3 (premise) **gathers; the agent decides.** Three verdicts: still true (name the file:line) · already fixed (release, comment, close) · changed shape (release, flag for re-spec) | UC PC | `brief:plan` | |
| 52 | Gate 3 reads the remote ref, and a failed fetch invalidates every line it printed | UC PC | `driver:start` | |
| 53 | `MOVED` is not evidence of anything; `ABSENT` is a prompt to look, not a verdict | UC PC | `brief:plan` | |
| 54 | A mechanical "does the cited path exist" gate was measured at 0 true positives in 25 — which is why Gate 3 has no automatic verdict | UC PC | `brief:plan` | |
| 55 | A design source the ticket names but you cannot open is a **stop** — park; never reconstruct it from prose | UC | `driver:park` | plugin copy lacks it |
| 56 | Record `mockup_viewed` and `backend_contract_acknowledged`; the merge refuses if either is false | UC PC UF PF | `driver:record` + `driver:ship` | |
| 57 | Setting an attestation without passing its gate falsifies the trail | UC PC | `driver:record` | |

### 3.5 Plan → `brief:plan`, `driver:plan`

| # | Rule | in | Destination | gap |
|---|---|---|---|---|
| 58 | The build chain is six ordered steps: brainstorm · plan · execute · test-first · verify · review | UC PC | `driver:*` (the whole sequence) | **measured at 3 of 161 runs; the sequence has to be the driver's, not a remembered list** |
| 59 | "This one is simple" is never a reason to skip a step; reasoning toward an exemption is the signal the step applies | UC PC | `brief:plan` | |
| 60 | Subagent-driven execution replaces step 3 on a sweep across many independent sites | UC PC | `driver:build` | |
| 61 | Systematic debugging replaces steps 1–2 on a bug: reproduce, isolate, prove red, then fix | UC PC | `brief:plan` | |
| 62 | The test for that path is an *observed failure to reproduce* — not that a feature feels investigative | UC PC | `brief:plan` | |
| 63 | Steps 1–2 may be satisfied by the ticket; state which, and record `design_source` (`ticket-body` · `brainstormed` · `debugged`) | UC PC | `driver:record` | |
| 64 | `design_source` is cross-checked against `spec_usable` — the two are written at different times, so they cannot both be waved through | UC PC UF PF | `driver:record` + `driver:ship` | |
| 65 | Record it **before** writing code; afterwards it is a memory, not a decision | UC PC | `driver:record` | |
| 66 | The design goes on the issue as a comment — never a per-ticket doc committed into the product repo | UC PC | `driver:plan` | |
| 67 | The plan reads current docs before naming any external library call; training data is behind every one | UC | `brief:plan` | plugin copy lacks it |
| 68 | The plan inventories the existing home for an outside service before planning a call to it — one home per service | UC | `brief:plan` | plugin copy lacks it |
| 69 | **Plannable is not planned.** A ticket can pass the gate and still name no files, boundaries or interfaces; writing the decomposition is still the agent's | UC | `brief:plan` | plugin copy lacks it |
| 70 | Read the coding standard once per ticket, not per file | UC PC | `brief:build` | |
| 71 | Read the programme **brief**, not the whole state file — ~77% of those bytes are history, and reading them designs from the programme's past | UC PC | `driver:start` | |
| 72 | Never hand-write the generated half of a state file | UC UF PF | `driver:ship` | PC lacks it |

### 3.6 Build → `driver:build`, `brief:build`

| # | Rule | in | Destination | gap |
|---|---|---|---|---|
| 73 | **Test-first: red before green, per change.** The driver enforces it | UC PC | `driver:build` | **measured at 0 of 161 runs under the current wording** |
| 74 | A test must go red when the bug comes back. Plant it by **deleting the fix**, not by mistyping it | UC | `driver:build` + `brief:build` | plugin copy lacks it |
| 75 | A test that reads a source file, counts classes or asserts a string is in a file is not a test of behaviour | UC | `brief:build` | plugin copy lacks it |
| 76 | Test the wiring at the call site, not a copy of it | UC | `brief:build` | plugin copy lacks it |
| 77 | Say each fact once, in one wording — check the whole composed screen before adding a line of copy (74 reports) | UC | `brief:build` + `brief:review` | plugin copy lacks it |
| 78 | A state change updates **every** surface that shows it; grep for all of them and change them together | UC | `brief:build` + `brief:review` | plugin copy lacks it |
| 79 | A failed read never looks empty, loading or finished — three visible outcomes, and "nothing here" is only loaded-and-empty (9 reports) | UC | `brief:build` + `brief:review` | plugin copy lacks it |
| 80 | Text reaches contrast AA on the rendered pixels in both themes; a held state differs by more than a hairline | UC | `brief:review` | plugin copy lacks it |
| 81 | The decision the screen asks for is the most prominent thing on it, above the fold | UC | `brief:review` | plugin copy lacks it |
| 82 | No coloured edge rails — banned, and shipped three times anyway | UC | `brief:review` | plugin copy lacks it |
| 83 | Build to what was approved: put the render beside it and list every difference; each is fixed or named on the PR | UC | `brief:compare` | plugin copy lacks it |
| 84 | Verification is observation: evidence before any claim of done | UC PC | `driver:self-check` | |
| 85 | A changelog entry is its own file named for the ticket — never an edit to the shared file, which conflicted every open PR | UF PF | `driver:ship` | project fact → config |
| 86 | The other valid answer is `no-changelog: <reason>` in the commit body. The driver cannot complete without one of the two | UF PF | `driver:ship` | |

### 3.7 Self-check → `driver:self-check`

| # | Rule | in | Destination | gap |
|---|---|---|---|---|
| 87 | Ship-whole: every AC box ticked or you are not done | UF PF | `driver:self-check` | |
| 88 | Walk every AC **and** every verify step against the branch | UF PF | `driver:self-check` | |
| 89 | The only legitimate partial is a remaining human-driven blocker | UF PF | `driver:self-check` | |
| 90 | **Gates are exit-code-gated, never batched past** — a printed failure mid-batch once reached the trunk | UF PF | `driver:self-check` | |
| 91 | Never put a gate and a commit/push/merge in one command batch | UF PF | `driver:*` (structural) | |
| 92 | Run each gate as its own command and read its exit code; a pipeline's `$?` is the last command's | UF PF | `driver:self-check` | |
| 93 | Diff-scoped gates read committed HEAD: commit, gate, then push — never commit, gate, soft-reset | UF | `driver:self-check` | plugin copy lacks it |
| 94 | Locally run only what the change touches; CI runs the whole suite and a red CI brings an agent back | UF | `driver:self-check` | **PF runs the whole suite locally — see 5.7** |
| 95 | Before calling a failure pre-existing, re-verify it in a worktree whose generated client exists | UF PF | `brief:fix` | |
| 96 | Changed a value? Grep the whole test tree for the old one and add every hit to the run | UF | `brief:fix` | plugin copy lacks it |
| 97 | A late source edit voids a fast-track — re-run the type gate against the final tree | UF | `driver:self-check` | plugin copy lacks it |
| 98 | A commit-reading gate must run after the clean-tree check, and stamp only when it fails | UF PF | `driver:self-check` | project fact → config |
| 99 | Delegate long gate runs to a gate-runner sub-agent so the main context stays clean | UF PF | `driver:self-check` | |
| 100 | Never `--no-verify`; never skip | UF PF | `hook` | hook exists in the kit today |

### 3.8 Review → `driver:review`

| # | Rule | in | Destination | gap |
|---|---|---|---|---|
| 101 | **Review is one step and it runs early:** both reviewers together on the first version that renders, findings batched into one fix list | UC UF | `driver:review` | plugin copies lack it entirely |
| 102 | They judge different things — is it designed · is it honest — and neither subsumes the other | UC UF PF | `driver:review` | |
| 103 | **Two rounds, then the PR ships.** Anything non-blocking after round 2 becomes its own ticket, linked | UF | `driver:review` | plugin copy lacks it |
| 104 | A blocker is exactly three things: a dead control, a broken flow, a data-honesty failure | UF | `driver:review` | plugin copy lacks it |
| 105 | The PR body carries `Review rounds: N of 2` and the claimed-at SHA, so both rules are checkable rather than promised | UF | `driver:ship` | plugin copy lacks it |
| 106 | A follow-up ticket carries the finding verbatim, its screenshot and the parent's programme label | UF | `driver:review` | plugin copy lacks it |
| 107 | About six fixes per PR: one late problem holds up six fixes, not seventeen | UF | `driver:ship` | plugin copy lacks it |
| 108 | Gate 4: a UI or kit diff needs a recorded SHIP verdict from the honesty review | UF PF | `driver:review` | |
| 109 | Gate 5: the head must not have moved since that verdict — a verdict is only about the commit it was taken against | UF PF | `driver:review` | |
| 110 | A verdict trailer an agent writes for itself is indistinguishable from one a reviewer earned; if the fingerprint moved, re-run | UF PF | `driver:review` | |
| 111 | The design gate is never self-attested — no self-approval, ever | UC PC | `driver:park` | |
| 112 | An approval covers the render the human saw — **nothing later**. Any change to what renders voids it | UC UF | `driver:review` + `ci` | plugin copies lack it |
| 113 | Never clear the hold by citing an approval of an earlier render | UC UF | `driver:ship` | plugin copies lack it |
| 114 | A resume brief may carry an approval forward only for commits that change no pixels, and must say so | UC UF | `driver:park` | plugin copies lack it |
| 115 | The honesty review does not prove the screen is *designed* — run the design critic too on any pixel-changing ticket | UF | `driver:review` | plugin copy lacks it |

### 3.9 Ship → `driver:ship`

| # | Rule | in | Destination | gap |
|---|---|---|---|---|
| 116 | Refuse to finish someone else's ticket — check the claim holder | UF PF | `driver:ship` | |
| 117 | Refuse to finish from a main repo clone | UF PF | `driver:ship` | |
| 118 | Refuse on the trunk or any branch not matching the ticket pattern | UF PF | `driver:ship` | |
| 119 | Uncommitted changes: ask before proceeding | UF PF | `driver:ship` | |
| 120 | Never push or merge directly to the trunk or the release branch | UF PF | `driver:ship` | |
| 121 | The PR title is what a squash merge ships — title it the way the commit should read | UF PF | `driver:ship` | |
| 122 | No "deferred to follow-up" line under the AC list — that is a partial, and the rule forbids it | UF PF | `driver:ship` | |
| 123 | An evidence-routes section is required on every PR that changes what a user sees | UF | `driver:ship` + `ci` | plugin copy lacks it |
| 124 | Step 5.5 Gate 1: UI without its backing API refuses unless the body declares a phase split **and** a feature flag | UF PF | `ci` | |
| 125 | Gate 2: evidence must be **viewable** — raw content URLs refused outright on a private repo | UF PF | `ci` | |
| 126 | Gate 2: a blob link must be pinned to a commit SHA, never a branch — the merge deletes the branch | UF PF | `ci` | |
| 127 | Gate 2 states its own limit: it proves the evidence can be opened, not that it is genuine | UF PF | `brief:review` | |
| 128 | Gate 2, deletion-only variant: a removal proves itself by execution and a removal-evidence section, not a photograph | UF PF | `ci` | |
| 129 | When the body carries no evidence, **produce it** — publish this run's screenshots, SHA-pinned — rather than refusing at the wrong end of the pipe | PF | `driver:ship` | **UF only refuses; see 5.8** |
| 130 | One shared definition of "changes what a user sees" — six inlined copies is how whole surfaces became invisible to the gate | PF | `ci` | UF inlines its own |
| 131 | A live preview URL is the strongest hand-over, and never replaces the durable screenshot | PF | `driver:park` | UF lacks it |
| 132 | Gate 3: a wiring-check table mapping each new UI element to the endpoint it calls | UF PF | `ci` | |
| 133 | **Finish the review before arming auto-merge** — auto fires the instant CI goes green, whatever else is unfinished | UF PF | `driver:ship` | |
| 134 | Not arming auto is **not** sufficient: an automerge workflow lands any green, non-draft, mergeable PR | UF PF | `driver:ship` | |
| 135 | The mechanism that works is a **draft** PR, marked ready only when review is complete | UF PF | `driver:ship` | |
| 136 | CI green means nothing already tested broke. It does not mean the change is correct | UF PF | `brief:review` | |
| 137 | **Hand off after the push; do not wait for CI.** A watcher brings an agent back on red or conflict | UF | `driver:ship` + `hook` | plugin copy still waits |
| 138 | Armed + green is not terminal — re-check landability after CI settles; a conflict silently voids the armed promise | UF PF | `hook` (watcher) | |
| 139 | Before acting on a dirty flag, confirm the conflict is real — the precompute is merge-driver-blind | UF PF | `driver:ship` | |
| 140 | Zero check runs with auto armed is a conflict, not a slow runner | UF | `driver:ship` | plugin copy lacks it |
| 141 | A drift retry must abort on a conflicted merge — **never** stage a conflicted tree wholesale | UF PF | `driver:ship` | |
| 142 | Re-gate after any drift-retry merge: the merged result is new code that has never been gated | UF PF | `driver:self-check` | |
| 143 | Merge verification is its own command, and nothing destructive runs in the same batch | UF PF | `driver:ship` | |
| 144 | Release the claim only after the merge is verified — a ref released early is a ticket a peer can claim out from under an open PR | UF PF | `driver:ship` | |
| 145 | Close the issue in the queue repo regardless of which repo the PR landed in | UF PF | `driver:ship` | |
| 146 | An epic parent auto-closed by a linked slice merge is reopened and relabelled | UF PF | `driver:ship` | |
| 147 | Auto-promote gated siblings whose last open blocker was this ticket | UF PF | `driver:ship` | |
| 148 | Never promote to the release branch from finish — the review gate owns that | UF PF | `driver:ship` | |
| 149 | Never touch production | UF PF | `driver:ship` | |
| 150 | Remove the worktree, sweep orphans, and never force a dirty tree | UF PF | `driver:ship` | |
| 151 | Read the live "also running" list **after** releasing this claim, or you report yourself | UF PF | `driver:ship` | |
| 152 | Close with the sign-off banner, always last on screen | UC UF PC PF | `hook` | hook exists in the kit today |
| 153 | The banner's second line names who it is paused on and the actual question — "blocked" is what makes an operator start a second agent | UC UF PC PF | `hook` | |

### 3.10 Park → `driver:park`

| # | Rule | in | Destination | gap |
|---|---|---|---|---|
| 154 | Never hold a claim while a human thinks: the slot is unusable and the ticket is invisible | UC PC | `driver:park` | |
| 155 | Push first — an unpushed branch is the only thing a park can lose | UC PC | `driver:park` | |
| 156 | Open a **draft** PR; that is what makes the work visible to the reconciler as in-review | UC PC | `driver:park` | |
| 157 | The resume brief is an issue comment: built · stopped at · needs (answerable in a line) · how to resume | UC PC | `driver:park` | |
| 158 | Then label, then release the ref | UC PC | `driver:park` | |
| 159 | A UI park carries a rendered concept plus 2–3 numbered questions — the label alone is not a park | UC | `driver:park` | plugin copy lacks it |
| 160 | Park only the human residual: first decompose and ship every slice the gates can prove | UC | `driver:park` | plugin copy lacks it |
| 161 | Hand over a URL that can be clicked, not screenshots | UC PC | `driver:park` | |
| 162 | Never spawn the interactive design flow — it needs a human present from the start | UC PC | `driver:start` | |
| 163 | Do not ship a stub duplicate of a feature a peer landed mid-build: reconcile, keep the additive part, file the rest | UC | `brief:fix` | plugin copy lacks it |

### 3.11 Epic mode → `driver:start`, `driver:ship`

| # | Rule | in | Destination | gap |
|---|---|---|---|---|
| 164 | Epic mode is entered only from a run-ready epic; the label is the authorization | UC PC | `driver:start` | |
| 165 | The epic body must carry an autonomy contract — AC, mockups, decision defaults, escalation bar — or the claim is released | UC PC | `driver:start` | |
| 166 | Slices live in the state file, never as child issues; existing children are adopted, not duplicated | UC PC | `driver:start` | |
| 167 | The state file is where every decision goes; decisions do not go in issue comments | UC PC | `driver:record` | |
| 168 | One worktree per slice, each cut from the trunk that already contains the prior merges | UC PC | `driver:start` | |
| 169 | A slice PR says `Part of #N`, never `Closes` | UF PF | `driver:ship` | |
| 170 | Exactly two issue comments per epic run: claim, and the completion digest | UC PC | `driver:record` | |
| 171 | The claim survives a slice merge; it is released at close-out only | UF PF | `driver:ship` | |
| 172 | The curated half of the state file gates the **push**; the generated half runs after | UF | `driver:ship` | **PF moved both before the push — see 5.9** |
| 173 | Escalate only for: a real scope change, a third-party blocker, a destructive action, or a gate failure you cannot fix | UC PC | `driver:park` | |
| 174 | Never stop between slices to ask whether to continue — the claim was the authorization | UC PC | `driver:start` | |
| 175 | Close-out walks the full AC list against the trunk with evidence before the epic closes | UC PC | `driver:ship` | |

### 3.12 Recovery → `driver:park`

| # | Rule | in | Destination | gap |
|---|---|---|---|---|
| 176 | A bad merge on the trunk is cheap until the review gate promotes it; revert by PR, or revert-and-push, or fix forward if small | UF PF | `driver:park` | |
| 177 | Never force-push the trunk | UF PF | `driver:park` | |
| 178 | If a gate fails, stop before the push. The local gate **is** the gate | UF PF | `driver:self-check` | |

---

## 4. The script blocks

All 111, by copy, numbered in line order. `what it does` is the block's job, not
a transcription. `dest` uses the vocabulary in Section 2. **IND** marks the one
indented block per file that a column-1 fence anchor misses.

### 4.1 UC — `~/.claude/commands/claim.md` (30 blocks)

| # | lines | what it does | dest |
|---|---|---|---|
| 1 | 32–34 | Sets the claim-lock path | `retired` — the driver knows where its own tools are |
| 2 | 50–75 | The whole park: draft PR, hold label, resume-brief comment, release | `driver:park` |
| 3 | 113–117 | Materialises repo scripts from the ref into a SHA-keyed temp dir | `retired` — the driver reads the ref itself, once |
| 4 | 127–137 | Config preamble, then the programme-state brief for the parent | `driver:start` |
| 5 | 160–170 | Diagram of the claim ref and the state directory | `retired` — reference prose, not an instruction |
| 6 | 190–192 | The local index's column header | `retired` — the index is gone |
| 7 | 200–205 | Resolves repo name/path/slug from the index column | `retired` — replaced by the repo label + config |
| 8 | 282–284 | Writes `spec_usable` | `driver:record` |
| 9 | 296–304 | Repo guard: index present, config valid, sister-repo warn | `driver:start` (the index check is `retired`) |
| 10 | 314–318 | Spawner usage examples | `retired` — reference prose |
| 11 | 330–368 | Step 0: rebuild index · programme stubs · reconcile · refresh manifests | `driver:start` (0a `retired`) |
| 12 | 384–393 | Fetch trunk on both repos | `driver:start` |
| 13 | 412–425 | Validates a named ticket and refuses rather than substituting | `driver:start` |
| 14 | 440–487 | Builds the candidate list by hand: two label passes, jq projection, held-ref filter, sort | `driver:start` — already a script in the kit |
| 15 | 507–532 | Duplicate-work check: open PRs, keyed branches, file overlap, recent merges | `driver:start` |
| 16 | 544–553 | Queue-health report when nothing is claimable | `driver:start` |
| 17 | 571–586 | Acquires the claim and branches on the exit code | `driver:start` |
| 18 | 595–599 | Records the trunk SHA the ticket was claimed at | `driver:record` |
| 19 | 609–619 | Mirrors the labels; appends to the session ticket ledger | `driver:record` (the ledger is `retired`) |
| 20 | 634–636 | Releases the claim when the spec gate fails | `driver:park` |
| 21 | 654–819 | Step 4.5: Gates 1, 2 and 3 — 165 lines, the largest block in either command | `driver:start` + `brief:plan` (Gate 3's verdict) |
| 22 | 846–862 | Computes slug, hash, worktree path, branch, repo routing | `driver:start` |
| 23 | 868–895 | Worktree add · node_modules symlink · hook shims with a refusal · ORM generate | `driver:start` |
| 24 | 907–911 | Stale-branch delete and retry | `driver:start` |
| 25 | 919–926 | Writes the two gate attestations plus run id and log | `driver:record` |
| 26 | 949–951 | Rebuilds the local index | `retired` — the index is gone |
| 27 | 977–982 | Writes the session scope label and its owner pid | `driver:record` |
| 28 | 1065–1074 | Writes `design_source`, three variants | `driver:record` |
| 29 | 1165–1175 | Epic autonomy-contract gate | `driver:start` |
| 30 | 1255–1260 | **IND** The sign-off banner's shape | `hook` — the backstop already refuses a stop without it |

### 4.2 UF — `~/.claude/commands/finish.md` (29 blocks)

| # | lines | what it does | dest |
|---|---|---|---|
| 1 | 43–45 | Invokes the gate-runner sub-agent | `driver:self-check` |
| 2 | 55–66 | Refreshes the programme state file for a child ticket | `driver:ship` |
| 3 | 124–134 | Cross-repo routing read from the claim record | `driver:start` |
| 4 | 142–156 | Repo guard: index present, inside a work tree, refuse every main clone | `driver:ship` (the index check is `retired`) |
| 5 | 166–168 | Rebuilds the local index | `retired` |
| 6 | 172–175 | Rebuilds it again after the close | `retired` |
| 7 | 181–218 | Branch, worktree, ticket key, claim-holder check, repo routing, epic mode | `driver:ship` |
| 8 | 224–226 | Uncommitted-change check | `driver:ship` |
| 9 | 236–243 | Writes the changelog fragment and rebuilds the changelog | `driver:ship` |
| 10 | 270–272 | The gate trio as one exit-code-gated command | `driver:self-check` |
| 11 | 280–303 | ORM generate · the trio individually · the commit-reading gate with a stamp-and-commit fallback | `driver:self-check` |
| 12 | 339–341 | Pushes the branch | `driver:ship` |
| 13 | 349–373 | Opens the PR from a body template (summary, spec, AC, verify, evidence routes) | `driver:ship` |
| 14 | 386–388 | Reads the PR number | `driver:ship` |
| 15 | 396–686 | Step 5.5: Gates 1–5 plus both attestation cross-checks — **291 lines, the largest block anywhere** | `ci` + `driver:review` + `driver:record` |
| 16 | 700–702 | Squash-merges and deletes the branch | `driver:ship` |
| 17 | 755–759 | Re-checks landability after CI settles | `hook` (the watcher) |
| 18 | 781–783 | Drift-retry merge that aborts on conflict | `driver:ship` |
| 19 | 798–803 | Reads the merge SHA from the trunk | `driver:ship` |
| 20 | 817–825 | Step 6.5 merge verification, as its own command | `driver:ship` |
| 21 | 835–837 | Releases the claim | `driver:ship` |
| 22 | 848–852 | Drops the ticket's index row | `retired` |
| 23 | 856–860 | Rewrites the index row as partial | `retired` |
| 24 | 864–880 | Appends to the merged log, the session ledger and the release-notes buffer | `retired` (all three are derived from merged PRs) |
| 25 | 890–951 | Closes the issue · epic auto-reopen · auto-promote gated siblings | `driver:ship` |
| 26 | 965–982 | Removes the worktree and sweeps orphans | `driver:ship` |
| 27 | 1002–1010 | **IND** Config preamble + tools materialiser, then the programme-decomposition hint appended to the close comment | `driver:ship` (the preamble is `retired`) |
| 28 | 1020–1025 | The sign-off banner's shape | `hook` — the backstop already refuses a stop without it |
| 29 | 1031–1034 | The changelog line format | `brief:build` |

### 4.3 PC — kit `skills/claim/SKILL.md` (28 blocks)

Same spine as UC with the index subsystem already removed. Differences from the
UC row are called out in the `dest` cell.

| # | lines | what it does | dest |
|---|---|---|---|
| 1 | 16–18 | Toolkit-env preamble | `retired` — the driver resolves its own environment once |
| 2 | 34–62 | The park block (adds the preview-URL hand-over) | `driver:park` |
| 3 | 98–101 | Toolkit-env plus the tools materialiser | `retired` |
| 4 | 111–118 | Programme-state brief for the parent | `driver:start` |
| 5 | 139–148 | Diagram of the claim ref and the state directory | `retired` |
| 6 | 172–177 | Repo routing via the toolkit helper | `retired` |
| 7 | 252–254 | Writes `spec_usable` | `driver:record` |
| 8 | 263–265 | Repo guard | `driver:start` |
| 9 | 275–279 | Spawner usage examples | `retired` |
| 10 | 291–321 | Step 0: reconcile · refresh manifests (no index rebuild) | `driver:start` |
| 11 | 335–340 | Fetch trunk on both repos | `driver:start` |
| 12 | 359–372 | Validates a named ticket | `driver:start` |
| 13 | 384–392 | Calls the candidate-list script — UC's 48 hand-rolled lines already collapsed to one call | `driver:start` |
| 14 | 412–437 | Duplicate-work and file-overlap check | `driver:start` |
| 15 | 446–450 | Queue-health report | `driver:start` |
| 16 | 468–483 | Acquires the claim, branches on the exit code | `driver:start` |
| 17 | 493–497 | Mirrors the labels and syncs the board (no session ledger) | `driver:record` |
| 18 | 512–514 | Releases on a failed spec gate | `driver:park` |
| 19 | 532–697 | Step 4.5 Gates 1–3 (165 lines) | `driver:start` + `brief:plan` |
| 20 | 722–736 | Branch, worktree path, repo routing | `driver:start` |
| 21 | 742–769 | Worktree add · symlink · hook shims · ORM generate | `driver:start` |
| 22 | 775–778 | Writes the programme stubs **in the worktree** and commits them | `driver:start` |
| 23 | 782–786 | Stale-branch delete and retry | `driver:start` |
| 24 | 794–801 | Writes the attestations | `driver:record` |
| 25 | 838–841 | Writes the session scope label (no owner pid) | `driver:record` |
| 26 | 894–903 | Writes `design_source` | `driver:record` |
| 27 | 955–965 | Epic autonomy-contract gate | `driver:start` |
| 28 | 1039–1044 | **IND** The sign-off banner's shape | `hook` — the backstop already refuses a stop without it |

**Absent from PC and present in UC:** the block that records the claimed-at
trunk SHA (UC 18). Nothing in PC freezes the rule set for a ticket.

### 4.4 PF — kit `skills/finish/SKILL.md` (24 blocks)

| # | lines | what it does | dest |
|---|---|---|---|
| 1 | 32–34 | Invokes the gate-runner sub-agent | `driver:self-check` |
| 2 | 44–51 | Refreshes the programme state file **and commits it on the branch** | `driver:ship` |
| 3 | 111–118 | Cross-repo routing from the claim record | `driver:start` |
| 4 | 126–138 | Repo guard — bare-repo-safe, because a bare repo prints `false` and exits 0 | `driver:ship` |
| 5 | 150–184 | Branch, claim-holder check, repo routing, epic mode | `driver:ship` |
| 6 | 190–192 | Uncommitted-change check | `driver:ship` |
| 7 | 202–209 | Changelog fragment | `driver:ship` |
| 8 | 236–238 | The gate trio — **whole-suite, not changed-scope** | `driver:self-check` |
| 9 | 244–267 | ORM generate · the trio · the commit-reading gate | `driver:self-check` |
| 10 | 275–277 | Pushes the branch | `driver:ship` |
| 11 | 285–306 | Opens the PR from a body template — **no evidence-routes heading** | `driver:ship` |
| 12 | 312–314 | Reads the PR number | `driver:ship` |
| 13 | 324–643 | Step 5.5: Gates 1–5, the shared user-visible predicate, the preview-URL probe, the **evidence publisher**, both attestation cross-checks — **320 lines** | `ci` + `driver:review` + `driver:ship` |
| 14 | 651–653 | Squash-merges and deletes the branch | `driver:ship` |
| 15 | 693–697 | Re-checks landability after CI settles | `hook` (the watcher) |
| 16 | 715–717 | Drift-retry merge that aborts on conflict | `driver:ship` |
| 17 | 724–729 | Reads the merge SHA | `driver:ship` |
| 18 | 743–751 | Merge verification | `driver:ship` |
| 19 | 761–763 | Releases the claim | `driver:ship` |
| 20 | 776–834 | Closes the issue · board sync · epic auto-reopen · auto-promote siblings | `driver:ship` |
| 21 | 848–860 | Removes the worktree and sweeps orphans | `driver:ship` |
| 22 | 880–884 | **IND** The programme-decomposition hint, kit form — three lines against UF 27's nine | `driver:ship` |
| 23 | 892–897 | Sign-off banner shape | `hook` — the backstop already refuses a stop without it |
| 24 | 903–906 | Changelog line format | `brief:build` |

### 4.5 What the block tally says

Each block is counted once, under the **first** destination its row names.

| Bucket | Blocks | Note |
|---|---|---|
| `driver:*` (the driver runs it) | 84 | 22 UC · 20 UF · 22 PC · 20 PF |
| `retired` | 17 | wholly. A further 5 rows are a driver step with a retired part inside |
| `hook` | 6 | the watcher, and the sign-off banner in all four copies |
| `ci` | 2 | the gate halves of UF 15 / PF 13, shared with a required check |
| `brief:*` | 2 | the changelog line format, in both finish copies |
| **Total** | **111** | |

Reproduce it by parsing the four tables above: every row's number is contiguous
from 1, and the bucket is the first backticked destination in its last column.

Two blocks account for **607 of the 1,869 shell lines** — UF 15 (289) and PF 13
(318), both the same Step 5.5. Just under a third of all the shell an agent is
asked to paste is one gate section, existing twice, and it belongs to `ci` plus a
driver step, not to an agent's clipboard.

**33 of the 111 blocks re-answer "where am I and where are my tools"** — they
carry a config preamble, a tools materialiser, or a `toolkit-env.sh` source
before doing their actual job: UC 3, 4, 7, 9, 11, 12, 16, 18, 22 · UF 3, 4, 7,
25, 26, 27 · PC 1, 3, 4, 6, 8, 10, 11, 13, 15, 16, 20 · PF 2, 3, 4, 5, 20, 21,
22. Three of them (PC 1, 3, 8) are nothing else. That is **80 shell lines**
spent re-deriving the same four paths. A driver resolves them once at start.

---

## 5. Where the two copies disagree

Ranked by what the disagreement costs. "Silent" means nothing fails when the two
diverge — which is why they did.

### 5.1 The plugin copies carry none of the rules their own reviewers apply

UC's "Build to the reviewers' rules" block — eight numbered rules, drawn from 207
review send-backs across 24 tickets — is absent from PC. So is the review-is-one-step
rule, the two-round cap, the blocker definition, the six-fixes-per-PR shape, and the
render-approval rule. An agent running the plugin skill is judged against rules it
was never given. **Highest-cost divergence in the set**: it is the measured cause of
the 7-rejection median the epic is trying to move.

| Missing from PC / PF | Rules |
|---|---|
| The eight reviewers' rules | 77–83, 74 |
| Review is one step, run early | 101 |
| Two rounds, then ship | 103 |
| What a blocker is | 104 |
| `Review rounds: N of 2` in the body | 105 |
| Six fixes per PR | 107 |
| An approval covers the render seen | 112–114 |

### 5.2 Nothing in the plugin copies freezes the rules for a ticket

UC records the claimed-at trunk SHA (block UC 18) and UF carries it into the PR
body (rule 105), so a required check that lands mid-build does not apply to a
ticket claimed before it existed. PC and PF have neither the block nor the rule. Three new
checks landing mid-ticket cost one ticket a round each; the plugin copy has no
defence against a repeat.

### 5.3 The plugin copy's spec gate contradicts itself

PC's gate text carries the current check — "can `writing-plans` turn this into a
plan with no placeholders … it is not about headings … this replaced a check for
five fixed headings on 2026-08-08". Two lines downstream in the same file still
cite the retired rule:

- *"Only write `true` when all five sections are genuinely there."*
- *"Step 4 above already refuses any ticket missing 'What it does' / 'Acceptance
  criteria' / 'How to verify' / 'Files to touch' / 'Out of scope'."*

Those headings appeared in 0 of the last 25 tickets. An agent reading PC top to
bottom is told both that the headings are not the test and that they are. UC
carries the correction in both places.

### 5.4 The two copies disagree on what a dead claim means

| | Verdict for a claim whose process died |
|---|---|
| UC | `FAILED`/`MALFORMED` → move the lock aside, flip the issue to needs-human |
| PC | judge on evidence: merged PR → close · open PR → in-review · branch only → partial · nothing → ready |

PC's rule is the corrected one and says why: the old rule would have been wrong 6
times in 11, because those six had open PRs a fresh agent would have rebuilt from
nothing. UC still describes the behaviour that was replaced — and UC is the copy a
human reads.

### 5.5 The local-index subsystem lives in the user copies and is gone from the plugin copies

| Retired in PC/PF, still live in UC/UF |
|---|
| The index rebuild at claim time (UC 11, block 0a) |
| The index rebuild at step 8 (UC 26) |
| The index rebuild twice in finish (UF 5, UF 6) |
| Index row drop and index row → partial (UF 22, UF 23) |
| The merged log and release-notes buffer append (UF 24) |
| The session ticket ledger (UC 19, UF 24) |
| Reading the spec from an index column instead of the issue body |
| Repo routing from an index column instead of the repo label |
| Every blocker-tag ⇄ label mapping table |

Nine subsystems, all derived data. The plugin copies already answer every one of
those questions by asking GitHub. The user copies are the ones being executed.

### 5.6 Where the programme state file is written — and when

| | Stub writer runs | State refresh on finish |
|---|---|---|
| UC / UF | in the session's own checkout | **after** the merge bookkeeping |
| PC / PF | in the worktree, committed with the slice | **before** the push |

PC's reasoning is that the directory is committed, so the writer must run where a
commit can land. PF's is that a commit made after the merge is discarded with the
worktree. Both are right and both contradict the user copies, which still tell an
agent to run the refresh after the merge — where it cannot survive.

### 5.7 The local gate scope

| | Command |
|---|---|
| UF | the changed-scope trio: `lint:changed`, the type gate, `test:changed` |
| PF | the whole suite: `lint`, the type gate, `test` |

UF carries the measurement behind its version: 23 of 123 agent-hours went on local
full suites and whole-repo lint that CI then ran again. PF asks for exactly that.

### 5.8 Gate 2 refuses in one copy and produces in the other

UF's Gate 2 refuses a UI PR whose body carries no evidence. PF's takes the
screenshots this run already rendered, commits them under an evidence directory,
pins them to the new head SHA and edits them into the PR body — with the reason
stated: refusing fired *after* the decision it existed to inform, while 5 UI PRs
sat in review with no images and 460 orphaned screenshots sat on a disk.

PF is the better behaviour and the user copy does not have it.

### 5.9 Hand-off

UF ends the run at the push: local gates green, trailers matching the head, PR
ready with auto armed, one hand-off comment, release, end — because 36 of 123
agent-hours were agents holding a slot while watching CI. PF still carries the
landability re-check as the finishing agent's own job. The kit's own copy keeps
the agent alive for the thing the user copy measured as the single largest waste.

### 5.10 Smaller, still real

| Only in | What |
|---|---|
| UC | A design source you cannot open is a stop (55) · XL is not too big to start (43) · plan reads current docs (67) · plan inventories the service home (68) · plannable is not planned (69) · a UI park carries a concept plus numbered questions (159) · park only the human residual (160) · do not ship a stub duplicate (163) · the type-gate-not-raw-compiler warnings · the worktree diagnosis list (36, 37) |
| UF | Diff gates read committed HEAD (93) · grep the whole test tree (96) · a late edit voids a fast-track (97) · zero check runs means a conflict (140) · evidence-routes heading (123) · run the design critic too (115) · the allowlist-pruning and ratchet rules for deletions · the trunk-drift diagnosis list |
| PC | The preview-URL hand-over in the park brief · the candidate list as one script call rather than 48 inline lines |
| PF | The shared user-visible predicate (130) · the preview probe (131) · the evidence publisher (129) · the bare-repo-safe work-tree check |

Both plugin copies are also **project-neutral** where the user copies name the
project directly. That is the one divergence that is deliberate and should stay.

---

## 6. Retired, with the reason

| What | Why |
|---|---|
| The local index file, in all nine of its uses | Derived from GitHub and drifted from it: 792 rows against 878 open issues, 15 tickets marked claimed when 4 were. The plugin copies already read GitHub directly. |
| The merged log and the release-notes buffer | Both reconstructable from merged PRs. The weekly draft already reads GitHub. |
| The session ticket ledger and the scope-label owner file | Per-machine state that only two read-only views consume; the driver knows its own run. |
| The human-narrative queue file | Superseded by the queue-health report, which is generated. |
| The retired ticket-id map | Ticket ids are issue numbers. Four blocks still carry the comment. |
| Two reconcilers with no file: `recover-stale-claims.sh`, `reconcile-claim-refs.sh` | Neither exists in the kit, the state directory, or the consuming repo's trunk. Both are still named in prose in both claim copies. |
| The tools materialiser, in all four of its copies | The driver reads the ref once at start. |
| Every environment-resolution preamble — 33 of the 111 blocks carry one, 80 shell lines in all | The driver resolves its environment once. |
| Three reference-prose blocks (the ref diagram twice, the spawner usage) | Documentation, not an instruction to run. |
| The index column header and the column-8 routing | The repo label answers it. |
| The five-headings spec check | Replaced 2026-08-08; the headings appeared in 0 of the last 25 tickets. Two lines in PC still cite it. |

Nothing above is deleted by this document. The rows are the list child 6 deletes
from, once children 2–5 have replaced them and the shadow run has measured it.

---

## 7. What this inventory does not answer

Deliberately out of scope, and handed on:

- **Which brief each judgement rule goes in, and its wording.** Section 3 names
  the step; child 3 writes the briefs and has to keep each under 3,000 words.
  The budget is not the constraint it looks like: the 34 `brief:*` rules state
  in **653 words** here (plan 335 · build 125 · fix 91 · review 80 · compare
  22), against the **25,534 words of prose** outside the blocks in the four
  source files. Child 3's risk is therefore transcription, not compression —
  writing each brief from these rules keeps every step inside budget, while
  reaching back to the source text blows it on the first step.
- **How the driver enforces test-first.** Rule 73 is the epic's headline target
  (0 of 161 runs) and the mechanism is child 2's.
- **The swarm parts.** The scheduler, queue, repair watch, live view, reporter
  and installer are child 4. Rules 137 and 138 point at the watcher and stop
  there.
- **Which `ci` rows already have a required check.** Every `ci` row here is a
  statement about where the rule *belongs*, not a claim that the check exists.
  Confirming each against the consuming repo's required-check list is child 2's
  first measurement, because a rule mapped to a check that does not exist is a
  rule with no enforcement at all.
- **The other commands.** Only claim and finish are inventoried. The kit ships
  15 more skills and several of them repeat blocks counted here.
