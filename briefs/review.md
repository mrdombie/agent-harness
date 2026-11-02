**Sign-off comes last:** on a PR the owner has already signed, a finding that would change pixels becomes a follow-up ticket, not a fix here. Only a fix the PR cannot merge without (a red check, a Critical) changes them, with `pixel-change-after-signoff: <why>` in its commit, and the owner signs again.

# Step 5 · Review

Return a verdict on a finished change, with every finding behind it graded and
tagged. You edit nothing in this step.

## Run the reviewer — do not review from this file

You are one of several voters reviewing this change in separate sessions; a finding
stays only when at least 2 of you report it.

Invoke **`code-review`** through the Skill tool, with args `{{EFFORT}} {{TARGET}}`.
It owns how the review is conducted; this brief owns how its findings are graded,
tagged and handed back. Post nothing and fix nothing.

**Start no subagents.** Never call the Agent or Task tool, and never ask
`code-review` for a multi-agent pass. A review step's agent count is bounded and
configured, never left to a skill's top level: a voter whose transcript shows a
subagent of its own fails the step.

## What you are given

- The change: {{DIFF}}
- The renders of every screen it touches: {{RENDERS}}
- The round: {{ROUND}}
- This project: {{PROJECT_FACTS}}

## Report every finding; the vote decides what stays

Return every finding `code-review` reports, with its file and line. Add no `votes`:
the driver matches the voters' findings by file, nearby line and summary, keeps one
a majority reported, and gives it their most common grade (a tie goes lower).

Then tag every finding:

- `important`: a defect this change introduces or re-exposes.
- `nit`: style, naming, reuse, simplification, efficiency, altitude or any other
  cleanup. Grade it `nit`; it is dropped.
- `pre-existing`: a real defect in code this change did not introduce and does
  not re-expose. Grade it honestly; it never blocks and never goes back to the
  builder. The driver sends it to the nightly sweep.

**A class is flagged as a class.** When several findings are one mistake made in
several places, return ONE finding naming the mistake in `class` and every place in
`instances` (`file:line`), so the fix covers each one, not only the line you saw.

**Never raise a finding twice.** The change may list findings already raised on it;
do not return any of them again, reworded or not.

## Grade every finding

The grade and the round decide each finding's effect.

| Grade | What it means | What happens to it |
|---|---|---|
| `critical` | wrong data, a security hole, lost work, something published unapproved | goes back to the build step; fixed in this ticket |
| `major` | a person is misled or stuck: an untrue screen, a dead control, a failure shown as success | goes back to the build step; fixed in this ticket |
| `minor` | polish: spacing, wording, a small visual slip | round 1: goes back to the build step, fixed in this change. From round 2: goes on the screen's polish list for the next change there. Never filed as a ticket |
| `nit` | taste | dropped |

**A Critical or a Major names who is harmed and how, in the `reason`, in a user's
words.** "The button is not wired" is a claim about the code; "the person clicks
Save, sees it succeed, and the draft is gone" is the harm. A finding whose harm you
cannot write in one line is a Minor.

Grade honestly and return `BLOCKED` when a Minor is all there is: the driver, not
you, decides from the round whether it still blocks. Green checks are not a
verdict; they mean nothing already tested broke, not that the change is correct.

## The findings that keep reaching the trunk

Hold the change to these as extra angles:

- **A test that cannot fail**: one that reads a source file or asserts a string is
  in a file measures shape, not behaviour.
- **The same fact said twice, in two wordings**, across a masthead, band, chip,
  toast or rail. Copy never narrates a control.
- **A state changed on one surface of three.**
- **A failed read that looks empty, loading or finished.**
- **Contrast below AA on the rendered pixels**, in either theme: 4.5:1 body text,
  3:1 large text and a control's boundary.
- **The decision the screen asks for, buried** below the fold or a large preview.
- **A coloured edge rail** down the side of a card or row: banned here.

## Return

JSON only, valid against `schemas/review.json`.

<!-- fields:begin — generated from schemas/review.json by briefs/return-fields.sh --write review; edit the schema, never this list -->
Every field the contract has; `additionalProperties` is false, so no other.

- `step` (required): "review"
- `skills` (required): list of string
- `status` (required): one of "reviewed", "park"
- `round` (required): integer
- `verdict` (required): one of "SHIP", "BLOCKED"
- `panel`: object
- `panel.skill` (required): string
- `panel.effort` (required): one of "low", "medium", "high", "xhigh", "max"
- `panel.voters`: integer
- `panel.answered`: integer
- `findings` (required): list of object
- `findings[].id` (required): string
- `findings[].file` (required): string
- `findings[].line` (required): integer
- `findings[].grade` (required): one of "critical", "major", "minor", "nit"
- `findings[].tag`: one of "important", "nit", "pre-existing"
- `findings[].votes`: object
- `findings[].votes.agree` (required): integer
- `findings[].votes.of` (required): integer
- `findings[].class`: string
- `findings[].instances`: list of string
- `findings[].summary` (required): string
- `findings[].reason` (required): string
- `findings[].fix` (required): string
- `question`: string
- `questionKind`: one of "base-red", "uncommitted-fix", "already-fixed", "uat-data", "other"
- `questionFor`: one of "owner", "pm"
- `notes`: string

Conditional:
- when `verdict` is "SHIP": a further rule on `findings` (see the schema)
- when `verdict` is "BLOCKED": a further rule on `findings` (see the schema)
- when `panel` is present: a further rule on `findings` (see the schema)
<!-- fields:end -->

The verdict is read off the grades, never typed beside them: `SHIP` with a Critical
or a Major that is not `pre-existing`, and `BLOCKED` with none, are both refused.
Every finding carries its file, its line (0 when it is on no line of a file, such as
the pull request's body), its grade, its `tag`, the one-line `reason` in a user's
words, and the fix; a class adds `class` and `instances`. `panel` names the reviewer
you ran: `{"skill": "code-review", "effort": "{{EFFORT}}"}`; the driver adds the
number of voters.

A question names who answers it in `questionFor` (`owner`: pixels, product, data
model; `pm`: repo, split, order, acceptance; unsure is `owner`)
and its kind in `questionKind`. Never ask for UAT data: measure on the local seed.

`skills` lists every skill you invoked. The driver reads the run log too, so a
skill claimed here and absent there fails the step.
